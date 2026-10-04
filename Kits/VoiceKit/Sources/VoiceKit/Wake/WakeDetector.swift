import Foundation

public struct WakeDetectorInfo: Equatable, Sendable {
    public let phrase: String
    public let model: String

    public init(phrase: String, model: String) {
        self.phrase = phrase
        self.model = model
    }
}

/// A wake: the run of frames that fired it and, from `WakeListener`, the audio that led to it.
public struct WakeDetection: Equatable, Sendable {
    /// The score of the frame that completed the run.
    public let score: Double
    public let phrase: String
    /// Consecutive frames at or above the threshold, ending with the one that fired: always the
    /// count the detector was armed with. `peak` is the part of the run that varies.
    public let frames: Int
    /// The highest score in the run.
    public let peak: Double
    /// The 16 kHz mono audio `WakeListener` fed the detector since it was armed, at most
    /// `WakeListener.heardSamples` (2.5 s), up to the end of the chunk in which the run completed:
    /// the rest of that chunk and samples that never made a whole frame are included. A host
    /// transcribes it on the device to confirm the phrase. On a false wake it is speech in the
    /// room: never saved, logged or sent. Empty from a detector itself.
    public let audio: [Float]

    /// `peak` defaults to `score`: a run of one frame.
    public init(score: Double, phrase: String, frames: Int = 1, peak: Double? = nil, audio: [Float] = []) {
        self.score = score
        self.phrase = phrase
        self.frames = frames
        self.peak = peak ?? score
        self.audio = audio
    }
}

/// Scores 16 kHz mono audio for the wake phrase. One wake per arm: after a detection the
/// detector stays quiet until armed again. Call `detect` serially; any error requires
/// re-arming (a missed interval corrupts the model's temporal context).
@MainActor
public protocol WakeDetector: AnyObject {
    /// Clears all context and listens for `frames` consecutive frames scoring at or above
    /// `threshold`.
    func arm(threshold: Double, frames: Int) async throws -> WakeDetectorInfo
    /// Accepts chunks of up to one second of samples, nominally in -1...1; louder samples are
    /// clipped, non-finite ones are an error.
    func detect(_ samples: [Float]) async throws -> WakeDetection?
    /// Drops buffered audio and in-flight results; the next `detect` needs a new `arm`.
    func disarm() async
}

public enum WakeDetectorError: LocalizedError, Equatable {
    case notArmed, invalidAudio, invalidThreshold, invalidFrames, modelFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notArmed: return "Wake detection was stopped."
        case .invalidAudio: return "The microphone supplied an invalid wake detection frame."
        case .invalidThreshold: return "The wake threshold must be between 0.05 and 0.95."
        case .invalidFrames: return "A wake must hold for 1 to 4 frames."
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
/// checks so late results after a disarm are dropped. It fires when `frames` consecutive frames
/// score at or above the threshold; a frame below it restarts the count. A passing sound can
/// reach the threshold for a frame; a spoken wake phrase holds for several.
@MainActor
public final class InProcessWakeDetector: WakeDetector {
    public nonisolated static let frameSamples = 1280
    public nonisolated static let thresholdRange = 0.05...0.95
    public nonisolated static let framesRange = 1...4
    private let engine: WakeScoringEngine
    private let info: WakeDetectorInfo
    private var threshold = 0.5
    private var frames = 1
    /// The frames at or above the threshold so far, and the best of them.
    private var run = 0
    private var runPeak = 0.0
    private var armed = false
    private var processing = false
    private var generation = UUID()
    private var pending: [Float] = []

    public init(engine: WakeScoringEngine, phrase: String, model: String) {
        self.engine = engine
        info = WakeDetectorInfo(phrase: phrase, model: model)
    }

    public func arm(threshold: Double, frames: Int) async throws -> WakeDetectorInfo {
        guard threshold.isFinite, Self.thresholdRange.contains(threshold) else {
            throw WakeDetectorError.invalidThreshold
        }
        guard Self.framesRange.contains(frames) else { throw WakeDetectorError.invalidFrames }
        invalidate()
        let current = generation
        try await engine.reset()
        guard current == generation else { throw WakeDetectorError.notArmed }
        self.threshold = threshold
        self.frames = frames
        armed = true
        return info
    }

    public func detect(_ samples: [Float]) async throws -> WakeDetection? {
        guard armed else { throw WakeDetectorError.notArmed }
        guard !processing else {
            invalidate()
            throw WakeDetectorError.notArmed
        }
        guard samples.count <= 16_000, samples.allSatisfy(\.isFinite) else {
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
                guard score >= threshold else {
                    run = 0
                    runPeak = 0
                    continue
                }
                run += 1
                runPeak = max(runPeak, score)
                if run >= frames {
                    let detection = WakeDetection(score: score, phrase: info.phrase, frames: run, peak: runPeak)
                    invalidate()
                    return detection
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
        run = 0
        runPeak = 0
    }
}

/// Printed, logged, debug-printed or reflected, a detection shows how much audio it holds, never
/// the samples: on a false wake they are speech in the room.
extension WakeDetection: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "WakeDetection(score: \(score), phrase: \"\(phrase)\", frames: \(frames), peak: \(peak), audio: \(audio.count) samples)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "score": score, "phrase": phrase, "frames": frames, "peak": peak, "audio": "\(audio.count) samples",
            ],
            displayStyle: .struct)
    }
}
