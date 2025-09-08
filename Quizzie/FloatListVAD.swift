//
//  FloatListVAD.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-09-10.
//


import Foundation

/// Minimal, dependency-free energy VAD for Float arrays (mono).
/// Assumes 16 kHz by default; customize frame/hop as needed.
/// gate(_:) -> same-length signal where non-speech is attenuated
/// stripSilence(_:) -> concatenated speech only (with optional padding)
public final class FloatListVAD {

    // MARK: - Tunables
    public var sampleRate: Int
    public var frameLen: Int      // e.g. 512 (32 ms @ 16 kHz)
    public var hopLen: Int        // e.g. 128 (8 ms hop, 75% overlap)
    public var startDeltaDB: Float = 8      // dB over noise to enter speech
    public var stopDeltaDB:  Float = 2      // dB over noise to exit speech
    public var gateSmoothing: Float = 0.85  // EMA over frame decisions (0..1)
    public var noiseAlphaQuiet: Float = 0.97   // noise floor EMA when quiet
    public var noiseAlphaSpeech: Float = 0.995 // slow adapt during speech
    public var minNoiseDB: Float = -70
    public var maxNoiseDB: Float = -20
    public var floorGain: Float = 0.0       // residual in non-speech (0..1)

    // MARK: - State
    private var noiseDB: Float = -60
    private var prevGate: Float = 0

    // sqrt-Hann window for COLA with 75% overlap
    private var win: [Float] = []

    public init(sampleRate: Int = 16_000, frameLen: Int = 512, hopLen: Int = 128) {
        self.sampleRate = sampleRate
        self.frameLen = frameLen
        self.hopLen = hopLen
        self.win = FloatListVAD.sqrtHann(frameLen)
    }

    // MARK: - Public API

    /// Gate the signal in-place (same length) using soft VAD.
    public func gate(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }

        let n = x.count
        var y = [Float](repeating: 0, count: n + frameLen)   // OLA tail
        var wsum = [Float](repeating: 0, count: n + frameLen)

        var i = 0
        while i < n {
            // 1) take frame (zero-pad at tail)
            var frame = [Float](repeating: 0, count: frameLen)
            let m = min(frameLen, n - i)
            if m > 0 { frame.replaceSubrange(0..<m, with: x[i..<i + m]) }

            // 2) window
            for k in 0..<frameLen { frame[k] *= win[k] }

            // 3) frame energy -> dB
            let r = FloatListVAD.rms(frame)
            let db = 20 * log10(max(r, 1e-6))

            // 4) update noise floor (different EMA in/near speech)
            let delta = db - noiseDB
            let p = softSpeechProb(delta: delta,
                                   startDelta: startDeltaDB,
                                   stopDelta:  stopDeltaDB)
            let alpha = p < 0.3 ? noiseAlphaQuiet : noiseAlphaSpeech
            noiseDB = clamp(alpha * noiseDB + (1 - alpha) * db, minNoiseDB, maxNoiseDB)

            // 5) smooth gate over time (EMA)
            let g = gateSmoothing * prevGate + (1 - gateSmoothing) * p
            prevGate = g

            // 6) apply soft gate: scale between floorGain..1
            let gain = floorGain + (1 - floorGain) * g
            if gain < 0.999 || gain > 1.001 {
                for k in 0..<frameLen { frame[k] *= gain }
            }

            // 7) overlap-add + weight sum for perfect reconstruction
            if y.count < i + frameLen {
                y.append(contentsOf: repeatElement(0, count: (i + frameLen) - y.count))
                wsum.append(contentsOf: repeatElement(0, count: (i + frameLen) - wsum.count))
            }
            for k in 0..<frameLen {
                y[i + k]    += frame[k]
                wsum[i + k] += win[k]
            }

            i += hopLen
        }

        // 8) normalize by window sum
        var out = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let w = max(wsum[k], 1e-9)
            out[k] = y[k] / w
        }
        return out
    }

    /// Return only speech samples concatenated together.
    /// keepPaddingMs keeps a bit of context before/after detected speech.
    public func stripSilence(_ x: [Float], keepPaddingMs: Int = 160) -> [Float] {
        guard !x.isEmpty else { return x }
        let pad = Int((Float(keepPaddingMs) / 1000.0) * Float(sampleRate))
        var keep = [Bool](repeating: false, count: x.count)

        var i = 0
        var lastSpeechEnd = -1
        while i < x.count {
            let m = min(frameLen, x.count - i)
            var frame = [Float](repeating: 0, count: frameLen)
            if m > 0 { frame.replaceSubrange(0..<m, with: x[i..<i + m]) }
            for k in 0..<frameLen { frame[k] *= win[k] }
            let r = FloatListVAD.rms(frame)
            let db = 20 * log10(max(r, 1e-6))

            let delta = db - noiseDB
            let p = softSpeechProb(delta: delta,
                                   startDelta: startDeltaDB,
                                   stopDelta:  stopDeltaDB)
            // noise update (same logic as gate)
            let alpha = p < 0.3 ? noiseAlphaQuiet : noiseAlphaSpeech
            noiseDB = clamp(alpha * noiseDB + (1 - alpha) * db, minNoiseDB, maxNoiseDB)

            let g = gateSmoothing * prevGate + (1 - gateSmoothing) * p
            prevGate = g

            if g >= 0.5 {
                let start = max(0, i - pad)
                let end   = min(x.count, i + m + pad)
                for idx in start..<end { keep[idx] = true }
                lastSpeechEnd = end
            } else if lastSpeechEnd >= 0 {
                // extend trailing pad if we're just after speech
                let end = min(x.count, lastSpeechEnd + pad)
                for idx in lastSpeechEnd..<end { keep[idx] = true }
            }

            i += hopLen
        }

        // collect kept samples
        var y: [Float] = []
        y.reserveCapacity(x.count)
        for (s, k) in zip(x, keep) where k { y.append(s) }
        return y
    }

    // MARK: - Helpers

    private static func rms(_ a: [Float]) -> Float {
        if a.isEmpty { return 0 }
        var s: Float = 0
        // only over non-zero padded region would be ideal, but negligible for speed
        for v in a { s += v * v }
        return sqrt(s / Float(a.count))
    }

    private func softSpeechProb(delta: Float, startDelta: Float, stopDelta: Float) -> Float {
        // Smoothstep from stopDelta (0) to startDelta (1)
        let t = clamp((delta - stopDelta) / max(1e-6, (startDelta - stopDelta)), 0, 1)
        return t * t * (3 - 2 * t)
    }

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

    private func clamp(_ x: Float, _ a: Float, _ b: Float) -> Float { max(a, min(b, x)) }
}