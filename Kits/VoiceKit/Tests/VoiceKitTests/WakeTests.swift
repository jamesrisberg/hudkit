import AVFoundation
import Foundation
import Testing

@testable import VoiceKit

/// Scores frames from a script; the default is silence.
final class ScriptedWakeEngine: WakeScoringEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var scores: [Float] = []
    private var frames = 0
    private var resets = 0
    private var nextScore: Float = 0

    func push(_ values: [Float]) { lock.withLock { scores.append(contentsOf: values) } }
    func setNext(_ value: Float) { lock.withLock { nextScore = value } }
    var frameCount: Int { lock.withLock { frames } }
    var resetCount: Int { lock.withLock { resets } }

    func reset() async throws { lock.withLock { resets += 1 } }
    func score(_ frame: [Float]) async throws -> Float {
        precondition(frame.count == 1280)
        return lock.withLock {
            frames += 1
            return scores.isEmpty ? nextScore : scores.removeFirst()
        }
    }
}

/// Stands in for the host's microphone; tests push samples by hand.
@MainActor
final class FakeAudioSource: WakeAudioSource {
    var onSamples: (([Float]) -> Void)?
    var running = false
    var starts = 0
    var failure: Error?

    func start() async throws {
        if let failure { throw failure }
        starts += 1
        running = true
    }

    func stop() { running = false }

    func push(_ count: Int, value: Float = 0.01) { onSamples?(Array(repeating: value, count: count)) }
}

@MainActor
struct InProcessWakeDetectorTests {
    @Test func firesOnConsecutiveFramesOncePerArm() async throws {
        let engine = ScriptedWakeEngine()
        let detector = InProcessWakeDetector(engine: engine, phrase: "Hey Jarvis", model: "scripted")
        await #expect(throws: WakeDetectorError.self) { _ = try await detector.detect([0]) }
        let info = try await detector.arm(threshold: 0.5, frames: 2)
        #expect(info.phrase == "Hey Jarvis")
        #expect(try await detector.detect(Array(repeating: 0, count: 1000)) == nil)
        #expect(engine.frameCount == 0)  // less than one frame buffered
        // A single frame at or above the threshold is not a wake; a frame below restarts the count.
        engine.push([0.1, 0.7, 0.2, 0.6])
        #expect(try await detector.detect(Array(repeating: 0, count: 4120)) == nil)
        #expect(engine.frameCount == 4)
        // The run carries over from one chunk to the next: 0.6, then 0.9 wakes.
        engine.push([0.9])
        let hit = try await detector.detect(Array(repeating: 0, count: 1280))
        #expect(hit == WakeDetection(score: Double(Float(0.9)), phrase: "Hey Jarvis", frames: 2, peak: Double(Float(0.9))))
        #expect(engine.frameCount == 5)
        // Latched until armed again.
        await #expect(throws: WakeDetectorError.self) {
            _ = try await detector.detect(Array(repeating: 0, count: 1280))
        }
        _ = try await detector.arm(threshold: 0.9, frames: 1)
        engine.push([0.8])
        #expect(try await detector.detect(Array(repeating: 0, count: 1280)) == nil)
        engine.push([0.95])
        #expect(try await detector.detect(Array(repeating: 0, count: 1280))?.frames == 1)
    }

    @Test func aDetectionCarriesItsRunAndPeak() async throws {
        let engine = ScriptedWakeEngine()
        let detector = InProcessWakeDetector(engine: engine, phrase: "x", model: "x")
        _ = try await detector.arm(threshold: 0.5, frames: 3)
        engine.push([0.7, 0.98, 0.6])
        let hit = try #require(try await detector.detect(Array(repeating: 0, count: 3840)))
        #expect(hit.score == Double(Float(0.6)))
        #expect(hit.frames == 3)
        #expect(hit.peak == Double(Float(0.98)))
        // An older caller's detection is a run of one frame that peaked at its score.
        #expect(WakeDetection(score: 0.7, phrase: "x") == WakeDetection(score: 0.7, phrase: "x", frames: 1, peak: 0.7))
    }

    @Test func armingAgainRestartsTheCount() async throws {
        let engine = ScriptedWakeEngine()
        let detector = InProcessWakeDetector(engine: engine, phrase: "x", model: "x")
        _ = try await detector.arm(threshold: 0.5, frames: 2)
        engine.push([0.9])
        #expect(try await detector.detect(Array(repeating: 0, count: 1280)) == nil)
        _ = try await detector.arm(threshold: 0.5, frames: 2)
        engine.push([0.9])
        #expect(try await detector.detect(Array(repeating: 0, count: 1280)) == nil)
        engine.push([0.9])
        #expect(try await detector.detect(Array(repeating: 0, count: 1280))?.frames == 2)
    }

    @Test func rejectsBadAudioThresholdsAndFrameCounts() async throws {
        let detector = InProcessWakeDetector(engine: ScriptedWakeEngine(), phrase: "x", model: "x")
        await #expect(throws: WakeDetectorError.invalidThreshold) { _ = try await detector.arm(threshold: 0.99, frames: 2) }
        await #expect(throws: WakeDetectorError.invalidFrames) { _ = try await detector.arm(threshold: 0.5, frames: 0) }
        await #expect(throws: WakeDetectorError.invalidFrames) { _ = try await detector.arm(threshold: 0.5, frames: 5) }
        #expect(InProcessWakeDetector.framesRange == 1...4)
        _ = try await detector.arm(threshold: 0.5, frames: 2)
        // A loud sample outside -1...1 is clipped by the engine, not an error.
        #expect(try await detector.detect([2, -3]) == nil)
        await #expect(throws: WakeDetectorError.self) { _ = try await detector.detect([.nan]) }
        // Any error disarms.
        await #expect(throws: WakeDetectorError.self) { _ = try await detector.detect([0]) }
        _ = try await detector.arm(threshold: 0.5, frames: 2)
        await #expect(throws: WakeDetectorError.self) {
            _ = try await detector.detect(Array(repeating: 0, count: 16_001))
        }
    }
}

