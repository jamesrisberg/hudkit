import Foundation
import OnnxRuntimeBindings

/// openWakeWord's streaming pipeline, in process: melspectrogram ONNX model, Google's
/// speech-embedding model, then a keyword classifier over the last 16 embeddings.
/// A faithful port of openwakeword 0.6.0 `AudioFeatures._streaming_features` for
/// 1280-sample steps (checked against the Python scores in the tests).
public actor OpenWakeWordEngine: WakeScoringEngine {
    public enum Failure: LocalizedError {
        case missingModel(String), badOutput(String)
        public var errorDescription: String? {
            switch self {
            case .missingModel(let name): return "The wake model file \(name) is missing. Download it again."
            case .badOutput(let name): return "The wake model \(name) returned an unexpected result."
            }
        }
    }

    private struct Model {
        let session: ORTSession
        let input: String
        let output: String
    }

    public static let frameSamples = 1280
    private static let melBins = 32
    private static let embeddingWindow = 76
    private static let embeddingSize = 96
    /// Samples of context before each step (three 10 ms hops), as upstream.
    private static let melContext = 160 * 3

    private let env: ORTEnv
    private let mel: Model
    private let embedding: Model
    private let classifier: Model
    private let featureFrames: Int
    private var raw: [Float] = []
    private var mels: [[Float]] = []
    private var features: [[Float]] = []
    private var initialFeatures: [[Float]]?
    private var steps = 0

    /// Loads the three models of an installed `WakeModel` folder.
    public init(model: WakeModel, directory: URL) throws {
        try self.init(directory: directory, classifier: model.classifier)
    }

    public init(directory: URL, classifier classifierFile: String, featureFrames: Int = 16) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        // One thread: a few milliseconds per 80 ms frame, and no burst of cores while idle-listening.
        try options.setIntraOpNumThreads(1)
        func load(_ name: String) throws -> Model {
            let path = directory.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { throw Failure.missingModel(name) }
            let session = try ORTSession(env: env, modelPath: path, sessionOptions: options)
            guard let input = try session.inputNames().first, let output = try session.outputNames().first
            else { throw Failure.badOutput(name) }
            return Model(session: session, input: input, output: output)
        }
        self.env = env
        mel = try load(WakeModels.melspectrogramFile)
        embedding = try load(WakeModels.embeddingFile)
        classifier = try load(classifierFile)
        self.featureFrames = featureFrames
    }

    public func reset() async throws {
        raw = []
        mels = Array(repeating: Array(repeating: 1, count: Self.melBins), count: Self.embeddingWindow)
        if initialFeatures == nil {
            // Upstream pre-fills the feature history with embeddings of 4 s of low-level noise.
            var generator = SplitMix64(seed: 0x4152_4348)
            let noise = (0..<64_000).map { _ in Float(Int(generator.next() % 2000) - 1000) }
            let spectrum = try melspectrogram(noise)
            let windows = stride(from: 0, to: spectrum.count, by: 8)
                .filter { $0 + Self.embeddingWindow <= spectrum.count }
                .map { Array(spectrum[$0..<($0 + Self.embeddingWindow)]) }
            initialFeatures = try embed(windows)
        }
        features = initialFeatures ?? []
        steps = 0
    }

    public func score(_ frame: [Float]) async throws -> Float {
        guard frame.count == Self.frameSamples else { throw WakeDetectorError.invalidAudio }
        if mels.isEmpty { try await reset() }
        // Same scaling as openWakeWord's PCM16 input: to PCM16 by truncation, then back to float.
        raw.append(contentsOf: frame.map { Float(Int16(clamping: Int($0 * 32767))) })
        if raw.count > Self.frameSamples + Self.melContext {
            raw.removeFirst(raw.count - (Self.frameSamples + Self.melContext))
        }
        mels.append(contentsOf: try melspectrogram(raw))
        if mels.count > 970 { mels.removeFirst(mels.count - 970) }
        features.append(contentsOf: try embed([Array(mels.suffix(Self.embeddingWindow))]))
        if features.count > 120 { features.removeFirst(features.count - 120) }
        let window = Array(features.suffix(featureFrames))
        guard window.count == featureFrames else { return 0 }
        let output = try run(classifier, window.flatMap { $0 }, shape: [1, featureFrames, Self.embeddingSize])
        guard let value = output.first, value.isFinite else { throw Failure.badOutput("classifier") }
        defer { steps += 1 }
        // Upstream reports zero for the first five frames after a reset.
        return steps < 5 ? 0 : min(1, max(0, value))
    }

    private func melspectrogram(_ samples: [Float]) throws -> [[Float]] {
        let output = try run(mel, samples, shape: [1, samples.count])
        guard output.count % Self.melBins == 0 else { throw Failure.badOutput("melspectrogram") }
        return stride(from: 0, to: output.count, by: Self.melBins).map { start in
            output[start..<(start + Self.melBins)].map { $0 / 10 + 2 }
        }
    }

    private func embed(_ windows: [[[Float]]]) throws -> [[Float]] {
        guard !windows.isEmpty else { return [] }
        let flat = windows.flatMap { $0.flatMap { $0 } }
        let output = try run(
            embedding, flat, shape: [windows.count, Self.embeddingWindow, Self.melBins, 1])
        guard output.count == windows.count * Self.embeddingSize else {
            throw Failure.badOutput("embedding")
        }
        return stride(from: 0, to: output.count, by: Self.embeddingSize).map {
            Array(output[$0..<($0 + Self.embeddingSize)])
        }
    }

    private func run(_ model: Model, _ values: [Float], shape: [Int]) throws -> [Float] {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 4) }
        let tensor = try ORTValue(
            tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
        let outputs = try model.session.run(
            withInputs: [model.input: tensor], outputNames: [model.output], runOptions: nil)
        guard let result = outputs[model.output] else { throw Failure.badOutput(model.output) }
        let bytes = try result.tensorData() as Data
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Deterministic noise for the feature pre-fill, so detection is reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
