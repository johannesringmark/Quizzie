//
//  CommandHandler.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-09-10.
//

import SwiftUI
import AVFoundation
import Speech

let speech = SpeechCoordinator()


final class CommandHandler {
    
    var whisper: WhisperVM
    
    private var expectedIndex = 0
    private var expectedResponse = "-"
    
    
    private var contextsFiles: [String] = []
    private var contexts: [Context] = []
    private var aliases: [String] = []
    
    private var selected_context : Context!
    private var questionIndex = 0
    
    init(whisper: WhisperVM){
        self.whisper = whisper
        var contextURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        for json in contextURLs.map { $0.deletingPathExtension().lastPathComponent }{
            contextsFiles.append(json)
        }
        print("contexts:")
        print(contextsFiles,terminator:"")
        
        
        for fileName in contextsFiles {
            let url = Bundle.main.url(forResource: fileName,
                                              withExtension: "json",
                                              subdirectory: nil)
            var context = CommandHandler.getContext(url: url!)
            contexts.append(context!)
            for alias in context!.matchOnAliases{
                aliases.append(alias)
            }
        }
        return
    }

    
    func handle(isMostlySilence: Bool, raw16:[Float]) async{
        print("[chunk] \(stats(raw16)) silenceRMS=\(whisper.mic.silenceRMS)")
        
        print("[transcribing]...")
        await whisper.transcribe()
        
        let input = whisper.transcript.lowercased() + ""
        let cleanedInput = input.replacingOccurrences(of: #"[ \t\r\n.!?]+"#, with: "", options: .regularExpression)
        print("input:" + cleanedInput + " (" + input  + ")")
        
        if (cleanedInput.contains("list")){
            
        }
        
        
        if (selected_context == nil && aliases.contains(cleanedInput)){
            for context in contexts {
                if (context.matchOnAliases.contains(cleanedInput)){
                    selected_context = context
                    await speak("Great choice")
                    await speak( input + " it is!")
                    await speak(context.customIntro[0])
                    await speak("Here comes the first one..")
                    let nextQuestion = selected_context.questions[questionIndex]
                    self.expectedResponse = nextQuestion.expectedAnswer.lowercased() + "";
                    print(expectedResponse)
                    await speak(nextQuestion.question)
                    
                }
            }
           
        } else if (selected_context == nil){
            if contextsFiles.isEmpty {
                await speak("There are unfortunately no options available")
            } else {
                await speak("I'm sorry", whisper: whisper)
                await speak("I couldn't hear you", whisper: whisper)
                await speak("The available contexts are ")
                for contex in contextsFiles {
                    await speak(contex)
                }
            }
        
        } else {
            var nextQuestion = selected_context.questions[questionIndex]
            print("expected=" + expectedResponse + " actual=" + cleanedInput + " " + String(expectedResponse == cleanedInput))
            if (expectedResponse == cleanedInput || cleanedInput.contains(expectedResponse)){
                await speak("Correct!")
                await speak("The answer is " + (selected_context.questions[questionIndex]).expectedAnswer)
                await speak("Now!")
                await speak("Here's another one!")
                questionIndex = questionIndex + 1;
                if (questionIndex > selected_context.questions.count){
                    await speak("You've now completed the " + selected_context.matchOnAliases[0])
                    expectedResponse = "-"
                    selected_context = nil
                } else {
                    nextQuestion = selected_context.questions[questionIndex]
                    expectedResponse = nextQuestion.expectedAnswer;
                    await speak(nextQuestion.question)
                }

            } else {
                await speak("I'll repeat the question again!")
                await speak(nextQuestion.question)
            }
            
        }
        
    }
    
    func introduction() async{
        await speak("Oh!")
        await speak("Hi there!")
        
        
        await speak("What would you like to rehearse today?")
        await speak("Say List if you'd like the available contexts.")
    }
    
    func unknownCommand(input: String) async{
        print("input:" + input)
        await speak("Not quite!", whisper: whisper)
        if (input == ""){
            await speak("I heard nothing", whisper: whisper)
        } else{
            await speak("I expected " + expectedResponse, whisper: whisper)
            await speak("I heard " + input , whisper: whisper)
        }
    }
    
    
    func stats(_ x: [Float]) -> String {
        guard !x.isEmpty else { return "empty" }
        let rms = sqrt(x.reduce(0){ $0 + $1*$1 } / Float(x.count))
        let peak = max(abs(x.max() ?? 0), abs(x.min() ?? 0))
        return String(format: "dur=%.2fs rms=%.3f peak=%.3f",
                      Double(x.count)/16_000.0, rms, peak)
    }
    
    @MainActor
    func speak(_ text: String, lang: String = "en-US") async{
        //let u = AVSpeechUtterance(string: text)
        //u.voice = bestVoice(for: lang)                  // e.g. "sv-SE" for Swedish
        //u.rate  = 0.38                                  // ~natural speed (0.0–1.0)
        //u.pitchMultiplier = 1.0                         // 0.5–2.0
        //u.preUtteranceDelay = 0.05
        //u.postUtteranceDelay = 0.02
        //u.volume = 1.0
        whisper.softMuteMic()
        print("[saying] 🔊 ) ) ) ) ) " + text)
        await speech.speakAndWait(text)
        whisper.softUnmuteMic()
        
        
    }

    @MainActor
    func speak(_ text: String, lang: String = "en-US", whisper: WhisperVM) async{
        
        //let u = AVSpeechUtterance(string: text)
        // u.voice = bestVoice(for: lang)
        
        whisper.softMuteMic()
        print("[saying] 🔊 ) ) ) ) ) " + text)
        await speech.speakAndWait(text)
        
        whisper.softUnmuteMic()
    }
    
    static func getContext(url: URL) -> Context? {
              let data = try? Data(contentsOf: url)
              let ctx = try? JSONDecoder().decode(Context.self, from: data!)
        return ctx
    }
    
    
    static func jsonFileNames(in folderURL: URL, recursive: Bool = false) -> [String] {
        let fm = FileManager.default

        if recursive, let en = fm.enumerator(at: folderURL, includingPropertiesForKeys: nil) {
            return en.compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "json" }
                .map { $0.lastPathComponent }               // keep extension
                // .map { $0.deletingPathExtension().lastPathComponent } // names only
        } else {
            let urls = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return urls.filter { $0.pathExtension.lowercased() == "json" }
                .map { $0.lastPathComponent }
        }
    }

}
