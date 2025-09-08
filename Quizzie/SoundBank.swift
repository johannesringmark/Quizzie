//
//  SoundBank.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-10-04.
//

final class SoundBank {
    // Read-only from outside
    private(set) var sounds: [String] = []

    /// Loads all intros, questions, and expected answers into `sounds`.
    func load(from contexts: [Context]) {
        sounds.removeAll(keepingCapacity: true)

        for context in contexts {
            // intros
            sounds.append(contentsOf: context.customIntro)

            // questions + expected answers
            for q in context.questions {
                sounds.append(q.question)
                sounds.append(q.expectedAnswer)
            }
        }

        // Optional: de-duplicate while preserving order
        var seen = Set<String>()
        sounds = sounds.filter { seen.insert($0).inserted }
    }
}

