import AVFoundation
import Foundation

/// Kokoro on this Mac: synthesizes mono 24 kHz samples and plays them from memory, never
/// writing audio to disk. No text or audio leaves the machine.
@MainActor
public final class KokoroVoice: SpeechVoice {
    public enum Failure: LocalizedError {
        case invalidText, invalidVoice, invalidSpeed, invalidAudio, oversizedAudio, playback

        public var errorDescription: String? {
            switch self {
            case .invalidText: return "The reply is empty or too long for local speech."
            case .invalidVoice: return "Choose a local voice in Settings."
            case .invalidSpeed: return "Choose a speech speed between 0.5 and 2."
            case .invalidAudio: return "Local speech returned no usable audio."
            case .oversizedAudio: return "Local speech exceeded the five-minute audio limit."
            case .playback: return "Local speech audio could not be played."
            }
        }
    }

    /// (text, voice, speed) → samples at `sampleRate`.
    public typealias Synthesizer = @Sendable (String, String, Double) async throws -> [Float]

    public nonisolated static let sampleRate = 24_000
    public nonisolated static let maximumSamples = sampleRate * 60 * 5

    public let kind = SpeechVoiceKind.kokoro
    public var options: VoiceSettings.Kokoro
    public var onSpeakingChanged: ((Bool) -> Void)? {
        get { playback.onSpeakingChanged }
        set { playback.onSpeakingChanged = newValue }
    }
    public var onLevel: ((Double) -> Void)? {
        get { playback.onLevel }
        set { playback.onLevel = newValue }
    }

    let playback: ClipPlayback
    private let synthesize: Synthesizer
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var completion: ((Result<Void, Error>) -> Void)?

    /// Kokoro loaded from an installed model folder (`KokoroModels.directory(in:)`).
    public convenience init(modelDirectory: URL, options: VoiceSettings.Kokoro = .init()) {
        let engine = KokoroEngine(modelDirectory: modelDirectory)
        self.init(options: options) { text, voice, speed in
            try await engine.synthesize(text: text, voice: voice, speed: Float(speed))
        }
    }

    public init(
        options: VoiceSettings.Kokoro = .init(),
        makePlayer: @escaping (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) },
        synthesize: @escaping Synthesizer
    ) {
        self.options = options
        self.synthesize = synthesize
        playback = ClipPlayback(makePlayer: makePlayer)
    }

    public nonisolated static func validate(text: String, voice: String, speed: Double) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 3_000
        else { throw Failure.invalidText }
        guard !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidVoice
        }
        guard speed.isFinite, (0.5...2).contains(speed) else { throw Failure.invalidSpeed }
    }

    /// PCM16 WAV, little endian; bounds allocations before encoding and clips finite peaks.
    public nonisolated static func wave(_ samples: [Float]) throws -> Data {
        guard !samples.isEmpty else { throw Failure.invalidAudio }
        guard samples.count <= maximumSamples else { throw Failure.oversizedAudio }
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples.count * 2))
        for (index, sample) in samples.enumerated() {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            guard sample.isFinite else { throw Failure.invalidAudio }
            let clipped = max(-1, min(1, sample))
            append(Int16((clipped * (clipped < 0 ? 32768 : 32767)).rounded()))
        }
        return data
    }

    // Encoding runs off the main actor, so a long reply does not stall the interface.
    private nonisolated static func encode(_ samples: [Float]) async throws -> Data {
        try wave(samples)
    }

    public func speak(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        let identity = generation
        let voice = options.voice
        let speed = options.speed
        self.completion = completion
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Self.validate(text: text, voice: voice, speed: speed)
                let samples = try await self.synthesize(text, voice, speed)
                try Task.checkCancellation()
                guard self.generation == identity else { return }
                let audio = try await Self.encode(samples)
                try Task.checkCancellation()
                guard self.generation == identity else { return }
                self.task = nil
                try self.playback.play(audio, failure: Failure.playback) { [weak self] result in
                    self?.finish(result, identity: identity)
                }
            } catch {
                guard self.generation == identity, !Task.isCancelled else { return }
                self.finish(.failure(error), identity: identity)
            }
        }
    }

    public func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        completion = nil
        playback.stop()
    }

    private func finish(_ result: Result<Void, Error>, identity: UUID) {
        guard generation == identity else { return }
        let callback = completion
        completion = nil
        task = nil
        playback.stop()
        callback?(result)
    }
}
