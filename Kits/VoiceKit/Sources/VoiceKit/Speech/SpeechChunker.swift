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
        while let end = Self.sentenceEnd(in: buffer) ?? Self.runawayCut(in: buffer, maximumLength: maximumLength) {
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

    /// The end of the first sentence in `text` known to be complete, or nil while none is.
    static func sentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline { return text.index(after: index) }
            if ".!?…".contains(character) {
                var end = text.index(after: index)
                while end < text.endIndex, ".!?…\"'”’)]".contains(text[end]) {
                    end = text.index(after: end)
                }
                guard end < text.endIndex else { return nil }  // wait for the next character
                if text[end].isWhitespace, !(character == "." && periodContinues(in: text, at: index)) {
                    return end
                }
                index = end
                continue
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Where a run longer than `maximumLength` with no sentence end is cut: its last space
    /// inside the limit, else the limit itself. Nil while the run is within the limit.
    static func runawayCut(in text: String, maximumLength: Int) -> String.Index? {
        guard text.count > maximumLength else { return nil }
        let limit = text.index(text.startIndex, offsetBy: maximumLength)
        if let space = text[..<limit].lastIndex(where: \.isWhitespace), space > text.startIndex {
            return text.index(after: space)
        }
        return limit
    }

    /// True when the period at `period` belongs to its word rather than ending the sentence:
    /// an abbreviation, an initialism (single letters between periods: "U.S", "e.g"), or a
    /// list number at the start of a sentence ("1. Buy milk").
    private static func periodContinues(in text: String, at period: String.Index) -> Bool {
        let head = text[..<period]
        let start = head.lastIndex(where: \.isWhitespace).map { head.index(after: $0) } ?? head.startIndex
        let word = head[start...].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"'“‘"))
        if abbreviations.contains(word) { return true }
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1, parts.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) { return true }
        let sentenceStart = head[..<start].allSatisfy(\.isWhitespace)
        return sentenceStart && !word.isEmpty && word.allSatisfy(\.isNumber)
    }
}

/// Cuts a streamed reply into the chunks `SpeechStreamer` speaks: sentences (`SentenceSplitter`),
/// with an earlier first chunk so speech starts before the first sentence is complete, and long
/// sentences split at a clause so no single chunk keeps synthesis waiting.
///
/// The first chunk (while `releasesEarly`) ends at the first clause boundary (`,` `;` `:` `—`
/// `–`) that has at least `firstClauseWords` words before it, or at the first word boundary
/// with at least `firstWordBoundaryWords`, whichever comes first; `releaseIdle()` releases it
/// sooner when the stream pauses. Every chunk after it is a sentence, except that a sentence
/// longer than `longSentenceLength` characters is cut at its last clause boundary inside that
/// length (else its first one). A cut inside a sentence is only made where at least
/// `minimumWords` words lie on each side, so it never leaves a shorter fragment, and never
/// inside inline markdown (code, a link, emphasis), so each chunk filters cleanly through
/// `MarkdownSpeechFilter` on its own. A complete sentence is a chunk whatever its length
/// ("Sure."); the text after an idle release has no minimum.
public struct SpeechChunker: Sendable {
    public struct Rules: Sendable, Equatable {
        /// Words the first chunk needs before a clause boundary may end it.
        public var firstClauseWords: Int
        /// Words after which the first chunk ends at a word boundary even with no clause.
        public var firstWordBoundaryWords: Int
        /// Words that are released as the first chunk once the stream pauses for `idleDelay`.
        public var idleWords: Int
        /// Seconds without new text before `idleWords` words are released.
        public var idleDelay: TimeInterval
        /// The fewest words on either side of a cut inside a sentence.
        public var minimumWords: Int
        /// Characters beyond which a sentence is split at a clause boundary.
        public var longSentenceLength: Int
        /// Characters beyond which a run with no sentence end and no clause is cut at a space.
        public var maximumLength: Int

        public init(
            firstClauseWords: Int = 5, firstWordBoundaryWords: Int = 12, idleWords: Int = 3,
            idleDelay: TimeInterval = 0.4, minimumWords: Int = 3, longSentenceLength: Int = 160,
            maximumLength: Int = SentenceSplitter.defaultMaximumLength
        ) {
            self.firstClauseWords = firstClauseWords
            self.firstWordBoundaryWords = firstWordBoundaryWords
            self.idleWords = idleWords
            self.idleDelay = idleDelay
            self.minimumWords = minimumWords
            self.longSentenceLength = longSentenceLength
            self.maximumLength = maximumLength
        }

        public static let standard = Rules()
    }

    public let rules: Rules
    /// True while the next chunk is a reply's first: the early rules and `releaseIdle()` apply.
    /// Releasing a chunk clears it; `SpeechStreamer` sets it again when that chunk turned out to
    /// have nothing to speak (a code fence), so the first spoken chunk still comes early.
    public var releasesEarly = true
    private var buffer = ""

