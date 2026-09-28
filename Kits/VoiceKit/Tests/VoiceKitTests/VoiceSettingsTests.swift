import AVFoundation
import Foundation
import Testing

@testable import VoiceKit

struct VoiceSettingsTests {
    @Test func defaultsFollowTheOwnerRulings() {
        let settings = VoiceSettings()
        #expect(settings.wakePhrase == "Hey Computer")
        #expect(!settings.wakeWordEnabled)
        #expect(settings.wakeThreshold == 0.5)
        #expect(settings.replyVoice == .kokoro)
        #expect(!settings.speakReplies)
        #expect(settings.kokoro == .init(voice: "af_heart", speed: 1))
        #expect(settings.system == .init(voiceIdentifier: "", rate: 1))
        #expect(settings.grok == .init(voice: "ara"))
    }

    @Test func roundTripsAndHoldsNoSecrets() throws {
        var settings = VoiceSettings()
        settings.wakeWordEnabled = true
        settings.replyVoice = .grok
        settings.speakReplies = true
        settings.kokoro.voice = "bm_george"
        settings.grok.voice = "eve"
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(VoiceSettings.self, from: data) == settings)
        let json = try #require(String(data: data, encoding: .utf8)).lowercased()
        #expect(!json.contains("key"))
        #expect(!json.contains("token"))
    }

    @Test func decodingFillsGapsAndRepairsBadValues() throws {
        let stored = Data("""
            {"wakeWordEnabled": true, "wakeThreshold": 3, "replyVoice": "vibevoice",
             "wakePhrase": " !! ", "kokoro": {"voice": "zz_nobody", "speed": 9},
             "system": {"rate": 0.1}, "grok": {"voice": "Eve"}, "unknown": 1}
            """.utf8)
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: stored)
        #expect(settings.wakeWordEnabled)
        #expect(settings.wakeThreshold == 0.95)
        #expect(settings.replyVoice == .kokoro)
        #expect(settings.wakePhrase == "Hey Computer")
        #expect(settings.kokoro == .init(voice: "af_heart", speed: 2))
        #expect(settings.system.rate == 0.5)
        #expect(settings.grok.voice == "eve")
        #expect(try JSONDecoder().decode(VoiceSettings.self, from: Data("{}".utf8)) == VoiceSettings())
    }

    @Test func theReplyVoiceFallsBackToTheSystemVoice() {
        var settings = VoiceSettings()
        #expect(settings.effectiveReplyVoice(kokoroReady: true, grokKeyAvailable: false) == .kokoro)
        #expect(settings.effectiveReplyVoice(kokoroReady: false, grokKeyAvailable: true) == .system)
        settings.replyVoice = .grok
        #expect(settings.effectiveReplyVoice(kokoroReady: true, grokKeyAvailable: true) == .grok)
        #expect(settings.effectiveReplyVoice(kokoroReady: true, grokKeyAvailable: false) == .system)
        settings.replyVoice = .system
        #expect(settings.effectiveReplyVoice(kokoroReady: true, grokKeyAvailable: true) == .system)
    }

    @MainActor @Test func theFactoryBuildsTheEffectiveVoice() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let secrets = InMemoryVoiceSecretStore()
        var settings = VoiceSettings()
        #expect(SpeechVoices.make(for: settings, kokoroModelDirectory: missing, secrets: secrets).kind == .system)
        settings.replyVoice = .grok
        #expect(SpeechVoices.make(for: settings, kokoroModelDirectory: missing, secrets: secrets).kind == .system)
        secrets.set("xai-key", forKey: VoiceSecrets.grokAPIKey)
        let voice = SpeechVoices.make(for: settings, kokoroModelDirectory: missing, secrets: secrets)
        #expect(voice.kind == .grok)
        secrets.set("", forKey: VoiceSecrets.grokAPIKey)
        #expect(secrets.values.isEmpty)
    }
}

@MainActor
struct SystemVoiceTests {
    @Test func rateIsAClampedMultiplierOfTheDefault() {
        #expect(SystemVoice.utteranceRate(multiplier: 1) == AVSpeechUtteranceDefaultSpeechRate)
        #expect(SystemVoice.utteranceRate(multiplier: 0.1) == AVSpeechUtteranceDefaultSpeechRate * 0.5)
        #expect(SystemVoice.utteranceRate(multiplier: .nan) == AVSpeechUtteranceDefaultSpeechRate)
        #expect(SystemVoice.utteranceRate(multiplier: 100) <= AVSpeechUtteranceMaximumSpeechRate)
    }

    @Test func blankTextCompletesWithoutSpeaking() {
        let voice = SystemVoice()
        var speaking = false
        var completed = false
        voice.onSpeakingChanged = { speaking = speaking || $0 }
        voice.speak("  \n ") { completed = (try? $0.get()) != nil }
        #expect(completed)
        #expect(!speaking)
    }
}
