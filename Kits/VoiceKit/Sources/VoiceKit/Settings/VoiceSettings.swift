import Foundation

/// Everything a settings tab binds to for voice: the wake word, the reply voice and its
/// options, and whether replies are spoken. Secrets (the Grok API key) are not here; they live
/// in the Keychain (`VoiceSecrets`). Decoding is tolerant: a missing key takes its default and
/// an out-of-range value is brought back into range, so an older or hand-edited file loads.
public struct VoiceSettings: Codable, Equatable, Sendable {
    public static let defaultWakePhrase = "Hey Computer"
    public static let wakeThresholdRange = InProcessWakeDetector.thresholdRange
    public static let speedRange = 0.5...2.0

    public struct Kokoro: Codable, Equatable, Sendable {
        /// A `KokoroModels.voices` id.
        public var voice: String
        /// 0.5...2, 1 is Kokoro's normal pace.
        public var speed: Double

        public init(voice: String = KokoroModels.defaultVoice, speed: Double = 1) {
            self.voice = voice
            self.speed = speed
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                voice: (try? c.decodeIfPresent(String.self, forKey: .voice)) ?? KokoroModels.defaultVoice,
                speed: (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? 1)
            self = sanitized()
        }

        public func sanitized() -> Kokoro {
            Kokoro(
                voice: KokoroModels.voiceIDs.contains(voice) ? voice : KokoroModels.defaultVoice,
                speed: VoiceSettings.clamp(speed, to: VoiceSettings.speedRange, default: 1))
        }
    }

    public struct System: Codable, Equatable, Sendable {
        /// An installed `AVSpeechSynthesisVoice` identifier; empty is the system default voice.
        public var voiceIdentifier: String
        /// Multiplier on the default speaking rate, 0.5...2.
        public var rate: Double

        public init(voiceIdentifier: String = "", rate: Double = 1) {
            self.voiceIdentifier = voiceIdentifier
            self.rate = rate
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                voiceIdentifier: (try? c.decodeIfPresent(String.self, forKey: .voiceIdentifier)) ?? "",
                rate: (try? c.decodeIfPresent(Double.self, forKey: .rate)) ?? 1)
            self = sanitized()
        }

        public func sanitized() -> System {
            System(voiceIdentifier: voiceIdentifier,
                   rate: VoiceSettings.clamp(rate, to: VoiceSettings.speedRange, default: 1))
        }
    }

    public struct Grok: Codable, Equatable, Sendable {
        /// One of `GrokVoice.voices`.
        public var voice: String

        public init(voice: String = GrokVoice.defaultVoice) { self.voice = voice }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(voice: (try? c.decodeIfPresent(String.self, forKey: .voice)) ?? GrokVoice.defaultVoice)
            self = sanitized()
        }

        public func sanitized() -> Grok {
            let voice = voice.lowercased()
            return Grok(voice: GrokVoice.voices.contains(voice) ? voice : GrokVoice.defaultVoice)
        }
    }

    /// Listen for the wake phrase. Off until the person turns it on: it keeps the microphone
    /// open and needs a wake model downloaded.
    public var wakeWordEnabled: Bool
    public var wakePhrase: String
    /// Detection threshold, 0.05...0.95; higher wakes less often.
    public var wakeThreshold: Double
    /// The preferred reply voice; see `effectiveReplyVoice` for the fallback.
    public var replyVoice: SpeechVoiceKind
    /// Replies are text only unless this is on.
    public var speakReplies: Bool
    public var kokoro: Kokoro
    public var system: System
    public var grok: Grok

    public init(
        wakeWordEnabled: Bool = false, wakePhrase: String = VoiceSettings.defaultWakePhrase,
        wakeThreshold: Double = 0.5, replyVoice: SpeechVoiceKind = .kokoro, speakReplies: Bool = false,
        kokoro: Kokoro = .init(), system: System = .init(), grok: Grok = .init()
    ) {
        self.wakeWordEnabled = wakeWordEnabled
        self.wakePhrase = wakePhrase
        self.wakeThreshold = wakeThreshold
        self.replyVoice = replyVoice
        self.speakReplies = speakReplies
        self.kokoro = kokoro
        self.system = system
        self.grok = grok
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init(
            wakeWordEnabled: value(.wakeWordEnabled, defaults.wakeWordEnabled),
            wakePhrase: value(.wakePhrase, defaults.wakePhrase),
            wakeThreshold: value(.wakeThreshold, defaults.wakeThreshold),
            replyVoice: value(.replyVoice, defaults.replyVoice),
            speakReplies: value(.speakReplies, defaults.speakReplies),
            kokoro: value(.kokoro, defaults.kokoro),
            system: value(.system, defaults.system),
            grok: value(.grok, defaults.grok))
        self = sanitized()
    }

    /// The same settings with every value in range.
    public func sanitized() -> VoiceSettings {
        var copy = self
        let phrase = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.wakePhrase = TriggerPhrase.normalize(phrase).isEmpty ? Self.defaultWakePhrase : phrase
        copy.wakeThreshold = Self.clamp(wakeThreshold, to: Self.wakeThresholdRange, default: 0.5)
        copy.kokoro = kokoro.sanitized()
        copy.system = system.sanitized()
        copy.grok = grok.sanitized()
        return copy
    }

    /// The voice that actually speaks: the preferred one when it can, else the system voice
    /// (Kokoro without its model, Grok without an API key).
    public func effectiveReplyVoice(kokoroReady: Bool, grokKeyAvailable: Bool) -> SpeechVoiceKind {
        switch replyVoice {
        case .kokoro: return kokoroReady ? .kokoro : .system
        case .grok: return grokKeyAvailable ? .grok : .system
        case .system: return .system
        }
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>, default fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
