//
//  Untitled.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-09-08.
//

import Foundation
import AVFoundation
import Speech
import Observation

final class SpeechCoordinator: NSObject, AVSpeechSynthesizerDelegate {
    private let tts = AVSpeechSynthesizer()
    private var cont: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        tts.delegate = self
    }

    @MainActor
    func speakAndWait(_ text: String, lang: String = "en-US") async {
        if tts.isSpeaking { _ = tts.stopSpeaking(at: .immediate) }

        let u = AVSpeechUtterance(string: text)
        // u.voice = bestVoice(for: lang)

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.cont = c
            self.tts.speak(u)   // must be on main thread
        }
    }

    // MARK: AVSpeechSynthesizerDelegate
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) { cont?.resume(); cont = nil }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) { cont?.resume(); cont = nil }
}
