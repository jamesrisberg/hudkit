import Foundation

/// Finds the Node companion BrainKit ships as a resource (`BrainKit_BrainKit.bundle`,
/// folder `Companion`).
///
/// SwiftPM puts the resource bundle next to the built executable or test bundle; an app
/// bundle carries it in `Contents/Resources`. The lookup tries those places, then the
/// source checkout, and never traps (SwiftPM's generated `Bundle.module` does when the
/// bundle is missing).
public enum BrainCompanion {
    public static let bundleName = "BrainKit_BrainKit.bundle"
    public static let folderName = "Companion"

    /// The companion folder, or nil when no copy is found.
    public static var directory: URL? { directory(in: candidates) }

    /// `server.mjs`, the companion's entry point.
    public static var serverScript: URL? { directory?.appendingPathComponent("server.mjs") }

    /// The first candidate folder that holds `server.mjs`.
    static func directory(in candidates: [URL]) -> URL? {
        candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("server.mjs").path)
        }
    }

    static var candidates: [URL] {
        var bundles: [URL] = []
        if let resources = Bundle.main.resourceURL { bundles.append(resources.appendingPathComponent(bundleName)) }
        for owner in [Bundle.main, Bundle(for: Marker.self)] {
            bundles.append(owner.bundleURL.appendingPathComponent(bundleName))
            bundles.append(owner.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName))
        }
        var folders = bundles.map { url -> URL in
            let resources = Bundle(url: url)?.resourceURL ?? url
            return resources.appendingPathComponent(folderName, isDirectory: true)
        }
        // Development builds run from a checkout.
        folders.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(folderName, isDirectory: true))
        return folders
    }

    private final class Marker {}
}
