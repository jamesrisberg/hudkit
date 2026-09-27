import Foundation

/// Finds MacHUD manifests in installed app bundles without launching them.
public struct HUDManifestScanner: Sendable {
    public struct Entry: Equatable, Sendable {
        public var manifest: HUDManifest
        public var bundleURL: URL
    }

    public struct Failure: Equatable, Sendable {
        public var bundleURL: URL
        public var reason: String
    }

    /// `/Applications` and `~/Applications`.
    public static var standardDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    public var directories: [URL]
    /// Individual bundles checked after the directories (e.g. apps announced from outside
    /// them). One without a manifest is skipped like a directory entry without one.
    public var bundles: [URL]

    /// - Parameters:
    ///   - extraDirectories: searched after the standard ones (e.g. a dev build directory).
    ///   - includeStandard: false to search only `extraDirectories` (tests).
    ///   - bundles: single `.app` bundles checked after every directory.
    public init(extraDirectories: [URL] = [], includeStandard: Bool = true, bundles: [URL] = []) {
        directories = (includeStandard ? Self.standardDirectories : []) + extraDirectories
        self.bundles = bundles
    }

    /// Every app with a valid manifest. Looks at `.app` bundles in each directory and one level
    /// of plain subfolders (e.g. `/Applications/Utilities`), then at `bundles`. When two bundles
    /// declare the same id, the one found first wins.
    public func scan() -> [Entry] { scanReport().entries }

    /// `scan()` plus the bundles whose manifest failed to load. With `keepingDuplicates`,
    /// every bundle declaring an id is returned (in search order) so the caller can choose
    /// between them; the same bundle reached twice (a symlinked directory, a bundle also in
    /// `bundles`) is still listed once.
    public func scanReport(keepingDuplicates: Bool = false) -> (entries: [Entry], failures: [Failure]) {
        var entries: [Entry] = []
        var failures: [Failure] = []
        var seenIDs = Set<String>()
        var seenBundles = Set<String>()
        let candidates = directories.flatMap(Self.appBundles(in:)) + bundles
        for bundle in candidates {
            guard seenBundles.insert(bundle.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { continue }
            let url = HUDManifest.manifestURL(inBundleAt: bundle)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let manifest = try HUDManifest.load(fromBundleAt: bundle)
                guard seenIDs.insert(manifest.id).inserted || keepingDuplicates else { continue }
                entries.append(Entry(manifest: manifest, bundleURL: bundle))
            } catch {
                failures.append(Failure(bundleURL: bundle, reason: "\(error)"))
            }
        }
        return (entries, failures)
    }

    static func appBundles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var bundles: [URL] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if item.pathExtension == "app" {
                bundles.append(item)
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let sub = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                bundles += sub.filter { $0.pathExtension == "app" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }
        return bundles
    }
}