@MainActor
struct WakeListenerTests {
    @Test func listensThenReportsOneWakeUntilRearmed() async throws {
        let engine = ScriptedWakeEngine()
        let source = FakeAudioSource()
        let listener = WakeListener(
            detector: InProcessWakeDetector(engine: engine, phrase: "Hey Computer", model: "scripted"),
            source: source, frames: 2)
        var wakes: [WakeDetection] = []
        listener.onWake = { wakes.append($0) }
        #expect(listener.state == .idle)
        await listener.start()
        #expect(listener.state == .listening)
        #expect(source.running)
        #expect(listener.info?.phrase == "Hey Computer")

        // Background audio: scored, no wake.
        source.push(2560)
        try await eventually { engine.frameCount == 2 }
        #expect(wakes.isEmpty)

        // One frame at the threshold is not enough for a two-frame rule; the second is.
        engine.setNext(0.95)
        source.push(1280)
        try await eventually { engine.frameCount == 3 }
        #expect(listener.state == .listening)
        source.push(1280)
        try await eventually { listener.state == .woke }
        #expect(wakes.map(\.phrase) == ["Hey Computer"])
        #expect(wakes.map(\.frames) == [2])
        // Quiet until re-armed; the source keeps running for the host's utterance.
        source.push(1280)
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.frameCount == 4)
        #expect(source.running)

        // Re-armed, it scores again at once.
        engine.setNext(0)
        await listener.rearm()
        #expect(listener.state == .listening)
        source.push(1280)
        try await eventually { engine.frameCount == 5 }

