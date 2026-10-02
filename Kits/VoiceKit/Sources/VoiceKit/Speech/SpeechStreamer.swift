import Foundation
import os

/// How one reply was spoken, measured from its first text. `SpeechStreamer` reports it once per
/// reply (`onMetrics`, and the log) when the reply finishes, fails or is stopped.
public struct SpeechStreamMetrics: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        case finished, failed, stopped
    }

    public var outcome: Outcome
    /// From the first text to the first chunk queued for speech; nil when none was.
    public var firstChunkQueuedMilliseconds: Int?
    /// From the first text to the first chunk handed to the voice to play; nil when none was.
    public var firstAudioMilliseconds: Int?
    /// Chunks that started playing.
    public var chunks: Int
    /// Times a chunk ended with the next one not ready to play, and the silence those waits
    /// added up to.
    public var underruns: Int
    public var underrunMilliseconds: Int
    /// The part of those waits spent with no next chunk queued yet (the reply's text was
    /// slower than speech), and the waits that had such a part.
    public var textUnderruns: Int
    public var textUnderrunMilliseconds: Int
    /// The part spent with the next chunk queued but its audio still being synthesized, and
    /// the waits that had such a part.
    public var synthesisUnderruns: Int
    public var synthesisUnderrunMilliseconds: Int

    public init(
        outcome: Outcome, firstChunkQueuedMilliseconds: Int?, firstAudioMilliseconds: Int?,
        chunks: Int, underruns: Int, underrunMilliseconds: Int,
        textUnderruns: Int, textUnderrunMilliseconds: Int,
        synthesisUnderruns: Int, synthesisUnderrunMilliseconds: Int
    ) {
        self.outcome = outcome
        self.firstChunkQueuedMilliseconds = firstChunkQueuedMilliseconds
        self.firstAudioMilliseconds = firstAudioMilliseconds
        self.chunks = chunks
        self.underruns = underruns
        self.underrunMilliseconds = underrunMilliseconds
        self.textUnderruns = textUnderruns
        self.textUnderrunMilliseconds = textUnderrunMilliseconds
        self.synthesisUnderruns = synthesisUnderruns
        self.synthesisUnderrunMilliseconds = synthesisUnderrunMilliseconds
    }
}

/// A chunk of a reply as `SpeechStreamer` speaks it.
public struct SpeechChunk: Sendable, Equatable {
    /// What is spoken: the chunk with its markdown stripped.
    public let text: String
    /// The chunk's place in the reply, from 0.
    public let index: Int
    /// Where the chunk lies in all the text appended for this reply, in `Character` offsets,
    /// markdown included: the host can show the reply up to `rawRange.upperBound` while the
    /// chunk plays.
    public let rawRange: Range<Int>

    public init(text: String, index: Int, rawRange: Range<Int>) {
        self.text = text
        self.index = index
        self.rawRange = rawRange
    }
}

/// Speaks text that arrives in pieces (an agent reply as it streams), starting before the reply
/// is complete. `SpeechChunker` cuts the text into chunks: an early first chunk, then sentences.
/// Markdown is stripped from each chunk before it is queued (`MarkdownSpeechFilter`), so
/// headings, emphasis, links, list markers and fenced code are not read aloud as written.
///
/// When `voice` can prefetch (`PrefetchingSpeechVoice`), every chunk is synthesized as soon as
/// it is queued, up to `prefetchDepth` chunks ahead of the one playing (one more while nothing
/// plays), and played with `play(_:completion:)` once its turn comes, so speech runs without a
/// gap whenever text arrives faster than it is spoken; when text is slower, the voice pauses
/// only between chunks. `play` does not re-arm the voice, so `onSpeakingChanged` stays true
/// across chunks. A voice that cannot prefetch speaks each chunk with `speak(_:completion:)`.
@MainActor
public final class SpeechStreamer {
    public private(set) var voice: SpeechVoice
    public let rules: SpeechChunker.Rules
    /// Chunks synthesized ahead of the one playing.
    public let prefetchDepth: Int
    /// Runs once: after `finish()` when every chunk has been spoken, or on the first failure
    /// (the rest is dropped). Never after `stop()`. Once it has run the stream is ended:
    /// `append` and `finish` are ignored until `stop()`.
    public var onFinished: ((Result<Void, Error>) -> Void)?
    /// A chunk starts playing.
    public var onChunkStarted: ((SpeechChunk) -> Void)?
    /// A chunk finished playing; not called for a chunk cut off by `stop()` or a failure.
    public var onChunkFinished: ((SpeechChunk) -> Void)?
    /// The reply's metrics, once per reply that received text: when it finishes, fails or is
    /// stopped.
    public var onMetrics: ((SpeechStreamMetrics) -> Void)?
    /// The metrics of the last reply reported.
    public private(set) var lastMetrics: SpeechStreamMetrics?
    /// True while a chunk is playing or waiting to play.
    public var isSpeaking: Bool { playing != nil || !pending.isEmpty }

