//
//  ContentView.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-08-31.
//

import SwiftUI
import AVFoundation
import AVFoundation


struct ContentView: View {
    
    @State private var silenceLength = 0
    @State private var lastSegIndex = 0
    @State private var sentenceWords: [String] = []
    let sentenceGap: TimeInterval = 0.7   // new sentence if ≥700 ms of silence
    
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var color: Color = .gray
    //@State private var task: SFSpeechRecognitionTask?
    @State private var pulse = false
    @State private var level: CGFloat = 0
    @State private var tail = ""   // keep a small tail to catch phrases across updates
    
    @State private var lastEndTime: TimeInterval = 0
    
    @StateObject private var whisper: WhisperVM
    private let handler: Mp3Handler
    
    private var detectionTimer: Timer?
    private var debounceSeconds: TimeInterval = 1.5
    
    @State private var pastCount = -1
    
    @State private var initialized = false
    
    @State private var showCircle = false
    
    @State private var wiggle = false
    
    private var frames: [Float] = []
    
    init() {
        let vm = WhisperVM()                    // create once
        _whisper = StateObject(wrappedValue: vm) // assign to @StateObject
        handler = Mp3Handler(whisper: vm)    // use the same instance
    }
    
    var body: some View {
        ZStack {
            Rectangle().fill(.gray)
                .frame(width: 100, height: 100)
                .opacity(showCircle ? 0 : 1)   // show when showCircle is true
                .rotationEffect(.degrees(wiggle ? 2 : -2))
                .offset(x: wiggle ? 3 : -3)
                .animation(.easeInOut(duration: 0.12).repeatForever(autoreverses: true), value: wiggle)
                .onAppear { wiggle = true }
            
            Circle().fill(color)
                .frame(width: 200, height: 200)
                .scaleEffect(0.5 + CGFloat(whisper.level) * 3)
                .opacity(showCircle ? 1 : 0)   // show when showCircle is true
        }
        .animation(.easeOut(duration: 0.08), value: whisper.level)
        .onAppear {
            let _ = Task.detached {
                while(true){
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    await refresh()
                }
            }
        }
    }
    
    @MainActor
    func refresh() async{
        
        if (!initialized){
            showCircle = false
            whisper.load()
            showCircle = true
            await handler.introduction()
            color = .blue
            // (re)start capture; chunk is 16 kHz mono Float32 samples
            try whisper.start()
            
            initialized = true;
            print("")
            return
        }
        let raw16 = whisper.getRaw16k()
        if raw16.isEmpty {
            print("⚠️ no frames from mic")
            return
        }
        let isMostlySilence = whisper.isMostlySilence();
        if (silenceLength > 6){
            print(String(raw16.count) + "?")
            await handler.debug(raw16: raw16)
        }
        if (!isMostlySilence){
            print("\n[processing]\n")
            showCircle = false
            color = Color(red:0, green:0.3, blue:1.0)
            await handler.handle(isMostlySilence : isMostlySilence, raw16: raw16)
            color = .blue
            showCircle = true
            silenceLength = 0;
        } else{
            print(".", terminator: " ")
            silenceLength = silenceLength + 1
        }
     
       
        //whisper.clear()
    }
    
    func start() {
        //preferHeadphonesIfPresent()
        print("initialized")
        // 1) Permissions first (speech + mic) — keep your existing requestAuthorization.
        // Then configure audio:
        
        //request.taskHint = .search
        
        //request.contextualStrings = context
        
        //let session = AVAudioSession.sharedInstance()
        
        
        // Target: 16kHz mono Float32
        //let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
        // sampleRate: 16_000,
        // channels: 1,
        // interleaved: false)!
        
        
        //try? session.setActive(false)
        //try? session.setCategory(.playAndRecord, mode: .measurement,
        //          options: [.allowBluetooth, .allowBluetoothA2DP])
        //try? session.overrideOutputAudioPort(.speaker)
        //try? session.setActive(true, options: .notifyOthersOnDeactivation)
        //print("cat:", session.category.rawValue, "mode:", session.mode.rawValue)
        
        //let node = engine.inputNode
        //let format = node.inputFormat(forBus: 0)        // <- not outputFormat
        //guard format.sampleRate > 0 else {
        //  print("No mic input (simulator mic off?). Use a device or enable mic in Simulator.")
        // return
        //}
        
        //node.removeTap(onBus: 0)
        //node.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
        //let rms = buf.rms()
        //let db  = 20 * log10(max(rms, 1e-7))            // avoid log(0)
        //let norm = max(0, min(1, (db + 50) / 50))       // map ~[-50,0] dB → [0,1]
        //DispatchQueue.main.async {
        //  level = level * 0.8 + CGFloat(norm) * 0.2   // smooth the motion
        //}
        
    }
    
    
    //waiter.start(threshold:0.010, hold:0.6, onSilence: {
    //    print("🔇 Silence detected!")
    //    print(speechRecognizer.transcript + ".")
    //    speechRecognizer.resetTranscript();
    //    speechRecognizer.startTranscribing()
    //}, engine: engine)
    
    //engine.prepare()
    //try? engine.start()

    
    
}


// MARK: - RMS helper
private extension AVAudioPCMBuffer {
    func rms() -> Float {
        guard let ch = floatChannelData else { return 0 }
        let n = Int(frameLength)
        guard n > 0 else { return 0 }
        let p = ch[0]
        var sum: Float = 0
        for i in 0..<n { let v = p[i]; sum += v*v }
        return sqrt(sum / Float(n))
    }
}

func bestVoice(for lang: String) -> AVSpeechSynthesisVoice? {
    // Prefer enhanced voices for the language; fall back to any match
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
    return voices.first(where: { $0.quality == .enhanced }) ?? voices.first
}



#Preview {
    ContentView()
}
