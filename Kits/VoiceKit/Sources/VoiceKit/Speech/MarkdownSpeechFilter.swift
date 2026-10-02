import Foundation

/// Strips markdown formatting from a reply's chunks before they reach a voice, so
/// `SpeechStreamer` speaks the words a reply means rather than its markup. It filters each
/// chunk `SpeechChunker` produced: a line break always ends a chunk, so a fence delimiter
/// always starts its own chunk and every chunk of a fenced code block's lines falls between
/// two fences; a persisted `inCodeBlock` flag is enough to recognize a fence without its own
/// buffering. Heading and list markers are dropped, emphasis markers are removed (the
/// emphasized words are kept), a link speaks its text, inline code is spoken as plain words,
/// and a fenced code block's lines, and the fence lines themselves, are skipped entirely
/// (never spoken). The chunker never cuts inside inline markup (`inlineMarkupClosed`), so
/// each chunk's markup is whole.
///
/// A marker is only recognized at the very start of a chunk, which is a genuine source line
/// for a real heading or list item (markdown always puts those on their own line). A chunk
/// that happens to start with "- " or "1. " because a length or punctuation cut fell there
/// rather than at a line break is a rare false positive this accepts.
public struct MarkdownSpeechFilter: Sendable {
    private var inCodeBlock = false

    public init() {}