    public init(rules: Rules = .standard) {
        precondition(rules.maximumLength > 0)
        self.rules = rules
    }

    public mutating func append(_ text: String) {
        buffer += text
    }

    /// The next chunk the rules release, trimmed and non-empty, or nil until more text comes.
    public mutating func next() -> String? {
        while true {
            let text = Array(buffer)
            let end = SentenceSplitter.sentenceEnd(in: buffer).map {
                buffer.distance(from: buffer.startIndex, to: $0)
            }
            let region = Array(text[..<(end ?? text.count)])
            let cut = (releasesEarly ? earlyCut(in: region) : nil)
                ?? (region.count > rules.longSentenceLength ? longCut(in: region) : nil)
                ?? end
                ?? SentenceSplitter.runawayCut(in: buffer, maximumLength: rules.maximumLength)
                    .map { buffer.distance(from: buffer.startIndex, to: $0) }
            guard let cut else { return nil }
            if let chunk = release(text, upTo: cut) { return chunk }
        }
    }

    /// True when `releaseIdle()` would release something: the first chunk is still due and the
    /// pending text has at least `idleWords` words, with no inline markdown left open.
    public var canReleaseIdle: Bool { idleCut() != nil }

    /// Releases all the pending text as the first chunk, for when the stream has paused
    /// `idleDelay` (the caller keeps the time). Nil when `canReleaseIdle` is false.
    public mutating func releaseIdle() -> String? {
        guard let cut = idleCut() else { return nil }
        return release(Array(buffer), upTo: cut)
    }

    /// What is left once the text is complete, if anything.
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private mutating func release(_ text: [Character], upTo cut: Int) -> String? {
        buffer = String(text[cut...])
        let chunk = String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return nil }
        releasesEarly = false
        return chunk
    }

    private func idleCut() -> Int? {
        guard releasesEarly else { return nil }
        let text = Array(buffer)
        guard Self.wordCounts(text).last ?? 0 >= rules.idleWords,
              MarkdownSpeechFilter.inlineMarkupClosed(text).last == true else { return nil }
        return text.count
    }

    /// The first clause boundary with `firstClauseWords` words before it, or the first word
    /// boundary with `firstWordBoundaryWords`, that leaves `minimumWords` after it.
    private func earlyCut(in region: [Character]) -> Int? {
        let closed = MarkdownSpeechFilter.inlineMarkupClosed(region)
        let before = Self.wordCounts(region)
        func fits(_ cut: Int, after needed: Int) -> Bool {
            closed[cut] && before[cut] >= needed && before[region.count] - before[cut] >= rules.minimumWords
        }
        for offset in region.indices {
            if let cut = Self.clauseCut(in: region, at: offset), fits(cut, after: rules.firstClauseWords) {
                return cut
            }
            if offset > 0, region[offset].isWhitespace, !region[offset - 1].isWhitespace,
               fits(offset, after: rules.firstWordBoundaryWords) {
                return offset
            }
        }
        return nil
    }

    /// The last clause boundary inside `longSentenceLength`, else the first one beyond it, with
    /// `minimumWords` on each side.
    private func longCut(in region: [Character]) -> Int? {
        let closed = MarkdownSpeechFilter.inlineMarkupClosed(region)
        let before = Self.wordCounts(region)
        let cuts = region.indices.compactMap { Self.clauseCut(in: region, at: $0) }.filter {
            closed[$0] && before[$0] >= rules.minimumWords
                && before[region.count] - before[$0] >= rules.minimumWords
        }
        return cuts.last { $0 <= rules.longSentenceLength } ?? cuts.first
    }

    /// The cut just after a clause mark at `offset`: `,` `;` `:` followed by whitespace (not
    /// "1,000" or "10:30"), or a dash followed by whitespace or joining two words ("now—then";
    /// not a range such as "3–5").
    static func clauseCut(in text: [Character], at offset: Int) -> Int? {
        let mark = text[offset]
        guard offset + 1 < text.count else { return nil }
        let next = text[offset + 1]
        switch mark {
        case ",", ";", ":":
            return next.isWhitespace ? offset + 1 : nil
        case "—", "–":
            if next.isWhitespace { return offset + 1 }
            return offset > 0 && text[offset - 1].isLetter && next.isLetter ? offset + 1 : nil
        default:
            return nil
        }
    }

    /// For each offset 0...text.count, the words begun before it (a word joined across the
    /// offset counts on the left only, so the count to its right is never overstated).
    static func wordCounts(_ text: [Character]) -> [Int] {
        var counts = [0]
        counts.reserveCapacity(text.count + 1)
        var count = 0
        var afterSpace = true
        for character in text {
            if !character.isWhitespace, afterSpace { count += 1 }
            afterSpace = character.isWhitespace
            counts.append(count)
        }
        return counts
    }
}
