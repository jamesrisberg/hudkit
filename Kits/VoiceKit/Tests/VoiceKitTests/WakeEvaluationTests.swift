import AVFoundation
import Foundation
import Testing

@testable import VoiceKit

/// The rule arithmetic and the audio loader behind the evaluation, on small made-up inputs.
struct WakeEvaluationCountingTests {
    @Test func oneFrameFiresOnlyUnderAOneFrameRule() {
        let scores: [Float] = [0, 0.2, 0.9, 0.1, 0]
        #expect(WakeEvaluation.events(in: scores, threshold: 0.5, run: 1).map(\.frame) == [2])
        #expect(WakeEvaluation.events(in: scores, threshold: 0.5, run: 2).isEmpty)
        #expect(WakeEvaluation.events(in: scores, threshold: 0.95, run: 1).isEmpty)
    }

    @Test func aDipBreaksTheRun() {
        let scores: [Float] = [0.9, 0.9, 0.2, 0.9, 0.9, 0.9]
        #expect(WakeEvaluation.events(in: scores, threshold: 0.5, run: 3).map(\.frame) == [5])
        #expect(WakeEvaluation.longestRun(in: scores, atLeast: 0.5) == 3)
        #expect(WakeEvaluation.runs(in: scores, atLeast: 0.5).map(\.start) == [0, 3])
    }

    @Test func twoSecondsAreSkippedAfterAnEvent() {
        // 80 ms frames: the skip is 25 frames, so a constant high score fires every 26th.
        let loud = [Float](repeating: 0.9, count: 60)
        #expect(WakeEvaluation.skipFrames == 25)
        #expect(WakeEvaluation.events(in: loud, threshold: 0.5, run: 1).map(\.frame) == [0, 26, 52])
        // A three-frame rule restarts its count after the skip: events complete at 2, 30, 58.
        #expect(WakeEvaluation.events(in: loud, threshold: 0.5, run: 3).map(\.frame) == [2, 30, 58])
    }

    @MainActor @Test func theRealDetectorPlacesItsWakesAsTheReplayDoes() async throws {
        // A constant high score: armed again after each skip, the detector fires where the replay does.
        let engine = ScriptedWakeEngine()
        engine.setNext(0.9)
        let samples = [Float](repeating: 0, count: 60 * WakeEvaluation.frameSamples + 500)
        let scores = [Float](repeating: 0.9, count: 60)
        let detected = try await WakeEvaluation.detections(samples, with: engine, threshold: 0.5, frames: 2)
        #expect(detected.map(\.frame) == [1, 28, 55])
        #expect(detected == WakeEvaluation.events(in: scores, threshold: 0.5, run: 2))

        // Agreement is judged at the owner's threshold and the settings default.
        let atDefault = try await WakeEvaluation.detections(
            samples, with: engine, threshold: WakeEvaluation.ownerThreshold, frames: WakeEvaluation.detectorFrames)
        func agreement(_ events: [WakeEvaluation.Event]) -> WakeEvaluation.FileResult.Agreement {
            WakeEvaluation.FileResult(name: "x", scores: scores, detected: events, failure: nil).agreement
        }
        #expect(agreement(atDefault) == .agrees)
        #expect(agreement(Array(atDefault.prefix(1))) == .differsAfterARearm)
        #expect(agreement([]) == .disagrees)
    }

    @Test func aFileWithNoWholeFrameIsAFailure() async throws {
        let directory = try temporaryDirectory("wake-eval")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        func silence(_ count: Int, _ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                ])
            try file.write(from: buffer)
            return url
        }
        let engine = ScriptedWakeEngine()
        let short = await WakeEvaluation.evaluate(try silence(1000, "short.wav"), padSeconds: 0, with: engine)
        #expect(short.failure != nil)
        let whole = await WakeEvaluation.evaluate(try silence(2560, "whole.wav"), padSeconds: 0, with: engine)
        #expect(whole.failure == nil)
        #expect(whole.scores.count == 2)
        let missing = await WakeEvaluation.evaluate(
            directory.appendingPathComponent("missing.wav"), padSeconds: 0, with: engine)
        #expect(missing.failure != nil)
    }

    @Test func theComparisonIsTheDetectors() {
        // `>=` on the score widened to Double, so an exact tie fires.
        #expect(WakeEvaluation.events(in: [0.5], threshold: 0.5, run: 1).count == 1)
        #expect(WakeEvaluation.events(in: [Float(0.4999)], threshold: 0.5, run: 1).isEmpty)
    }

    @Test func loadsAndResamplesOtherFormatsToSixteenKilohertzMono() throws {
        let directory = try temporaryDirectory("wake-eval")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let url = directory.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frameCount: AVAudioFrameCount = 48_000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            let value = Float(sin(2 * Double.pi * 440 * Double(index) / 48_000)) * 0.5
            buffer.floatChannelData![0][index] = value
            buffer.floatChannelData![1][index] = value
        }
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                ])
            try file.write(from: buffer)
        }
        let samples = try WakeEvaluation.samples(from: url, padSeconds: 1)
        // One second of tone at 16 kHz plus a second of silence each side, give or take the
        // converter's edge frames.
        #expect(abs(samples.count - 48_000) < 400)
        #expect(samples.prefix(16_000).allSatisfy { $0 == 0 })
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0.45 && peak < 0.55, "peak \(peak)")
    }
}

