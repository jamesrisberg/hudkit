import Foundation

/// Isolation switches for tests and parallel instances (docs/CONTRACT.md):
///
/// - `__REPO_UPPER___HOME`: base directory for everything __PRODUCT__ writes (settings in
///   `<home>/preferences.json`); default `~/Library/Application Support/__PRODUCT__`.
/// - `__REPO_UPPER___SOCKET`: socket name under MacHUD's sockets directory; default `__REPO__`.
/// - `__REPO_UPPER___NO_HOTKEYS`: set to skip registering global hotkeys.
enum AppEnvironment {
    static let environment = ProcessInfo.processInfo.environment

    static var isolatedHome: String? { nonEmpty("__REPO_UPPER___HOME") }

    static var baseDirectory: URL {
        if let home = isolatedHome {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("__PRODUCT__", isDirectory: true)
    }

    static var settingsURL: URL { baseDirectory.appendingPathComponent("preferences.json") }

    static func socketName(default name: String) -> String { nonEmpty("__REPO_UPPER___SOCKET") ?? name }

    static var hotKeysEnabled: Bool { environment["__REPO_UPPER___NO_HOTKEYS"] == nil }

    private static func nonEmpty(_ key: String) -> String? {
        environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }
}