    /// The cleaned chunk, or nil for a fence delimiter or text inside a fenced code block
    /// (never spoken).
    public mutating func filter(_ sentence: String) -> String? {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            inCodeBlock.toggle()
            return nil
        }
        if inCodeBlock { return nil }
        return Self.stripInline(Self.stripLeadingMarker(sentence))
    }

    /// Drops a sentence's leading blockquote marker, heading marker or one list marker;
    /// leading indentation is dropped too, since it carries no meaning read aloud.
    static func stripLeadingMarker(_ line: String) -> String {
        var text = Substring(line)
        while text.first == ">" {
            text = text.dropFirst()
            while text.first == " " { text = text.dropFirst() }
        }
        text = text.drop { $0 == " " || $0 == "\t" }

        let hashes = text.prefix { $0 == "#" }
        if (1...6).contains(hashes.count), let after = text[hashes.endIndex...].first, after.isWhitespace {
            return String(text[hashes.endIndex...].drop { $0 == " " })
        }
        if let first = text.first, "-*+".contains(first) {
            let rest = text.dropFirst()
            if rest.first == " " { return String(rest.drop { $0 == " " }) }
        }
        let digits = text.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let afterDigits = text[digits.endIndex...]
            if let marker = afterDigits.first, marker == "." || marker == ")",
               afterDigits.dropFirst().first == " " {
                return String(afterDigits.dropFirst().drop { $0 == " " })
            }
        }
        return String(text)
    }

    /// Removes emphasis markers, inline code backticks and link brackets, keeping the words
    /// they wrap. A marker with no match (an unpaired "*", or "$3 * 4") is left as written.
    static func stripInline(_ line: String) -> String {
        let chars = Array(line)
        var result = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "`", let (inner, next) = matchedRun(chars, marker: "`", from: i) {
                result += inner
                i = next
                continue
            }
            if c == "[", let (text, next) = matchedLink(chars, from: i) {
                result += stripInline(text)
                i = next
                continue
            }
            if c == "*" || c == "_" {
                if i + 1 < chars.count, chars[i + 1] == c,
                   let (inner, next) = matchedRun(chars, marker: c, count: 2, from: i) {
                    result += stripInline(inner)
                    i = next
                    continue
                }
                if isEmphasisOpener(chars, at: i), let close = emphasisCloser(chars, marker: c, from: i + 1) {
                    result += stripInline(String(chars[(i + 1)..<close]))
                    i = close + 1
                    continue
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    /// For each offset 0...line.count, whether a cut there leaves no inline markup open (inline
    /// code, a link's text or target, strong or emphasis), so both sides filter cleanly on
    /// their own. An offset inside a marker run is never a clean cut. Openers are recognized as
    /// `stripInline` recognizes them, so an unpaired "*" in "3 * 4" or the "_" in "snake_case"
    /// opens nothing; an opener that is never closed keeps every later cut unclean.
    static func inlineMarkupClosed(_ line: [Character]) -> [Bool] {
        var closed = Array(repeating: true, count: line.count + 1)
        var code = 0
        var linkText = false
        var linkTarget = false
        var strong: Character?
        var emphasis: Character?
        var i = 0
        while i < line.count {
            let c = line[i]
            var run = 1
            while i + run < line.count, line[i + run] == c, "`*_".contains(c) { run += 1 }
            var next = i + 1
            if code > 0 {
                if c == "`" {
                    if run == code { code = 0 }
                    next = i + run
                }
            } else if c == "`" {
                code = run
                next = i + run
            } else if linkTarget {
                if c == ")" { linkTarget = false }
            } else if c == "[", !linkText {
                linkText = true
            } else if c == "]", linkText {
                linkText = false
                if i + 1 < line.count, line[i + 1] == "(" {
                    linkTarget = true
                    next = i + 2
                }
            } else if c == "*" || c == "_" {
                if run == 2 {
                    if strong == c {
                        strong = nil
                    } else if strong == nil, isEmphasisOpener(line, at: i + 1) {
                        strong = c
                    }
                } else if run == 1 {
                    if emphasis == c, i > 0, !line[i - 1].isWhitespace {
                        emphasis = nil
                    } else if emphasis == nil, isEmphasisOpener(line, at: i) {
                        emphasis = c
                    }
                }
                next = i + run
            }
            let open = code > 0 || linkText || linkTarget || strong != nil || emphasis != nil
            for offset in (i + 1)..<next { closed[offset] = false }
            closed[next] = !open
            i = next
        }
        return closed
    }

    /// Finds a run of exactly `count` `marker` characters at `from`, a matching run later in
    /// the line, and returns the text between them plus the index just past the closing run.
    private static func matchedRun(
        _ chars: [Character], marker: Character, count: Int = 1, from: Int
    ) -> (String, Int)? {
        var openEnd = from
        while openEnd < chars.count, chars[openEnd] == marker { openEnd += 1 }
        guard openEnd - from == count, openEnd < chars.count else { return nil }
        var i = openEnd
        while i < chars.count {
            guard chars[i] == marker else {
                i += 1
                continue
            }
            var closeEnd = i
            while closeEnd < chars.count, chars[closeEnd] == marker { closeEnd += 1 }
            if closeEnd - i == count, i > openEnd { return (String(chars[openEnd..<i]), closeEnd) }
            i = closeEnd
        }
        return nil
    }

    /// `[text](url)`: the bracketed text and the index just past the closing `)`.
    private static func matchedLink(_ chars: [Character], from: Int) -> (String, Int)? {
        guard chars[from] == "[" else { return nil }
        var i = from + 1
        while i < chars.count, chars[i] != "]" { i += 1 }
        guard i < chars.count, i + 1 < chars.count, chars[i + 1] == "(" else { return nil }
        let textEnd = i
        var j = i + 2
        while j < chars.count, chars[j] != ")" { j += 1 }
        guard j < chars.count else { return nil }
        return (String(chars[(from + 1)..<textEnd]), j + 1)
    }

    /// A single `*`/`_` opens emphasis only where it cannot be part of a word: the start of
    /// the line or after whitespace/punctuation, and followed by a non-whitespace character
    /// (so "3 * 4" and "snake_case" are left alone).
    private static func isEmphasisOpener(_ chars: [Character], at i: Int) -> Bool {
        guard i + 1 < chars.count, !chars[i + 1].isWhitespace else { return false }
        guard i > 0 else { return true }
        return chars[i - 1].isWhitespace || chars[i - 1].isPunctuation
    }

    /// The next `marker` preceded by a non-whitespace character and not immediately followed
    /// by a letter or digit (so it closes a word instead of opening another one).
    private static func emphasisCloser(_ chars: [Character], marker: Character, from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == marker, i > from, !chars[i - 1].isWhitespace,
               (i + 1 == chars.count || !(chars[i + 1].isLetter || chars[i + 1].isNumber)) {
                return i
            }
            i += 1
        }
        return nil
    }
}
