import AVFoundation

/// An installed macOS voice through `AVSpeechSynthesizer`; the fallback when the chosen voice
/// is unavailable. Stopping cannot finish a newer utterance.
@MainActor
public final class SystemVoice: NSObject, SpeechVoice, AVSpeechSynthesizerDelegate {
    public let kind = SpeechVoiceKind.system
    public var options: VoiceSettings.System
    public var onSpeakingChanged: ((Bool) -> Void)?
    /// The synthesizer reports no level; this is never called.
    public var onLevel: ((Double) -> Void)?
    private let synthesizer: AVSpeechSynthesizer
    private var current: AVSpeechUtterance?
    private var completion: ((Result<Void, Error>) -> Void)?

    public init(options: VoiceSettings.System = .init(), synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.options = options
        self.synthesizer = synthesizer
        super.init()
        synthesizer.delegate = self
    }

    /// `AVSpeechUtterance.rate` for a multiplier on the default rate (clamped to 0.5...2).
    public nonisolated static func utteranceRate(multiplier: Double) -> Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(max(0.5, min(2, multiplier.isFinite ? multiplier : 1)))
        return max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, rate))
    }

    public func speak(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.success(()))
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        if !options.voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: options.voiceIdentifier) {
            utterance.voice = voice
        }
        utterance.rate = Self.utteranceRate(multiplier: options.rate)
        current = utterance
        self.completion = completion
        onSpeakingChanged?(true)
        synthesizer.speak(utterance)
    }

    public func stop() {
        let wasSpeaking = current != nil
        current = nil
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
        if wasSpeaking { onSpeakingChanged?(false) }
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let box = UtteranceBox(utterance)
        Task { @MainActor [weak self] in self?.finished(box.utterance) }
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let box = UtteranceBox(utterance)
        Task { @MainActor [weak self] in self?.finished(box.utterance) }
    }

    /// Completes only the utterance still current, compared by reference (the box keeps a
    /// finished utterance alive, so its address cannot be reused by a newer one).
    func finished(_ utterance: AVSpeechUtterance) {
        guard let current, current === utterance else { return }
        self.current = nil
        let callback = completion
        completion = nil
        onSpeakingChanged?(false)
        callback?(.success(()))
    }
}

/// Carries an utterance to the main actor for an identity check only.
private struct UtteranceBox: @unchecked Sendable {
    let utterance: AVSpeechUtterance
    init(_ utterance: AVSpeechUtterance) { self.utterance = utterance }
}
