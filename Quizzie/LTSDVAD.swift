//
//  LTSDVAD.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-09-10.
//


import Foundation
import Accelerate

/// LTSD VAD: robust against steady noise, keeps consonant onsets via hangover.
/// Input:  mono Float @ 16 kHz (configurable)
/// Output: same-length Float, with non-speech softly attenuated (no hard chops).
public final class LTSDVAD {

    // MARK: - Config
    public var sampleRate: Int
    public var frameLen: Int        // e.g. 512 (32 ms @ 16 kHz)
    public var hopLen: Int          // e.g. 128 (8 ms hop)
    public var ltsdOn: Float = 9.0  // dB to enter speech
    public var ltsdOff: Float = 6.0 // dB to leave speech
    public var hangoverFrames: Int = 6  // keep talking ~6*hop ≈ 48 ms after falling below off
    public var floorGain: Float = 0.08  // residual in non-speech (0..1)
    public var attack: Float = 0.25     // gain rise (smaller = faster attack)
    public var release: Float = 0.90    // gain fall (closer to 1 = slower release)

    // Noise adaptation (EMA on noise PSD)
    public var noiseAlphaQuiet: Float = 0.95
    public var noiseAlphaSpeech: Float = 0.995
    public var initNoiseFrames: Int = 40 // ~320 ms bootstrap

    // LTSE window (max across ±L frames)
    public var ltseRadius: Int = 2       // 2 → look at 5 frames total

    // MARK: - State
    private let log2n: vDSP_Length
    private let fft: FFTSetup
    private let bins: Int
    private let eps: Float = 1e-12

    private var window: [Float]
    private var winSum: [Float] = []

    private var noisePSD: [Float]
    private var haveNoise = false
    private var noiseBootCount = 0

    private var ring: [[Float]]
    private var ringPos = 0
    private var ringCount = 0

    private var prevGain: Float = 0
    private var hangCount = 0

    public init(sampleRate: Int = 16_000, frameLen: Int = 512, hopLen: Int = 128) {
        self.sampleRate = sampleRate
        self.frameLen = frameLen
        self.hopLen = hopLen

        self.bins = frameLen/2 + 1
        self.log2n = vDSP_Length(Int(round(log2(Double(frameLen)))))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("FFT setup failed")
        }
        self.fft = setup

        self.window = LTSDVAD.sqrtHann(frameLen)
        self.noisePSD = [Float](repeating: 1e-6, count: bins)
        self.ring = Array(repeating: [Float](repeating: 0, count: bins), count: 2*ltseRadius + 1)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    // MARK: - Public

    /// Soft-gates the input: same length out, speech preserved, non-speech attenuated.
    public func gate(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }

        var y = [Float](repeating: 0, count: x.count + frameLen)
        if winSum.count != y.count { winSum = [Float](repeating: 0, count: y.count) }

