import Foundation
import Testing

@testable import VoiceKit

struct TriggerPhraseTests {
    @Test func normalizationIgnoresCaseAccentsAndPunctuation() {
        #expect(TriggerPhrase.normalize("  Hey,   Computer! ") == "hey computer")
        #expect(TriggerPhrase.normalize("Héy Cömputer") == "hey computer")
        #expect(TriggerPhrase.normalize("—") == "")
    }

    @Test func theStandardRegistryMapsTheWakePhraseToAnAgentTurn() {
        let registry = TriggerPhraseRegistry.standard
        #expect(registry.entries == [TriggerPhrase("Hey Computer", action: .agentTurn)])
        #expect(registry.action(forPhrase: "hey computer") == .agentTurn)
        #expect(registry.action(forPhrase: "Hey Jarvis") == nil)
    }

    @Test func registeringAPhraseTwiceReplacesItsAction() {
        var registry = TriggerPhraseRegistry()
        registry.register("Park it", action: "layout.park")
        registry.register("park it!", action: "layout.park-all")
        registry.register("   ", action: "ignored")
        #expect(registry.entries.count == 1)
        #expect(registry.action(forPhrase: "PARK IT") == "layout.park-all")
        registry.remove("park, it")
        #expect(registry.entries.isEmpty)
    }

    @Test func aTranscriptMatchesItsOpeningWordsAndKeepsTheRest() throws {
        var registry = TriggerPhraseRegistry.standard
        registry.register("Hey Computer dictate", action: "dictation.start")
        let turn = try #require(registry.match(transcript: "Hey, computer — what's on my calendar?"))
        #expect(turn.trigger.action == .agentTurn)
        #expect(turn.remainder == "what's on my calendar?")
        // The longest phrase wins when one starts another.
        let dictate = try #require(registry.match(transcript: "hey computer dictate. Dear Sam"))
        #expect(dictate.trigger.action == "dictation.start")
        #expect(dictate.remainder == "Dear Sam")
        #expect(registry.match(transcript: "hey computer")?.remainder == "")
        // Whole words only, and only at the start.
        #expect(registry.match(transcript: "hey computers are great") == nil)
        #expect(registry.match(transcript: "so hey computer") == nil)
        #expect(registry.match(transcript: "") == nil)
    }

    @Test func theRegistryRoundTripsAsAPlainList() throws {
        var registry = TriggerPhraseRegistry.standard
        registry.register("Next layout", action: "layout.next")
        let data = try JSONEncoder().encode(registry)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""action":"agent.turn""#))
        #expect(try JSONDecoder().decode(TriggerPhraseRegistry.self, from: data) == registry)
        // Blank and duplicate phrases in a stored list collapse on load.
        let stored = Data(#"[{"phrase":"a b","action":"x"},{"phrase":"A, B","action":"y"},{"phrase":"","action":"z"}]"#.utf8)
        let loaded = try JSONDecoder().decode(TriggerPhraseRegistry.self, from: stored)
        #expect(loaded.entries == [TriggerPhrase("A, B", action: "y")])
    }
}
