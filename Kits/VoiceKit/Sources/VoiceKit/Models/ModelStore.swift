import Combine
import CryptoKit
import Foundation

/// Downloads a manifest into a directory, verifying every file's size and SHA-256 before it
/// is installed. Readiness is a marker written after full verification plus a size check of
/// every file, so launch never re-hashes hundreds of megabytes. A folder with every file at
/// its pinned size but no marker (an install made by another app) is hashed once in the
/// background and then marked; a file that fails that check is deleted, so it is not hashed
/// again at the next launch and the next download replaces it.
@MainActor
public final class ModelStore: ObservableObject {
    public typealias Downloader =
        @Sendable (URL, Int64, @escaping @Sendable (Int64) -> Void) async throws -> URL

    public enum Failure: LocalizedError {
        case checksum(String)
        public var errorDescription: String? {
            switch self {
            case .checksum(let name): return "The downloaded \(name) failed verification. Try again."
            }
        }
    }

    public nonisolated static let markerName = ".verified"

    public let manifest: ModelManifest
    public let directory: URL
    @Published public private(set) var isReady = false
    @Published public private(set) var isDownloading = false
    /// True while an unmarked folder is being hashed.
    @Published public private(set) var isVerifying = false
    @Published public private(set) var progress = 0.0
    @Published public private(set) var status = ""
    @Published public private(set) var error = ""

    private let downloader: Downloader
    private var operation: Task<Void, Never>?
    /// The detached hashing of an unmarked folder; cancelled with the operation.
    private var verification: Task<UnmarkedCheck, Never>?
    private var generation = UUID()

    enum UnmarkedCheck: Sendable { case verified, failed, cancelled }

    public init(
        manifest: ModelManifest, directory: URL,
        downloader: @escaping Downloader = { try await ModelDownload.fetch($0, expectedSize: $1, progress: $2) }
    ) {
        self.manifest = manifest
        self.directory = directory
        self.downloader = downloader
        refresh()
    }

