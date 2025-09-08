//
//  FramesReader.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-09-05.
//

import AVFoundation

final class FramesReader {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    // input to FramesReader = 16 kHz, mono, Float32
    private let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000,
                                      channels: 1,
                                      interleaved: false)!
    private let mixFmt: AVAudioFormat
    private let converter: AVAudioConverter

    init() throws {
        // Use current audio session (Mic already set .playAndRecord / .voiceChat)
        engine.attach(player)
        let m = engine.mainMixerNode
        mixFmt = m.outputFormat(forBus: 0)              // device mix format
        converter = AVAudioConverter(from: inFmt, to: mixFmt)!
        engine.connect(player, to: m, format: mixFmt)
        try engine.start()
        player.play()
    }

    func enqueue(_ frames: [Float]) {
        guard !frames.isEmpty else { return }

        // Build input buffer at 16 kHz mono
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(frames.count))!
        inBuf.frameLength = AVAudioFrameCount(frames.count)
        frames.withUnsafeBufferPointer { src in
            inBuf.floatChannelData!.pointee.assign(from: src.baseAddress!, count: frames.count)
        }

        // Convert to the mixer’s format (e.g., 24k/48k, 1–2 ch)
        let ratio = mixFmt.sampleRate / inFmt.sampleRate
        let outCap = AVAudioFrameCount(Double(frames.count) * ratio + 1024)
        let outBuf = AVAudioPCMBuffer(pcmFormat: mixFmt, frameCapacity: outCap)!
        outBuf.frameLength = 0

        var provided = false
        _ = converter.convert(to: outBuf, error: nil) { _, st in
            if !provided {
                provided = true
                st.pointee = .haveData
                return inBuf
            } else {
                st.pointee = .endOfStream
                return nil
            }
        }

        if outBuf.frameLength > 0 {
            player.scheduleBuffer(outBuf, completionHandler: nil)
        }
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
