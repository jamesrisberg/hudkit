import Foundation
import Kokoro

/// Serializes model access off the main actor. All assets must already be installed; the
/// engine never downloads. Cancellation is checked between bounded phrases; an in-flight GPU
/// call finishes before another request can use the model, and its cancelled output is
/// discarded.
public actor KokoroEngine {
    public nonisolated static let sampleRate = 24_000
    private let modelDirectory: URL
    private var pipelines: [String: KPipeline] = [:]
    private var model: KModel?
    private var voices: VoiceLoader?
    private var warmVoices: Set<String> = []

    public init(modelDirectory: URL) { self.modelDirectory = modelDirectory }

    /// Loads the model and synthesizes one word with `voice`, discarding it, so the next real
    /// synthesis skips loading and first-run setup. Returns at once for a voice already warm.
    public func warmUp(voice: String) async throws {
        guard !warmVoices.contains(voice) else { return }
        _ = try await synthesize(text: KokoroVoice.warmUpText, voice: voice, speed: 1)
        warmVoices.insert(voice)
    }

    public func synthesize(text: String, voice: String, speed: Float) async throws -> [Float] {
        try Task.checkCancellation()
        #if !arch(arm64)
            throw Failure.unsupportedHardware
        #else
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 3_000, speed.isFinite, (0.5...2.0).contains(speed),
                  KokoroModels.voiceIDs.contains(voice)
            else { throw Failure.invalidRequest }
            let lang = voice.hasPrefix("b") ? "en-gb" : "en-us"
            let pipeline = try loadPipeline(language: lang, voice: voice)
            try Task.checkCancellation()
            var samples: [Float] = []
            // Short phrases bound uncancellable GPU work and per-call duration allocation.
            for phrase in Self.phrases(text, limit: 180) {
                try Task.checkCancellation()
                let result = try pipeline.synthesize(text: phrase, voice: voice, speed: speed)
                try Task.checkCancellation()
                guard result.sampleRate == Self.sampleRate,
                      result.audio.allSatisfy(\.isFinite),
                      result.audio.count <= Self.sampleRate * 60,
                      samples.count <= Self.sampleRate * 240 - result.audio.count
                else { throw Failure.invalidAudio }
                samples.append(contentsOf: result.audio)
            }
            guard !samples.isEmpty else { throw Failure.invalidAudio }
            return samples
        #endif
    }

    private func loadPipeline(language: String, voice: String) throws -> KPipeline {
        let files = ["config.json", "kokoro-v1_0.safetensors", "voices/\(voice).npy"]
        guard files.allSatisfy({
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }) else { throw Failure.missingModel }
        if let cached = pipelines[language] { return cached }
        let loadedModel: KModel
        if let model {
            loadedModel = model
        } else {
            loadedModel = try KModel(
                configURL: modelDirectory.appendingPathComponent("config.json"),
                weightsURL: modelDirectory.appendingPathComponent("kokoro-v1_0.safetensors"))
            model = loadedModel
        }
        let loadedVoices = voices
            ?? VoiceLoader(baseDirectory: modelDirectory.appendingPathComponent("voices"), enableDownload: false)
        voices = loadedVoices
        let pipeline = KPipeline(model: loadedModel, voices: loadedVoices, langCode: language)
        pipelines[language] = pipeline
        return pipeline
    }

    /// Splits text into chunks of at most `limit` characters, at the last space or sentence
    /// mark inside the limit when there is one.
    public nonisolated static func phrases(_ text: String, limit: Int) -> [String] {
        precondition(limit > 0)
        var remaining = text[...]
        var result: [String] = []
        while !remaining.isEmpty {
            var end = remaining.index(remaining.startIndex, offsetBy: limit, limitedBy: remaining.endIndex)
                ?? remaining.endIndex
            if end != remaining.endIndex,
               let boundary = remaining[..<end].lastIndex(where: { $0.isWhitespace || ".!?;".contains($0) }) {
                end = remaining.index(after: boundary)
            }
            let phrase = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { result.append(phrase) }
            remaining = remaining[end...]
        }
        return result
    }

    public enum Failure: LocalizedError {
        case unsupportedHardware, invalidRequest, missingModel, invalidAudio
        public var errorDescription: String? {
            switch self {
            case .unsupportedHardware: return "Local Kokoro speech requires an Apple Silicon Mac."
            case .invalidRequest:
                return "Choose an English Kokoro voice and a speed between 0.5 and 2.0. Replies must be at most 3,000 characters."
            case .missingModel: return "Download the Kokoro model in Settings before using local speech."
            case .invalidAudio: return "Kokoro could not produce a bounded, valid audio response."
            }
        }
    }
}
