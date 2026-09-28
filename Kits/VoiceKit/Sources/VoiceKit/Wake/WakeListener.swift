import Foundation

/// Where wake audio comes from. The host owns the microphone: VoiceKit never opens it, it
/// only consumes what the source delivers.
@MainActor
public protocol WakeAudioSource: AnyObject {
    /// 16 kHz mono chunks in -1...1, each at most one second long, delivered on the main actor.
    var onSamples: (([Float]) -> Void)? { get set }
    func start() async throws
    func stop()
}

/// Feeds an audio source into a wake detector, one chunk at a time, and reports each wake.
/// After a wake the listener stays quiet (the source keeps running) until `rearm()`, so the
/// host can take the utterance that follows.
@MainActor
public final class WakeListener {
    public enum State: Equatable, Sendable {
        case idle, arming, listening, woke, failed(String)
    }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChanged?(state) } }
    }
    public private(set) var info: WakeDetectorInfo?
    public var onWake: ((WakeDetection) -> Void)?
    public var onStateChanged: ((State) -> Void)?

    /// Chunks queued beyond this (about three seconds of audio when chunks are 80 ms) mean
    /// the detector has fallen behind; the backlog is dropped and the detector re-armed,
    /// since a gap in the audio corrupts the model's temporal context anyway.
    public static let maximumBacklog = 40

    private let detector: WakeDetector
    private let source: WakeAudioSource
    private var threshold: Double
    private var backlog: [[Float]] = []
    private var draining = false
    private var generation = UUID()

    public init(detector: WakeDetector, source: WakeAudioSource, threshold: Double = 0.5) {
        self.detector = detector
        self.source = source
        self.threshold = threshold
    }

    /// Arms the detector, then starts the source.
    public func start() async {
        guard state == .idle || isFailed else { return }
        let token = UUID()
        generation = token
        state = .arming
        source.onSamples = { [weak self] samples in self?.receive(samples, token: token) }
        do {
            info = try await detector.arm(threshold: threshold)
            guard generation == token else { return }
            try await source.start()
            guard generation == token else { return }
            state = .listening
        } catch {
            guard generation == token else { return }
            fail(error)
        }
    }

    /// Listens for the next wake after one was reported, optionally at a new threshold.
    public func rearm(threshold: Double? = nil) async {
        guard state == .woke || state == .listening else { return }
        if let threshold { self.threshold = threshold }
        let token = UUID()
        generation = token
        backlog.removeAll()
        draining = false
        state = .arming
        source.onSamples = { [weak self] samples in self?.receive(samples, token: token) }
        do {
            info = try await detector.arm(threshold: self.threshold)
            guard generation == token else { return }
            state = .listening
        } catch {
            guard generation == token else { return }
            fail(error)
        }
    }

    public func stop() async {
        generation = UUID()
        source.onSamples = nil
        source.stop()
        backlog.removeAll()
        draining = false
        state = .idle
        await detector.disarm()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func fail(_ error: Error) {
        generation = UUID()
        source.onSamples = nil
        source.stop()
        backlog.removeAll()
        draining = false
        state = .failed(error.localizedDescription)
    }

    private func receive(_ samples: [Float], token: UUID) {
        guard generation == token, state == .listening else { return }
        backlog.append(samples)
        if backlog.count > Self.maximumBacklog {
            Task { await self.rearm() }
            return
        }
        guard !draining else { return }
        draining = true
        Task { await self.drain(token: token) }
    }

    /// The only caller of `detect`, so calls stay serial.
    private func drain(token: UUID) async {
        while generation == token, state == .listening, !backlog.isEmpty {
            let chunk = backlog.removeFirst()
            do {
                if let detection = try await detector.detect(chunk) {
                    guard generation == token else { return }
                    backlog.removeAll()
                    draining = false
                    state = .woke
                    onWake?(detection)
                    return
                }
            } catch {
                guard generation == token else { return }
                fail(error)
                return
            }
        }
        if generation == token { draining = false }
    }
}
