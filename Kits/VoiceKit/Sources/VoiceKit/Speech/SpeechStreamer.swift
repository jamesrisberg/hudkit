import Foundation

/// Cuts streamed text into sentences as it arrives. A sentence ends at `.`, `!`, `?` or `…`
/// (with any closing quotes or brackets) followed by whitespace, or at a line break. A mark at
/// the very end of the text so far is held until the next character shows whether the
/// sentence really ended ("3.14", "e.g."). A run longer than `maximumLength` with no ending
/// is cut at its last space so speech never waits on a runaway sentence.
public struct SentenceSplitter: Sendable {
    public static let defaultMaximumLength = 280
    /// Words whose period does not end a sentence. Initialisms ("U.S.", "e.g.") are
    /// recognised by shape instead.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "approx",
    ]

    public let maximumLength: Int
    private var buffer = ""

    public init(maximumLength: Int = SentenceSplitter.defaultMaximumLength) {
        precondition(maximumLength > 0)
        self.maximumLength = maximumLength
    }

    /// Adds text and returns the sentences it completed, trimmed and non-empty.
    public mutating func append(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let end = nextBoundary() {
            let sentence = buffer[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    /// Returns what is left once the text is complete, if anything.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private func nextBoundary() -> String.Index? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if character.isNewline { return buffer.index(after: index) }
            if ".!?…".contains(character) {
                var end = buffer.index(after: index)
                while end < buffer.endIndex, ".!?…\"'”’)]".contains(buffer[end]) {
                    end = buffer.index(after: end)
                }
                guard end < buffer.endIndex else { break }  // wait for the next character
                if buffer[end].isWhitespace, !(character == "." && periodContinues(at: index)) {
                    return end
                }
                index = end
                continue
            }
            index = buffer.index(after: index)
        }
        guard buffer.count > maximumLength else { return nil }
        let limit = buffer.index(buffer.startIndex, offsetBy: maximumLength)
        if let space = buffer[..<limit].lastIndex(where: \.isWhitespace), space > buffer.startIndex {
            return buffer.index(after: space)
        }
        return limit
    }

    /// True when the period at `period` belongs to its word rather than ending the sentence:
    /// an abbreviation, an initialism (single letters between periods: "U.S", "e.g"), or a
    /// list number at the start of a sentence ("1. Buy milk").
    private func periodContinues(at period: String.Index) -> Bool {
        let head = buffer[..<period]
        let start = head.lastIndex(where: \.isWhitespace).map { head.index(after: $0) } ?? head.startIndex
        let word = head[start...].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"'“‘"))
        if Self.abbreviations.contains(word) { return true }
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1, parts.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) { return true }
        let sentenceStart = head[..<start].allSatisfy(\.isWhitespace)
        return sentenceStart && !word.isEmpty && word.allSatisfy(\.isNumber)
    }
}

/// Speaks text that arrives in pieces (an agent reply as it streams): each completed sentence
/// is queued and spoken in order through one voice, so speech starts before the reply ends.
/// Markdown in the text is stripped before it is queued (`MarkdownSpeechFilter`), so headings,
/// emphasis, links, list markers and fenced code are not read aloud as written. When `voice`
/// can prefetch (`PrefetchingSpeechVoice`), the next sentence is synthesized while the current
/// one plays and handed to `play(_:completion:)`, which does not re-arm the voice, so
/// `onSpeakingChanged` stays true across the boundary instead of flickering false-then-true.
@MainActor
public final class SpeechStreamer {
    public private(set) var voice: SpeechVoice
    /// Runs once: after `finish()` when every sentence has been spoken, or on the first
    /// failure (the rest is dropped). Never after `stop()`. Once it has run the stream is
    /// ended: `append` and `finish` are ignored until `stop()`.
    public var onFinished: ((Result<Void, Error>) -> Void)?
    /// True while a sentence is speaking or queued.
    public private(set) var isSpeaking = false

    private let prefetching: (any PrefetchingSpeechVoice)?
    private var splitter: SentenceSplitter
    private var markdownFilter = MarkdownSpeechFilter()
    private var queue: [String] = []
    private var finishing = false
    private var ended = false
    private var generation = UUID()

    /// The sentence a prefetch is preparing or has prepared, and the clip once it lands. Set
    /// together, cleared together (by `speakNext()` consuming them or `reset()` dropping
    /// them), so a stray clip can never be played for the wrong sentence.
    private var prefetchTarget: String?
    private var preparedClip: SpeechClip?
    private var prefetchGeneration = UUID()

    public init(voice: SpeechVoice, maximumSentenceLength: Int = SentenceSplitter.defaultMaximumLength) {
        self.voice = voice
        prefetching = voice as? any PrefetchingSpeechVoice
        splitter = SentenceSplitter(maximumLength: maximumSentenceLength)
    }

    /// Adds the next piece of text.
    public func append(_ text: String) {
        guard !finishing, !ended else { return }
        queue += splitter.append(text).compactMap { markdownFilter.filter($0) }
        speakNext()
        maybePrefetch()
    }

    /// Marks the text complete: the unfinished tail is spoken too.
    public func finish() {
        guard !finishing, !ended else { return }
        finishing = true
        if let rest = splitter.flush(), let cleaned = markdownFilter.filter(rest) { queue.append(cleaned) }
        speakNext()
        maybePrefetch()
    }

    /// Stops speaking and drops everything queued; the streamer can be used again.
    public func stop() {
        let wasSpeaking = isSpeaking
        reset()
        ended = false
        if wasSpeaking { voice.stop() }
    }

    private func reset() {
        generation = UUID()
        queue.removeAll()
        splitter = SentenceSplitter(maximumLength: splitter.maximumLength)
        markdownFilter = MarkdownSpeechFilter()
        finishing = false
        isSpeaking = false
        prefetchGeneration = UUID()
        prefetchTarget = nil
        preparedClip = nil
    }

    private func speakNext() {
        guard !isSpeaking else { return }
        guard !queue.isEmpty else {
            if finishing { complete(.success(())) }
            return
        }
        let sentence = queue.removeFirst()
        let identity = generation
        isSpeaking = true
        let clip = prefetchTarget == sentence ? preparedClip : nil
        prefetchTarget = nil
        preparedClip = nil
        let onDone: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, self.generation == identity else { return }
            self.isSpeaking = false
            switch result {
            case .success: self.speakNext()
            case .failure(let error): self.complete(.failure(error))
            }
        }
        if let prefetching, let clip {
            prefetching.play(clip, completion: onDone)
        } else {
            voice.speak(sentence, completion: onDone)
        }
        maybePrefetch()
    }

    /// Starts synthesizing the sentence after the one currently speaking, when the voice can
    /// prefetch and nothing is already prepared or in flight for it.
    private func maybePrefetch() {
        guard let prefetching, isSpeaking, prefetchTarget == nil, let next = queue.first else { return }
        prefetchTarget = next
        let identity = prefetchGeneration
        prefetching.prepare(next) { [weak self] result in
            guard let self, self.prefetchGeneration == identity, self.prefetchTarget == next else { return }
            if case .success(let clip) = result { self.preparedClip = clip }
            // A failure leaves `preparedClip` nil: `speakNext()` falls back to `voice.speak`,
            // which reports the same failure through the normal path instead of silently here.
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        reset()
        ended = true
        onFinished?(result)
    }
}
