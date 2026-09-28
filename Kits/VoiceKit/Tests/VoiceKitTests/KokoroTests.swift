import AVFoundation
import Foundation
import Testing

@testable import VoiceKit

private actor SynthesisGate {
    var calls: [(String, String, Double)] = []
    var pending: [CheckedContinuation<[Float], Error>] = []
    func run(_ text: String, _ voice: String, _ speed: Double) async throws -> [Float] {
        calls.append((text, voice, speed))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func count() -> Int { pending.count }
    func finish(_ index: Int, result: Result<[Float], Error>) { pending[index].resume(with: result) }
    func lastSpeed() -> Double? { calls.last?.2 }
}

@MainActor
private func speakAndWait(_ voice: SpeechVoice, _ text: String) async -> Result<Void, Error> {
    await withCheckedContinuation { continuation in
        voice.speak(text) { continuation.resume(returning: $0) }
    }
}

@MainActor
struct KokoroVoiceTests {
    @Test func wavHeaderAndSamplesArePlayableAndClipped() throws {
        let wave = try KokoroVoice.wave([-2, -1, 0, 1, 2])
        #expect(wave.count == 54)
        #expect(String(data: wave.prefix(4), encoding: .utf8) == "RIFF")
        #expect(String(data: wave[8..<16], encoding: .utf8) == "WAVEfmt ")
        #expect(Array(wave[22..<24]) == [1, 0])  // one channel
        #expect(Array(wave[24..<28]) == [0xc0, 0x5d, 0, 0])  // 24000 Hz
        #expect(Array(wave[44...]) == [0, 128, 0, 128, 0, 0, 255, 127, 255, 127])
        let player = try AVAudioPlayer(data: wave)
        #expect(player.numberOfChannels == 1)
        #expect(abs(player.duration - 5.0 / 24000) < 0.00001)
    }

    @Test func invalidPCMAndInputAreRejected() {
        for samples: [Float] in [[], [.nan], [.infinity], [-.infinity]] {
            #expect(throws: KokoroVoice.Failure.self) { try KokoroVoice.wave(samples) }
        }
        #expect(throws: KokoroVoice.Failure.self) {
            try KokoroVoice.wave(Array(repeating: 0, count: KokoroVoice.maximumSamples + 1))
        }
        for (text, voice, speed) in [
            ("", "af_heart", 1.0), ("hello", "", 1),
            (String(repeating: "a", count: 3001), "af_heart", 1),
            ("hello", "af_heart", 0.49), ("hello", "af_heart", 2.01),
            ("hello", "af_heart", Double.nan), ("hello", "af_heart", Double.infinity),
        ] {
            #expect(throws: KokoroVoice.Failure.self) {
                try KokoroVoice.validate(text: text, voice: voice, speed: speed)
            }
        }
    }

    @Test func invalidInputNeverStartsInference() async {
        let gate = SynthesisGate()
        let voice = KokoroVoice(options: .init(voice: "af_heart", speed: .nan)) { try await gate.run($0, $1, $2) }
        let result = await speakAndWait(voice, "hello")
        #expect((try? result.get()) == nil)
        #expect(await gate.count() == 0)
    }

    @Test func speaksWithTheCurrentOptions() async throws {
        let gate = SynthesisGate()
        let player = try FakePlayer(data: silentWave())
        let voice = KokoroVoice(makePlayer: { _ in player }) { try await gate.run($0, $1, $2) }
        voice.options.speed = 1.5
        voice.speak("hello") { _ in }
        while await gate.count() == 0 { await Task.yield() }
        #expect(await gate.lastSpeed() == 1.5)
        voice.stop()
    }

    @Test func cancelledSynthesisCannotPlayOrComplete() async {
        let gate = SynthesisGate()
        var players = 0
        let voice = KokoroVoice(makePlayer: { data in
            players += 1
            return try FakePlayer(data: data)
        }) { try await gate.run($0, $1, $2) }
        var completed = false
        voice.speak("hello") { _ in completed = true }
        while await gate.count() == 0 { await Task.yield() }
        voice.stop()
        await gate.finish(0, result: .success([0, 0]))
        for _ in 0..<100 { await Task.yield() }
        #expect(players == 0)
        #expect(!completed)
    }

    @Test func replacementAndLateDelegatesCannotFinishCurrentPlayback() async throws {
        let gate = SynthesisGate()
        let wave = try KokoroVoice.wave(Array(repeating: 0, count: 100))
        let first = try FakePlayer(data: wave)
        let second = try FakePlayer(data: wave)
        var players = [first, second]
        let voice = KokoroVoice(makePlayer: { _ in players.removeFirst() }) { try await gate.run($0, $1, $2) }
        var events: [Bool] = []
        var oldCompletions = 0
        var completions = 0
        voice.onSpeakingChanged = { events.append($0) }
        voice.speak("stale") { _ in oldCompletions += 1 }
        while await gate.count() < 1 { await Task.yield() }
        voice.speak("first") { _ in oldCompletions += 1 }
        while await gate.count() < 2 { await Task.yield() }
        await gate.finish(0, result: .success([0, 0]))
        await gate.finish(1, result: .success([0, 0]))
        while events.isEmpty { await Task.yield() }
        #expect(first.fakePlaying)
        voice.speak("second") { result in
            if case .success = result { completions += 1 }
        }
        while await gate.count() < 3 { await Task.yield() }
        await gate.finish(2, result: .success([0, 0]))
        while events.count < 3 { await Task.yield() }
        #expect(!first.fakePlaying)
        #expect(second.fakePlaying)
        voice.playback.audioPlayerDidFinishPlaying(first, successfully: true)
        voice.playback.audioPlayerDecodeErrorDidOccur(first, error: nil)
        for _ in 0..<100 { await Task.yield() }
        #expect(completions == 0)
        #expect(oldCompletions == 0)
        #expect(second.fakePlaying)
        voice.playback.audioPlayerDidFinishPlaying(second, successfully: true)
        while completions == 0 { await Task.yield() }
        #expect(events == [true, false, true, false])
        #expect(!second.fakePlaying)
    }

    @Test func rejectedPlaybackReportsErrorWithoutSpeaking() async throws {
        let player = try FakePlayer(data: KokoroVoice.wave([0, 0]))
        player.acceptsPlayback = false
        let voice = KokoroVoice(makePlayer: { _ in player }) { _, _, _ in [0, 0] }
        var speaking = false
        voice.onSpeakingChanged = { speaking = speaking || $0 }
        let result = await speakAndWait(voice, "Hello")
        #expect((try? result.get()) == nil)
        #expect(!speaking)
        #expect(!player.fakePlaying)
    }
}

