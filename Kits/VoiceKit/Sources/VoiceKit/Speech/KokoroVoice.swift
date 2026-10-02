import AVFoundation
import Foundation

/// Kokoro on this Mac: synthesizes mono 24 kHz samples and plays them from memory, never
/// writing audio to disk. No text or audio leaves the machine.
@MainActor
public final class KokoroVoice: PrefetchingSpeechVoice {
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
    /// Readies synthesis with a voice id (`warmUp()`).
    public typealias Warmer = @Sendable (String) async throws -> Void

    /// What a warm-up synthesizes when no `Warmer` is given; the audio is discarded.
    public nonisolated static let warmUpText = "Hi."

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
    private let warm: Warmer
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var completion: ((Result<Void, Error>) -> Void)?
    /// `prepare(_:completion:)` requests not yet started, oldest first. One task, `preparer`,
    /// takes them in this order and synthesizes, encodes and completes each before taking the
    /// next, so the synthesizer sees them, and their completions run, in the order asked for.
    /// This runs apart from `generation`/`task`, so it can proceed while a different clip plays.
    private var preparations: [Preparation] = []
    private var preparer: Task<Void, Never>?
    /// Replaced by `stop()`, so a preparation that outlives its cancellation never completes
    /// and the cancelled `preparer` takes nothing more from the queue.
    private var prepareEpoch = UUID()
    /// The voice id warmed, or being warmed.
    private var warmVoice: String?

    /// Engines by model folder: every `KokoroVoice` for one folder shares its loaded model, so
    /// a voice made for each reply starts warm once any of them has warmed up or spoken.
    private static var engines: [String: KokoroEngine] = [:]

    static func engine(for modelDirectory: URL) -> KokoroEngine {
        let key = modelDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if let engine = engines[key] { return engine }
        let engine = KokoroEngine(modelDirectory: modelDirectory)
        engines[key] = engine
        return engine
    }

    /// Lets go of every shared model, for when Kokoro is no longer the reply voice
    /// (`SpeechVoices.make` calls it when it builds another voice). A model's memory is freed
    /// once the voices still using it are gone; the next `KokoroVoice(modelDirectory:)` loads
    /// it again.
    public static func unloadModels() {
        engines.removeAll()
    }

    /// Kokoro loaded from an installed model folder (`KokoroModels.directory(in:)`). The loaded
    /// model is shared with every other `KokoroVoice` for the same folder and kept until
    /// `unloadModels()`.
    public convenience init(modelDirectory: URL, options: VoiceSettings.Kokoro = .init()) {
        let engine = Self.engine(for: modelDirectory)
        self.init(options: options, warm: { voice in try await engine.warmUp(voice: voice) }) { text, voice, speed in
            try await engine.synthesize(text: text, voice: voice, speed: Float(speed))
        }
    }

    /// - Parameter warm: readies `synthesize` for a voice id; without it a warm-up synthesizes
    ///   `warmUpText` and discards it.
    public init(
        options: VoiceSettings.Kokoro = .init(),
        makePlayer: @escaping (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) },
        warm: Warmer? = nil,
        synthesize: @escaping Synthesizer
    ) {
        self.options = options
        self.synthesize = synthesize
        self.warm = warm ?? { voice in _ = try await synthesize(KokoroVoice.warmUpText, voice, 1) }
        playback = ClipPlayback(makePlayer: makePlayer)
    }

    /// Readies the model for `options.voice` in the background; nothing plays. Repeated calls
    /// for a voice already warm or warming do nothing; after a failure the next call tries
    /// again.
    public func warmUp() {
        let voice = options.voice
        guard warmVoice != voice else { return }
        warmVoice = voice
        let warm = warm
        Task { [weak self] in
            do {
                try await warm(voice)
            } catch {
                guard let self, self.warmVoice == voice else { return }
                self.warmVoice = nil
            }
        }
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

    /// Synthesizes `text` without playing it, so it can be handed to `play(_:completion:)` once
    /// its turn comes. Runs independently of `speak`/`play`'s own generation, so it can proceed
    /// while another clip plays. Several can be asked for at once: they are synthesized one at
    /// a time in the order asked for, each completion runs before the next synthesis starts,
    /// and `stop()` cancels them all.
    public func prepare(_ text: String, completion: @escaping (Result<SpeechClip, Error>) -> Void) {
        preparations.append(Preparation(text: text, voice: options.voice, speed: options.speed, completion: completion))
        guard preparer == nil else { return }
        let epoch = prepareEpoch
        let synthesize = synthesize
        preparer = Task { [weak self] in
            while let next = self?.nextPreparation(epoch: epoch) {
                let result: Result<SpeechClip, Error>
                do {
                    result = .success(SpeechClip(audio: try await Self.render(
                        next.text, voice: next.voice, speed: next.speed, synthesize: synthesize)))
                } catch {
                    result = .failure(error)
                }
                guard let self, self.prepareEpoch == epoch, !Task.isCancelled else { return }
                next.completion(result)
            }
        }
    }

    private struct Preparation {
        let text: String
        let voice: String
        let speed: Double
        let completion: (Result<SpeechClip, Error>) -> Void
    }

    /// The oldest waiting preparation, or nil once `stop()` has replaced `epoch` or the queue
    /// is empty; an empty queue also retires `preparer`, so the next `prepare` starts another.
    private func nextPreparation(epoch: UUID) -> Preparation? {
        guard prepareEpoch == epoch else { return nil }
        guard !preparations.isEmpty else {
            preparer = nil
            return nil
        }
        return preparations.removeFirst()
    }

    private nonisolated static func render(
        _ text: String, voice: String, speed: Double, synthesize: Synthesizer
    ) async throws -> Data {
        try Task.checkCancellation()
        try validate(text: text, voice: voice, speed: speed)
        let samples = try await synthesize(text, voice, speed)
        try Task.checkCancellation()
        return try wave(samples)
    }

    /// Plays a clip `prepare(_:completion:)` already produced. Unlike `speak`, this does not
    /// reset the whole voice first: `ClipPlayback` itself coalesces a `play()` that follows
    /// the previous clip's natural end into one uninterrupted `onSpeakingChanged`.
    public func play(_ clip: SpeechClip, completion: @escaping (Result<Void, Error>) -> Void) {
        task?.cancel()
        task = nil
        generation = UUID()
        let identity = generation
        self.completion = completion
        do {
            try playback.play(clip.audio, failure: Failure.playback) { [weak self] result in
                self?.finish(result, identity: identity)
            }
        } catch {
            finish(.failure(error), identity: identity)
        }
    }

    public func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        completion = nil
        playback.stop()
        prepareEpoch = UUID()
        preparer?.cancel()
        preparer = nil
        preparations.removeAll()
    }

    private func finish(_ result: Result<Void, Error>, identity: UUID) {
        guard generation == identity else { return }
        let callback = completion
        completion = nil
        task = nil
        callback?(result)
    }
}
