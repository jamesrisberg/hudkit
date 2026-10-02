import Foundation
import Testing

@testable import VoiceKit

/// Records what it is asked to say; the test finishes each utterance.
@MainActor
final class RecordingVoice: SpeechVoice {
    let kind = SpeechVoiceKind.system
    var onSpeakingChanged: ((Bool) -> Void)?
    var onLevel: ((Double) -> Void)?
    var spoken: [String] = []
    var stops = 0
    private var completion: ((Result<Void, Error>) -> Void)?

    func speak(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        spoken.append(text)
        self.completion = completion
    }

    func stop() {
        stops += 1
        completion = nil
    }

    func finishCurrent(_ result: Result<Void, Error> = .success(())) {
        let callback = completion
        completion = nil
        callback?(result)
    }
}

/// A voice that can prefetch: records every `speak`, `prepare` and `play` call in order,
/// carrying a clip's text in `SpeechClip.audio` so a test can tell which sentence was played
/// without synthesizing anything. The test finishes each `speak`/`play` and each `prepare`.
@MainActor
final class RecordingPrefetchingVoice: PrefetchingSpeechVoice {
    let kind = SpeechVoiceKind.kokoro
    var onSpeakingChanged: ((Bool) -> Void)?
    var onLevel: ((Double) -> Void)?
    var spoken: [String] = []
    var played: [String] = []
    var prepared: [String] = []
    var stops = 0
    var warmUps = 0
    private var completion: ((Result<Void, Error>) -> Void)?
    private var prepareCompletions: [String: (Result<SpeechClip, Error>) -> Void] = [:]

    func speak(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        spoken.append(text)
        self.completion = completion
    }

    func prepare(_ text: String, completion: @escaping (Result<SpeechClip, Error>) -> Void) {
        prepared.append(text)
        prepareCompletions[text] = completion
    }

    func play(_ clip: SpeechClip, completion: @escaping (Result<Void, Error>) -> Void) {
        played.append(String(data: clip.audio, encoding: .utf8) ?? "")
        self.completion = completion
    }

    func stop() {
        stops += 1
        completion = nil
    }

    func warmUp() { warmUps += 1 }

    func finishCurrent(_ result: Result<Void, Error> = .success(())) {
        let callback = completion
        completion = nil
        callback?(result)
    }

    /// Resolves a `prepare(text:)` call; the clip carries `text` itself so `played` can decode
    /// it back.
    func finishPrepare(_ text: String, result: Result<SpeechClip, Error>? = nil) {
        let callback = prepareCompletions.removeValue(forKey: text)
        callback?(result ?? .success(SpeechClip(audio: Data(text.utf8))))
    }
}

struct SentenceSplitterTests {
    @Test func emitsSentencesOnlyOnceTheirEndIsCertain() {
        var splitter = SentenceSplitter()
        #expect(splitter.append("Hello there. How") == ["Hello there."])
        var more = SentenceSplitter()
        #expect(more.append("It costs 3.").isEmpty)  // could be 3.14
        #expect(more.append("14 dollars. Next") == ["It costs 3.14 dollars."])
        #expect(more.append("?") == [])
        #expect(more.append(" ok") == ["Next?"])
        #expect(more.flush() == "ok")
        #expect(more.flush() == nil)
    }

    @Test func handlesQuotesAbbreviationsAndLineBreaks() {
        var splitter = SentenceSplitter()
        #expect(splitter.append("He said \"stop!\" Then Dr. Lee left.\nNew line") ==
            ["He said \"stop!\"", "Then Dr. Lee left."])
        #expect(splitter.flush() == "New line")
        var list = SentenceSplitter()
        #expect(list.append("Bring snacks, e.g. chips. Done ") == ["Bring snacks, e.g. chips."])
    }

    @Test func listNumbersAndInitialismsDoNotEndASentence() {
        var list = SentenceSplitter()
        #expect(list.append("1. Buy milk. 2. Eggs. ") == ["1. Buy milk.", "2. Eggs."])
        var initialism = SentenceSplitter()
        #expect(initialism.append("The U.S. is big. Yes ") == ["The U.S. is big."])
        var answer = SentenceSplitter()
        #expect(answer.append("The answer is no. Next ") == ["The answer is no."])
    }

    @Test func cutsARunawaySentenceAtASpace() {
        var splitter = SentenceSplitter(maximumLength: 20)
        let sentences = splitter.append("one two three four five six seven eight")
        #expect(sentences == ["one two three four"])
        var unbroken = SentenceSplitter(maximumLength: 5)
        #expect(unbroken.append("abcdefghij") == ["abcde"])
        #expect(unbroken.flush() == "fghij")
    }
}

