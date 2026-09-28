import Foundation

/// A wake phrase and the pinned openWakeWord files that detect it: the two shared feature
/// models plus the phrase's classifier, installed together in one folder.
public struct WakeModel: Sendable, Identifiable {
    public var id: String { manifest.id }
    public let phrase: String
    /// The classifier's file name inside the installed folder.
    public let classifier: String
    public let manifest: ModelManifest

    public init(phrase: String, classifier: String, manifest: ModelManifest) {
        self.phrase = phrase
        self.classifier = classifier
        self.manifest = manifest
    }

    /// The install folder under a host's models root (`<root>/<manifest id>`).
    public func directory(in root: URL) -> URL {
        root.appendingPathComponent(manifest.id, isDirectory: true)
    }
}

/// The wake models VoiceKit knows. Every one is downloaded on demand into a folder the host
/// chooses; VoiceKit bundles no model files.
public enum WakeModels {
    public static let melspectrogramFile = "melspectrogram.onnx"
    public static let embeddingFile = "embedding_model.onnx"

    /// openWakeWord's shared feature models (melspectrogram and Google's speech embedding),
    /// Apache-2.0.
    static let featureArtifacts: [ModelArtifact] = [
        .init(
            path: melspectrogramFile, size: 1_087_958,
            sha256: "ba2b0e0f8b7b875369a2c89cb13360ff53bac436f2895cced9f479fa65eb176f"),
        .init(
            path: embeddingFile, size: 1_326_578,
            sha256: "70d164290c1d095d1d4ee149bc5e00543250a7316b59f31d056cff7bd3075c1f"),
    ]

    /// openWakeWord's "hey jarvis" classifier. CC BY-NC-SA 4.0: personal, non-commercial use
    /// only, so it is never bundled with an app or a release; the person downloads it.
    public static let heyJarvis = WakeModel(
        phrase: "Hey Jarvis",
        classifier: "hey_jarvis_v0.1.onnx",
        manifest: ModelManifest(
            id: "openwakeword-hey-jarvis-v0.1",
            displayName: "wake model",
            baseURL: URL(string: "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/")!,
            artifacts: featureArtifacts + [
                .init(
                    path: "hey_jarvis_v0.1.onnx", size: 1_271_370,
                    sha256: "94a13cfe60075b132f6a472e7e462e8123ee70861bc3fb58434a73712ee0d2cb"),
            ],
            licence:
                "openWakeWord “hey jarvis” model: CC BY-NC-SA 4.0 (personal, non-commercial use). Feature models: Apache-2.0.",
            redistributable: false))

    public static let all: [WakeModel] = [heyJarvis]

    /// The model for a phrase, compared as `TriggerPhrase.normalize` does; nil when no model
    /// detects that phrase.
    public static func model(forPhrase phrase: String) -> WakeModel? {
        let key = TriggerPhrase.normalize(phrase)
        return all.first { TriggerPhrase.normalize($0.phrase) == key }
    }
}
