import Foundation

/// What a trigger phrase does, as an identifier the host resolves (`agent.turn`, or a
/// `machud` command the host maps). VoiceKit attaches no meaning to it.
public struct VoiceAction: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Start an agent turn with what follows the phrase.
    public static let agentTurn: VoiceAction = "agent.turn"
}

/// One phrase and the action it runs.
public struct TriggerPhrase: Codable, Hashable, Sendable {
    public var phrase: String
    public var action: VoiceAction

    public init(_ phrase: String, action: VoiceAction) {
        self.phrase = phrase
        self.action = action
    }

    /// The comparison form of a phrase: lowercased, accents folded, punctuation dropped,
    /// words separated by single spaces. "Hey, Computer!" and "hey computer" are equal.
    public static func normalize(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(normalizeWord).filter { !$0.isEmpty }
    }

    static func normalizeWord<S: StringProtocol>(_ word: S) -> String {
        String(word)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}

/// A trigger phrase found at the start of a transcript, with the words that followed it.
public struct TriggerMatch: Equatable, Sendable {
    public let trigger: TriggerPhrase
    /// The transcript after the phrase, as spoken (leading punctuation removed).
    public let remainder: String
}

/// The phrases the host listens for, each mapped to an action. It does not care how a phrase
/// was heard: a wake model reports its phrase (`action(forPhrase:)`), a transcript is matched
/// by its opening words (`match(transcript:)`).
public struct TriggerPhraseRegistry: Codable, Equatable, Sendable {
    public private(set) var entries: [TriggerPhrase] = []

    public init(_ entries: [TriggerPhrase] = []) {
        for entry in entries { register(entry.phrase, action: entry.action) }
    }

    /// "Hey Computer" starts an agent turn.
    public static let standard = TriggerPhraseRegistry([
        TriggerPhrase(VoiceSettings.defaultWakePhrase, action: .agentTurn),
    ])

    /// Adds a phrase, or changes the action of one already registered (compared normalized).
    /// A phrase with no words is ignored.
    public mutating func register(_ phrase: String, action: VoiceAction) {
        let key = TriggerPhrase.normalize(phrase)
        guard !key.isEmpty else { return }
        let entry = TriggerPhrase(phrase.trimmingCharacters(in: .whitespacesAndNewlines), action: action)
        if let index = entries.firstIndex(where: { TriggerPhrase.normalize($0.phrase) == key }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    public mutating func remove(_ phrase: String) {
        let key = TriggerPhrase.normalize(phrase)
        entries.removeAll { TriggerPhrase.normalize($0.phrase) == key }
    }

    public func action(forPhrase phrase: String) -> VoiceAction? {
        let key = TriggerPhrase.normalize(phrase)
        return entries.first { TriggerPhrase.normalize($0.phrase) == key }?.action
    }

    /// The registered phrase the transcript opens with, whole words only; the longest wins
    /// when one phrase starts another.
    public func match(transcript: String) -> TriggerMatch? {
        let spoken = transcript.split(whereSeparator: \.isWhitespace)
        let normalized = spoken.map { TriggerPhrase.normalizeWord($0) }
        var best: (entry: TriggerPhrase, length: Int, consumed: Int)?
        for entry in entries {
            let phrase = TriggerPhrase.words(entry.phrase)
            // Walk the transcript, skipping words that are only punctuation.
            var matched = 0
            var consumed = 0
            while matched < phrase.count, consumed < normalized.count {
                if normalized[consumed].isEmpty {
                    consumed += 1
                } else if normalized[consumed] == phrase[matched] {
                    matched += 1
                    consumed += 1
                } else {
                    break
                }
            }
            guard matched == phrase.count, phrase.count > (best?.length ?? 0) else { continue }
            best = (entry, phrase.count, consumed)
        }
        guard let best else { return nil }
        let rest = spoken.dropFirst(best.consumed).joined(separator: " ")
        let remainder = rest.drop { $0.isPunctuation || $0.isWhitespace }
        return TriggerMatch(trigger: best.entry, remainder: String(remainder))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode([TriggerPhrase].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}
