//
//  LiveWhisper.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-09-02.
//
import AVFoundation


/// Captures microphone audio, converts it to 16 kHz mono Float32 (for Whisper),
/// buffers it in a simple ring buffer, and can also **play back** 16 kHz chunks
/// through the same AVAudioEngine.
///
/// Design notes:
/// - Uses a single AVAudioEngine for both capture and playback to avoid issues
///   with voice-processing audio sessions.
/// - Input is captured at the hardware sample rate (e.g. 24k / 48k), then
///   converted → 16 kHz mono Float32 for Whisper.
/// - Playback accepts 16 kHz mono Float32 and converts it to the device's mix format.

final class MicPCM16k {
    /// Single engine for I/O (capture + playback)
    private let engine = AVAudioEngine()
    
    /// Converter for input: input format (device) → 16 kHz mono Float32 (outFmt)
    private var converter: AVAudioConverter?
    
    /// Target audio format for Whisper (16 kHz mono Float32).
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000,
                                       channels: 1,
                                       interleaved: false)!
    
    
    private let VAD = FloatListVAD();
    private let VAD2 = LTSDVAD(sampleRate: 16_000, frameLen: 512, hopLen: 128);
    

    
    /// Buffer format used to feed the input→outFmt converter.
    /// IMPORTANT: This must be compatible with `converter`'s **input** format.
    /// If the mic is stereo, either set this to the actual input format,
    /// or rebuild `converter` to accept a forced-mono format.
    private var inFmtMono: AVAudioFormat!
    
    // Playback node and converter: outFmt (16 kHz mono) → device mix format
    private let player = AVAudioPlayerNode()
    
    /// The device's mixer/output format (e.g. 24k/48k, typically 2 channels).
    private var mixFmt: AVAudioFormat?
    
    /// Current input sample rate (from the mic's input format).
    private var inputSR: Double = 0
    
    /// UI callback reporting a smoothed input level [0,1].
    var onLevel: ((Float) -> Void)?
    
    var silenceRMS: Float = 0.0027     // tweak 0.002–0.005 depending on room
    private let minSilenceMs: Double = 120.0   // how long a “silence” must be
    private let winMs: Double = 20.0           // RMS window for scanning
    
    // ===== Ring buffer (holds **raw input-SR** mono samples) =====
    // We push channel 0 samples from the mic tap into this buffer.
    private var rb: [Float] = []     // mono @ input sample rate
    private var r = 0, w = 0, filled = 0
    private var rbCap = 0
    
    /// Approximate chunk size if you popped directly at 16 kHz (kept for reference).
    /// We now pop based on `inputSR` to get ~2 seconds at the real input SR.
    var chunkFrames = 32_000
    
    
    var  softMuted = false
    
    var playing = false;
    
    var DTLN : DTLNProcessor
    
    init() {
        let m1 = Bundle.main.url(forResource: "model_1", withExtension: "tflite")!
        let m2 = Bundle.main.url(forResource: "model_2", withExtension: "tflite")!
       
        DTLN = try! DTLNProcessor(modelURL: m1);
    }
    
    
    /// Starts microphone capture and sets up playback on the same engine.
    /// - Throws: if the AVAudioSession or engine fail to configure/start.
    func start() throws {
        

        
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.handleRouteChange()
        }
        
        // Configure audio session for duplex I/O with voice processing.
        // `.voiceChat` gives AEC/AGC/NS; if you hear oddities, try `.measurement`.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        
        // Input format (device/hardware format).
        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else {
            print("No mic input (simulator?)")
            return
        }
        
        // Initialize ring buffer capacity (~2 seconds at input SR).
        // TIP: For more robustness, consider 10× (e.g. *10) to survive hiccups.
        inputSR = inFmt.sampleRate
        rbCap = Int(inputSR * 10)
        rb = [Float](repeating: 0, count: rbCap)
        r = 0; w = 0; filled = 0
        
        // Buffer format used when chunking into the converter.
        // Here we **force mono** at the same sample rate as input.
        // ⚠️ GOTCHA: If the mic is stereo, either:
        //    1) set `inFmtMono = inFmt` (no force-mono), OR
        //    2) rebuild `converter = AVAudioConverter(from: inFmtMono, to: outFmt)`
        // to keep formats consistent. Input channels mismatching the converter
        // input will produce empty output.
        inFmtMono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: inputSR,
                                  channels: 1,
                                  interleaved: false)!
        
        // Converter for input: device format → 16 kHz mono Float32.
        // NOTE: `inFmtMono` below must be compatible with this converter's input.
        converter = AVAudioConverter(from: inFmtMono, to: outFmt)
        
        // Before installing the tap
        let fmt = engine.inputNode.inputFormat(forBus: 0)
        
        // Remove any previous tap before installing a new one.
        input.removeTap(onBus: 0)
        
        // ===== Playback wiring on the SAME engine =====
        engine.attach(player)
        let mixer = engine.mainMixerNode
        engine.connect(player, to: mixer, format: outFmt) // <-- outFmt, not mfmt
        self.mixFmt = mixer.outputFormat(forBus: 0)
        
        // Debug prints (helpful when validating formats on device)
        let s = AVAudioSession.sharedInstance()
        print("Session sampleRate:", s.sampleRate)
        print("Input channels:", fmt.channelCount)   // 1 = mono, 2 = stereo
        
        
        // ===== Mic tap: capture float data from channel 0 and push to ring buffer =====
        input.installTap(onBus: 0, bufferSize: 256, format: inFmt) { [weak self] buf, _ in
            guard let self else { return }
            
            // Level metering for UI (done on main queue to update SwiftUI state).
            if let ch = buf.floatChannelData {
                let n = Int(buf.frameLength)
                DispatchQueue.main.async { 
                    let norm = self.computeLevel(frameLength: n, p: ch[0])
                    self.onLevel?(norm)
                }
                
                // Push mic channel 0 samples to the ring buffer (mono @ input SR).
                self.rbPush(ch[0], count: n)
            }
            
        }
        
        player.volume = 1.0                          // 0..1 (max)
        engine.mainMixerNode.outputVolume = 1.0      // also 0..1
        
        // Start engine and playback node.
        engine.prepare()
        try engine.start()
        player.play()
        
        /*
        // after start(), grab 1s and compute noise RMS
        let noise = rbPopUpTo(Int(inputSR * 1))
        let noiseRMS = sqrt(noise.reduce(0){ $0 + $1*$1 } / Float(max(1, noise.count)))
        let silenceRMS = max(Float(2.5)*noiseRMS, 0.0015) // 2–3× noise floor
        if (silenceRMS < self.silenceRMS){
            self.silenceRMS = silenceRMS;
        }
         */
    }
    
    /// Computes a normalized audio level [0,1] from an audio buffer for UI animation.
    private func computeLevel(frameLength: Int, p: UnsafeMutablePointer<Float>) -> Float {
        let n = frameLength
        var sum: Float = 0
        for i in 0..<n { let v = p[i]; sum += v*v }
        let rms = sqrt(sum / Float(max(1, n)))
        let db = 20 * log10(max(rms, 1e-7))
        let norm = max(0, min(1, (db + 50) / 50))
        return norm
    }
    
    /// Stops capture/playback and deactivates the audio session.
    func stop(flush: Bool = true) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        player.stop()   
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    func softMute(){
        softMuted = true;
    }
    func softUnmute(){
        softMuted = false;
    }
    

    
    /// Plays a chunk of **16 kHz mono Float32** (the same format `getChunk()` returns).
    /// Internally converts to the device's mixer format and schedules it on `player`.
    
    
    func play16kAndWait(_ frames: [Float], gainDB: Float = 15) async {
        guard !frames.isEmpty else { return }
        print("[repeating_input] 🔊 ) ) ) ) ) frames=" + String(frames.count))
        playing = true;
        // (optional) mute mic so you don't re-record TTS
        softMuted = true
        let g = pow(10, gainDB/20)
        
             // e.g. +6 dB => 1.995
        // build 16 kHz mono buffer
        var f = frames
        for i in f.indices { f[i] *= g }

        let buf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(f.count))!
        buf.frameLength = AVAudioFrameCount(f.count)
        f.withUnsafeBufferPointer { src in
            buf.floatChannelData!.pointee.assign(from: src.baseAddress!, count: f.count)
        }

        // ensure engine is running
        if !engine.isRunning { try? engine.start() }
        player.play() // idempotent

        // suspend until playback finishes
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buf) {
                cont.resume()
            }
        }
        playing = false
        softMuted = false
    }

    
    /// Converts raw **input-SR mono** frames → **16 kHz mono Float32**.
    /// - Parameter raw: Mono frames at the current input sample rate.
    /// - Returns: 16 kHz mono Float32 frames suitable for Whisper.
    private func transform(_ raw: [Float]) -> [Float] {
        guard !raw.isEmpty else { return [] }
        guard let conv = converter, let inFmtMono = inFmtMono else {
            // already 16k mono (HFP) – passthrough
            return raw
        }
        
        let converter = AVAudioConverter(from: inFmtMono, to: outFmt)!

        // Build input buffer (mono @ input SR)
        let inCount = raw.count
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFmtMono, frameCapacity: AVAudioFrameCount(inCount))!
        inBuf.frameLength = AVAudioFrameCount(inCount)
        raw.withUnsafeBufferPointer { src in
            inBuf.floatChannelData!.pointee.assign(from: src.baseAddress!, count: inCount)
        }

        // Output buffer sized for the worst case (and some headroom)
        let ratio  = outFmt.sampleRate / inFmtMono.sampleRate          // e.g. 16000/48000 = 0.333...
        let expect = max(1, Int(Double(inCount) * ratio))
        let outCap = AVAudioFrameCount(max(expect + 4096, 8192))       // >= expected, with headroom
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)!

        var provided = false
        var result: [Float] = []

        while true {
            outBuf.frameLength = 0
            let status = converter.convert(to: outBuf, error: nil) { _, ioStatus in
                if !provided {
                    provided = true
                    ioStatus.pointee = .haveData
                    return inBuf
                } else {
                    ioStatus.pointee = .endOfStream
                    return nil
                }
            }

            let nOut = Int(outBuf.frameLength)
            if nOut > 0, let p = outBuf.floatChannelData?.pointee {
                result.append(contentsOf: UnsafeBufferPointer(start: p, count: nOut))
            }

            if status != .haveData { break }  // done (endOfStream / inputRanDry / error)
        }

        return result
    }
 
    
    // MARK: - Ring buffer (SPSC)
    @inline(__always)
    private func rbPush(_ src: UnsafePointer<Float>, count n: Int) {
        if softMuted { return }
        var remaining = n
        var i = 0
        while remaining > 0 {
            let spaceToEnd = rbCap - w
            let c = min(spaceToEnd, remaining)
            rb.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.advanced(by: w).assign(from: src.advanced(by: i), count: c)
            }
            w = (w + c) % rbCap
            if filled + c <= rbCap {
                filled += c
            } else {
                // overwrite oldest: advance read index when full
                let over = filled + c - rbCap
                filled = rbCap
                r = (r + over) % rbCap
            }
            i += c
            remaining -= c
        }
    }
    
    /// Pop up to `maxN` raw frames (at input SR) from the ring.
    func rbPopUpTo2(_ maxN: Int) -> [Float] {
        let n = min(maxN, filled)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let first = min(n, rbCap - r)
        out[0..<first] = rb[r..<(r + first)]
        if n > first { out[first..<n] = rb[0..<(n - first)] }
        r = (r + n) % rbCap
        filled -= n
        return out
    }
    
    /// Pop a 2s slice that ends near "now", but whose start is aligned to the most recent
    /// preceding silence. Works in **input SR** space (rb holds input-SR mono).
    /// Advances r/filled to the end of the returned slice.
    func rbPopUpTo(_ ignored: Int = 0) -> [Float] {
        // Need at least 2 seconds buffered
        let twoSec = Int(inputSR * 2)
        guard filled >= twoSec, rbCap > 0 else { return [] }

        // We will scan up to the last 4 seconds to find a silence boundary
        let scanLen = min(filled, Int(inputSR * 4))
        let scanStartRing = (w - scanLen + rbCap) % rbCap

        // Linearize the last `scanLen` samples ending at current write index
        var scan = [Float](repeating: 0, count: scanLen)
        let first = min(scanLen, rbCap - scanStartRing)
        if first > 0 {
            scan[0..<first] = rb[scanStartRing..<(scanStartRing + first)]
        }
        if scanLen > first {
            scan[first..<scanLen] = rb[0..<(scanLen - first)]
        }

        // We want a 2s chunk; naive start is "2 seconds from the end"
        var startIdx = max(0, scanLen - twoSec)

        // Build prefix sum of squares for fast RMS over arbitrary windows
        var ps = [Double](repeating: 0, count: scanLen + 1)
        for i in 0..<scanLen {
            ps[i+1] = ps[i] + Double(scan[i] * scan[i])
        }
        @inline(__always)
        func rms(_ a: Int, _ b: Int) -> Float {
            let n = max(1, b - a)
            let e = ps[b] - ps[a]
            return Float(sqrt(max(0.0, e) / Double(n)))
        }

        // Window sizes in samples
        let win = max(1, Int((winMs / 1000.0) * inputSR))
        let hold = max(win, Int((minSilenceMs / 1000.0) * inputSR))

        // Scan backward from the naive start to find a preceding "silence" window.
        // We step by `win` for speed.
        var foundSilenceEnd: Int? = nil
        var i = startIdx
        while i - hold >= 0 {
            if rms(i - hold, i) < silenceRMS {
                foundSilenceEnd = i  // silence ends at i; start after it
                break
            }
            i -= win
        }

        if let silenceEnd = foundSilenceEnd {
            // align start to just after the silent run; ensure we still have 2s available
            startIdx = min(silenceEnd, max(0, scanLen - twoSec))
        } else {
            // no silence found; keep naive start (2s back from end)
            startIdx = max(0, scanLen - twoSec)
        }

        // Final chunk [startIdx, startIdx+twoSec)
        let endIdx = min(scanLen, startIdx + twoSec)
        if endIdx - startIdx < twoSec {
            // If not enough (shouldn’t happen with guard), left-pad
            startIdx = max(0, endIdx - twoSec)
        }

        let chunk = Array(scan[startIdx..<(startIdx + twoSec)])

        // Advance the ring read pointer to the end of the popped chunk
        // Map endIdx in `scan` back to ring index
        let newR = (scanStartRing + (startIdx + twoSec)) % rbCap

        // Compute how many frames we’re discarding from current r to newR (forward distance)
        let popped: Int = {
            if newR >= r { return newR - r }
            else { return rbCap - r + newR }
        }()

        let consume = min(popped, filled)
        r = (r + consume) % rbCap
        filled -= consume

        return chunk
    }
    
    func getChunk() -> [Float]{
        // gather ~8 s raw
        let raw = rbPopUpTo(Int(inputSR * 2))  // raw mono @ input SR
        //print("raw@inputSR:", raw.count, "sr:", inputSR, terminator: " ")
        if (rms(raw) > silenceRMS){
            let converted = transform(raw)
            //var gated = raw
            //for i in gated.indices {
             //   let oneFloat = raw[i]
             //   if (rms([oneFloat]) > silenceRMS * 0.5){
             //       gated[i] = oneFloat
             //   } else {
             //       gated[i] = 0.0
             //   }
            //}
            //let gated = (rms(raw) > max(silenceRMS, 0.002)) ? raw : []
            let normalized = normalizeRMS(converted)
            let vaded = VAD2.gate(normalized)
            //let vaded = VAD2.gate(normalized)
            //print(normalized)
            //let denoised = try! DTLN.process(normalized)
            //print(denoised)
            //print("converted@16k:", converted.count) // expect ~128k at 16k*8
            //let normalizedVaded = normalizeRMS(vaded)
            return vaded//denoised
        }
        return raw
    }
    
    
    

    
    private func handleRouteChange() {
        print("[input_change]")
        engine.stop()
        let s = AVAudioSession.sharedInstance()
        let hasBTMic = s.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
   
        // Recreate tap & converter with the *current* input format
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        
        let inFmt = input.inputFormat(forBus: 0)    // may now be 16k mono
        inputSR = inFmt.sampleRate

        print("Session sampleRate:", s.sampleRate)
        print("Input channels:", inFmt.channelCount)   // 1 = mono, 2 = stereo
        
        // Ring re-init (keep your current policy)
        rbCap = Int(inputSR * 10)
        rb = [Float](repeating: 0, count: rbCap); r = 0; w = 0; filled = 0

        // Format for converter input: use the actual input to avoid mismatches
        inFmtMono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSR, channels: 1, interleaved: false)!

        // Build converter to 16k mono (unless we’re already 16k mono)
        if inFmtMono.sampleRate == 16_000 && inFmtMono.channelCount == 1 {
            converter = nil   // passthrough in your transform()
        } else {
            converter = AVAudioConverter(from: inFmtMono, to: outFmt)
        }

        // ===== Mic tap: capture float data from channel 0 and push to ring buffer =====
        input.installTap(onBus: 0, bufferSize: 256, format: inFmt) { [weak self] buf, _ in
            guard let self else { return }
            
            // Level metering for UI (done on main queue to update SwiftUI state).
            if let ch = buf.floatChannelData {
                let n = Int(buf.frameLength)
                // compute on the audio thread (pointer is valid here)
                    let levelNow = self.computeLevel( frameLength: n, p: ch[0])
                DispatchQueue.main.async {
                    self.onLevel?(levelNow)
                }
                
                // Push mic channel 0 samples to the ring buffer (mono @ input SR).
                self.rbPush(ch[0], count: n)
            }
            
        }
        
        player.volume = 1.0                          // 0..1 (max)
        engine.mainMixerNode.outputVolume = 1.0      // also 0..1
        
        // Reconnect the player to the mixer (format nil lets the engine adapt to the new route)
           let mixer = engine.mainMixerNode
           engine.disconnectNodeOutput(player)
           engine.connect(player, to: mixer, format: nil)

           // Restart audio
           try? engine.start()
           player.play()
    }
    
}
