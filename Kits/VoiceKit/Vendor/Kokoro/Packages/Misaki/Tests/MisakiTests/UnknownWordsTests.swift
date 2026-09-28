import Testing
@testable import Misaki

struct UnknownWordsTests {
    @Test func unfamiliarWordsAreNotSilentlyDropped() throws {
        for british in [false, true] {
            let g2p = try G2P(british: british, unk: "")
            for word in ["Archibald", "Kokoro", "archibald", "kokoro", "zzqxw", "zzqxw-plmzz"] {
                let result = g2p(word)
                #expect(!result.phonemes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(result.tokens.allSatisfy { $0.phonemes != nil })
            }
            #expect(g2p("archibald").phonemes.contains("ʧ"))
            #expect(g2p("kokoro").phonemes.contains("k"))
        }
    }
    @Test func knownWordsRemainLexicalAndPunctuationIsPreserved() throws {
        let g2p = try G2P(unk: "")
        #expect(g2p("hello").phonemes == "həlˈO")
        #expect(g2p("hello, zzqxw!").phonemes.contains(","))
        #expect(g2p("hello, zzqxw!").phonemes.contains("!"))
    }
}
