import AVFoundation
import Foundation

@testable import VoiceKit

/// The loading, counting and reporting half of the opt-in wake detector evaluation
/// (`WakeEvaluationTests`). Scores come from the real engine one 1280-sample frame at a time,
/// exactly as `InProcessWakeDetector` feeds it; every threshold and consecutive-frame rule is
/// then replayed over the same scores, so one pass over the audio answers all of them. A second
/// pass runs `InProcessWakeDetector` itself at the owner's threshold and the settings default
/// for frames, and its wakes are compared with the replay's.
enum WakeEvaluation {
    static let frameSamples = InProcessWakeDetector.frameSamples
    static let sampleRate = 16_000.0
    static let frameSeconds = Double(frameSamples) / sampleRate
    /// After an event the next two seconds are not counted: a take that follows a wake is longer
    /// than that, and the detector is disarmed for it.
    static let skipFrames = Int((2.0 / frameSeconds).rounded())
    static let thresholds = [0.3, 0.4, 0.5, 0.53, 0.6, 0.7, 0.8, 0.9]
    static let runLengths = [1, 2, 3, 4]
    /// The threshold per-file peaks and run detail are reported at: the owner's setting.
    static let ownerThreshold = 0.53
    /// The consecutive frames the real detector is run with: the settings default.
    static let detectorFrames = VoiceSettings().wakeFrames

    // MARK: Counting

    /// A wake the rule would report. Times are the start of the frame that completes the run.
    struct Event: Equatable {
        let frame: Int
        let score: Float
        var seconds: Double { Double(frame) * WakeEvaluation.frameSeconds }
    }

    /// A maximal stretch of frames at or above a threshold.
    struct Run: Equatable {
        let start: Int
        let scores: [Float]
        var seconds: Double { Double(start) * WakeEvaluation.frameSeconds }
    }

    /// Events under "`run` consecutive frames at or above `threshold`", skipping `skipFrames`
    /// frames after each. The comparison is the detector's: the score widened to Double.
    static func events(in scores: [Float], threshold: Double, run: Int) -> [Event] {
        var events: [Event] = []
        var streak = 0
        var index = 0
        while index < scores.count {
            streak = Double(scores[index]) >= threshold ? streak + 1 : 0
            if streak >= run {
                events.append(Event(frame: index, score: scores[index]))
                streak = 0
                index += skipFrames
            }
            index += 1
        }
        return events
    }

    static func runs(in scores: [Float], atLeast threshold: Double) -> [Run] {
        var runs: [Run] = []
        var start: Int?
        for (index, score) in scores.enumerated() {
            if Double(score) >= threshold {
                start = start ?? index
            } else if let begun = start {
                runs.append(Run(start: begun, scores: Array(scores[begun..<index])))
                start = nil
            }
        }
        if let begun = start { runs.append(Run(start: begun, scores: Array(scores[begun...]))) }
        return runs
    }

    static func longestRun(in scores: [Float], atLeast threshold: Double) -> Int {
        runs(in: scores, atLeast: threshold).map(\.scores.count).max() ?? 0
    }

    // MARK: Audio

