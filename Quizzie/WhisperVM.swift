import SwiftWhisper
import AVFoundation

final class WhisperVM: ObservableObject {
    var transcript = ""
    @Published var level : Float = 0.0;
    @Published var silence : Bool = true;
    private var micOn = false
    var frames: [Float] = []

    let mic = MicPCM16k()
    private var core: SwiftWhisper.Whisper?

    init() {
        mic.chunkFrames = Int(16_000 * 2) // ~2 seconds
    }
    
    func load(){
        let url = Bundle.main.url(forResource: "ggml-medium.en-q5_0", withExtension: "bin")!
        
        
        var p = WhisperParams.default
        
        p.print_progress   = false   // no progress bars
        //p.print_realtime   = false   // no realtime token stream
        p.detect_language = false      // don't auto-detect
        p.print_special = false              // don’t emit <|...|> special tokens
        p.suppress_non_speech_tokens = true  // suppress [Music], (laugh), etc.
        //p.beam_size = 1
        //p.temperature = 0.2
        
        p.max_len = 0
        //p.max_text_ctx = 0
        p.language = WhisperLanguage(rawValue: "en")!       // ISO 639-1 code (e.g. "sv", "en", "fr")
        p.translate = false                     // transcribe in source language

        // configure beam search (nested struct):
        p.beam_search.beam_size = 1
        p.beam_search.patience  = 1.0        // optional
        
        //p.use_gpu = true          // or
        //p.n_gpu_layers = -1       // offload all possible layers
        
        //p.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        
        p.no_context = true
        //let prompt = "Answer ONLY with a color word: blue, green, pink, yellow, or red."
        //let cPrompt = strdup(prompt)
        //p.initial_prompt = UnsafePointer<CChar>(cPrompt)
        
        p.n_threads = Int32(min(ProcessInfo.processInfo.activeProcessorCount, 3)) // at most 3; 2 keeps UI smooth
        
        p.beam_search.beam_size = 1
        //p.best_of = 1
        p.token_timestamps = false // skip per-token timestamps work
        p.no_context = true      // good for short, streaming chunks
        p.temperature = 0.0

        
        
        core = try! SwiftWhisper.Whisper(fromFileURL: url, withParams: p)
        
    }
    

    func start() {
        guard !micOn else {return}
        
        mic.onLevel = { [weak self] lvl in
                   Task { @MainActor in self?.level = lvl }
               }
        
        do {
            try mic.start()
            micOn = true;
        } catch {
            print("failed to start mic")
        }
        
    }

    func stop() {
        guard micOn else {return}
        mic.stop()
        micOn = false;
    }
    
    static func rms(_ frames: [Float]) -> Float {
          guard !frames.isEmpty else { return 0 }
          let s = frames.reduce(0) { $0 + $1 * $1 }
          return sqrt(s / Float(frames.count))
      }
    
    public func debugRms() -> Float{
        return Self.rms(frames)
    }
    
    public func isMostlySilence() -> Bool {
        return Self.rms(frames) <  mic.silenceRMS
    }
    
    public func getRaw16k() -> [Float]{
        let raw = mic.getChunk();
        frames = raw;
        return raw;
    }
    
    public func transcribe() async{
        do {
            let boosted = normalizeRMS(frames, targetRMS: 0.08)
        let segs = try await self.core!.transcribe(audioFrames: boosted)
        let text = segs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            self.transcript = text
        }
        } catch {
            print("transcribe error:", error)
        }
    }
    
    func play(_ frames16k: [Float]) async { await mic.play16kAndWait(frames16k) }
    
    func softMuteMic(){
        mic.softMute();
    }
    
    func softUnmuteMic(){
        mic.softUnmute();
    }
    
    
    private func normalizeRMS(_ x: [Float], targetRMS: Float = 0.08, limit: Float = 0.98) -> [Float] {
        guard !x.isEmpty else { return x }
        let rms = sqrt(x.reduce(0){ $0 + $1*$1 } / Float(x.count))
        let g   = min(limit / (abs(x.max() ?? 0.0)), (rms > 1e-6 ? targetRMS / rms : 1))
        return x.map { min(max($0 * g, -limit), limit) }
    }

}
