//
//  CommandHandler.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-09-10.
//

import SwiftUI
import AVFoundation
import Speech


let player = BlockingPlayer()


final class Mp3Handler {
    
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
    
    func introduction() async{
        try! await player.playBlocking(name: "intro_1")
        sayPrint(text :
        """
        Hi!
        
        What do you want to practice today? 
        Say “List” to see what’s available. 
        I’ll be right here whenever you’re ready
        """
        )
    }
    
    func unknownCommand(input: String) async{
        print("input:" + input)
        try! await player.playBlocking(name: "not_quite_1")
        if (input == ""){
            try! await player.playBlocking(name:"unsure_of_what_I_heard_1")
        } else{
            try! await player.playBlocking(name: "I_expected_1")
            await speak(" " + expectedResponse, whisper: whisper)
            try! await player.playBlocking(name: "I_think_I_heard_1")
            await speak(input , whisper: whisper)
        }
    }
    
    func debug(raw16:[Float]) async{
        print("[chunk] \(stats(raw16)) silenceRMS=\(whisper.mic.silenceRMS)")
        
        print("[transcribing]...")
        await whisper.transcribe()
        
        let input = whisper.transcript.lowercased() + ""
        let cleanedInput = input.replacingOccurrences(of: #"[ \t\r\n.!?]+"#, with: "", options: .regularExpression)
        print("input:" + cleanedInput + " (" + input  + ")")
    }

    
    func handle(isMostlySilence: Bool, raw16:[Float]) async{
        print("[chunk] \(stats(raw16)) silenceRMS=\(whisper.mic.silenceRMS)")
        
        print("[transcribing]...")
        await whisper.transcribe()
        
        let input = whisper.transcript.lowercased() + ""
        let cleanedInput = input.replacingOccurrences(of: #"[ \t\r\n.!?]+"#, with: "", options: .regularExpression)
        print("input:" + cleanedInput + " (" + input  + ")")
        
        if (selected_context == nil && cleanedInput.contains("list") || cleanedInput.contains("least")){
            
            try! await player.playBlocking(name: "these_are_your_options_1")
            for contex in contextsFiles {
                await speak(contex)
            }
            return
        }
        
        
        if (selected_context == nil && aliases.contains(cleanedInput)){
            for context in contexts {
                if (context.matchOnAliases.contains(cleanedInput)){
                    selected_context = context
                    try! await player.playBlocking(name: "great_choice_1")
                    await speak(input)
                    try! await player.playBlocking(name: "it_is_1")
                    await speak(context.customIntro[0])
                    try! await player.playBlocking(name: "here_comes_the_first_one_1")
                    let nextQuestion = selected_context.questions[questionIndex]
                    self.expectedResponse = nextQuestion.expectedAnswer.lowercased() + "";
                    print(expectedResponse)
                    await speak(nextQuestion.question)
                    
                }
            }
           
        } else if (selected_context == nil){
            if contextsFiles.isEmpty {
                try! await player.playBlocking(name: "there_are_no_available_options_1")
            } else {
                try! await player.playBlocking(name: "I_couldnt_understand_you_1")
                for contex in contextsFiles {
                    await speak(contex)
                }
            }
        
        } else {
            var nextQuestion = selected_context.questions[questionIndex]
            print("expected=" + expectedResponse + " actual=" + cleanedInput + " " + String(expectedResponse == cleanedInput))
            if (expectedResponse == cleanedInput || cleanedInput.contains(expectedResponse)){
                try! await player.playBlocking(name:"good_correct_1")
                try! await player.playBlocking(name:"the_answer_is_1")
                await speak((selected_context.questions[questionIndex]).expectedAnswer)
                try! await player.playBlocking(name:"now_heres_another_one_1")
                
                questionIndex = questionIndex + 1;
                if (questionIndex > selected_context.questions.count - 1){
                    print("completed" + selected_context.matchOnAliases[0])
                    try! await player.playBlocking(name:"you_completed_the_1")
                    await speak(selected_context.matchOnAliases[0])
                    expectedResponse = "-"
                    selected_context = nil
                    return
                } else {
                    nextQuestion = selected_context.questions[questionIndex]
                    expectedResponse = nextQuestion.expectedAnswer;
                    await speak(nextQuestion.question)
                }

            } else {
                try! await player.playBlocking(name: "I_repeat_the_question_again_1")
                await speak(nextQuestion.question)
            }
            
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
    func sayPrint(text : String){
        print("[saying] 🔊 ) ) ) ) ) " + text)
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