@MainActor
struct SpeechStreamerTests {
    @Test func speaksSentencesInOrderAsTheyArrive() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        var finished: [Bool] = []
        streamer.onFinished = { finished.append((try? $0.get()) != nil) }
        streamer.append("Sure. I'll ")
        #expect(voice.spoken == ["Sure."])
        streamer.append("check that. Then")
        #expect(voice.spoken == ["Sure."])  // one at a time
        voice.finishCurrent()
        #expect(voice.spoken == ["Sure.", "I'll check that."])
        streamer.append(" report back")
        streamer.finish()
        voice.finishCurrent()
        #expect(voice.spoken.last == "Then report back")
        #expect(finished.isEmpty)
        voice.finishCurrent()
        #expect(finished == [true])
        #expect(!streamer.isSpeaking)
    }

    @Test func stopDropsTheQueueAndLateCompletions() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        var finished = 0
        streamer.onFinished = { _ in finished += 1 }
        streamer.append("One. Two. Three ")
        streamer.stop()
        #expect(voice.stops == 1)
        voice.finishCurrent()
        #expect(voice.spoken == ["One."])
        #expect(finished == 0)
        // Usable again.
        streamer.append("Again.")
        streamer.finish()
        #expect(voice.spoken == ["One.", "Again."])
        voice.finishCurrent()
        #expect(finished == 1)
    }

    @Test func aFailureEndsTheStreamOnce() {
        struct Broken: Error {}
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        var results: [Bool] = []
        streamer.onFinished = { results.append((try? $0.get()) != nil) }
        streamer.append("One. Two. ")
        voice.finishCurrent(.failure(Broken()))
        #expect(results == [false])
        #expect(voice.spoken == ["One."])
        #expect(!streamer.isSpeaking)
        // Ended: more text is ignored and the end is reported once, until stop().
        streamer.append("Three. Four. ")
        streamer.finish()
        #expect(voice.spoken == ["One."])
        #expect(results == [false])
        streamer.stop()
        streamer.append("Five. ")
        #expect(voice.spoken == ["One.", "Five."])
    }

    @Test func aFinishedStreamIgnoresMoreTextUntilStopped() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        var finished = 0
        streamer.onFinished = { _ in finished += 1 }
        streamer.append("Done.")
        streamer.finish()
        voice.finishCurrent()
        #expect(finished == 1)
        streamer.append("Late. ")
        streamer.finish()
        #expect(voice.spoken == ["Done."])
        #expect(finished == 1)
    }

    @Test func finishingEmptyTextCompletesAtOnce() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        var finished = false
        streamer.onFinished = { _ in finished = true }
        streamer.finish()
        #expect(finished)
        #expect(voice.spoken.isEmpty)
    }

    @Test func stripsMarkdownAndSkipsCodeBlocksOnARealisticReply() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        streamer.append(
            "Here's how to fix it:\n\n```swift\nlet x = 1\nprint(x)\n```\n\n" +
            "**Note:** run `swift build` first. "
        )
        #expect(voice.spoken == ["Here's how to fix it:"])
        voice.finishCurrent()
        #expect(voice.spoken == ["Here's how to fix it:", "Note: run swift build first."])
        streamer.finish()
        voice.finishCurrent()
    }

    @Test func everyChunkIsPreparedAsSoonAsItIsQueuedAndPlayedOnceReady() {
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        streamer.append("One. Two. ")
        // Nothing plays yet, but both sentences are already synthesizing.
        #expect(voice.prepared == ["One.", "Two."])
        #expect(voice.played.isEmpty)
        #expect(streamer.isSpeaking)
        voice.finishPrepare("Two.")
        #expect(voice.played.isEmpty)  // "Two." waits for "One."
        voice.finishPrepare("One.")
        #expect(voice.played == ["One."])
        voice.finishCurrent()
        #expect(voice.played == ["One.", "Two."])
        // A prepared clip is played, never synthesized again.
        #expect(voice.spoken.isEmpty)
    }

    @Test func synthesisRunsUpToTwoChunksAheadOfTheOnePlaying() {
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        streamer.append("One. Two. Three. Four. Five. ")
        // Before anything plays: the next chunk plus two ahead of it.
        #expect(voice.prepared == ["One.", "Two.", "Three."])
        voice.finishPrepare("One.")
        #expect(voice.played == ["One."])
        #expect(voice.prepared == ["One.", "Two.", "Three."])
        voice.finishPrepare("Two.")
        voice.finishCurrent()
        #expect(voice.played == ["One.", "Two."])
        #expect(voice.prepared == ["One.", "Two.", "Three.", "Four."])
    }

    @Test func thePrefetchDepthIsConfigurable() {
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice, prefetchDepth: 0, clock: ManualSpeechClock())
        streamer.append("One. Two. Three. ")
        #expect(voice.prepared == ["One."])
        voice.finishPrepare("One.")
        #expect(voice.prepared == ["One."])  // nothing ahead of the one playing
        voice.finishCurrent()
        #expect(voice.prepared == ["One.", "Two."])
    }

    @Test func aFailedPreparationEndsTheStreamWhenItsTurnComes() {
        struct Broken: Error {}
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        var results: [Bool] = []
        streamer.onFinished = { results.append((try? $0.get()) != nil) }
        streamer.append("One. Two. ")
        voice.finishPrepare("Two.", result: .failure(Broken()))
        #expect(results.isEmpty)
        voice.finishPrepare("One.")
        voice.finishCurrent()
        #expect(results == [false])
        #expect(voice.played == ["One."])
        #expect(!streamer.isSpeaking)
    }

    @Test func stopCancelsPendingPreparationsAndIgnoresTheirLateCompletions() {
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        var finished = 0
        streamer.onFinished = { _ in finished += 1 }
        streamer.append("One. Two. ")
        #expect(voice.prepared == ["One.", "Two."])
        streamer.stop()
        #expect(voice.stops == 1)
        #expect(!streamer.isSpeaking)
        voice.finishPrepare("One.")  // late: must not play for the stopped stream
        voice.finishPrepare("Two.")
        #expect(voice.played.isEmpty)
        streamer.append("Again.")
        streamer.finish()
        voice.finishPrepare("Again.")
        #expect(voice.played == ["Again."])
        voice.finishCurrent()
        #expect(finished == 1)
    }

    @Test func theFirstChunkIsReleasedEarlyAtAClause() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        streamer.append("Well, the build failed because, as it turns out")
        #expect(voice.spoken == ["Well, the build failed because,"])
        streamer.append(", the cache was stale. ")
        voice.finishCurrent()
        #expect(voice.spoken == ["Well, the build failed because,", "as it turns out, the cache was stale."])
    }

    @Test func threeWordsThatWaitFourHundredMillisecondsAreSpoken() {
        let clock = ManualSpeechClock()
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: clock)
        streamer.append("Let me")
        clock.advance(by: 1)
        #expect(voice.spoken.isEmpty)  // two words never go early
        streamer.append(" check")
        clock.advance(by: 0.3)
        streamer.append(" the")  // new text restarts the wait
        clock.advance(by: 0.399)
        #expect(voice.spoken.isEmpty)
        clock.advance(by: 0.001)
        // "the" may be the start of a longer word, so it waits for the next text.
        #expect(voice.spoken == ["Let me check"])
        // Later chunks wait for their sentence however long the pause.
        streamer.append(" logs now")
        clock.advance(by: 5)
        voice.finishCurrent()
        #expect(voice.spoken == ["Let me check"])
        streamer.append(". ")
        #expect(voice.spoken == ["Let me check", "the logs now."])
    }

    @Test func aChunkFilteredAwayDoesNotCountAsTheFirst() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        streamer.append("```\nlet x = 1\n```\nWell, the build failed because, as it turns out")
        #expect(voice.spoken == ["Well, the build failed because,"])
    }

    @Test func chunkCallbacksReportEachSpokenChunkInOrder() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        var events: [String] = []
        streamer.onChunkStarted = { events.append("start \($0.index) \($0.text)") }
        streamer.onChunkFinished = { events.append("end \($0.index) \($0.text)") }
        streamer.append("One. **Two** more. ")
        #expect(events == ["start 0 One."])
        voice.finishCurrent()
        #expect(events == ["start 0 One.", "end 0 One.", "start 1 Two more."])
        streamer.stop()
        voice.finishCurrent()
        #expect(events == ["start 0 One.", "end 0 One.", "start 1 Two more."])
    }

    @Test func warmUpReachesTheVoice() {
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        streamer.warmUp()
        #expect(voice.warmUps == 1)
        #expect(voice.prepared.isEmpty)
    }

    @Test func metricsAreRecordedOncePerReply() {
        let clock = ManualSpeechClock()
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: clock)
        var reports: [SpeechStreamMetrics] = []
        streamer.onMetrics = { reports.append($0) }
        streamer.append("One. Two. ")
        clock.advance(by: 0.25)
        voice.finishPrepare("One.")
        clock.advance(by: 1)
        voice.finishCurrent()  // "Two." is not ready: a gap starts
        clock.advance(by: 0.2)
        voice.finishPrepare("Two.")
        streamer.finish()
        clock.advance(by: 1)
        voice.finishCurrent()
        #expect(reports == [SpeechStreamMetrics(
            outcome: .finished, firstChunkQueuedMilliseconds: 0, firstAudioMilliseconds: 250,
            chunks: 2, underruns: 1, underrunMilliseconds: 200, textUnderruns: 0,
            textUnderrunMilliseconds: 0, synthesisUnderruns: 1, synthesisUnderrunMilliseconds: 200)])
        #expect(streamer.lastMetrics == reports.first)
        streamer.stop()
        #expect(reports.count == 1)
    }

    @Test func aStoppedReplyReportsItsMetricsOnce() {
        let clock = ManualSpeechClock()
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: clock)
        var reports: [SpeechStreamMetrics] = []
        streamer.onMetrics = { reports.append($0) }
        clock.advance(by: 1)
        streamer.append("Some text")
        clock.advance(by: 0.5)
        streamer.append(" arrives slowly. ")
        streamer.stop()
        streamer.stop()
        #expect(reports == [SpeechStreamMetrics(
            outcome: .stopped, firstChunkQueuedMilliseconds: 500, firstAudioMilliseconds: 500,
            chunks: 1, underruns: 0, underrunMilliseconds: 0, textUnderruns: 0,
            textUnderrunMilliseconds: 0, synthesisUnderruns: 0, synthesisUnderrunMilliseconds: 0)])
    }

    @Test func underrunsSeparateWaitingForTextFromWaitingForSynthesis() {
        let clock = ManualSpeechClock()
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: clock)
        var metrics: SpeechStreamMetrics?
        streamer.onMetrics = { metrics = $0 }
        streamer.append("One. ")
        voice.finishPrepare("One.")
        clock.advance(by: 1)
        voice.finishCurrent()  // nothing queued: waiting for text
        clock.advance(by: 0.3)
        streamer.append("Two. ")  // queued: now waiting for its synthesis
        clock.advance(by: 0.2)
        voice.finishPrepare("Two.")
        streamer.finish()
        voice.finishCurrent()
        #expect(metrics == SpeechStreamMetrics(
            outcome: .finished, firstChunkQueuedMilliseconds: 0, firstAudioMilliseconds: 0,
            chunks: 2, underruns: 1, underrunMilliseconds: 500, textUnderruns: 1,
            textUnderrunMilliseconds: 300, synthesisUnderruns: 1, synthesisUnderrunMilliseconds: 200))
    }

    @Test func chunksCarryTheirRangeInTheRawReply() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        var chunks: [SpeechChunk] = []
        streamer.onChunkStarted = { chunks.append($0) }
        streamer.append("**One** two three. Four five six. ")
        voice.finishCurrent()
        #expect(chunks == [
            SpeechChunk(text: "One two three.", index: 0, rawRange: 0..<18),
            SpeechChunk(text: "Four five six.", index: 1, rawRange: 19..<33),
        ])
    }

    @Test func aFailureStopsSynthesisAheadSoItCannotDelayTheNextReply() {
        struct Broken: Error {}
        let clock = ManualSpeechClock()
        let voice = TimedVoice(clock: clock, synthesisLatency: 0.3, secondsPerWord: 0.3)
        voice.failing = ["One."]
        let streamer = SpeechStreamer(voice: voice, clock: clock)
        var results: [Bool] = []
        streamer.onFinished = { results.append((try? $0.get()) != nil) }
        streamer.append("One. Two. Three. ")
        #expect(voice.prepared == ["One.", "Two.", "Three."])
        clock.advance(by: 0.3)
        #expect(results == [false])
        #expect(voice.stops == 1)
        clock.advance(by: 5)
        #expect(voice.spans.isEmpty)
    }

    @Test func aFastStreamIsSpokenWithoutGaps() throws {
        let clock = ManualSpeechClock()
        let voice = TimedVoice(clock: clock, synthesisLatency: 0.3, secondsPerWord: 0.3)
        let streamer = SpeechStreamer(voice: voice, clock: clock)
        var metrics: SpeechStreamMetrics?
        streamer.onMetrics = { metrics = $0 }
        let reply = "Okay, so the build failed, because the cache was stale. I cleared it and ran the "
            + "tests again. Everything passes now, and the app launches. Let me know if you want more."
        for piece in pieces(of: reply, size: 4) {
            streamer.append(piece)
            clock.advance(by: 0.01)
        }
        streamer.finish()
        clock.advance(by: 60)
        #expect(voice.spans.map(\.text) == [
            "Okay, so the build failed,", "because the cache was stale.",
            "I cleared it and ran the tests again.", "Everything passes now, and the app launches.",
            "Let me know if you want more.",
        ])
        for (earlier, later) in zip(voice.spans, voice.spans.dropFirst()) {
            #expect(abs(later.start - earlier.end) < 0.000_001, "no gap before \(later.text)")
        }
        let measured = try #require(metrics)
        #expect(measured.outcome == .finished)
        #expect(measured.underruns == 0)
        #expect((measured.firstChunkQueuedMilliseconds ?? .max) < 200)
        #expect((measured.firstAudioMilliseconds ?? .max) < 500)
    }

    @Test func aSlowStreamPausesOnlyBetweenChunks() throws {
        let clock = ManualSpeechClock()
        let voice = TimedVoice(clock: clock, synthesisLatency: 0.3, secondsPerWord: 0.3)
        let streamer = SpeechStreamer(voice: voice, clock: clock)
        var metrics: SpeechStreamMetrics?
        streamer.onMetrics = { metrics = $0 }
        let reply = "Okay, so the build failed, because the cache was stale. "
            + "I cleared it and ran every one of the tests again. Everything passes now."
        // A word every 0.38 s: slower than speech, but never a 400 ms silence.
        for word in reply.split(separator: " ") {
            streamer.append(String(word) + " ")
            clock.advance(by: 0.38)
        }
        streamer.finish()
        clock.advance(by: 60)
        #expect(voice.spans.map(\.text) == [
            "Okay, so the build failed,", "because the cache was stale.",
            "I cleared it and ran every one of the tests again.", "Everything passes now.",
        ])
        let measured = try #require(metrics)
        #expect(measured.underruns > 0)
        #expect(measured.underrunMilliseconds > 0)
        #expect(measured.textUnderruns > 0)
    }

    @Test func stopMidReplyDropsEverything() {
        let clock = ManualSpeechClock()
        let voice = TimedVoice(clock: clock, synthesisLatency: 0.3, secondsPerWord: 0.3)
        let streamer = SpeechStreamer(voice: voice, clock: clock)
        var started = 0
        var finished = 0
        var metrics: SpeechStreamMetrics?
        streamer.onChunkStarted = { _ in started += 1 }
        streamer.onFinished = { _ in finished += 1 }
        streamer.onMetrics = { metrics = $0 }
        streamer.append("Okay, so the build failed, because the cache was stale. I cleared it. It works now. ")
        clock.advance(by: 1)
        #expect(voice.spans.map(\.text) == ["Okay, so the build failed,"])
        streamer.stop()
        #expect(voice.stops == 1)
        #expect(!streamer.isSpeaking)
        clock.advance(by: 30)
        #expect(voice.spans.count == 1)
        #expect(started == 1)
        #expect(finished == 0)
        #expect(metrics?.outcome == .stopped)
        // Usable again.
        streamer.append("Again.")
        streamer.finish()
        clock.advance(by: 5)
        #expect(voice.spans.map(\.text) == ["Okay, so the build failed,", "Again."])
        #expect(finished == 1)
    }

    @Test func aVoiceThatCannotPrefetchKeepsWorking() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice, clock: ManualSpeechClock())
        streamer.append("One. Two. ")
        #expect(voice.spoken == ["One."])
        voice.finishCurrent()
        #expect(voice.spoken == ["One.", "Two."])
        voice.finishCurrent()
    }
}
