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

    @Test func aTranscriptContainsThePhraseOnlyAsItsWordsTogetherAndInOrder() {
        let phrase = "Hey Jarvis"
        let heard = [
            "Hey Jarvis", "hey jarvis", "Hey, Jarvis!", "  HEY \n  JARVIS. ", "Héy Jarvís",
            "Okay hey Jarvis, what time is it?", "hey jarvis what's the weather",
            // Punctuation between the words, a sentence end included: transcribers punctuate pauses.
            "Hey. Jarvis", "Hey! Jarvis?", "hey jarvis'", "hey — jarvis", "Hey-Jarvis", "hey…jarvis",
            // Punctuation inside a word separates words too: the phrase is followed by "s".
            "hey jarvis's friend",
        ]
        for transcript in heard {
            #expect(TriggerPhrase.transcript(transcript, contains: phrase), "\(transcript)")
        }
        let notHeard = [
            "hey javier", "Hey Travis", "hey harvey", "Jarvis", "hey", "Jarvis, hey", "hey there jarvis",
            "they jarvis", "hey jarvisson", "hey jar", "", "—",
            // Its words run together or split apart: not the phrase.
            "heyjarvis", "okay, HeyJarvis.", "hey jar vis", "heyjar vis", "he yjarvis",
        ]
        for transcript in notHeard {
            #expect(!TriggerPhrase.transcript(transcript, contains: phrase), "\(transcript)")
        }
        // A phrase with no words is in no transcript.
        #expect(!TriggerPhrase.transcript("hey jarvis", contains: " !! "))
    }

    @Test func wordsRunTogetherOrSplitApartAreNotThePhrase() {
        #expect(!TriggerPhrase.transcript("in its heyday", contains: "Hey Day"))
        #expect(!TriggerPhrase.transcript("anyway", contains: "Any Way"))
        #expect(!TriggerPhrase.transcript("any way you like", contains: "Anyway"))
        #expect(!TriggerPhrase.transcript("in its hey day", contains: "Heyday"))
        #expect(!TriggerPhrase.transcript("okayhey jarvis", contains: "Okay Hey Jarvis"))
        #expect(!TriggerPhrase.transcript("okay heyjarvis", contains: "Okay Hey Jarvis"))
        #expect(!TriggerPhrase.transcript("okayheyjarvis", contains: "Okay Hey Jarvis"))
        #expect(TriggerPhrase.transcript("okay hey jarvis", contains: "Okay Hey Jarvis"))
        #expect(TriggerPhrase.transcript("okay-hey-jarvis", contains: "Okay Hey Jarvis"))
        #expect(TriggerPhrase.transcript("any way you like", contains: "Any-Way"))
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
