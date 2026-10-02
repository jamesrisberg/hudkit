import Testing

@testable import VoiceKit

struct SpeechChunkerTests {
    @Test func theFirstChunkEndsAtAClauseOnceItHasFiveWords() {
        var chunker = SpeechChunker()
        chunker.append("Well, the build failed")
        #expect(chunker.next()?.text == nil)  // "Well," has one word
        chunker.append(" because, as it")
        #expect(chunker.next()?.text == nil)  // two words after the comma so far
        chunker.append(" turns out")
        #expect(chunker.next()?.text == "Well, the build failed because,")
        #expect(!chunker.releasesEarly)
        // Later chunks are sentences: the comma after "out" is not a cut.
        chunker.append(", the cache was stale")
        #expect(chunker.next()?.text == nil)
        chunker.append(". Next")
        #expect(chunker.next()?.text == "as it turns out, the cache was stale.")
        #expect(chunker.next()?.text == nil)
        #expect(chunker.flush()?.text == "Next")
        #expect(chunker.flush()?.text == nil)
    }

    @Test func theFirstChunkEndsAtAWordBoundaryAfterTwelveWords() {
        let twelve = "one two three four five six seven eight nine ten eleven twelve"
        var chunker = SpeechChunker()
        chunker.append(twelve + " thirteen fourteen")
        #expect(chunker.next()?.text == nil)  // only two words would follow the cut
        chunker.append(" fifteen")
        #expect(chunker.next()?.text == nil)  // "fifteen" may still be arriving
        chunker.append(" ")
        #expect(chunker.next()?.text == twelve)
        #expect(chunker.flush()?.text == "thirteen fourteen fifteen")
    }

    @Test func aCompleteSentenceIsReleasedWhateverItsLength() {
        var chunker = SpeechChunker()
        chunker.append("Sure. I'll")
        #expect(chunker.next()?.text == "Sure.")
        #expect(chunker.next()?.text == nil)
    }

    @Test func aCutNeverLeavesAFragmentShorterThanThreeWords() {
        var chunker = SpeechChunker()
        chunker.append("Okay so here we go now, done. Then")
        #expect(chunker.next()?.text == "Okay so here we go now, done.")
    }

    @Test func idleTextIsReleasedOnlyFromThreeWordsAndOnlyForTheFirstChunk() {
        var chunker = SpeechChunker()
        chunker.append("Hi there")
        #expect(!chunker.canReleaseIdle)
        #expect(chunker.releaseIdle()?.text == nil)
        chunker.append(" friend")
        #expect(!chunker.canReleaseIdle)  // "friend" may still be arriving
        chunker.append(".")
        #expect(chunker.canReleaseIdle)
        #expect(chunker.releaseIdle()?.text == "Hi there friend.")
        chunker.append(" and some more words here")
        #expect(!chunker.canReleaseIdle)  // no longer the first chunk
        #expect(chunker.releaseIdle()?.text == nil)
    }

    @Test func anIdleReleaseNeverSplitsAWordStillArriving() {
        var found = SpeechChunker()
        found.append("Here is what I fou")
        #expect(found.releaseIdle()?.text == "Here is what I")
        found.append("nd in the logs today. ")
        #expect(found.next()?.text == "found in the logs today.")
        var number = SpeechChunker()
        number.append("The total comes to 3")
        #expect(number.releaseIdle()?.text == "The total comes to")
        number.append(".5 dollars. ")
        #expect(number.next()?.text == "3.5 dollars.")
        var decimal = SpeechChunker()
        decimal.append("The total comes to 3.")  // the period may be a decimal point
        #expect(decimal.releaseIdle()?.text == "The total comes to")
        var clause = SpeechChunker()
        clause.append("Okay, so here it is:")
        #expect(clause.releaseIdle()?.text == "Okay, so here it is:")
    }

    @Test func markdownMarkersAndListNumbersAreNotWords() {
        #expect(SpeechChunker.wordCounts(Array("## Big - news **"), complete: true).last == 2)
        #expect(SpeechChunker.wordCounts(Array("1. Buy 2 eggs"), complete: true).last == 3)
        var heading = SpeechChunker()
        heading.append("## Big news ")
        #expect(!heading.canReleaseIdle)
    }

    @Test func eachChunkCarriesItsRangeInTheRawText() {
        var chunker = SpeechChunker()
        chunker.append("**Sure.** Then\n\nmore here. Tail")
        let first = chunker.next()
        #expect(first == SpeechChunker.Chunk(text: "**Sure.** Then", rawRange: 0..<14))
        #expect(chunker.next() == SpeechChunker.Chunk(text: "more here.", rawRange: 16..<26))
        #expect(chunker.flush() == SpeechChunker.Chunk(text: "Tail", rawRange: 27..<31))
    }

    @Test func aLongSentenceWaitsForWordsAfterItsBestClause() {
        let head = "The first part of this answer explains how the project is set up on your machine, "
            + "the second part walks through each of the failing tests one at a time,"
        var chunker = SpeechChunker()
        chunker.releasesEarly = false
        chunker.append(head + " and the third")
        #expect(chunker.next()?.text == nil)  // not the earlier clause, though it would fit
        chunker.append(" part")
        #expect(chunker.next()?.text == head)
    }

    @Test func aLongSentenceSplitsAtItsLastClauseWithinTheLimit() {
        let sentence = "The first part of this answer explains how the project is set up on your machine, "
            + "the second part walks through each of the failing tests one at a time, "
            + "and the third part covers the fix we applied."
        var chunker = SpeechChunker()
        chunker.releasesEarly = false
        chunker.append(sentence + " Next")
        #expect(chunker.next()?.text == "The first part of this answer explains how the project is set up on your machine, "
            + "the second part walks through each of the failing tests one at a time,")
        #expect(chunker.next()?.text == "and the third part covers the fix we applied.")
        #expect(chunker.next()?.text == nil)
    }

    @Test func numbersTimesAndRangesAreNotClauseBoundaries() {
        var chunker = SpeechChunker()
        chunker.append("Our team moved these large 1,000 files at 10:30 today, so the job is done")
        #expect(chunker.next()?.text == "Our team moved these large 1,000 files at 10:30 today,")
        var range = SpeechChunker()
        range.append("Read the pages numbered 3–5 and 7–9 carefully today — then come back here")
        #expect(range.next()?.text == "Read the pages numbered 3–5 and 7–9 carefully today —")
    }

    @Test func cutsNeverFallInsideInlineMarkup() {
        var bold = SpeechChunker()
        bold.append("**Note:** the build is slow today, so be patient with it")
        #expect(bold.next()?.text == "**Note:** the build is slow today,")
        var insideBold = SpeechChunker()
        insideBold.append("**Note: the build is slow today, so** be patient")
        #expect(insideBold.next()?.text == nil)
        var code = SpeechChunker()
        code.append("Run `make clean, build, test, deploy now` and then wait for it")
        #expect(code.next()?.text == nil)
        var link = SpeechChunker()
        link.append("Read [the long guide on setup, part one](https://e.com) first, then come back here")
        #expect(link.next()?.text == "Read [the long guide on setup, part one](https://e.com) first,")
        var open = SpeechChunker()
        open.append("This is **really important")
        #expect(!open.canReleaseIdle)  // the bold is still open
    }

    @Test func blankLinesProduceNoChunks() {
        var chunker = SpeechChunker()
        chunker.append("\n\n  \nHello there.\n\n")
        #expect(chunker.next()?.text == "Hello there.")
        #expect(chunker.next()?.text == nil)
        #expect(chunker.flush()?.text == nil)
    }
}
