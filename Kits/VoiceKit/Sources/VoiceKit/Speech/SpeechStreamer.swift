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
@MainActor
public final class SpeechStreamer {
    public private(set) var voice: SpeechVoice
    /// Runs once: after `finish()` when every sentence has been spoken, or on the first
    /// failure (the rest is dropped). Never after `stop()`. Once it has run the stream is
    /// ended: `append` and `finish` are ignored until `stop()`.
    public var onFinished: ((Result<Void, Error>) -> Void)?
    /// True while a sentence is speaking or queued.
    public private(set) var isSpeaking = false

    private var splitter: SentenceSplitter
    private var queue: [String] = []
    private var finishing = false
    private var ended = false
    private var generation = UUID()

    public init(voice: SpeechVoice, maximumSentenceLength: Int = SentenceSplitter.defaultMaximumLength) {
        self.voice = voice
        splitter = SentenceSplitter(maximumLength: maximumSentenceLength)
    }

    /// Adds the next piece of text.
    public func append(_ text: String) {
        guard !finishing, !ended else { return }
        queue += splitter.append(text)
        speakNext()
    }

    /// Marks the text complete: the unfinished tail is spoken too.
    public func finish() {
        guard !finishing, !ended else { return }
        finishing = true
        if let rest = splitter.flush() { queue.append(rest) }
        speakNext()
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
        finishing = false
        isSpeaking = false
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
        voice.speak(sentence) { [weak self] result in
            guard let self, self.generation == identity else { return }
            self.isSpeaking = false
            switch result {
            case .success: self.speakNext()
            case .failure(let error): self.complete(.failure(error))
            }
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        reset()
        ended = true
        onFinished?(result)
    }
}
