//
//  ContentView.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-08-31.
//

import SwiftUI
import Speech
import AVFoundation

import SwiftUI
import Speech
import AVFoundation

let tts = AVSpeechSynthesizer()

struct ContentView: View {
    @State private var lastSegIndex = 0
    @State private var sentenceWords: [String] = []
    let sentenceGap: TimeInterval = 0.7   // new sentence if ≥700 ms of silence
    
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var color: Color = .blue
    @State private var task: SFSpeechRecognitionTask?
    @State private var pulse = false
    @State private var level: CGFloat = 0
    @State private var tail = ""   // keep a small tail to catch phrases across updates
    
    @State private var lastEndTime: TimeInterval = 0

    @State private var engine = AVAudioEngine()
    @State private var request = SFSpeechAudioBufferRecognitionRequest()
    
    @State var speechRecognizer = SpeechRecognizer()
    
    private var detectionTimer: Timer?
    private var debounceSeconds: TimeInterval = 1.5
    
    @State private var pastCount = -1
    
    
    @State private var expectedIndex = 0
    @State private var expectedResponse = "-"
    
    private var colors = ["blue", "green", "pink", "yellow", "red"]
    
    private var context = ["quiz","blue", "green", "pink", "yellow", "red"]


    
    
    var body: some View {
        Circle().fill(color)
        
            .frame(width: 200, height: 200)
            .scaleEffect(0.5 + level * 3)
            .animation(.easeOut(duration: 0.08), value: level)
            //.onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
              //        preferHeadphonesIfPresent()
                //  }
                //  .onChange(of: scenePhase) { _, phase in
                //      if phase == .active { preferHeadphonesIfPresent() }
                //  }
            .onAppear {
                SFSpeechRecognizer.requestAuthorization { _ in start() }
                print("input:" + speechRecognizer.transcript)
                let _ = Task.detached {
                    while(true){
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        await refresh()
                    }
                }
            }
            //.onChange(of: scenePhase) { oldPhase, newPhase in
             //   switch newPhase {
             //   case .inactive, .background: pauseListening()
             //   case .active: resumeListening()
             //   default: break
              //  }
            //}
        
      
    }
    
    @MainActor
    func refresh(){
        if (pastCount == -1){
            speak("Oh!")
            speak("Hi there!")
            speak("Sweety!")
            speechRecognizer.resetTranscript()
            speechRecognizer.stopTranscribing()
            speechRecognizer.startTranscribing()
            pastCount = 0;
            speak("Say quiz!")
            return
        }
        let input = speechRecognizer.transcript.lowercased() + ""
        let cnt = input.count + 0
        if (cnt > 0 || pastCount > 0){
            if (cnt == pastCount){
                print("input:" + input)
                speechRecognizer.resetTranscript()
                speechRecognizer.stopTranscribing()
                speechRecognizer.transcript = "";
                if (expectedResponse != "-"){
                    if (input.contains(expectedResponse)){
                        speak("Correct!")
                        expectedIndex = expectedIndex + 1
                        expectedResponse = String(colors[expectedIndex % colors.count])
                        speak(expectedResponse)
                    }
                    else {
                        speak("Not quite!")
                        speak("I expected " + expectedResponse)
                        speak("I heard " + input)
                    }
                }
                else if (input == ("quiz")){
                    speak("Okay! Let's start quizzing!")
                    speak("  Repeat after me")
                    speak(colors[0])
                    expectedResponse = colors[0]
                }
                else{
                    speak("I'm sorry")
                    speak("I didn't get that")
                }
              
                speechRecognizer.startTranscribing()
                
            }
        }
        pastCount = cnt
    }
    
    func start() {
        //preferHeadphonesIfPresent()
        print("initialized")
        // 1) Permissions first (speech + mic) — keep your existing requestAuthorization.
        // Then configure audio:
        
        request.taskHint = .search
        
        request.contextualStrings = context
        
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.allowBluetooth, .allowBluetoothA2DP])
        try? session.overrideOutputAudioPort(.speaker)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        print("cat:", session.category.rawValue, "mode:", session.mode.rawValue)
        
        let node = engine.inputNode
        let format = node.inputFormat(forBus: 0)        // <- not outputFormat
        guard format.sampleRate > 0 else {
            print("No mic input (simulator mic off?). Use a device or enable mic in Simulator.")
            return
        }
        
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            let rms = buf.rms()
            let db  = 20 * log10(max(rms, 1e-7))            // avoid log(0)
            let norm = max(0, min(1, (db + 50) / 50))       // map ~[-50,0] dB → [0,1]
            DispatchQueue.main.async {
                level = level * 0.8 + CGFloat(norm) * 0.2   // smooth the motion
            }

        }
        
        
        //waiter.start(threshold:0.010, hold:0.6, onSilence: {
        //    print("🔇 Silence detected!")
        //    print(speechRecognizer.transcript + ".")
        //    speechRecognizer.resetTranscript();
        //    speechRecognizer.startTranscribing()
        //}, engine: engine)
        
        engine.prepare()
        try? engine.start()
    

    }
    
    // MARK: - Pause/Resume
    func pauseListening() {
        guard engine.isRunning else { return }
        engine.pause() // keep tap & request alive
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // DO NOT call request.endAudio() or task?.cancel() — that would stop instead of pause.
    }
    
    func resumeListening() {
        // reactivate session and restart engine quickly
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        if !engine.isRunning { try? engine.start() }
        // If the recognition task died during interruption, recreate it:
        if task == nil {
            if let r = SFSpeechRecognizer(locale: .init(identifier: "en-US")), r.isAvailable {
                task = r.recognitionTask(with: request) { result, error in
                    if let text = result?.bestTranscription.formattedString.lowercased(),
                       text.contains("color") { DispatchQueue.main.async { color = .red } }
                    if error != nil || (result?.isFinal ?? false) { task = nil }
                }
            }
        }
    }
    
    
    func preferHeadphonesIfPresent() {
        let s = AVAudioSession.sharedInstance()
        // Allow Bluetooth for input/output; do NOT default to speaker
        try? s.setCategory(.playAndRecord, mode: .measurement,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        try? s.overrideOutputAudioPort(.none) // ensure no speaker override
        try? s.setActive(true, options: .notifyOthersOnDeactivation)

        // Prefer AirPods mic if available; else wired headset mic
        if let bt = s.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? s.setPreferredInput(bt)
        } else if let wired = s.availableInputs?.first(where: { $0.portType == .headsetMic }) {
            try? s.setPreferredInput(wired)
        } else {
            try? s.setPreferredInput(nil) // fall back to built-in
        }
    }
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

func speak(_ text: String, lang: String = "en-US") {
    let u = AVSpeechUtterance(string: text)
    //u.voice = bestVoice(for: lang)                  // e.g. "sv-SE" for Swedish
    //u.rate  = 0.38                                  // ~natural speed (0.0–1.0)
    //u.pitchMultiplier = 1.0                         // 0.5–2.0
    //u.preUtteranceDelay = 0.05
    //u.postUtteranceDelay = 0.02
    //u.volume = 1.0
    tts.speak(u)
}


#Preview {
    ContentView()
}
