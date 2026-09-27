import AppKit

/// MacHUD's announcement that it hosts its siblings' menus, so they can hide their own
/// status items (`HUDStatusItemPolicy`). The file is
/// `~/Library/Application Support/MacHUD/host.json`:
///
/// ```json
/// {"pid": 4242, "bundleID": "xyz.machud", "hostsMenus": true, "updatedAt": "2026-09-26T12:00:00Z"}
/// ```
///
/// MacHUD writes it on launch (and refreshes it every minute), rewrites it with
/// `hostsMenus: false` when menu consolidation is turned off, and removes it on quit. A file
/// left behind by a crash is harmless: readers check that `pid` is still that app.
public struct HUDMenuHost: Codable, Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    public var hostsMenus: Bool
    public var updatedAt: Date

    public init(pid: Int32 = getpid(), bundleID: String, hostsMenus: Bool, updatedAt: Date = Date()) {
        self.pid = pid
        self.bundleID = bundleID
        self.hostsMenus = hostsMenus
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case pid, bundleID, hostsMenus, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
        hostsMenus = try c.decodeIfPresent(Bool.self, forKey: .hostsMenus) ?? false
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt).flatMap(HUDDockRegistry.parseDate) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pid, forKey: .pid)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(hostsMenus, forKey: .hostsMenus)
        try c.encode(HUDDockRegistry.formatDate(updatedAt), forKey: .updatedAt)
    }

    /// `MACHUD_HOST_FILE` when set (isolated instances and tests), else
    /// `~/Library/Application Support/MacHUD/host.json`.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["MACHUD_HOST_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return HUDSocket.directory.deletingLastPathComponent().appendingPathComponent("host.json")
    }

    /// The file's contents, or nil when missing or unreadable.
    public static func read(from url: URL = defaultURL) -> HUDMenuHost? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> HUDMenuHost? { try? JSONDecoder().decode(HUDMenuHost.self, from: data) }

    /// Writes the file atomically.
    public func write(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Removes the file if it is `pid`'s (another instance's file is left alone).
    public static func remove(at url: URL = defaultURL, ifOwnedBy pid: Int32 = getpid()) {
        guard let current = read(from: url), current.pid == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether `pid` is still running and (when it has a bundle id) still that app, so a
    /// reused pid does not count.
    @MainActor
    public var isAlive: Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno != ESRCH else { return false }
        guard !bundleID.isEmpty, let app = NSRunningApplication(processIdentifier: pid),
              let running = app.bundleIdentifier else { return true }
        return running == bundleID
    }
}