/// Scores recorded audio through the real openWakeWord engine and prints how often each
/// threshold and consecutive-frame rule would have woken the detector. An instrument: it asserts
/// nothing about rates. Opt-in, and it only reads the files it is pointed at:
///
///     VOICEKIT_WAKE_MODELS="$HOME/Library/Application Support/MacHUD/Voice/Models/openwakeword-hey-jarvis-v0.1" \
///     VOICEKIT_WAKE_EVAL_AUDIO=~/.config/speakfree/recordings VOICEKIT_WAKE_EVAL_LATEST=400 \
///     swift test --filter WakeEvaluationTests
///
/// See `WakeEvaluation.configuration()` for the other variables. `Tests/WakeEval/make-synthetic.sh`
/// renders "Hey Jarvis" and sound-alike phrases with `say` for the positive side (use
/// `VOICEKIT_WAKE_EVAL_PAD_SECONDS=1`, as the fixture test pads).
struct WakeEvaluationTests {
    @Test(
        .enabled(
            if: WakeEvaluation.configuration() != nil,
            "set VOICEKIT_WAKE_MODELS to a folder with the Hey Jarvis files and VOICEKIT_WAKE_EVAL_AUDIO to a folder of .wav files or a text file listing them"
        ))
    func scoresAudioThroughTheRealEngine() async throws {
        let configuration = try #require(WakeEvaluation.configuration())
        // Installed through the seed path, which also checks the model files' hashes.
        let directory = try temporaryDirectory("wake")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let model = WakeModels.heyJarvis
        try await ModelStore.install(
            model.manifest.seeded(from: [configuration.models]), into: directory,
            downloader: { _, _, _ in throw ModelDownload.Failure.invalidDownload }, progress: { _, _ in })

        let files = try WakeEvaluation.files(at: configuration.audio, latest: configuration.latest)
        let workers = min(configuration.workers, max(1, files.count))
        let engines = try (0..<workers).map { _ in try OpenWakeWordEngine(model: model, directory: directory) }
        let results = Locked([WakeEvaluation.FileResult?](repeating: nil, count: files.count))
        let cursor = Locked(0)
        let started = Date()

        await withTaskGroup(of: Void.self) { group in
            for engine in engines {
                group.addTask {
                    while true {
                        var index = 0
                        cursor.mutate {
                            index = $0
                            $0 += 1
                        }
                        guard index < files.count else { return }
                        let result = await WakeEvaluation.evaluate(
                            files[index], padSeconds: configuration.padSeconds, with: engine)
                        results.mutate { $0[index] = result }
                        if (index + 1) % 50 == 0 {
                            print("wake evaluation: file \(index + 1) of \(files.count) scored")
                            // Redirected to a file, standard output is block-buffered and the line would
                            // appear only when the run ends.
                            fflush(stdout)
                        }
                    }
                }
            }
        }

        let finished = results.value.compactMap { $0 }
        let report = WakeEvaluation.report(
            label: configuration.label, results: finished, padSeconds: configuration.padSeconds,
            wallSeconds: Date().timeIntervalSince(started))
        print(report)
        fflush(stdout)
        #expect(finished.contains { $0.failure == nil }, "no file could be scored")
        let disagreeing = finished.filter { $0.failure == nil && $0.agreement == .disagrees }.map(\.name)
        #expect(disagreeing.isEmpty, "InProcessWakeDetector and the replay disagree on the first wake: \(disagreeing)")
    }
}
