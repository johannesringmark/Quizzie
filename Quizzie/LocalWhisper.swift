//
//  Whisper.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-09-02.
//
//import SwiftWhisper

//public actor LocalWhisper {

//    private let whisper: SwiftWhisper.Whisper
    
//    public init() throws {
//        let modelURL = Bundle.main.url(forResource: "ggml-tiny.en-q8_0", withExtension: "bin")!
//        let whisper = Whisper(fromFileURL: modelURL)
//    }
    
//    public func transcribe(_ frames: [Float]) async throws -> String {
//        // Convert any input to 16 kHz mono Float32
//        let frames = try await to16kMonoFloats(fileURL: fileURL)
        
//        return try await whisper.transcribe(audioFrames: frames)
//    }
//}