    /// Cheap readiness check: the verification marker matches this manifest and every file
    /// has its pinned size.
    public nonisolated static func isInstalled(_ manifest: ModelManifest, in directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(markerName)
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines) == manifest.fingerprint
        else { return false }
        return hasPinnedSizes(manifest, in: directory)
    }

    nonisolated static func hasPinnedSizes(_ manifest: ModelManifest, in directory: URL) -> Bool {
        manifest.artifacts.allSatisfy {
            let values = try? directory.appendingPathComponent($0.path).resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey,
            ])
            return values?.isRegularFile == true && values?.fileSize.map(Int64.init) == $0.size
        }
    }

    public func refresh() {
        guard !isDownloading else { return }
        settleReadiness()
        guard !isReady, !isVerifying, Self.hasPinnedSizes(manifest, in: directory) else { return }
        verifyUnmarked()
    }

    private func settleReadiness() {
        isReady = Self.isInstalled(manifest, in: directory)
        progress = isReady ? 1 : 0
        status = isReady ? "Ready" : "Not downloaded (\(manifest.sizeDescription))"
    }

    private func stopOperation() {
        operation?.cancel()
        operation = nil
        verification?.cancel()
        verification = nil
        isVerifying = false
    }

    /// Hashes a complete but unmarked folder off the main actor; never downloads.
    private func verifyUnmarked() {
        let token = UUID()
        generation = token
        isVerifying = true
        status = "Checking model files…"
        let manifest = manifest
        let directory = directory
        let verification = Task.detached(priority: .utility) { () -> UnmarkedCheck in
            Self.checkUnmarked(manifest, in: directory)
        }
        self.verification = verification
        operation = Task { [weak self] in
            _ = await verification.value
            guard let self, self.generation == token else { return }
            // Settled without refresh(): a failed check removed the bad files, and a cancelled
            // one waits for the next refresh().
            self.verification = nil
            self.isVerifying = false
            self.settleReadiness()
        }
    }

    public func download() {
        guard !isDownloading else { return }
        stopOperation()
        let token = UUID()
        generation = token
        isDownloading = true
        isReady = false
        error = ""
        progress = 0
        status = "Checking model files…"
        let manifest = manifest
        let directory = directory
        let downloader = downloader
        let report: @Sendable (Double, String?) -> Void = { [weak self] fraction, text in
            Task { @MainActor in
                guard let self, self.generation == token, self.isDownloading else { return }
                self.progress = max(self.progress, fraction)
                if let text { self.status = text }
            }
        }
        operation = Task { [weak self] in
            do {
                try await Self.install(manifest, into: directory, downloader: downloader, progress: report)
                guard let self, self.generation == token else { return }
                self.isDownloading = false
                self.refresh()
            } catch {
                guard let self, self.generation == token else { return }
                self.isDownloading = false
                self.isReady = false
                self.error = error is CancellationError ? "" : error.localizedDescription
                self.status = error is CancellationError ? "Download cancelled" : "Download failed"
            }
        }
    }

    /// Stops a download or a background check; neither restarts until `download()` or
    /// `refresh()`.
    public func cancel() {
        generation = UUID()
        stopOperation()
        isDownloading = false
        settleReadiness()
        if !isReady { status = "Download cancelled" }
    }

    /// Hashes every file of a complete, unmarked folder and writes the marker when all match.
    /// Files that do not match are deleted. Cancellation leaves the folder as it was.
    nonisolated static func checkUnmarked(_ manifest: ModelManifest, in directory: URL) -> UnmarkedCheck {
        var bad: [URL] = []
        for artifact in manifest.artifacts {
            let url = directory.appendingPathComponent(artifact.path)
            let ok = verified(url, artifact: artifact)
            if Task.isCancelled { return .cancelled }
            if !ok { bad.append(url) }
        }
        guard bad.isEmpty else {
            for url in bad { try? FileManager.default.removeItem(at: url) }
            return .failed
        }
        guard !Task.isCancelled, (try? writeMarker(manifest, in: directory)) != nil else { return .cancelled }
        return .verified
    }

    /// Installs every artifact: keeps verified files already present, clones matching files
    /// from seed folders, downloads the rest, and writes the marker last.
    public nonisolated static func install(
        _ manifest: ModelManifest, into directory: URL, downloader: Downloader,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: directory.appendingPathComponent(markerName))
        removePartials(in: directory)
        let total = Double(max(1, manifest.totalBytes))
        var finished: Int64 = 0
        for artifact in manifest.artifacts {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(artifact.path)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !verified(destination, artifact: artifact) {
                let seed = manifest.seedDirectories.map { $0.appendingPathComponent(artifact.path) }
                    .first { verified($0, artifact: artifact) }
                // Staged beside the final file so the final rename is atomic on this volume.
                let staged = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).partial")
                defer { try? fileManager.removeItem(at: staged) }
                if let seed {
                    progress(Double(finished) / total, "Using the copy already on this Mac…")
                    try fileManager.copyItem(at: seed, to: staged)
                } else {
                    progress(Double(finished) / total, "Downloading \(manifest.displayName)…")
                    let completed = finished
                    let temporary = try await downloader(
                        manifest.baseURL.appendingPathComponent(artifact.path), artifact.size
                    ) { bytes in
                        progress(Double(completed + min(artifact.size, max(0, bytes))) / total, nil)
                    }
                    defer { try? fileManager.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    try fileManager.copyItem(at: temporary, to: staged)
                }
                guard verified(staged, artifact: artifact) else {
                    throw Failure.checksum(URL(fileURLWithPath: artifact.path).lastPathComponent)
                }
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try fileManager.moveItem(at: staged, to: destination)
                }
            }
            finished += artifact.size
            progress(Double(finished) / total, nil)
        }
        try writeMarker(manifest, in: directory)
    }

    /// Staged files an interrupted install left behind (`.<uuid>.partial`, at any depth).
    nonisolated static func removePartials(in directory: URL) {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for case let url as URL in files
        where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "partial" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func writeMarker(_ manifest: ModelManifest, in directory: URL) throws {
        try Data((manifest.fingerprint + "\n").utf8)
            .write(to: directory.appendingPathComponent(markerName), options: .atomic)
    }

    /// Full check of one file: regular file, pinned size (before hashing), then SHA-256.
    public nonisolated static func verified(_ url: URL, artifact: ModelArtifact) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, values.fileSize.map(Int64.init) == artifact.size,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                if Task.isCancelled { return false }
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == artifact.sha256
        } catch { return false }
    }
}
