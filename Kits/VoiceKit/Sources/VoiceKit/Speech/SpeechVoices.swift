import Foundation

/// Builds the reply voice for the current settings, with the system-voice fallback applied.
@MainActor
public enum SpeechVoices {
    /// - Parameters:
    ///   - kokoroModelDirectory: the installed Kokoro folder; Kokoro is used only when
    ///     `ModelStore.isInstalled(KokoroModels.manifest, in:)` holds for it.
    ///   - secrets: where the Grok key is read, at each `speak`.
    public static func make(
        for settings: VoiceSettings, kokoroModelDirectory: URL, secrets: VoiceSecretStoring
    ) -> SpeechVoice {
        let grokKey = secrets.string(forKey: VoiceSecrets.grokAPIKey) ?? ""
        let kind = settings.effectiveReplyVoice(
            kokoroReady: ModelStore.isInstalled(KokoroModels.manifest, in: kokoroModelDirectory),
            grokKeyAvailable: !grokKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // Kokoro's shared model stays loaded only while Kokoro is the voice in use.
        if kind != .kokoro { KokoroVoice.unloadModels() }
        switch kind {
        case .kokoro:
            return KokoroVoice(modelDirectory: kokoroModelDirectory, options: settings.kokoro)
        case .grok:
            return GrokVoice(options: settings.grok) { secrets.string(forKey: VoiceSecrets.grokAPIKey) }
        case .system:
            return SystemVoice(options: settings.system)
        }
    }
}
