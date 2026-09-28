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
        let streamer = SpeechStreamer(voice: voice)
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
        let streamer = SpeechStreamer(voice: voice)
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
        let streamer = SpeechStreamer(voice: voice)
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
        let streamer = SpeechStreamer(voice: voice)
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
        let streamer = SpeechStreamer(voice: voice)
        var finished = false
        streamer.onFinished = { _ in finished = true }
        streamer.finish()
        #expect(finished)
        #expect(voice.spoken.isEmpty)
    }

    @Test func stripsMarkdownAndSkipsCodeBlocksOnARealisticReply() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice)
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

    @Test func prefetchesTheNextSentenceWhileTheCurrentPlays() {
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice)
        streamer.append("One. Two. Three. ")
        #expect(voice.spoken == ["One."])
        // The next sentence starts synthesizing immediately, while "One." is still speaking.
        #expect(voice.prepared == ["Two."])
        voice.finishPrepare("Two.")
        voice.finishCurrent()
        // The prepared clip is played directly, never re-spoken.
        #expect(voice.spoken == ["One."])
        #expect(voice.played == ["Two."])
        #expect(voice.prepared == ["Two.", "Three."])
        voice.finishPrepare("Three.")
        voice.finishCurrent()
        #expect(voice.played == ["Two.", "Three."])
        voice.finishCurrent()
    }

    @Test func fallsBackToSpeakWhenThePrefetchIsNotReadyYet() {
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice)
        streamer.append("One. Two. ")
        #expect(voice.spoken == ["One."])
        #expect(voice.prepared == ["Two."])
        // "One." finishes before the prefetch for "Two." does.
        voice.finishCurrent()
        #expect(voice.spoken == ["One.", "Two."])
        #expect(voice.played.isEmpty)
    }

    @Test func stopCancelsAPendingPrefetchAndIgnoresItsLateCompletion() {
        let voice = RecordingPrefetchingVoice()
        let streamer = SpeechStreamer(voice: voice)
        streamer.append("One. Two. ")
        #expect(voice.prepared == ["Two."])
        streamer.stop()
        #expect(voice.stops == 1)
        voice.finishPrepare("Two.")  // late: must not resurrect a clip for the stopped stream
        streamer.append("Again.")
        streamer.finish()
        #expect(voice.spoken == ["One.", "Again."])
        #expect(voice.played.isEmpty)
    }

    @Test func aVoiceThatCannotPrefetchKeepsWorking() {
        let voice = RecordingVoice()
        let streamer = SpeechStreamer(voice: voice)
        streamer.append("One. Two. ")
        #expect(voice.spoken == ["One."])
        voice.finishCurrent()
        #expect(voice.spoken == ["One.", "Two."])
        voice.finishCurrent()
    }
}
