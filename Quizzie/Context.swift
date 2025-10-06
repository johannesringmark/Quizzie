//
//  Context.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-09-10.
//

import Foundation

struct Context: Codable {
    let matchOnAliases: [String]
    let customIntro: [String]
    let questions: [Question]

    enum CodingKeys: String, CodingKey {
        case matchOnAliases = "match_on_aliases"
        case customIntro = "custom_intro"
        case questions
    }
}


struct Question: Codable {
    let question: String
    let expectedAnswer: String

    enum CodingKeys: String, CodingKey {
        case question
        case expectedAnswer = "expected_answer"
    }
}