    private struct Chunk {
        let spoken: SpeechChunk
        var text: String { spoken.text }
        var index: Int { spoken.index }
        var requested = false
        var clip: SpeechClip?
        var failure: Error?
    }

    /// The reply in progress, measured on `clock`.
    private struct Meter {
        var firstText: TimeInterval?
        var firstQueued: TimeInterval?
        var firstAudio: TimeInterval?
        var chunks = 0
        var underruns = 0
        var underrunSeconds: TimeInterval = 0
        var textUnderruns = 0
        var textSeconds: TimeInterval = 0
        var synthesisUnderruns = 0
        var synthesisSeconds: TimeInterval = 0
        /// The silence since a chunk ended with the next one not ready.
        var gap: Gap?
    }

    /// One wait between chunks: for text while no chunk is queued, then for synthesis.
    private struct Gap {
        let start: TimeInterval
        let beganWaitingForText: Bool
        var waitingForText: Bool
        var phaseStart: TimeInterval
        var text: TimeInterval = 0
        var synthesis: TimeInterval = 0

        init(at now: TimeInterval, waitingForText: Bool) {
            start = now
            phaseStart = now
            beganWaitingForText = waitingForText
            self.waitingForText = waitingForText
        }

        /// Adds the time since `phaseStart` to the phase in progress.
        mutating func closePhase(at now: TimeInterval) {
            if waitingForText { text += now - phaseStart } else { synthesis += now - phaseStart }
            phaseStart = now
        }
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceKit", category: "speech")

    private let prefetching: (any PrefetchingSpeechVoice)?
    private let clock: any SpeechClock
    private var chunker: SpeechChunker
    private var markdownFilter = MarkdownSpeechFilter()
    /// Chunks queued and not yet started, in order.
    private var pending: [Chunk] = []
    private var playing: Chunk?
    private var nextIndex = 0
    private var finishing = false
    private var ended = false
    /// Replaced by every reset, so a completion from an earlier reply is recognized and ignored.
    private var generation = UUID()
    private var idleTimer: SpeechClockTimer?
    private var meter = Meter()

    /// - Parameters:
    ///   - prefetchDepth: chunks a prefetching voice synthesizes ahead of the one playing.
    ///   - clock: the system clock unless given.
    public init(
        voice: SpeechVoice, rules: SpeechChunker.Rules = .standard, prefetchDepth: Int = 2,
        clock: (any SpeechClock)? = nil
    ) {
        precondition(prefetchDepth >= 0)
        self.voice = voice
        self.rules = rules
        self.prefetchDepth = prefetchDepth
        self.clock = clock ?? SystemSpeechClock()
        prefetching = voice as? any PrefetchingSpeechVoice
        chunker = SpeechChunker(rules: rules)
    }

    /// Asks the voice to get ready (`SpeechVoice.warmUp()`), for a host that knows a reply is
    /// coming before its first text arrives.
    public func warmUp() {
        voice.warmUp()
    }

