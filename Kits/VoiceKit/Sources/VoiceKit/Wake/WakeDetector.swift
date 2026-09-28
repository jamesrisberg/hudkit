import Foundation

public struct WakeDetectorInfo: Equatable, Sendable {
    public let phrase: String
    public let model: String

    public init(phrase: String, model: String) {
        self.phrase = phrase
        self.model = model
    }
}

public struct WakeDetection: Equatable, Sendable {
    public let score: Double
    public let phrase: String

    public init(score: Double, phrase: String) {
        self.score = score
        self.phrase = phrase
    }
}

/// Scores 16 kHz mono audio for the wake phrase. One wake per arm: after a detection the
/// detector stays quiet until armed again. Call `detect` serially; any error requires
/// re-arming (a missed interval corrupts the model's temporal context).
@MainActor
public protocol WakeDetector: AnyObject {
    func arm(threshold: Double) async throws -> WakeDetectorInfo
    /// Accepts chunks of up to one second of samples in -1...1.
    func detect(_ samples: [Float]) async throws -> WakeDetection?
    /// Drops buffered audio and in-flight results; the next `detect` needs a new `arm`.
    func disarm() async
}

public enum WakeDetectorError: LocalizedError, Equatable {
    case notArmed, invalidAudio, invalidThreshold, modelFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notArmed: return "Wake detection was stopped."
        case .invalidAudio: return "The microphone supplied an invalid wake detection frame."
        case .invalidThreshold: return "The wake threshold must be between 0.05 and 0.95."
        case .modelFailed(let detail): return "The wake model failed: \(detail)"
        }
    }
}

/// A keyword model that scores one 80 ms frame (1280 samples) at a time.
public protocol WakeScoringEngine: AnyObject, Sendable {
    /// Clears all temporal context.
    func reset() async throws
    /// Scores one frame of exactly 1280 samples; returns 0...1.
    func score(_ frame: [Float]) async throws -> Float
}

/// Runs a keyword model in process: bounded input, one detection per arm, and generation
/// checks so late results after a disarm are dropped.
@MainActor
public final class InProcessWakeDetector: WakeDetector {
    public nonisolated static let frameSamples = 1280
    public nonisolated static let thresholdRange = 0.05...0.95
    private let engine: WakeScoringEngine
    private let info: WakeDetectorInfo
    private var threshold = 0.5
    private var armed = false
    private var processing = false
    private var generation = UUID()
    private var pending: [Float] = []

    public init(engine: WakeScoringEngine, phrase: String, model: String) {
        self.engine = engine
        info = WakeDetectorInfo(phrase: phrase, model: model)
    }

    public func arm(threshold: Double) async throws -> WakeDetectorInfo {
        guard threshold.isFinite, Self.thresholdRange.contains(threshold) else {
            throw WakeDetectorError.invalidThreshold
        }
        invalidate()
        let current = generation
        try await engine.reset()
        guard current == generation else { throw WakeDetectorError.notArmed }
        self.threshold = threshold
        armed = true
        return info
    }

    public func detect(_ samples: [Float]) async throws -> WakeDetection? {
        guard armed else { throw WakeDetectorError.notArmed }
        guard !processing else {
            invalidate()
            throw WakeDetectorError.notArmed
        }
        guard samples.count <= 16_000, samples.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            invalidate()
            throw WakeDetectorError.invalidAudio
        }
        pending.append(contentsOf: samples)
        guard pending.count >= Self.frameSamples else { return nil }
        processing = true
        let current = generation
        defer { if generation == current { processing = false } }
        do {
            while pending.count >= Self.frameSamples {
                let frame = Array(pending.prefix(Self.frameSamples))
                pending.removeFirst(Self.frameSamples)
                let score = Double(try await engine.score(frame))
                guard generation == current else { throw WakeDetectorError.notArmed }
                guard score.isFinite else { throw WakeDetectorError.modelFailed("non-finite score") }
                if score >= threshold {
                    armed = false
                    pending.removeAll(keepingCapacity: false)
                    return WakeDetection(score: score, phrase: info.phrase)
                }
            }
            return nil
        } catch {
            if generation == current { invalidate() }
            throw error
        }
    }

    public func disarm() async {
        invalidate()
        try? await engine.reset()
    }

    private func invalidate() {
        generation = UUID()
        armed = false
        processing = false
        pending.removeAll(keepingCapacity: false)
    }
}
