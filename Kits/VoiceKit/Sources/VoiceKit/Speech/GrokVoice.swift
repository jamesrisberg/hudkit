import AVFoundation
import Foundation

/// xAI's text to speech. Sends only the text it is asked to speak; the audio stays in memory.
/// The API key comes from the host (the Keychain, `VoiceSecrets`), never from settings.
@MainActor
public final class GrokVoice: PrefetchingSpeechVoice {
    public enum Failure: LocalizedError, Equatable {
        case missingKey, invalidText, invalidVoice, service(Int), invalidResponse, oversizedAudio, playback, network

        public var errorDescription: String? {
            switch self {
            case .missingKey: return "Add your xAI API key in Settings to use Grok speech."
            case .invalidText: return "The reply is empty or too long for Grok speech."
            case .invalidVoice: return "Choose a supported Grok voice in Settings."
            case .service(let status): return "Grok speech request failed (HTTP \(status))."
            case .invalidResponse: return "Grok speech returned no usable audio."
            case .oversizedAudio: return "Grok speech audio exceeded the size limit."
            case .playback: return "Grok speech audio could not be played."
            case .network: return "Could not reach Grok speech. Check your connection and try again."
            }
        }
    }

    public typealias Requester = @MainActor (URLRequest) async throws -> Data

    /// xAI's built-in voices.
    public nonisolated static let voices = ["ara", "rex", "sal", "eve", "leo"]
    public nonisolated static let defaultVoice = "ara"
    public nonisolated static let maximumAudioBytes = 8 * 1024 * 1024
    nonisolated static let endpoint = URL(string: "https://api.x.ai/v1/tts")!

    public let kind = SpeechVoiceKind.grok
    public var options: VoiceSettings.Grok
    public var onSpeakingChanged: ((Bool) -> Void)? {
        get { playback.onSpeakingChanged }
        set { playback.onSpeakingChanged = newValue }
    }
    public var onLevel: ((Double) -> Void)? {
        get { playback.onLevel }
        set { playback.onLevel = newValue }
    }

    let playback: ClipPlayback
    private let apiKey: @MainActor () -> String?
    private let requester: Requester
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var completion: ((Result<Void, Error>) -> Void)?
    /// `prepare(_:completion:)` requests in flight, tracked apart from `generation`/`task` so
    /// they can run while a different clip plays (as in `KokoroVoice`). `stop()` replaces
    /// `prepareEpoch`, so a request that outlives its cancellation never completes.
    private var prepareEpoch = UUID()
    private var prepareTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        options: VoiceSettings.Grok = .init(),
        apiKey: @escaping @MainActor () -> String?,
        requester: @escaping Requester = { try await GrokVoice.download($0) },
        makePlayer: @escaping (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) }
    ) {
        self.options = options
        self.apiKey = apiKey
        self.requester = requester
        playback = ClipPlayback(makePlayer: makePlayer)
    }

    public static func request(text: String, apiKey: String, voice: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else { throw Failure.missingKey }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 15_000 else { throw Failure.invalidText }
        guard voices.contains(voice) else { throw Failure.invalidVoice }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "voice_id": voice, "language": "en",
            "output_format": ["codec": "mp3", "sample_rate": 24000, "bit_rate": 128000],
        ])
        return request
    }

    /// One size-capped request: no cache, no cookies, no redirects. `configuration` is copied,
    /// not changed.
    public nonisolated static func download(
        _ request: URLRequest, configuration base: URLSessionConfiguration = .ephemeral
    ) async throws -> Data {
        // swiftlint:disable:next force_cast
        let configuration = base.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Failure.service(http.statusCode) }
        guard response.expectedContentLength <= maximumAudioBytes else { throw Failure.oversizedAudio }
        var audio = Data()
        var chunk: [UInt8] = []
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            guard audio.count + chunk.count < maximumAudioBytes else { throw Failure.oversizedAudio }
            chunk.append(byte)
            if chunk.count == chunk.capacity {
                try Task.checkCancellation()
                audio.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        audio.append(contentsOf: chunk)
        guard !audio.isEmpty else { throw Failure.invalidResponse }
        return audio
    }

    public func speak(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        let identity = generation
        let voice = options.voice
        let key = apiKey() ?? ""
        self.completion = completion
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try Self.request(text: text, apiKey: key, voice: voice)
                let audio = try await self.requester(request)
                try Task.checkCancellation()
                guard self.generation == identity else { return }
                guard !audio.isEmpty else { throw Failure.invalidResponse }
                guard audio.count <= Self.maximumAudioBytes else { throw Failure.oversizedAudio }
                self.task = nil
                try self.playback.play(audio, failure: Failure.playback) { [weak self] result in
                    self?.finish(result, identity: identity)
                }
            } catch {
                guard self.generation == identity, !Task.isCancelled else { return }
                // Transport errors can carry request details; report a fixed message instead.
                self.finish(.failure((error as? Failure) ?? Failure.network), identity: identity)
            }
        }
    }

    /// Fetches `text` without playing it, so it can be handed to `play(_:completion:)` once its
    /// turn comes. Runs independently of `speak`/`play`'s own generation, so it can proceed
    /// while another clip plays; several requests can be in flight, and `stop()` cancels them
    /// all.
    public func prepare(_ text: String, completion: @escaping (Result<SpeechClip, Error>) -> Void) {
        let id = UUID()
        let epoch = prepareEpoch
        let voice = options.voice
        let key = apiKey() ?? ""
        prepareTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try Self.request(text: text, apiKey: key, voice: voice)
                let audio = try await self.requester(request)
                try Task.checkCancellation()
                guard self.prepareEpoch == epoch else { return }
                guard !audio.isEmpty else { throw Failure.invalidResponse }
                guard audio.count <= Self.maximumAudioBytes else { throw Failure.oversizedAudio }
                self.prepareTasks[id] = nil
                completion(.success(SpeechClip(audio: audio)))
            } catch {
                guard self.prepareEpoch == epoch, !Task.isCancelled else { return }
                self.prepareTasks[id] = nil
                completion(.failure((error as? Failure) ?? Failure.network))
            }
        }
    }

    /// Plays a clip `prepare(_:completion:)` already produced. Unlike `speak`, this does not
    /// re-fetch: `ClipPlayback` coalesces a `play()` that follows the previous clip's natural
    /// end into one uninterrupted `onSpeakingChanged`.
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
        prepareTasks.values.forEach { $0.cancel() }
        prepareTasks.removeAll()
    }

    private func finish(_ result: Result<Void, Error>, identity: UUID) {
        guard generation == identity else { return }
        let callback = completion
        completion = nil
        task = nil
        callback?(result)
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
