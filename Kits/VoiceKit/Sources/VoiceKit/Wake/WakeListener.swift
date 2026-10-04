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
///
/// Each wake carries the last `heardSamples` (2.5 s) of the audio the listener fed the detector
/// since it was armed, so the host can transcribe it and confirm the phrase. It is handed to
/// `onWake` once and not kept; stopping, failing or re-arming drops it.
///
/// A host that listens again after a wake it refused or could not confirm can ask for a quiet
/// period (`quietFor:` on `rearm` and `start`): audio that arrives in it is neither scored nor
/// kept, so the rest of the refused sound is not scored again. Without one, nothing is dropped. A
/// sound-alike that keeps playing past the quiet period can wake it again.
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
    /// At most this much audio (2.5 s at 16 kHz) is handed over with a wake.
    public nonisolated static let heardSamples = 40_000

    private let detector: WakeDetector
    private let source: WakeAudioSource
    private let now: @MainActor () -> TimeInterval
    private var threshold: Double
    private var frames: Int
    private var heard = SampleRing(capacity: WakeListener.heardSamples)
    /// Audio that arrives before this (by `now`) is dropped: the quiet period a host asked for.
    private var quietUntil = -TimeInterval.infinity
    private var backlog: [[Float]] = []
    private var backlogSamples = 0
    private var draining = false
    private var generation = UUID()
    /// `source.start()` calls not yet returned; a superseded start stops the source only
    /// when none is left, so it never turns off the microphone a newer start opened.
    private var sourceStartsInFlight = 0

    /// - Parameters:
    ///   - threshold: the score a frame must reach (`VoiceSettings.wakeThreshold`).
    ///   - frames: the consecutive frames at or above it that make a wake (`VoiceSettings.wakeFrames`).
    ///   - now: seconds on a monotonic clock, for a quiet period.
    public init(detector: WakeDetector, source: WakeAudioSource, threshold: Double = 0.5, frames: Int,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.detector = detector
        self.source = source
        self.threshold = threshold
        self.frames = frames
        self.now = now
    }

    /// Arms the detector, then starts the source. `quietFor`: as for `rearm`.
    public func start(quietFor: TimeInterval = 0) async {
        guard state == .idle || isFailed else { return }
        let token = UUID()
        generation = token
        state = .arming
        source.onSamples = { [weak self] samples in self?.receive(samples, token: token) }
        do {
            info = try await detector.arm(threshold: threshold, frames: frames)
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
            listen(quietFor: quietFor)
        } catch {
            guard generation == token else { return }
            fail(error)
        }
    }

    /// Listens for the next wake after one was reported, optionally with a new threshold or
    /// frame count. Ignored while arming, so overlapping calls arm once.
    ///
    /// `quietFor` seconds of audio, counted from when listening resumes, are neither scored nor
    /// kept: a host asks for this when it listens again after a wake it refused or could not
    /// confirm. The default, 0 (or any value that is not a positive number), drops nothing.
    public func rearm(threshold: Double? = nil, frames: Int? = nil, quietFor: TimeInterval = 0) async {
        guard state == .woke || state == .listening else { return }
        if let threshold { self.threshold = threshold }
        if let frames { self.frames = frames }
        let token = UUID()
        generation = token
        dropAudio()
        state = .arming
        source.onSamples = { [weak self] samples in self?.receive(samples, token: token) }
        do {
            info = try await detector.arm(threshold: self.threshold, frames: self.frames)
            guard generation == token else { return }
            listen(quietFor: quietFor)
        } catch {
            guard generation == token else { return }
            fail(error)
        }
    }

    public func stop() async {
        generation = UUID()
        source.onSamples = nil
        source.stop()
        dropAudio()
        state = .idle
        await detector.disarm()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func listen(quietFor: TimeInterval) {
        quietUntil = quietFor.isFinite && quietFor > 0 ? now() + quietFor : -.infinity
        state = .listening
    }

    /// The audio waiting for the detector and the audio it heard both belong to the arm that is
    /// ending.
    private func dropAudio() {
        backlog.removeAll()
        backlogSamples = 0
        draining = false
        heard.removeAll()
    }

    private func fail(_ error: Error) {
        generation = UUID()
        source.onSamples = nil
        source.stop()
        dropAudio()
        state = .failed(error.localizedDescription)
    }

    private func receive(_ samples: [Float], token: UUID) {
        guard generation == token, state == .listening, now() >= quietUntil else { return }
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
            heard.append(chunk)
            do {
                if let detection = try await detector.detect(chunk) {
                    guard generation == token else { return }
                    let wake = WakeDetection(
                        score: detection.score, phrase: detection.phrase, frames: detection.frames,
                        peak: detection.peak, audio: heard.samples)
                    dropAudio()
                    state = .woke
                    onWake?(wake)
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

/// The most recent samples, up to `capacity`, oldest first.
struct SampleRing {
    let capacity: Int
    private var storage: [Float] = []
    /// Once `storage` is full: where the next sample goes, which is the oldest one.
    private var next = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var samples: [Float] {
        storage.count < capacity ? storage : Array(storage[next...]) + storage[..<next]
    }

    mutating func append(_ samples: [Float]) {
        var incoming = samples.suffix(capacity)
        if storage.count < capacity {
            let room = capacity - storage.count
            storage.append(contentsOf: incoming.prefix(room))
            incoming = incoming.dropFirst(room)
        }
        for sample in incoming {
            storage[next] = sample
            next = (next + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        next = 0
    }
}
