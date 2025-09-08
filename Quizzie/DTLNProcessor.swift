//
//  DTLNProcessor.swift  — minimal, single-model (stage-1) denoiser
//
//  Requirements:
//    - Input: mono Float32 @ 16 kHz
//    - Model: DTLN stage-1 (model_1.tflite, float32)
//    - Frames: 512 (32 ms), hop: 128 (8 ms), sqrt-Hann windows
//

import Foundation
import Accelerate          // vDSP FFT (classic API)
import TensorFlowLite      // TensorFlowLiteSwift (Pod or SPM)

//
//  DTLNProcessor.swift — minimal stage-1 DTLN denoiser
//  Input:  mono Float32 @ 16 kHz
//  Frames: 512 (32 ms), hop: 128 (8 ms), sqrt-Hann windows
//

import Foundation
import Accelerate          // vDSP FFT (classic API)
import TensorFlowLite      // TensorFlowLiteSwift (Pod or SPM)

public final class DTLNProcessor {

    // MARK: - Public config

    public enum FeatureDomain { case log, linear }

    /// Choose the feature domain that matches your model training.
    public let featureDomain: FeatureDomain

    /// Clamp scale to avoid wild gains when input magnitude is tiny.
    public var scaleClamp: ClosedRange<Float> = 0.0...4.0

    // MARK: - STFT constants

    private let frameLen = 512                  // 32 ms @ 16k
    private let hopLen   = 128                  // 8 ms (75% overlap)
    private let bins     = 257                  // frameLen/2 + 1
    private let eps: Float = 1e-8

    // MARK: - TFLite

    private let net: Interpreter
    private var stateInputIdxs: [Int] = []      // indices of RNN state inputs
    private var stateOutputIdxs: [Int] = []     // matching outputs
    private var stateBlobs: [Data] = []         // persisted across frames

    // Input-0 shape handling
    private var in0ElementCount = 257
    private enum FeatMode { case currentOnly, prevAndCurrent }
    private var featMode: FeatMode = .currentOnly

    // MARK: - FFT (classic vDSP)

    private let log2n: vDSP_Length = 9          // log2(512)
    private let fft: FFTSetup

    // MARK: - Windows & previous frame context

    private let anaWin: [Float]
    private let synWin: [Float]

    private var prevLogMag: [Float]
    private var prevMag:    [Float]
    
    public var maskFloor: Float = 0.15   // avoid killing speech formants
    public var wet: Float = 0.85         // 0..1, amount of denoised signal
    public var maskSmoothing: Float = 0.85  // EMA in time
    private var prevMask = [Float](repeating: 1.0, count: 257)

    // MARK: - Init