    /// 16 kHz mono samples of a file: other rates are resampled and channels averaged. A
    /// non-zero `padSeconds` adds that much silence before and after, as the fixture test does.
    /// The file is read in chunks into one array: a long recording is hundreds of megabytes.
    static func samples(from url: URL, padSeconds: Double = 0) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let padding = Int((padSeconds * sampleRate).rounded())
        let chunk: AVAudioFrameCount = 1 << 20
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw Failure.unreadable("\(url.lastPathComponent): no buffer for \(chunk) frames")
        }
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length) + 2 * padding)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let count = Int(buffer.frameLength)
            if channelCount == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
            } else {
                for index in 0..<count {
                    var sum: Float = 0
                    for channel in 0..<channelCount { sum += channels[channel][index] }
                    mono.append(sum / Float(channelCount))
                }
            }
        }
        if format.sampleRate != sampleRate { mono = try resample(mono, from: format.sampleRate) }
        if padding > 0 {
            mono.insert(contentsOf: repeatElement(0, count: padding), at: 0)
            mono.append(contentsOf: repeatElement(0, count: padding))
        }
        return mono
    }

    private static func resample(_ mono: [Float], from rate: Double) throws -> [Float] {
        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target),
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(mono.count)),
            let output = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(Double(mono.count) * sampleRate / rate) + 1024)
        else { throw Failure.unreadable("no converter from \(rate) Hz") }
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        input.frameLength = AVAudioFrameCount(mono.count)
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw failure ?? Failure.unreadable("conversion from \(rate) Hz failed") }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let detail): return detail }
        }
    }

    // MARK: Scoring

    /// The detector's feed: reset, then whole frames from the start (a short tail is dropped).
    static func score(_ samples: [Float], with engine: WakeScoringEngine) async throws -> [Float] {
        try await engine.reset()
        var scores: [Float] = []
        var start = 0
        while start + frameSamples <= samples.count {
            scores.append(try await engine.score(Array(samples[start..<(start + frameSamples)])))
            start += frameSamples
        }
        return scores
    }

    /// Every wake `InProcessWakeDetector` itself reports for the audio, fed in chunks that are not
    /// a multiple of a frame. After a wake the next `skipFrames` frames are skipped, as the replay
    /// skips them, and the detector is armed again. Arming resets the engine (the live listener's
    /// re-arm does too), so the scores after a wake can differ from the replay's, which scores the
    /// file in one go.
    @MainActor
    static func detections(
        _ samples: [Float], with engine: WakeScoringEngine, threshold: Double, frames: Int
    ) async throws -> [Event] {
        let counter = FrameCounter(engine)
        let detector = InProcessWakeDetector(engine: counter, phrase: "Hey Jarvis", model: "evaluation")
        _ = try await detector.arm(threshold: threshold, frames: frames)
        var events: [Event] = []
        var armedAt = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 4_096, samples.count)
            guard let hit = try await detector.detect(Array(samples[offset..<end])) else {
                offset = end
                continue
            }
            let frame = armedAt + (await counter.frames) - 1
            events.append(Event(frame: frame, score: Float(hit.score)))
            armedAt = frame + 1 + skipFrames
            offset = armedAt * frameSamples
            _ = try await detector.arm(threshold: threshold, frames: frames)
        }
        return events
    }

    /// An engine that counts the frames scored since its last reset, so a detection can be placed
    /// in the file.
    private actor FrameCounter: WakeScoringEngine {
        private let engine: WakeScoringEngine
        private(set) var frames = 0

        init(_ engine: WakeScoringEngine) { self.engine = engine }

        func reset() async throws {
            frames = 0
            try await engine.reset()
        }

        func score(_ frame: [Float]) async throws -> Float {
            frames += 1
            return try await engine.score(frame)
        }
    }

    /// One file: its scores and the real detector's wakes. A file that cannot be read, or holds
    /// less than one whole frame, is a failure, not a file without a wake.
    static func evaluate(_ url: URL, padSeconds: Double, with engine: WakeScoringEngine) async -> FileResult {
        let name = url.lastPathComponent
        do {
            let samples = try samples(from: url, padSeconds: padSeconds)
            let scores = try await score(samples, with: engine)
            guard !scores.isEmpty else {
                return FileResult(name: name, scores: [], detected: [], failure: "shorter than one 80 ms frame")
            }
            let detected = try await detections(samples, with: engine, threshold: ownerThreshold, frames: detectorFrames)
            return FileResult(name: name, scores: scores, detected: detected, failure: nil)
        } catch {
            return FileResult(name: name, scores: [], detected: [], failure: "\(error)")
        }
    }

    /// The most memory the process has held, in megabytes.
    static func peakResidentMegabytes() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_maxrss) / 1_048_576  // bytes on macOS
    }

    // MARK: Inputs

    struct Configuration {
        let models: URL
        let audio: URL
        let padSeconds: Double
        let latest: Int?
        let workers: Int
        let label: String
    }

    /// `VOICEKIT_WAKE_MODELS` (the Hey Jarvis folder) and `VOICEKIT_WAKE_EVAL_AUDIO` (a folder of
    /// .wav files, or a text file with one path per line) enable the evaluation. Optional:
    /// `VOICEKIT_WAKE_EVAL_LATEST` (only the newest N files of a folder, by modification date),
    /// `VOICEKIT_WAKE_EVAL_PAD_SECONDS` (silence added to both ends of every file),
    /// `VOICEKIT_WAKE_EVAL_WORKERS` (engines scoring in parallel, default 3) and
    /// `VOICEKIT_WAKE_EVAL_LABEL` (the report's title).
    static func configuration() -> Configuration? {
        let environment = ProcessInfo.processInfo.environment
        guard let models = environmentDirectory("VOICEKIT_WAKE_MODELS"),
            let path = environment["VOICEKIT_WAKE_EVAL_AUDIO"], !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else { return nil }
        return Configuration(
            models: models,
            audio: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            padSeconds: environment["VOICEKIT_WAKE_EVAL_PAD_SECONDS"].flatMap(Double.init) ?? 0,
            latest: environment["VOICEKIT_WAKE_EVAL_LATEST"].flatMap(Int.init),
            workers: max(1, environment["VOICEKIT_WAKE_EVAL_WORKERS"].flatMap(Int.init) ?? 3),
            label: environment["VOICEKIT_WAKE_EVAL_LABEL"] ?? "unlabelled")
    }

    /// The .wav files to score, in name order. A folder is listed (nothing but .wav files is
    /// opened); a text file lists paths, absolute or relative to it, `#` starting a comment.
    static func files(at audio: URL, latest: Int?) throws -> [URL] {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: audio.path, isDirectory: &isDirectory)
        var files: [URL]
        if isDirectory.boolValue {
            files = try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "wav" }
            if let latest {
                let modified = { (url: URL) -> Date in
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                }
                files = Array(files.sorted { modified($0) > modified($1) }.prefix(latest))
            }
        } else {
            files = try String(contentsOf: audio, encoding: .utf8).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { line in
                    let expanded = (line as NSString).expandingTildeInPath
                    return expanded.hasPrefix("/")
                        ? URL(fileURLWithPath: expanded)
                        : URL(fileURLWithPath: expanded, relativeTo: audio.deletingLastPathComponent())
                }
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Report

    struct FileResult: Sendable {
        let name: String
        let scores: [Float]
        /// The real detector's wakes (`detections`).
        let detected: [Event]
        let failure: String?
        var seconds: Double { Double(scores.count) * WakeEvaluation.frameSeconds }
        var peak: Float { scores.max() ?? 0 }
        var replayed: [Event] { events(in: scores, threshold: ownerThreshold, run: detectorFrames) }

        enum Agreement: String { case agrees, differsAfterARearm = "differs after a re-arm", disagrees = "DISAGREES" }

        /// Whether the real detector's wakes are the replay's. Only those after its first can
        /// differ, from the engine reset that comes with arming again.
        var agreement: Agreement {
            let replayed = replayed
            if detected == replayed { return .agrees }
            if let first = detected.first, first == replayed.first { return .differsAfterARearm }
            return .disagrees
        }
    }

    /// The tables and the per-file listing. Only file names, durations and scores appear.
    static func report(
        label: String, results: [FileResult], padSeconds: Double, wallSeconds: Double
    ) -> String {
        let scored = results.filter { $0.failure == nil }
        let failed = results.filter { $0.failure != nil }
        let audioSeconds = scored.reduce(0) { $0 + $1.seconds }
        let hours = audioSeconds / 3600
        var out: [String] = []
        func line(_ text: String = "") { out.append(text) }
        func column(_ text: String, _ width: Int) -> String {
            String(repeating: " ", count: max(0, width - text.count)) + text
        }
        func perHour(_ events: Int) -> String { hours > 0 ? String(format: "%.2f", Double(events) / hours) : "-" }

        line("Wake detector evaluation: \(label)")
        line("Frames of \(frameSamples) samples (80 ms) at 16 kHz mono, engine reset before each file.")
        line("An event is N consecutive frames at or above the threshold; the next 2 s (\(skipFrames) frames) are then skipped.")
        line("Times are the start of the frame that completes the run, in seconds from the start of the file (after padding).")
        line(
            String(
                format: "Files scored: %d, failed: %d. Audio: %.1f s (%.3f h), %d frames, padding %.1f s each side.",
                scored.count, failed.count, audioSeconds, hours, scored.reduce(0) { $0 + $1.scores.count },
                padSeconds))
        line(
            String(
                format: "Scoring took %.1f s wall clock (%.1fx real time).", wallSeconds,
                wallSeconds > 0 ? audioSeconds / wallSeconds : 0))
        for failure in failed { line("  failed: \(failure.name): \(failure.failure ?? "")") }
        line()

        func grid(_ title: String, cell: (Double, Int) -> String, width: Int) {
            line(title)
            line(column("threshold", 10) + " |" + runLengths.map { column("N=\($0)", width) }.joined())
            for threshold in thresholds {
                line(
                    column(String(format: "%.2f", threshold), 10) + " |"
                        + runLengths.map { column(cell(threshold, $0), width) }.joined())
            }
            line()
        }

        let counts = Dictionary(
            uniqueKeysWithValues: thresholds.flatMap { threshold in
                runLengths.map { run in
                    (
                        "\(threshold)/\(run)",
                        scored.map { events(in: $0.scores, threshold: threshold, run: run) }
                    )
                }
            })
        func perFile(_ threshold: Double, _ run: Int) -> [[Event]] { counts["\(threshold)/\(run)"] ?? [] }

        grid(
            "Wake events, and events per hour of audio",
            cell: { threshold, run in
                let total = perFile(threshold, run).reduce(0) { $0 + $1.count }
                return "\(total) (\(perHour(total))/h)"
            }, width: 18)
        grid(
            "Files with at least one event (of \(scored.count))",
            cell: { threshold, run in "\(perFile(threshold, run).filter { !$0.isEmpty }.count)" }, width: 8)

        let longest = thresholds.map { threshold in
            scored.map { longestRun(in: $0.scores, atLeast: threshold) }.sorted()
        }
        line("Longest run of frames at or above the threshold, over files")
        line(column("threshold", 10) + " |" + ["min", "median", "max"].map { column($0, 8) }.joined())
        for (index, threshold) in thresholds.enumerated() {
            let runs = longest[index]
            line(
                column(String(format: "%.2f", threshold), 10) + " |"
                    + [runs.first, runs.isEmpty ? nil : runs[runs.count / 2], runs.last]
                    .map { column($0.map(String.init) ?? "-", 8) }.joined())
        }
        line()
        grid(
            "Frames to spare when every file should fire: weakest file's longest run minus N (negative: some file does not fire)",
            cell: { threshold, run in
                guard let weakest = longest[thresholds.firstIndex(of: threshold)!].first else { return "-" }
                return "\(weakest - run)"
            }, width: 8)

        line("Per file: seconds, peak score, longest run (frames) at or above each threshold")
        line(
            column("file", 44) + column("seconds", 9) + column("peak", 7)
                + thresholds.map { column(String(format: ">=%.2f", $0), 7) }.joined())
        for result in scored {
            line(
                column(result.name, 44) + column(String(format: "%.1f", result.seconds), 9)
                    + column(String(format: "%.3f", result.peak), 7)
                    + thresholds.map { column("\(longestRun(in: result.scores, atLeast: $0))", 7) }.joined())
        }
        line()

        let floor = thresholds.min() ?? ownerThreshold
        line(String(format: "Runs at or above %.2f (file, start in s, scores of the frames in the run, up to 12)", floor))
        var listed = 0
        for result in scored {
            for run in runs(in: result.scores, atLeast: floor) {
                let values = run.scores.prefix(12).map { String(format: "%.2f", $0) }.joined(separator: " ")
                let more = run.scores.count > 12 ? " ... (\(run.scores.count) frames)" : ""
                line("  \(result.name)  \(String(format: "%7.2f", run.seconds)) s  \(values)\(more)")
                listed += 1
            }
        }
        if listed == 0 { line("  none") }
        line()

        let rule = String(format: "%.2f with %d consecutive frames", ownerThreshold, detectorFrames)
        let detectedTotal = scored.reduce(0) { $0 + $1.detected.count }
        let replayedTotal = scored.reduce(0) { $0 + $1.replayed.count }
        line("InProcessWakeDetector at \(rule) (the settings default), armed again 2 s after each wake")
        line(
            "Wake events: \(detectedTotal) (\(perHour(detectedTotal))/h) in \(scored.filter { !$0.detected.isEmpty }.count) "
                + "of \(scored.count) files; the replay of the same rule: \(replayedTotal) (\(perHour(replayedTotal))/h).")
        let agreements = scored.map(\.agreement)
        line(
            "Files where the detector and the replay agree: \(agreements.filter { $0 == .agrees }.count); "
                + "differ only after a re-arm: \(agreements.filter { $0 == .differsAfterARearm }.count); "
                + "disagree: \(agreements.filter { $0 == .disagrees }.count).")
        func listing(_ events: [Event]) -> String {
            events.isEmpty
                ? "none" : events.map { String(format: "%.2f s %.4f", $0.seconds, $0.score) }.joined(separator: ", ")
        }
        for result in scored where !result.detected.isEmpty || !result.replayed.isEmpty {
            line(
                "  \(result.name): \(result.agreement.rawValue) (detector \(listing(result.detected)); "
                    + "replay \(listing(result.replayed)))")
        }
        line()
        line(String(format: "Peak resident memory of the test process: %.0f MB.", peakResidentMegabytes()))
        return out.joined(separator: "\n")
    }
}
