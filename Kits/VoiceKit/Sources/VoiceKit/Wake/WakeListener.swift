import Foundation

/// Where wake audio comes from. The host owns the microphone: VoiceKit never opens it, it
/// only consumes what the source delivers.
@MainActor
public protocol WakeAudioSource: AnyObject {
    /// 16 kHz mono chunks, nominally in -1...1, each at most one second long, delivered on the
    /// main actor.
    var onSamples: (([Float]) -> Void)? { get set }
    func start() async throws
    func stop()
}

/// Feeds an audio source into a wake detector, one chunk at a time, and reports each wake.
/// After a wake the listener stays quiet (the source keeps running) until `rearm()`, so the
/// host can take the utterance that follows. On `.failed` the source is stopped; the host
/// calls `start()` again to resume.
@MainActor
public final class WakeListener {
    public enum Failure: LocalizedError {
        case fellBehind
        public var errorDescription: String? {
            "Wake detection fell behind the microphone."
        }
    }

    public enum State: Equatable, Sendable {
        case idle, arming, listening, woke, failed(String)
    }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChanged?(state) } }
    }
    public private(set) var info: WakeDetectorInfo?
    public var onWake: ((WakeDetection) -> Void)?
    public var onStateChanged: ((State) -> Void)?

    /// Audio waiting for the detector beyond this (half a second) means it cannot keep up;
    /// listening fails rather than scoring stale audio with a gap the model cannot see.
    public static let maximumBacklogSamples = 8_000

    private let detector: WakeDetector
    private let source: WakeAudioSource
    private var threshold: Double
    private var backlog: [[Float]] = []
    private var backlogSamples = 0
    private var draining = false
    private var generation = UUID()
    /// `source.start()` calls not yet returned; a superseded start stops the source only
    /// when none is left, so it never turns off the microphone a newer start opened.
    private var sourceStartsInFlight = 0

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
            sourceStartsInFlight += 1
            defer { sourceStartsInFlight -= 1 }
            do {
                try await source.start()
            } catch {
                guard generation == token else { return }
                throw error
            }
            guard generation == token else {
                // Stopped (or restarted) while the source was starting.
                if sourceStartsInFlight == 1, state != .listening, state != .woke { source.stop() }
                return
            }
            state = .listening
        } catch {
            guard generation == token else { return }
            fail(error)
        }
    }

    /// Listens for the next wake after one was reported, optionally at a new threshold.
    /// Ignored while arming, so overlapping calls arm once.
    public func rearm(threshold: Double? = nil) async {
        guard state == .woke || state == .listening else { return }
        if let threshold { self.threshold = threshold }
        let token = UUID()
        generation = token
        clearBacklog()
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
        clearBacklog()
        state = .idle
        await detector.disarm()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func clearBacklog() {
        backlog.removeAll()
        backlogSamples = 0
        draining = false
    }

    private func fail(_ error: Error) {
        generation = UUID()
        source.onSamples = nil
        source.stop()
        clearBacklog()
        state = .failed(error.localizedDescription)
    }

    private func receive(_ samples: [Float], token: UUID) {
        guard generation == token, state == .listening else { return }
        backlog.append(samples)
        backlogSamples += samples.count
        if backlogSamples > Self.maximumBacklogSamples {
            fail(Failure.fellBehind)
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
            backlogSamples -= chunk.count
            do {
                if let detection = try await detector.detect(chunk) {
                    guard generation == token else { return }
                    clearBacklog()
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