        await listener.stop()
        #expect(listener.state == .idle)
        #expect(!source.running)
        source.push(1280)
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.frameCount == 5)
    }

    @Test func theFrameRuleReachesTheDetector() async throws {
        let engine = ScriptedWakeEngine()
        engine.setNext(0.95)
        let source = FakeAudioSource()
        let listener = WakeListener(
            detector: InProcessWakeDetector(engine: engine, phrase: "x", model: "x"),
            source: source, threshold: 0.5, frames: 3)
        await listener.start()
        source.push(2560)
        try await eventually { engine.frameCount == 2 }
        #expect(listener.state == .listening)
        source.push(1280)
        try await eventually { listener.state == .woke }
        await listener.rearm(frames: 1)
        source.push(1280)
        try await eventually { listener.state == .woke }
        #expect(engine.frameCount == 4)
    }

    @Test func anInvalidFrameCountFailsListening() async {
        let source = FakeAudioSource()
        let listener = WakeListener(
            detector: InProcessWakeDetector(engine: ScriptedWakeEngine(), phrase: "x", model: "x"),
            source: source, frames: 5)
        await listener.start()
        #expect(listener.state == .failed(WakeDetectorError.invalidFrames.localizedDescription))
        #expect(source.starts == 0)

        let listening = WakeListener(
            detector: InProcessWakeDetector(engine: ScriptedWakeEngine(), phrase: "x", model: "x"),
            source: source, frames: 2)
        await listening.start()
        #expect(listening.state == .listening)
        await listening.rearm(frames: 0)
        #expect(listening.state == .failed(WakeDetectorError.invalidFrames.localizedDescription))
        #expect(!source.running)
    }

    @Test func badAudioOrASourceFailureStopsListening() async throws {
        let source = FakeAudioSource()
        let listener = WakeListener(
            detector: InProcessWakeDetector(engine: ScriptedWakeEngine(), phrase: "x", model: "x"),
            source: source, frames: 2)
        await listener.start()
        source.onSamples?([Float.nan])
        try await eventually { if case .failed = listener.state { return true } else { return false } }
        #expect(!source.running)

        struct Denied: LocalizedError { var errorDescription: String? { "no microphone" } }
        source.failure = Denied()
        await listener.start()
        #expect(listener.state == .failed("no microphone"))
    }

    @Test func anInvalidThresholdFailsBeforeTheSourceStarts() async {
        let source = FakeAudioSource()
        let listener = WakeListener(
            detector: InProcessWakeDetector(engine: ScriptedWakeEngine(), phrase: "x", model: "x"),
            source: source, threshold: 2, frames: 2)
        await listener.start()
        #expect(listener.state == .failed(WakeDetectorError.invalidThreshold.localizedDescription))
        #expect(source.starts == 0)
    }
}

// MARK: The real openWakeWord models (opt-in; never downloads)

private func fixtureSamples(_ name: String) throws -> [Float] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures"))
    let file = try AVAudioFile(forReading: url)
    #expect(file.processingFormat.sampleRate == 16_000)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

/// `VOICEKIT_WAKE_MODELS`: a folder holding the Hey Jarvis files (for example Archibald's
/// `~/Library/Application Support/Archibald/wake/models`).
private let wakeModels = environmentDirectory("VOICEKIT_WAKE_MODELS")

