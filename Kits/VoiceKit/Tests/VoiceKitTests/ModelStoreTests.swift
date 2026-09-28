import Foundation
import Testing

@testable import VoiceKit

@MainActor
struct ModelStoreTests {
    private func manifest(files: [String: Data], base: URL, seeds: [URL] = []) -> ModelManifest {
        ModelManifest(
            id: "test", displayName: "test model", baseURL: base,
            artifacts: files.keys.sorted().map {
                ModelArtifact(path: $0, size: Int64(files[$0]!.count), sha256: sha256(files[$0]!))
            },
            licence: "test", redistributable: true, seedDirectories: seeds)
    }

    private func write(_ files: [String: Data], to directory: URL) throws {
        for (path, data) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    private func settle(_ store: ModelStore) async throws {
        try await eventually { !store.isDownloading && !store.isVerifying }
    }

    private static let noNetwork: ModelStore.Downloader = { _, _, _ in
        Issue.record("must not download")
        throw CancellationError()
    }

    @Test func downloadsFromAFileURLAndVerifies() async throws {
        let files = ["a.onnx": Data("model a".utf8), "nested/b.bin": Data(repeating: 7, count: 4096)]
        let source = try temporaryDirectory("source")
        try write(files, to: source)
        let target = source.deletingLastPathComponent().appendingPathComponent("target")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let spec = manifest(files: files, base: source)
        let store = ModelStore(manifest: spec, directory: target)
        #expect(!store.isReady)
        store.download()
        try await settle(store)
        #expect(store.isReady, "\(store.error)")
        #expect(store.progress == 1)
        #expect(try Data(contentsOf: target.appendingPathComponent("nested/b.bin")) == files["nested/b.bin"])
        #expect(ModelStore.isInstalled(spec, in: target))
        // The marker check is cheap: same size passes, a new size fails.
        try Data("model A".utf8).write(to: target.appendingPathComponent("a.onnx"))
        #expect(ModelStore.isInstalled(spec, in: target))
        try Data("model aa".utf8).write(to: target.appendingPathComponent("a.onnx"))
        #expect(!ModelStore.isInstalled(spec, in: target))
    }

    @Test func rejectsAChecksumMismatchAndRetrySkipsVerifiedFiles() async throws {
        let valid = Data("model b".utf8)
        let files = ["a.onnx": Data("model a".utf8), "b.onnx": valid]
        let source = try temporaryDirectory("source")
        try write(["a.onnx": files["a.onnx"]!, "b.onnx": Data("model x".utf8)], to: source)
        let target = source.deletingLastPathComponent().appendingPathComponent("target")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fetched = Locked<[String]>([])
        let store = ModelStore(manifest: manifest(files: files, base: source), directory: target) { url, size, progress in
            fetched.mutate { $0.append(url.lastPathComponent) }
            return try await ModelDownload.fetch(url, expectedSize: size, progress: progress)
        }
        store.download()
        try await settle(store)
        #expect(!store.isReady)
        #expect(store.error.contains("failed verification"))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("b.onnx").path))
        try valid.write(to: source.appendingPathComponent("b.onnx"))
        fetched.mutate { $0 = [] }
        store.download()
        try await settle(store)
        #expect(store.isReady, "\(store.error)")
        #expect(fetched.value == ["b.onnx"])
        // Nothing staged is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()
            == [ModelStore.markerName, "a.onnx", "b.onnx"])
    }