    /// Adds the next piece of text.
    public func append(_ text: String) {
        guard !finishing, !ended else { return }
        if !text.isEmpty, meter.firstText == nil { meter.firstText = clock.now }
        chunker.append(text)
        drain()
        scheduleIdleRelease()
        advance()
    }

    /// Marks the text complete: the unfinished tail is spoken too.
    public func finish() {
        guard !finishing, !ended else { return }
        finishing = true
        cancelIdleRelease()
        drain()
        if let rest = chunker.flush() { enqueue(rest) }
        advance()
    }

    /// Stops speaking and drops everything queued; the streamer can be used again.
    public func stop() {
        let wasSpeaking = isSpeaking
        report(.stopped)
        reset()
        ended = false
        if wasSpeaking { voice.stop() }
    }

    private func reset() {
        generation = UUID()
        cancelIdleRelease()
        pending.removeAll()
        playing = nil
        nextIndex = 0
        chunker = SpeechChunker(rules: rules)
        markdownFilter = MarkdownSpeechFilter()
        finishing = false
        meter = Meter()
    }

    private func drain() {
        while let raw = chunker.next() { enqueue(raw) }
    }

    /// Queues a chunk with its markdown stripped. A chunk with nothing left to say (a code
    /// fence or a line inside one) is dropped, and the next chunk may still come early.
    private func enqueue(_ raw: SpeechChunker.Chunk) {
        guard let cleaned = markdownFilter.filter(raw.text)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            if nextIndex == 0 { chunker.releasesEarly = true }
            return
        }
        pending.append(Chunk(spoken: SpeechChunk(text: cleaned, index: nextIndex, rawRange: raw.rawRange)))
        nextIndex += 1
        let now = clock.now
        if meter.firstQueued == nil { meter.firstQueued = now }
        if var gap = meter.gap, gap.waitingForText {
            gap.closePhase(at: now)
            gap.waitingForText = false
            meter.gap = gap
        }
    }

    /// Releases the first chunk early once enough words have waited `rules.idleDelay` with no
    /// new text; restarted by every `append`.
    private func scheduleIdleRelease() {
        cancelIdleRelease()
        guard chunker.canReleaseIdle else { return }
        let identity = generation
        idleTimer = clock.schedule(after: rules.idleDelay) { [weak self] in
            guard let self, self.generation == identity, !self.finishing, !self.ended else { return }
            self.idleTimer = nil
            if let raw = self.chunker.releaseIdle() { self.enqueue(raw) }
            self.advance()
        }
    }

    private func cancelIdleRelease() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// Starts synthesis for the chunks within reach, then starts the next chunk when nothing
    /// plays and it is ready, or completes the stream when it is finished and nothing is left.
    private func advance() {
        requestPreparations()
        guard playing == nil else { return }
        guard let head = pending.first else {
            if finishing { complete(.success(())) }
            return
        }
        if let prefetching {
            if let failure = head.failure { return complete(.failure(failure)) }
            guard let clip = head.clip else { return }  // still synthesizing
            start { prefetching.play(clip, completion: $0) }
        } else {
            let voice = voice
            start { voice.speak(head.text, completion: $0) }
        }
    }

    /// Plays the first pending chunk through `play`, which is handed the chunk's completion.
    private func start(_ play: (@escaping (Result<Void, Error>) -> Void) -> Void) {
        let chunk = pending.removeFirst()
        playing = chunk
        let now = clock.now
        if meter.firstAudio == nil { meter.firstAudio = now }
        if var gap = meter.gap {
            gap.closePhase(at: now)
            meter.underruns += 1
            meter.underrunSeconds += now - gap.start
            if gap.beganWaitingForText || gap.text > 0 {
                meter.textUnderruns += 1
                meter.textSeconds += gap.text
            }
            if !gap.beganWaitingForText || gap.synthesis > 0 {
                meter.synthesisUnderruns += 1
                meter.synthesisSeconds += gap.synthesis
            }
            meter.gap = nil
        }
        meter.chunks += 1
        let identity = generation
        onChunkStarted?(chunk.spoken)
        guard generation == identity else { return }
        play { [weak self] result in
            guard let self, self.generation == identity, self.playing?.index == chunk.index else { return }
            self.playing = nil
            switch result {
            case .success:
                self.onChunkFinished?(chunk.spoken)
                guard self.generation == identity else { return }
                self.advance()
                // Nothing started in its place: the silence until the next chunk is an underrun.
                if self.generation == identity, self.playing == nil, !self.ended {
                    self.meter.gap = Gap(at: self.clock.now, waitingForText: self.pending.isEmpty)
                }
            case .failure(let error):
                self.complete(.failure(error))
            }
        }
        requestPreparations()
    }