struct RealWakeModelTests {
    /// Python openWakeWord 0.6.0 on the same fixture: zeros, then 0.271, 0.975, 0.996 …
    /// peaking at 0.9992 on frame 25 (1 s of silence padding on each side).
    @Test(.enabled(if: wakeModels != nil, "set VOICEKIT_WAKE_MODELS to a folder with the Hey Jarvis files"))
    @MainActor func openWakeWordMatchesThePythonReference() async throws {
        let source = try #require(wakeModels)
        // Installed through the seed path, exactly as a real install from another app's copy.
        let directory = try temporaryDirectory("wake")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let model = WakeModels.heyJarvis
        try await ModelStore.install(
            model.manifest.seeded(from: [source]), into: directory,
            downloader: { _, _, _ in throw ModelDownload.Failure.invalidDownload }, progress: { _, _ in })
        let engine = try OpenWakeWordEngine(model: model, directory: directory)
        try await engine.reset()
        let speech = try fixtureSamples("hey-jarvis-16k")
        let silence = [Float](repeating: 0, count: 16_000)
        let audio = silence + speech + silence
        var scores: [Float] = []
        for start in stride(from: 0, to: audio.count - 1280, by: 1280) {
            scores.append(try await engine.score(Array(audio[start..<(start + 1280)])))
        }
        let peak = scores.max() ?? 0
        #expect(peak > 0.95, "scores: \(scores)")
        #expect(scores.firstIndex { $0 >= 0.5 }.map { (20...24).contains($0) } == true, "scores: \(scores)")
        #expect(scores.prefix(18).allSatisfy { $0 < 0.05 }, "scores: \(scores)")

        // The detector at the settings default wakes one frame after the first at the owner's
        // threshold, fed in 100 ms chunks as the microphone delivers them.
        let threshold = 0.53
        let frames = VoiceSettings().wakeFrames
        let first = try #require(scores.firstIndex { Double($0) >= threshold })
        let detector = InProcessWakeDetector(engine: engine, phrase: model.phrase, model: model.id)
        _ = try await detector.arm(threshold: threshold, frames: frames)
        var hit: WakeDetection?
        for start in stride(from: 0, to: audio.count, by: 1600) where hit == nil {
            hit = try await detector.detect(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let detection = try #require(hit)
        #expect(detection.frames == 2)
        #expect(detection.score == Double(scores[first + 1]), "scores: \(scores)")
        #expect(detection.peak == Double(max(scores[first], scores[first + 1])))

        // A non-finite sample is an error, not a crash.
        await #expect(throws: WakeDetectorError.self) {
            _ = try await engine.score([Float](repeating: .nan, count: 1280))
        }

        // Silence after a reset never wakes.
        try await engine.reset()
        for _ in 0..<40 { #expect(try await engine.score([Float](repeating: 0, count: 1280)) < 0.05) }
    }
}

/// A source whose start waits until the test releases it, like a microphone asking for access.
@MainActor
final class SuspendingAudioSource: WakeAudioSource {
    var onSamples: (([Float]) -> Void)?
    var running = false
    var pending: CheckedContinuation<Void, Never>?

    func start() async throws {
        await withCheckedContinuation { pending = $0 }
        running = true
    }

    func stop() { running = false }

    func release() {
        pending?.resume()
        pending = nil
    }
}

/// Never finishes a detection, so audio backs up behind it.
@MainActor
final class StuckDetector: WakeDetector {
    var detects = 0
    func arm(threshold: Double, frames: Int) async throws -> WakeDetectorInfo { WakeDetectorInfo(phrase: "x", model: "x") }
    func detect(_ samples: [Float]) async throws -> WakeDetection? {
        detects += 1
        try await Task.sleep(for: .seconds(3600))
        return nil
    }
    func disarm() async {}
}

@MainActor
struct WakeListenerLifecycleTests {
    @Test func stopDuringASlowSourceStartLeavesTheMicrophoneOff() async throws {
        let source = SuspendingAudioSource()
        let listener = WakeListener(
            detector: InProcessWakeDetector(engine: ScriptedWakeEngine(), phrase: "x", model: "x"), source: source,
            frames: 2)
        let starting = Task { await listener.start() }
        try await eventually { source.pending != nil }
        await listener.stop()
        source.release()
        await starting.value
        #expect(!source.running)
        #expect(listener.state == .idle)
    }

    @Test func aStaleStartDoesNotStopTheSourceOfANewerOne() async throws {
        let source = SuspendingAudioSource()
        let listener = WakeListener(
            detector: InProcessWakeDetector(engine: ScriptedWakeEngine(), phrase: "x", model: "x"), source: source,
            frames: 2)
        let first = Task { await listener.start() }
        try await eventually { source.pending != nil }
        await listener.stop()
        let firstStart = source.pending
        source.pending = nil
        let second = Task { await listener.start() }
        try await eventually { source.pending != nil }
        source.release()
        await second.value
        #expect(listener.state == .listening)
        firstStart?.resume()
        await first.value
        #expect(source.running)
        #expect(listener.state == .listening)
        await listener.stop()
    }

    @Test func audioBackingUpBeyondTheCapFailsListening() async throws {
        let source = FakeAudioSource()
        let detector = StuckDetector()
        let listener = WakeListener(detector: detector, source: source, frames: 2)
        await listener.start()
        source.push(1280)
        try await eventually { detector.detects == 1 }
        for _ in 0..<7 { source.push(1280) }  // 8960 samples waiting
        #expect(listener.state == .failed(WakeListener.Failure.fellBehind.localizedDescription))
        #expect(!source.running)
    }
}