    @Test func usesVerifiedSeedFilesWithoutDownloading() async throws {
        let files = ["a.onnx": Data("model a".utf8), "b.onnx": Data("model b".utf8)]
        let seed = try temporaryDirectory("seed")
        try write(["a.onnx": files["a.onnx"]!, "b.onnx": Data("tampered".utf8)], to: seed)
        let source = seed.deletingLastPathComponent().appendingPathComponent("source")
        try write(files, to: source)
        let target = seed.deletingLastPathComponent().appendingPathComponent("target")
        defer { try? FileManager.default.removeItem(at: seed.deletingLastPathComponent()) }
        let fetched = Locked<[String]>([])
        let spec = manifest(files: files, base: source).seeded(from: [seed])
        let store = ModelStore(manifest: spec, directory: target) { url, size, progress in
            fetched.mutate { $0.append(url.lastPathComponent) }
            return try await ModelDownload.fetch(url, expectedSize: size, progress: progress)
        }
        store.download()
        try await settle(store)
        #expect(store.isReady, "\(store.error)")
        // Only the seed file that failed verification was fetched.
        #expect(fetched.value == ["b.onnx"])
    }

    @Test func anUnmarkedCompleteFolderIsHashedOnceWithoutNetwork() async throws {
        let files = ["model": Data("valid model".utf8), "voice": Data("valid voice".utf8)]
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let spec = manifest(files: files, base: URL(string: "https://invalid.invalid/")!)
        // One file missing: not ready, nothing hashed or fetched.
        try write(["model": files["model"]!], to: directory)
        let store = ModelStore(manifest: spec, directory: directory, downloader: Self.noNetwork)
        #expect(!store.isVerifying)
        #expect(!store.isReady)
        // All files present (as another app installs them), no marker: verified in the background.
        try write(["voice": files["voice"]!], to: directory)
        store.refresh()
        try await settle(store)
        #expect(store.isReady)
        #expect(ModelStore.isInstalled(spec, in: directory))
    }

    @Test func anUnmarkedFolderWithABadFileStaysNotReady() async throws {
        let files = ["model": Data("valid model".utf8)]
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try write(["model": Data("wrong model".utf8)], to: directory)  // same size
        let spec = manifest(files: files, base: URL(string: "https://invalid.invalid/")!)
        let store = ModelStore(manifest: spec, directory: directory, downloader: Self.noNetwork)
        try await settle(store)
        #expect(!store.isReady)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(ModelStore.markerName).path))
        // The bad file is removed, so the next launch does not hash the folder again.
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("model").path))
        let again = ModelStore(manifest: spec, directory: directory, downloader: Self.noNetwork)
        #expect(!again.isVerifying)
    }

    @Test func cancelStopsABackgroundVerification() async throws {
        let big = Data(repeating: 1, count: 48 * 1024 * 1024)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try write(["big": big], to: directory)
        let spec = manifest(files: ["big": big], base: URL(string: "https://invalid.invalid/")!)
        let store = ModelStore(manifest: spec, directory: directory, downloader: Self.noNetwork)
        #expect(store.isVerifying)
        store.cancel()
        #expect(!store.isVerifying)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!store.isReady)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(ModelStore.markerName).path))
    }

    @Test func installSweepsLeftoverPartialFiles() async throws {
        let files = ["nested/a.onnx": Data("model a".utf8)]
        let source = try temporaryDirectory("source")
        try write(files, to: source)
        let target = source.deletingLastPathComponent().appendingPathComponent("target")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try write([".stale.partial": Data("x".utf8), "nested/.old.partial": Data("y".utf8)], to: target)
        try await ModelStore.install(
            manifest(files: files, base: source), into: target,
            downloader: { try await ModelDownload.fetch($0, expectedSize: $1, progress: $2) }, progress: { _, _ in })
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(".stale.partial").path))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("nested/.old.partial").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("nested/a.onnx").path))
    }

    @Test func cancelSuppressesLateCompletionAndCleansUp() async throws {
        let data = Data("model".utf8)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let fixture = SuspendedFetch(data: data)
        let spec = manifest(files: ["model": data], base: URL(string: "https://invalid.invalid/")!)
        let store = ModelStore(manifest: spec, directory: directory) { try await fixture.fetch($0, $1, $2) }
        store.download()
        while await fixture.calls == 0 { await Task.yield() }
        store.cancel()
        await fixture.release()
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!store.isReady)
        #expect(!store.isDownloading)
        #expect(store.status == "Download cancelled")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("model").path))
        if let temporary = await fixture.lastTemporary {
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
        }
        store.download()
        try await settle(store)
        #expect(store.isReady)
    }

    @Test func refusesPlainHTTP() async throws {
        await #expect(throws: ModelDownload.Failure.self) {
            _ = try await ModelDownload.fetch(URL(string: "http://example.com/a")!, expectedSize: 1) { _ in }
        }
    }

    @Test func aCancelledTransferNeverStarts() async {
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ModelDownload.fetch(
                URL(string: "https://invalid.invalid/model")!, expectedSize: 10
            ) { _ in Issue.record("Cancelled transport emitted progress") }
        }
        do {
            let unexpected = try await operation.value
            try? FileManager.default.removeItem(at: unexpected)
            Issue.record("Cancelled transport returned a file")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func aTruncatedFileIsRejectedBeforeHashing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let url = directory.appendingPathComponent("partial")
        try Data("mod".utf8).write(to: url)
        let full = Data("model".utf8)
        #expect(!ModelStore.verified(url, artifact: .init(path: "partial", size: 5, sha256: sha256(full))))
    }
}