    public init(modelURL: URL,
                threads: Int = 2,
                featureDomain: FeatureDomain = .log) throws
    {
        self.featureDomain = featureDomain

        // --- TFLite
        var opts = Interpreter.Options()
        opts.threadCount = max(1, threads)
        net = try Interpreter(modelPath: modelURL.path, options: opts)
        try net.allocateTensors()
        
        // --- DEBUG: model introspection (print once)
        do {
            func shapeStr(_ dims: [Int]) -> String { "[" + dims.map(String.init).joined(separator: ",") + "]" }

            print("DTLN ▶︎ inputs:", net.inputTensorCount, "outputs:", net.outputTensorCount)

            for i in 0..<net.inputTensorCount {
                let t = try net.input(at: i)
                print("DTLN ▶︎ in[\(i)] shape:", shapeStr(t.shape.dimensions), "type:", t.dataType)
            }
            for i in 0..<net.outputTensorCount {
                let t = try net.output(at: i)
                print("DTLN ▶︎ out[\(i)] shape:", shapeStr(t.shape.dimensions), "type:", t.dataType)
            }

            print("DTLN ▶︎ in0ElementCount:", in0ElementCount,
                  "featMode:", featMode == .prevAndCurrent ? "prev+cur" : "currentOnly",
                  "featureDomain:", featureDomain == .log ? "log" : "linear")
        } catch {
            print("DTLN ▶︎ introspection error:", error)
        }


        // Discover input-0 shape and choose feature mode
        let in0 = try net.input(at: 0)
        let dims = in0.shape.dimensions           // e.g. [1,257] or [1,257,2]
        in0ElementCount = max(1, dims.reduce(1, *))
        if in0ElementCount == 257 {
            featMode = .currentOnly
        } else if in0ElementCount == 257 * 2 {
            featMode = .prevAndCurrent
        } else {
            // Unusual export; default to current-only (we’ll resize as a safety net)
            featMode = .currentOnly
        }

        // RNN states (if any): all inputs after index 0, and outputs after index 0
        if net.inputTensorCount > 1 {
            for i in 1..<net.inputTensorCount {
                let shape = try net.input(at: i).shape.dimensions
                let count = max(1, shape.reduce(1, *))
                stateInputIdxs.append(i)
                stateBlobs.append(Data(count: count * MemoryLayout<Float>.size)) // zero-init
            }
        }
        if net.outputTensorCount > 1 {
            for i in 1..<net.outputTensorCount { stateOutputIdxs.append(i) }
        }

        // --- FFT + windows
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "DTLN", code: -1, userInfo: [NSLocalizedDescriptionKey: "FFT setup failed"])
        }
        fft = setup

        var hann = [Float](repeating: 0, count: frameLen)
        vDSP_hann_window(&hann, vDSP_Length(frameLen), Int32(vDSP_HANN_NORM))
        anaWin = hann.map { sqrt($0) }            // sqrt-Hann pair
        synWin = anaWin

        prevLogMag = Array(repeating: -6.0, count: bins) // ~log(1e-3)
        prevMag    = Array(repeating: 1e-3, count: bins)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    // MARK: - API

    /// Process mono Float32 @ 16 kHz; returns denoised samples of the same length.
    public func process(_ x: [Float]) throws -> [Float] {
        guard !x.isEmpty else { return x }

        var y = [Float](repeating: 0, count: x.count + frameLen) // OLA tail room
        var writeIndex = 0

        var i = 0
        while i < x.count {
            // 1) Gather one 512-sample frame (zero-padded at tail)
            var frame = [Float](repeating: 0, count: frameLen)
            let n = min(frameLen, x.count - i)
            if n > 0 { frame.replaceSubrange(0..<n, with: x[i..<i+n]) }

            // 2) Analysis window
            vDSP.multiply(frame, anaWin, result: &frame)

            // 3) Forward real FFT (zrip)
            let half = frameLen / 2
            var real = [Float](repeating: 0, count: half)
            var imag = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { rPtr in
                imag.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    frame.withUnsafeBufferPointer { inPtr in
                        inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cPtr in
                            vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }

            // 4) Magnitude (257 bins)
            var mag = [Float](repeating: 0, count: bins)
            mag[0]       = abs(real[0])   // DC
            mag[half]    = abs(imag[0])   // Nyquist
            if half > 1 {
                var re = Array(real[1..<half])
                var im = Array(imag[1..<half])
                var out = [Float](repeating: 0, count: half - 1)
                vDSP.hypot(re, im, result: &out)
                mag.replaceSubrange(1..<half, with: out)
            }
            let logMag = mag.map { log(max($0, 1e-3)) }  // keep “log” (natural log) as you had

            // 5) Build features to match model input-0
            var feats: [Float]
            switch (featureDomain, featMode) {
            case (.log, .currentOnly):
                let logMag = mag.map { log(max($0, 1e-3)) }
                feats = Array(logMag.prefix(bins))
            case (.log, .prevAndCurrent):
                let logMag = mag.map { log(max($0, 1e-3)) }
                feats = .init(); feats.reserveCapacity(bins * 2)
                for k in 0..<bins { feats.append(prevLogMag[k]); feats.append(logMag[k]) }
            case (.linear, .currentOnly):
                feats = Array(mag.prefix(bins))
            case (.linear, .prevAndCurrent):
                feats = .init(); feats.reserveCapacity(bins * 2)
                for k in 0..<bins { feats.append(prevMag[k]); feats.append(mag[k]) }
            }
            if feats.count != in0ElementCount {
                feats = resampleLinear(feats, toCount: in0ElementCount) // safety net
            }
            
            // --- DEBUG: feature stats (first few frames or when weird)
            @inline(__always) func stats(_ a: [Float]) -> (min: Float, mean: Float, max: Float) {
                guard !a.isEmpty else { return (0,0,0) }
                let mn = a.min() ?? 0
                let mx = a.max() ?? 0
                let mean = a.reduce(0, +) / Float(a.count)
                return (mn, mean, mx)
            }
            let fStats = stats(feats)
            print("DTLN ▶︎ feats count:", feats.count, "min/mean/max:", fStats)
            

            // 6) TFLite: copy input-0 + states (if any), run
            try net.copy(feats.asData, toInputAt: 0)
            for (j, idx) in stateInputIdxs.enumerated() { try net.copy(stateBlobs[j], toInputAt: idx) }
            try net.invoke()

            // 7a) Read output-0 (mask or enhanced magnitude) → 257 bins
            var out0 = try net.output(at: 0).data.toArray(of: Float.self)
            if out0.count == bins * 2 { out0 = Array(out0.suffix(bins)) }  // take "current" column
            if out0.count != bins { out0 = resampleLinear(out0, toCount: bins) }
            
            let oStats = stats(out0)
            let looksLikeMask = (oStats.max <= 1.25 && oStats.min >= -0.1)
            print("DTLN ▶︎ out0 min/mean/max:", oStats, "maskGuess:", looksLikeMask ? "MASK" : "ENH-MAG")

            // Update states
            for (j, idx) in stateOutputIdxs.enumerated() { stateBlobs[j] = try net.output(at: idx).data }

            // 7b) Build a friendly mask: clamp, mix residual, smooth in time
            var mask = out0
            let a = maskSmoothing
            let w = wet
            for k in 0..<bins {
                // clamp to [maskFloor, 1]
                var m = min(max(mask[k], maskFloor), 1.0)
                // residual mix in the spectral domain: (1-w) * original + w * mask
                // equivalently: scale = (1 - w) + w * m
                m = (1.0 - w) + w * m
                // EMA smoothing over time
                let sm = a * prevMask[k] + (1.0 - a) * m
                prevMask[k] = sm
                mask[k] = sm
            }

            // 8) Apply to split-complex spectrum (zrip layout)
            real[0] *= mask[0]          // DC
            imag[0] *= mask[half]       // Nyquist
            if half > 1 {
                for k in 1..<half {
                    real[k] *= mask[k]
                    imag[k] *= mask[k]
                }
            }
            // 8) Decide how to apply output
            //    If it looks like a mask ([0,1]), multiply spectrum by mask.
            //    Else treat as enhanced magnitude in the same domain as features.
            let oMin = out0.min() ?? 0, oMax = out0.max() ?? 0

            var scale = [Float](repeating: 1, count: bins)
            if looksLikeMask {
                // Mask → clamp to [0,1] and multiply
                scale = out0.map { max(0, min($0, 1)) }
            } else {
                // Enhanced magnitude
                var targetMag: [Float]
                switch featureDomain {
                case .log:
                    // If model emits enhanced log-magnitude, map back to linear
                    targetMag = out0.map { exp($0) }
                case .linear:
                    targetMag = out0
                }
                var denom = mag; vDSP.add(eps, denom, result: &denom)
                vDSP.divide(targetMag, denom, result: &scale)   // scale = target / mag
                // Safety clamp
                for i in 0..<scale.count { scale[i] = min(max(scale[i], scaleClamp.lowerBound), scaleClamp.upperBound) }
            }

            // Apply scale to split-complex (zrip: DC at real[0], Nyquist at imag[0])
            real[0] *= scale[0]
            imag[0] *= scale[bins - 1]
            if bins > 2 {
                for k in 1..<(bins - 1) {
                    real[k] *= scale[k]
                    imag[k] *= scale[k]
                }
            }
            
            // --- DEBUG: scale sanity
            let bad = scale.first(where: { !$0.isFinite }) != nil
            let sStats = stats(scale)
            let clampLo = scale.filter { $0 <= scaleClamp.lowerBound + 1e-6 }.count
            let clampHi = scale.filter { $0 >= scaleClamp.upperBound - 1e-6 }.count
            print("DTLN ▶︎ scale min/mean/max:", sStats, "NaN/Inf:", bad, "clampLo:", clampLo, "clampHi:", clampHi)

            // 9) Inverse FFT → time, then scale by 1/(2*N) and window
            var time = [Float](repeating: 0, count: frameLen)
            real.withUnsafeMutableBufferPointer { rPtr in
                imag.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    time.withUnsafeMutableBufferPointer { tPtr in
                        tPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cPtr in
                            vDSP_ztoc(&split, 1, cPtr, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            // 👇 this was 1.0 / Float(frameLen) before; use 1/(2*N)
            var invScale: Float = 1.0 / Float(2 * frameLen)
            vDSP_vsmul(time, 1, &invScale, &time, 1, vDSP_Length(frameLen))

            // synthesis window
            vDSP.multiply(time, synWin, result: &time)

            // 10) Overlap-add
            if y.count < writeIndex + frameLen { y.append(contentsOf: repeatElement(0, count: writeIndex + frameLen - y.count)) }
            for t in 0..<frameLen { y[writeIndex + t] += time[t] }

            // 11) Next hop + remember previous features
            switch featureDomain {
            case .log:    prevLogMag = mag.map { log(max($0, 1e-3)) }
            case .linear: prevMag    = mag
            }
            writeIndex += hopLen
            i += hopLen
        }

        return Array(y.prefix(x.count))
    }

    /// Optional: clear the RNN states (e.g., when starting a new clip)
    public func resetStates() {
        for idx in 0..<stateBlobs.count {
            stateBlobs[idx].resetBytes(in: 0..<stateBlobs[idx].count)
        }
        prevLogMag = Array(repeating: -6.0, count: bins)
        prevMag    = Array(repeating: 1e-3, count: bins)
    }

    // MARK: - Helpers

    private func resampleLinear(_ x: [Float], toCount m: Int) -> [Float] {
        let n = x.count
        guard n > 1, m > 1 else { return Array(repeating: x.first ?? 0, count: m) }
        var out = [Float](repeating: 0, count: m)
        let scale = Float(n - 1) / Float(m - 1)
        for j in 0..<m {
            let t = Float(j) * scale
            let i0 = Int(t)
            let frac = t - Float(i0)
            let i1 = min(i0 + 1, n - 1)
            out[j] = x[i0] + (x[i1] - x[i0]) * frac
        }
        return out
    }
}

// MARK: - Data/Array bridges

private extension Data {
    func toArray<T>(of: T.Type) -> [T] {
        withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }
}
private extension Array where Element == Float {
    var asData: Data { withUnsafeBufferPointer { Data(buffer: $0) } }
}


func normalizeRMS(_ x: [Float],
                  targetRMS: Float = 0.04,  // ≈ -28 dBFS
                  peakCeiling: Float = 0.98) -> [Float] {
    guard !x.isEmpty else { return x }
    var m2: Float = 0
    vDSP_measqv(x, 1, &m2, vDSP_Length(x.count))   // mean square
    let rms = sqrt(m2)
    if rms < 1e-8 { return x }
    let peak = max(abs(x.max() ?? 0), abs(x.min() ?? 0))
    let gainByRMS  = targetRMS / rms
    let gainByPeak = peak > 0 ? peakCeiling / peak : .greatestFiniteMagnitude
    let gain = min(gainByRMS, gainByPeak)
    var y = [Float](repeating: 0, count: x.count)
    vDSP_vsmul(x, 1, [gain], &y, 1, vDSP_Length(x.count))
    return y
}

@inline(__always)
func rms(_ x: [Float]) -> Float {
    guard !x.isEmpty else { return 0 }
    var meanSquare: Float = 0
    vDSP_measqv(x, 1, &meanSquare, vDSP_Length(x.count))  // mean of squares
    return sqrt(meanSquare)
}
