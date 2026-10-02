import Testing

@testable import VoiceKit

struct SpeechChunkerTests {
    @Test func theFirstChunkEndsAtAClauseOnceItHasFiveWords() {
        var chunker = SpeechChunker()
        chunker.append("Well, the build failed")
        #expect(chunker.next() == nil)  // "Well," has one word
        chunker.append(" because, as it")
        #expect(chunker.next() == nil)  // two words after the comma so far
        chunker.append(" turns out")
        #expect(chunker.next() == "Well, the build failed because,")
        #expect(!chunker.releasesEarly)
        // Later chunks are sentences: the comma after "out" is not a cut.
        chunker.append(", the cache was stale")
        #expect(chunker.next() == nil)
        chunker.append(". Next")
        #expect(chunker.next() == "as it turns out, the cache was stale.")
        #expect(chunker.next() == nil)
        #expect(chunker.flush() == "Next")
        #expect(chunker.flush() == nil)
    }

    @Test func theFirstChunkEndsAtAWordBoundaryAfterTwelveWords() {
        let twelve = "one two three four five six seven eight nine ten eleven twelve"
        var chunker = SpeechChunker()
        chunker.append(twelve + " thirteen fourteen")
        #expect(chunker.next() == nil)  // only two words would follow the cut
        chunker.append(" fifteen")
        #expect(chunker.next() == twelve)
        #expect(chunker.flush() == "thirteen fourteen fifteen")
    }

    @Test func aCompleteSentenceIsReleasedWhateverItsLength() {
        var chunker = SpeechChunker()
        chunker.append("Sure. I'll")
        #expect(chunker.next() == "Sure.")
        #expect(chunker.next() == nil)
    }

    @Test func aCutNeverLeavesAFragmentShorterThanThreeWords() {
        var chunker = SpeechChunker()
        chunker.append("Okay so here we go now, done. Then")
        #expect(chunker.next() == "Okay so here we go now, done.")
    }

    @Test func idleTextIsReleasedOnlyFromThreeWordsAndOnlyForTheFirstChunk() {
        var chunker = SpeechChunker()
        chunker.append("Hi there")
        #expect(!chunker.canReleaseIdle)
        #expect(chunker.releaseIdle() == nil)
        chunker.append(" friend")
        #expect(chunker.canReleaseIdle)
        #expect(chunker.releaseIdle() == "Hi there friend")
        chunker.append(" and some more words here")
        #expect(!chunker.canReleaseIdle)  // no longer the first chunk
        #expect(chunker.releaseIdle() == nil)
    }

    @Test func aLongSentenceSplitsAtItsLastClauseWithinTheLimit() {
        let sentence = "The first part of this answer explains how the project is set up on your machine, "
            + "the second part walks through each of the failing tests one at a time, "
            + "and the third part covers the fix we applied."
        var chunker = SpeechChunker()
        chunker.releasesEarly = false
        chunker.append(sentence + " Next")
        #expect(chunker.next() == "The first part of this answer explains how the project is set up on your machine, "
            + "the second part walks through each of the failing tests one at a time,")
        #expect(chunker.next() == "and the third part covers the fix we applied.")
        #expect(chunker.next() == nil)
    }

    @Test func numbersTimesAndRangesAreNotClauseBoundaries() {
        var chunker = SpeechChunker()
        chunker.append("Our team moved these large 1,000 files at 10:30 today, so the job is done")
        #expect(chunker.next() == "Our team moved these large 1,000 files at 10:30 today,")
        var range = SpeechChunker()
        range.append("Read the pages numbered 3–5 and 7–9 carefully today — then come back")
        #expect(range.next() == "Read the pages numbered 3–5 and 7–9 carefully today —")
    }

    @Test func cutsNeverFallInsideInlineMarkup() {
        var bold = SpeechChunker()
        bold.append("**Note:** the build is slow today, so be patient with it")
        #expect(bold.next() == "**Note:** the build is slow today,")
        var insideBold = SpeechChunker()
        insideBold.append("**Note: the build is slow today, so** be patient")
        #expect(insideBold.next() == nil)
        var code = SpeechChunker()
        code.append("Run `make clean, build, test, deploy now` and then wait for it")
        #expect(code.next() == nil)
        var link = SpeechChunker()
        link.append("Read [the long guide on setup, part one](https://e.com) first, then come back")
        #expect(link.next() == "Read [the long guide on setup, part one](https://e.com) first,")
        var open = SpeechChunker()
        open.append("This is **really important")
        #expect(!open.canReleaseIdle)  // the bold is still open
    }

    @Test func blankLinesProduceNoChunks() {
        var chunker = SpeechChunker()
        chunker.append("\n\n  \nHello there.\n\n")
        #expect(chunker.next() == "Hello there.")
        #expect(chunker.next() == nil)
        #expect(chunker.flush() == nil)
    }
}
