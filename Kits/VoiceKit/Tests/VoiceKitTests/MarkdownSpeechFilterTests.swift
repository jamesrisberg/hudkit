import Testing

@testable import VoiceKit

struct MarkdownSpeechFilterTests {
    @Test func stripsEmphasisKeepingTheWords() {
        var filter = MarkdownSpeechFilter()
        #expect(filter.filter("**Bold** and *italic* and _also italic_ text.") ==
            "Bold and italic and also italic text.")
    }

    @Test func leavesUnpairedMarkersAndMidWordCharactersAlone() {
        var filter = MarkdownSpeechFilter()
        #expect(filter.filter("The total is 3 * 4 and the file is snake_case_name.") ==
            "The total is 3 * 4 and the file is snake_case_name.")
        #expect(filter.filter("An unmatched * stays as written.") == "An unmatched * stays as written.")
    }

    @Test func speaksInlineCodeAsPlainWords() {
        var filter = MarkdownSpeechFilter()
        #expect(filter.filter("Call `foo()` before `bar()`.") == "Call foo() before bar().")
    }

    @Test func linksSpeakTheirText() {
        var filter = MarkdownSpeechFilter()
        #expect(filter.filter("See [the docs](https://example.com/x) for more.") ==
            "See the docs for more.")
        // No matching "(url)": left as written.
        #expect(filter.filter("A [bracket] with no link.") == "A [bracket] with no link.")
    }

    @Test func dropsHeadingAndListMarkers() {
        var filter = MarkdownSpeechFilter()
        #expect(filter.filter("# Welcome") == "Welcome")
        #expect(filter.filter("### Sub heading") == "Sub heading")
        #expect(filter.filter("- First item") == "First item")
        #expect(filter.filter("* Also a bullet") == "Also a bullet")
        #expect(filter.filter("1. Ordered item") == "Ordered item")
        #expect(filter.filter("2) Also ordered") == "Also ordered")
        #expect(filter.filter("> A quoted line") == "A quoted line")
    }

    @Test func aFencedCodeBlockIsSkippedEntirelyAcrossCalls() {
        var filter = MarkdownSpeechFilter()
        #expect(filter.filter("Here is the fix:") == "Here is the fix:")
        #expect(filter.filter("```swift") == nil)
        #expect(filter.filter("let x = 1") == nil)
        #expect(filter.filter("print(x)") == nil)
        #expect(filter.filter("```") == nil)
        #expect(filter.filter("Done.") == "Done.")
    }

    @Test func aTildeFenceIsRecognizedToo() {
        var filter = MarkdownSpeechFilter()
        #expect(filter.filter("~~~") == nil)
        #expect(filter.filter("skipped") == nil)
        #expect(filter.filter("~~~") == nil)
        #expect(filter.filter("spoken") == "spoken")
    }

    @Test func inlineBackticksInsideACodeBlockAreStillSkipped() {
        var filter = MarkdownSpeechFilter()
        _ = filter.filter("```")
        #expect(filter.filter("`not spoken either`") == nil)
        _ = filter.filter("```")
    }

    @Test func combinesMarkersOnOneLine() {
        var filter = MarkdownSpeechFilter()
        #expect(filter.filter("- **Note:** call `run()` then see [the guide](https://x.test).") ==
            "Note: call run() then see the guide.")
    }
}