    /// Asks a prefetching voice to synthesize every chunk within `prefetchDepth` of the one
    /// playing (or of the next to play, which is included while nothing plays) that it has not
    /// been asked for yet. Each result is kept on its chunk until the chunk's turn.
    private func requestPreparations() {
        guard let prefetching else { return }
        let identity = generation
        while generation == identity {
            let reach = playing == nil ? prefetchDepth + 1 : prefetchDepth
            guard let position = pending.prefix(reach).firstIndex(where: { !$0.requested }) else { return }
            pending[position].requested = true
            let index = pending[position].index
            prefetching.prepare(pending[position].text) { [weak self] result in
                guard let self, self.generation == identity,
                      let position = self.pending.firstIndex(where: { $0.index == index }) else { return }
                switch result {
                case .success(let clip): self.pending[position].clip = clip
                case .failure(let error): self.pending[position].failure = error
                }
                self.advance()
            }
        }
    }

    /// Ends the stream. A failure also stops the voice, which cancels the chunks still being
    /// synthesized ahead so they do not hold up the next reply's synthesis.
    private func complete(_ result: Result<Void, Error>) {
        let failed: Bool
        if case .failure = result { failed = true } else { failed = false }
        let hadWork = isSpeaking
        report(failed ? .failed : .finished)
        reset()
        ended = true
        if failed, hadWork { voice.stop() }
        onFinished?(result)
    }

    /// Logs and reports the reply's metrics, once, if it received any text.
    private func report(_ outcome: SpeechStreamMetrics.Outcome) {
        guard let firstText = meter.firstText else { return }
        func milliseconds(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
        let metrics = SpeechStreamMetrics(
            outcome: outcome,
            firstChunkQueuedMilliseconds: meter.firstQueued.map { milliseconds($0 - firstText) },
            firstAudioMilliseconds: meter.firstAudio.map { milliseconds($0 - firstText) },
            chunks: meter.chunks, underruns: meter.underruns,
            underrunMilliseconds: milliseconds(meter.underrunSeconds),
            textUnderruns: meter.textUnderruns, textUnderrunMilliseconds: milliseconds(meter.textSeconds),
            synthesisUnderruns: meter.synthesisUnderruns,
            synthesisUnderrunMilliseconds: milliseconds(meter.synthesisSeconds))
        meter.firstText = nil
        lastMetrics = metrics
        let queued = Self.describe(metrics.firstChunkQueuedMilliseconds)
        let audio = Self.describe(metrics.firstAudioMilliseconds)
        Self.log.notice("""
            Reply speech \(outcome.rawValue, privacy: .public): first chunk queued \(queued, privacy: .public), \
            first audio \(audio, privacy: .public), \(metrics.chunks) chunks, \
            \(metrics.underruns) underruns (\(metrics.underrunMilliseconds) ms; waiting for text \
            \(metrics.textUnderruns) for \(metrics.textUnderrunMilliseconds) ms, for synthesis \
            \(metrics.synthesisUnderruns) for \(metrics.synthesisUnderrunMilliseconds) ms)
            """)
        onMetrics?(metrics)
    }

    private static func describe(_ milliseconds: Int?) -> String {
        milliseconds.map { "\($0) ms" } ?? "never"
    }
}
