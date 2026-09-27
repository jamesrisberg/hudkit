import Foundation

/// Tells a running MacHUD that this app exists, so a freshly built bundle gets its dock
/// button without a rescan or a MacHUD relaunch.
///
/// `HUDSocketServer.start()` calls `announceOnLaunch(excluding:)`: when the app's bundle has a
/// `Contents/Resources/machud.json` and a MacHUD socket exists, it sends
/// `{"command": "apps", "args": {"action": "announce", "path": <bundle path>}}` on a
/// background queue. Fire-and-forget: it never blocks launch and ignores every error.
/// `HUD_NO_ANNOUNCE=1` turns it off. MacHUD answers an already-known bundle with a no-op.
public enum HUDAnnounce {
    /// The MacHUD socket announcements go to: `MACHUD_SOCKET` (an isolated instance) when
    /// set, else the MacHUD contract socket (`HUDSocket.path(for: "machud")`).
    public static func machudSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["MACHUD_SOCKET"], !path.isEmpty { return path }
        return HUDSocket.path(for: "machud")
    }

    /// True when `HUD_NO_ANNOUNCE=1`.
    public static func isDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["HUD_NO_ANNOUNCE"] == "1"
    }

    /// The request `announce` sends.
    public static func request(bundlePath: String) -> (command: String, args: [String: Any]) {
        ("apps", ["action": "announce", "path": bundlePath])
    }

    /// Why an announcement is skipped, or nil when it should be sent to `socketPath`.
    /// Skipped when disabled, when the bundle has no MacHUD manifest (CLIs, test runners),
    /// when nothing exists at `socketPath`, or when `socketPath` is one of the announcing
    /// server's own paths (MacHUD itself).
    public static func skipReason(bundleURL: URL, socketPath: String, ownPaths: [String] = [],
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if isDisabled(environment: environment) { return "HUD_NO_ANNOUNCE=1" }
        guard bundleURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: HUDManifest.manifestURL(inBundleAt: bundleURL).path) else {
            return "no machud.json in \(bundleURL.path)"
        }
        guard FileManager.default.fileExists(atPath: socketPath) else { return "no MacHUD socket at \(socketPath)" }
        if ownPaths.contains(socketPath) { return "announcing to itself" }
        return nil
    }

    /// Sends the announcement for `bundleURL` to `socketPath` on `queue`, unless
    /// `skipReason` says not to. `completion` (on `queue`) gets MacHUD's response, or nil
    /// when skipped or when the request failed. Returns whether a request was sent.
    @discardableResult
    public static func announce(bundleURL: URL, socketPath: String, ownPaths: [String] = [],
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                queue: DispatchQueue = .global(qos: .utility),
                                completion: (@Sendable ([String: Any]?) -> Void)? = nil) -> Bool {
        if skipReason(bundleURL: bundleURL, socketPath: socketPath, ownPaths: ownPaths, environment: environment) != nil {
            return false
        }
        let (command, args) = request(bundlePath: bundleURL.path)
        let payload = args.mapValues { "\($0)" }
        queue.async {
            let response = try? HUDSocketClient(path: socketPath, timeout: 5).request(command, args: payload)
            completion?(response)
        }
        return true
    }

    private static let lock = NSLock()
    private static var didAnnounce = false

    /// Once per process: announces `Bundle.main` to the MacHUD socket. Called by
    /// `HUDSocketServer.start()`; `ownPaths` are that server's paths.
    static func announceOnLaunch(excluding ownPaths: [String]) {
        lock.lock()
        guard !didAnnounce else { lock.unlock(); return }
        didAnnounce = true
        lock.unlock()
        let bundleURL = Bundle.main.bundleURL
        DispatchQueue.global(qos: .utility).async {
            // Resolving the socket path touches the file system; keep it off the launch path.
            announce(bundleURL: bundleURL, socketPath: machudSocketPath(), ownPaths: ownPaths)
        }
    }
}