struct PinnedManifestTests {
    @Test func everyPinnedManifestIsWellFormed() {
        for manifest in WakeModels.all.map(\.manifest) + [KokoroModels.manifest] {
            #expect(manifest.baseURL.scheme == "https")
            #expect(!manifest.artifacts.isEmpty)
            #expect(!manifest.licence.isEmpty)
            #expect(Set(manifest.artifacts.map(\.path)).count == manifest.artifacts.count)
            for artifact in manifest.artifacts {
                #expect(artifact.sha256.count == 64 && artifact.size > 0)
            }
        }
    }

    @Test func heyJarvisCarriesItsNonCommercialNoticeAndIsNeverBundled() {
        let model = WakeModels.heyJarvis
        #expect(model.manifest.licence.contains("CC BY-NC-SA 4.0"))
        #expect(!model.manifest.redistributable)
        #expect(model.manifest.artifacts.map(\.path).contains(model.classifier))
        #expect(WakeModels.model(forPhrase: "hey, jarvis") != nil)
        #expect(WakeModels.model(forPhrase: VoiceSettings.defaultWakePhrase) == nil)
        // No model file ships inside the VoiceKit module.
        let bundled = Bundle.allBundles.flatMap { $0.paths(forResourcesOfType: "onnx", inDirectory: nil) }
        #expect(bundled.isEmpty)
    }

    @Test func kokoroCatalogHasTheModelAndEnglishVoices() {
        #expect(KokoroModels.manifest.artifacts.count == 30)
        #expect(KokoroModels.voices.count == 28)
        #expect(KokoroModels.voiceIDs.contains(KokoroModels.defaultVoice))
        #expect(KokoroModels.voices.first { $0.id == "bm_george" }?.displayName == "George · British")
        let root = URL(fileURLWithPath: "/models")
        #expect(KokoroModels.directory(in: root).path == "/models/Kokoro-82M/\(KokoroModels.revision)")
        #expect(WakeModels.heyJarvis.directory(in: root).path == "/models/openwakeword-hey-jarvis-v0.1")
    }
}

private actor SuspendedFetch {
    let data: Data
    var suspended = true
    var continuation: CheckedContinuation<Void, Never>?
    var calls = 0
    var lastTemporary: URL?

    init(data: Data) { self.data = data }

    func release() {
        suspended = false
        continuation?.resume()
        continuation = nil
    }

    func fetch(_ url: URL, _ size: Int64, _ progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        calls += 1
        if suspended { await withCheckedContinuation { continuation = $0 } }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary)
        lastTemporary = temporary
        progress(Int64(data.count))
        return temporary
    }
}
