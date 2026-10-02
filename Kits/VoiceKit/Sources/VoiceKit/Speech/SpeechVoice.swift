import Foundation

/// The reply voices VoiceKit provides.
public enum SpeechVoiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Kokoro-82M on this Mac; needs its model downloaded.
    case kokoro
    /// An installed macOS voice; always available.
    case system
    /// xAI's text to speech; needs an API key and sends the text to xAI.
    case grok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kokoro: return "Kokoro · Local"
        case .system: return "Mac voice"
        case .grok: return "Grok voice"
        }
    }
}

/// Something that speaks text aloud. `speak` replaces whatever the voice is saying; the
/// completion runs once when that text finishes or fails, and never after `stop()` or a
/// newer `speak`.
@MainActor
public protocol SpeechVoice: AnyObject {
    var kind: SpeechVoiceKind { get }
    /// True while audio plays.
    var onSpeakingChanged: ((Bool) -> Void)? { get set }
    /// Output level 0...1 while audio plays, for a meter or an orb.
    var onLevel: ((Double) -> Void)? { get set }
    func speak(_ text: String, completion: @escaping (Result<Void, Error>) -> Void)
    func stop()
    /// Gets ready to speak, so the first `speak` or `prepare` of a reply starts sooner (Kokoro
    /// loads its model and synthesizes a word, which is discarded). Never plays anything, may
    /// be called at any time and as often as wanted: once warm it returns at once. A voice with
    /// nothing to prepare does nothing (the default).
    func warmUp()
}

extension SpeechVoice {
    public func warmUp() {}
}

/// A clip `PrefetchingSpeechVoice.prepare(_:completion:)` already synthesized, ready to play
/// with `play(_:completion:)` and no further synthesis delay. Opaque outside VoiceKit.
public struct SpeechClip: Sendable, Equatable {
    let audio: Data
    public init(audio: Data) { self.audio = audio }
}

/// A voice that can synthesize text ahead of when it is spoken, so `SpeechStreamer` can prepare
/// the next chunks while an earlier one plays and move to each with no synthesis gap.
/// Not every voice can (`SystemVoice` cannot): the streamer checks `voice as? (any
/// PrefetchingSpeechVoice)` and falls back to `speak(_:completion:)` when it cannot.
@MainActor
public protocol PrefetchingSpeechVoice: SpeechVoice {
    /// Synthesizes `text` without playing it. `completion` runs once, with the same failures
    /// `speak(_:completion:)` would report; never after `stop()`. Several preparations may be
    /// in flight at once and complete in any order; `stop()` cancels all of them.
    func prepare(_ text: String, completion: @escaping (Result<SpeechClip, Error>) -> Void)
    /// Plays a clip `prepare(_:completion:)` already produced, exactly like
    /// `speak(_:completion:)` but without synthesizing again.
    func play(_ clip: SpeechClip, completion: @escaping (Result<Void, Error>) -> Void)
}
