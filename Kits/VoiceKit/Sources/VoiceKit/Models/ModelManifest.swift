import CryptoKit
import Foundation

/// One file of a model, pinned by size and SHA-256.
public struct ModelArtifact: Sendable, Equatable {
    public let path: String
    public let size: Int64
    public let sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// A pinned, downloadable model: where it comes from, what it must hash to, and the licence
/// it is used under. Nothing is fetched until the person asks (`ModelStore.download()`).
public struct ModelManifest: Sendable {
    public let id: String
    public let displayName: String
    /// Files are fetched from `baseURL/<path>`: `https` for real downloads, `file` in tests.
    public let baseURL: URL
    public let artifacts: [ModelArtifact]
    public let licence: String
    /// False when the licence forbids shipping the files inside an app (a non-commercial
    /// model): such a model is only ever downloaded on the person's request.
    public let redistributable: Bool
    /// Folders that may already hold identical files (an earlier install, another app's cache
    /// of the same pinned revision). Matching files are copied instead of downloaded; on APFS
    /// the copy is a clone and uses no extra space.
    public var seedDirectories: [URL]

    public init(
        id: String, displayName: String, baseURL: URL, artifacts: [ModelArtifact],
        licence: String, redistributable: Bool, seedDirectories: [URL] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.artifacts = artifacts
        self.licence = licence
        self.redistributable = redistributable
        self.seedDirectories = seedDirectories
    }

    /// The same manifest with extra seed folders, for a host that knows where another app
    /// keeps the same files.
    public func seeded(from directories: [URL]) -> ModelManifest {
        var copy = self
        copy.seedDirectories += directories
        return copy
    }

    public var totalBytes: Int64 { artifacts.reduce(0) { $0 + $1.size } }

    /// Changes whenever any pinned file changes, so an old verified install is re-checked.
    public var fingerprint: String {
        let text = artifacts.map { "\($0.path) \($0.size) \($0.sha256)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}