        var i = 0
        while i < x.count {
            // ----- frame (zero-pad) -----
            var frame = [Float](repeating: 0, count: frameLen)
            let m = min(frameLen, x.count - i)
            if m > 0 { frame.replaceSubrange(0..<m, with: x[i..<i+m]) }
            vDSP.multiply(frame, window, result: &frame)

            // ----- FFT → power spectrum -----
            let half = frameLen / 2
            var re = [Float](repeating: 0, count: half)
            var im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rPtr in
                im.withUnsafeMutableBufferPointer { iPtr in
                    var sc = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    frame.withUnsafeBufferPointer { inPtr in
                        inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cPtr in
                            vDSP_ctoz(cPtr, 2, &sc, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }

            // zrip layout → power[0..bins-1]
            var power = [Float](repeating: 0, count: bins)
            power[0]    = re[0]*re[0]                 // DC (imag[0] unused)
            power[half] = im[0]*im[0]                 // Nyquist in imag[0]
            if half > 1 {
                // bins 1..half-1
                for k in 1..<half {
                    let a = re[k], b = im[k]
                    power[k] = a*a + b*b
                }
            }

            // ----- LTSE (max across ±R frames) -----
            ring[ringPos] = power
            ringPos = (ringPos + 1) % ring.count
            ringCount = min(ringCount + 1, ring.count)
            var ltse = [Float](repeating: 0, count: bins)
            for r in 0..<ringCount {
                let idx = (ringPos + r) % ring.count
                vDSP.maximum(ltse, ring[idx], result: &ltse)
            }

            // ----- Noise update -----
            if !haveNoise {
                // Bootstrap noise with running min of first few frames (robust to speech)
                if noiseBootCount == 0 { noisePSD = power }
                else { noisePSD = vDSP.minimum(noisePSD, power) }
                noiseBootCount += 1
                if noiseBootCount >= initNoiseFrames { haveNoise = true }
            }

            // LTSD score (dB)
            var ratio = [Float](repeating: 0, count: bins)
            var denom = noisePSD
            vDSP.add(eps, denom, result: &denom)
            vDSP.divide(ltse, denom, result: &ratio)     // power ratio per bin
            let meanRatio: Float = vDSP.mean(ratio)
            let ltsdDB: Float = 10 * log10f(max(meanRatio, 1e-9 as Float))


            // Speech decision with hangover
            var speech = false
            if ltsdDB >= ltsdOn {
                speech = true
                hangCount = hangoverFrames
            } else if ltsdDB >= ltsdOff || hangCount > 0 {
                speech = true
                hangCount = max(0, hangCount - 1)
            }

            // Adaptive noise tracking
            let alpha: Float = speech ? noiseAlphaSpeech : noiseAlphaQuiet
            let oneMinusAlpha: Float = 1 - alpha

            // noise = alpha*noise + (1 - alpha)*power
            vDSP.multiply(alpha, noisePSD, result: &noisePSD)
            var inc = power
            vDSP.multiply(oneMinusAlpha, inc, result: &inc)
            vDSP.add(noisePSD, inc, result: &noisePSD)

            // Soft probability from LTSD (smoothstep between off→on)
            let t = clamp((ltsdDB - ltsdOff) / max(0.001, (ltsdOn - ltsdOff)), 0, 1)
            let p = t*t*(3 - 2*t)  // 0..1

            // Frame gain with attack/release smoothing + floor
            let target = floorGain + (1 - floorGain) * max(p, speech ? 0.8 : p)
            let a = (target > prevGain) ? attack : release
            let g = a*prevGain + (1 - a)*target
            prevGain = g

            // Apply gain in time domain (windowed) and overlap-add
            if g < 0.999 || g > 1.001 {
                var gg = [Float](repeating: g, count: frameLen)
                vDSP.multiply(gg, frame, result: &frame)
            }
            if y.count < i + frameLen {
                y.append(contentsOf: repeatElement(0, count: (i + frameLen) - y.count))
                winSum.append(contentsOf: repeatElement(0, count: (i + frameLen) - winSum.count))
            }
            for k in 0..<frameLen {
                y[i + k]    += frame[k]
                winSum[i+k] += window[k]
            }

            i += hopLen
        }

        // Normalize by window sum
        var out = [Float](repeating: 0, count: x.count)
        for k in 0..<x.count {
            let w = max(winSum[k], 1e-9)
            out[k] = y[k] / w
        }
        return out
    }

    public func reset() {
        noisePSD = [Float](repeating: 1e-6, count: bins)
        haveNoise = false; noiseBootCount = 0
        ring = Array(repeating: [Float](repeating: 0, count: bins), count: 2*ltseRadius + 1)
        ringPos = 0; ringCount = 0
        prevGain = 0; hangCount = 0
    }

    // MARK: - Helpers
    private static func sqrtHann(_ N: Int) -> [Float] {
        guard N > 1 else { return [1] }
        var w = [Float](repeating: 0, count: N)
        let twoPi = Float.pi * 2
        for n in 0..<N {
            let hann = 0.5 * (1 - cos(twoPi * Float(n) / Float(N - 1)))
            w[n] = sqrt(Float(hann))
        }
        return w
    }
    @inline(__always) private func clamp(_ x: Float, _ a: Float, _ b: Float) -> Float { max(a, min(b, x)) }
}
