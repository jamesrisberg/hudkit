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
    @Test func scoresWholeFramesAndFiresOncePerArm() async throws {
        let engine = ScriptedWakeEngine()
        let detector = InProcessWakeDetector(engine: engine, phrase: "Hey Jarvis", model: "scripted")
        await #expect(throws: WakeDetectorError.self) { _ = try await detector.detect([0]) }
        let info = try await detector.arm(threshold: 0.5)
        #expect(info.phrase == "Hey Jarvis")
        #expect(try await detector.detect(Array(repeating: 0, count: 1000)) == nil)
        #expect(engine.frameCount == 0)  // less than one frame buffered
        engine.push([0.1, 0.7])
        let hit = try await detector.detect(Array(repeating: 0, count: 2000))
        #expect(hit == WakeDetection(score: Double(Float(0.7)), phrase: "Hey Jarvis"))
        #expect(engine.frameCount == 2)
        // Latched until armed again.
        await #expect(throws: WakeDetectorError.self) {
            _ = try await detector.detect(Array(repeating: 0, count: 1280))
        }
        _ = try await detector.arm(threshold: 0.9)
        engine.push([0.8])
        #expect(try await detector.detect(Array(repeating: 0, count: 1280)) == nil)
    }

    @Test func rejectsBadAudioAndThresholds() async throws {
        let detector = InProcessWakeDetector(engine: ScriptedWakeEngine(), phrase: "x", model: "x")
        await #expect(throws: WakeDetectorError.self) { _ = try await detector.arm(threshold: 0.99) }
        _ = try await detector.arm(threshold: 0.5)
        await #expect(throws: WakeDetectorError.self) { _ = try await detector.detect([2]) }
        // Any error disarms.
        await #expect(throws: WakeDetectorError.self) { _ = try await detector.detect([0]) }
        _ = try await detector.arm(threshold: 0.5)
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
            source: source)
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

        engine.setNext(0.95)
        source.push(1280)
        try await eventually { listener.state == .woke }
        #expect(wakes.map(\.phrase) == ["Hey Computer"])
        // Quiet until re-armed; the source keeps running for the host's utterance.
        source.push(1280)
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.frameCount == 3)
        #expect(source.running)

        engine.setNext(0)
        await listener.rearm()
        #expect(listener.state == .listening)
        source.push(1280)
        try await eventually { engine.frameCount == 4 }

        await listener.stop()
        #expect(listener.state == .idle)
        #expect(!source.running)
        source.push(1280)
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.frameCount == 4)
    }

    @Test func badAudioOrASourceFailureStopsListening() async throws {
        let source = FakeAudioSource()
        let listener = WakeListener(
            detector: InProcessWakeDetector(engine: ScriptedWakeEngine(), phrase: "x", model: "x"),
            source: source)
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
            source: source, threshold: 2)
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
    func openWakeWordMatchesThePythonReference() async throws {
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

        // Silence after a reset never wakes.
        try await engine.reset()
        for _ in 0..<40 { #expect(try await engine.score([Float](repeating: 0, count: 1280)) < 0.05) }
    }
}
