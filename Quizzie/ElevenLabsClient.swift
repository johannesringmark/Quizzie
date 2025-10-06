//
//  ElevenLabsClient.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-10-04.
//
import Foundation

public final class ElevenLabsClient {

    // MARK: - Public types

    public enum AudioFormat: String {
        // Use one of ElevenLabs' output formats
        case mp3_44100_128
        case mp3_44100_64
        case mp3_22050_32
        case pcm_16000     // WAV PCM16 mono
        case pcm_22050
        case pcm_44100

        var fileExtension: String {
            switch self {
            case .mp3_44100_128, .mp3_44100_64, .mp3_22050_32: return "mp3"
            default: return "wav"
            }
        }

        var acceptHeader: String {
            switch self {
            case .mp3_44100_128, .mp3_44100_64, .mp3_22050_32: return "audio/mpeg"
            default: return "audio/wav"
            }
        }
    }

    public struct VoiceSettings: Codable {
        public var stability: Double?        // 0…1
        public var similarityBoost: Double?  // 0…1
        public var style: Double?            // 0…1
        public var useSpeakerBoost: Bool?

        public init(stability: Double? = nil,
                    similarityBoost: Double? = nil,
                    style: Double? = nil,
                    useSpeakerBoost: Bool? = nil) {
            self.stability = stability
            self.similarityBoost = similarityBoost
            self.style = style
            self.useSpeakerBoost = useSpeakerBoost
        }

        enum CodingKeys: String, CodingKey {
            case stability
            case similarityBoost = "similarity_boost"
            case style
            case useSpeakerBoost = "use_speaker_boost"
        }
    }

    // MARK: - Init

    private let apiKey: String
    private let baseURL = URL(string: "https://api.elevenlabs.io/v1")!
    private let fm = FileManager.default
    private let soundsDir: URL

    /// - Parameters:
    ///   - apiKey: Your ElevenLabs API key (store in Keychain / configuration, not source control).
    ///   - directory: Where to save audio. Defaults to Application Support / sounds.
    public init(apiKey: String, directory: URL? = nil) throws {
        self.apiKey = apiKey
        if let directory {
            self.soundsDir = directory
        } else {
            var root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            root.appendPathComponent("sounds", isDirectory: true)
            self.soundsDir = root
        }
        try fm.createDirectory(at: soundsDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Generates speech for `text`, saves to disk, and returns the local file URL.
    /// - Parameters:
    ///   - text: Text to synthesize.
    ///   - voiceId: ElevenLabs voice ID (e.g. "21m00Tcm4TlvDq8ikWAM").
    ///   - model: Model id, e.g. "eleven_multilingual_v2" (good default).
    ///   - format: Audio format (bitrate/sample-rate).
    ///   - fileName: Optional file name (without extension). If nil, one is derived from the text hash.
    ///   - settings: Optional voice settings (stability, similarity boost, etc.).
    public func synthesize(
        text: String,
        voiceId: String,
        model: String = "eleven_multilingual_v2",
        format: AudioFormat = .mp3_44100_128,
        settings: VoiceSettings? = nil
    ) async throws -> URL {
        var fileName = Self.makeFilename(from: text)
        // Build endpoint: /v1/text-to-speech/{voiceId}?output_format=...
        var components = URLComponents(url: baseURL.appendingPathComponent("text-to-speech/\(voiceId)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "output_format", value: format.rawValue),
            URLQueryItem(name: "optimize_streaming_latency", value: "0")
        ]
        let url = components.url!

        // Request body
        struct Body: Codable {
            let text: String
            let model_id: String
            let voice_settings: VoiceSettings?
        }
        let body = Body(text: text, model_id: model, voice_settings: settings)

        let requestData = try JSONEncoder().encode(body)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = requestData
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(format.acceptHeader, forHTTPHeaderField: "Accept")

        // Call API
        let (data, resp) = try await URLSession.shared.data(for: req)

        // Handle errors
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200...299).contains(http.statusCode) else {
            // Try to surface server error text if present
            let serverMessage = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            throw NSError(domain: "ElevenLabsTTS", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS failed: \(serverMessage)"])
        }

        // Save to disk
        let file = (fileName ?? Self.safeFilename(from: text, suffix: voiceId))
            + "." + format.fileExtension
        let dst = soundsDir.appendingPathComponent(file)
        // Overwrite if exists (use .atomic for safety)
        try data.write(to: dst, options: [.atomic])

        // Make sure it’s not backed up to iCloud (optional)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dst
        try? mutable.setResourceValues(values)

        return dst
    }

    /// Quick existence check by filename (without extension).
    public func exists(fileName: String, format: AudioFormat = .mp3_44100_128) -> Bool {
        let url = soundsDir.appendingPathComponent(fileName).appendingPathExtension(format.fileExtension)
        return fm.fileExists(atPath: url.path)
    }

    /// Removes all generated sounds.
    public func purgeAll() throws {
        if fm.fileExists(atPath: soundsDir.path) {
            try fm.removeItem(at: soundsDir)
        }
        try fm.createDirectory(at: soundsDir, withIntermediateDirectories: true)
    }

    // MARK: - Helpers
    
    /// Strips special chars, converts spaces to underscores, lowercases, and trims.
    /// Keeps only [a–z0–9_]. Collapses repeats and limits length.
    private static func makeFilename(from text: String, maxLength: Int = 128) -> String {
        var s = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) // remove accents
            .lowercased()

        // spaces/tabs/newlines → underscore
        s = s.replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)

        // keep only a–z 0–9 and underscore
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        s = String(s.unicodeScalars.filter { allowed.contains($0) })

        // collapse multiple underscores and trim edges
        s = s.replacingOccurrences(of: #"_{2,}"#, with: "_", options: .regularExpression)
             .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if s.isEmpty { s = "file" } //TODO: fix this
        if s.count > maxLength {
            s = String(s.prefix(maxLength))
        }
        return s
    }

    private static func safeFilename(from text: String, suffix: String) -> String {
        // Derive a stable file name from a hash of the text + voice for caching
        let key = text + "::" + suffix
        let hash = abs(key.hashValue)
        return "tts_\(hash)"
    }
}