struct KokoroEngineTests {
    @Test func phrasesBoundLongUnbrokenText() {
        let input = String(repeating: "x", count: 3_000)
        let chunks = KokoroEngine.phrases(input, limit: 180)
        #expect(chunks.joined() == input)
        #expect(chunks.allSatisfy { $0.count <= 180 })
    }

    @Test func phrasesPreserveWordsAndDiscardBlankInput() {
        #expect(KokoroEngine.phrases("  \n  ", limit: 180).isEmpty)
        let chunks = KokoroEngine.phrases("A short sentence. And another one.", limit: 20)
        #expect(chunks == ["A short sentence.", "And another one."])
    }

    @Test func missingAssetsDoNotTriggerDownload() async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let engine = KokoroEngine(modelDirectory: directory)
        await #expect(throws: KokoroEngine.Failure.self) {
            _ = try await engine.synthesize(text: "Hello", voice: "af_heart", speed: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aCancelledRequestCannotLoadTheModel() async {
        let engine = KokoroEngine(modelDirectory: URL(fileURLWithPath: "/missing-model"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await engine.synthesize(text: "Hello", voice: "af_heart", speed: 1)
                Issue.record("Cancelled synthesis should throw")
            } catch is CancellationError {} catch {
                Issue.record("Expected cancellation before model loading, got \(error)")
            }
        }
        await task.value
    }
}

/// `VOICEKIT_KOKORO_MODELS`: an installed Kokoro folder (for example Archibald's
/// `~/Library/Application Support/Archibald/Models/Kokoro-82M/<revision>`). Synthesizes only;
/// nothing is played.
private let kokoroModels = environmentDirectory("VOICEKIT_KOKORO_MODELS")

struct RealKokoroTests {
    @Test(.enabled(if: kokoroModels != nil, "set VOICEKIT_KOKORO_MODELS to an installed Kokoro folder"))
    func synthesizesFiniteAudibleSpeechOffline() async throws {
        let engine = KokoroEngine(modelDirectory: try #require(kokoroModels))
        for (voice, speed): (String, Float) in [("af_heart", 1), ("bm_george", 1.2)] {
            let start = Date()
            let audio = try await engine.synthesize(
                text: "Hello. This voice is running on your Mac.", voice: voice, speed: speed)
            #expect(!audio.isEmpty)
            #expect(audio.allSatisfy { $0.isFinite })
            #expect(audio.contains { abs($0) > 0.001 })
            print("\(voice) speed=\(speed): \(Double(audio.count) / 24_000) s of audio in \(Date().timeIntervalSince(start)) s")
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.synthesize(text: "This must not play.", voice: "af_heart", speed: 1)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    }
}
