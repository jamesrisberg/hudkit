import Combine
import Foundation

/// Where each dock strip currently sits, shared between processes so sibling strips (the
/// MacHUD dock, Sift's dock mode, ...) can stay out of each other's way.
///
/// The file is `~/Library/Application Support/MacHUD/docks.json`:
///
/// ```json
/// {"xyz.machud": {"position": "topLeft", "frames": [[0, 950, 40, 40], [0, 600, 40, 390]],
///                 "updatedAt": "2026-09-26T12:00:00Z", "pid": 4242}}
/// ```
///
/// Frames are `[x, y, w, h]` in AppKit screen coordinates (one per strip segment, e.g. both
/// arms of an L). Writes are atomic (temp file + rename) and serialised across processes with
/// an `flock` on `docks.json.lock`. `publish` is a no-op when nothing changed, so strips that
/// republish in response to `watch` do not ping-pong. Entries whose `pid` is no longer running
/// are ignored by `others(than:)`.
///
/// ```swift
/// let registry = HUDDockRegistry()
/// try registry.publish(appID: "xyz.machud", position: .top, frames: [strip.frame])
/// watcher = registry.watch { entries in
///     let blocked = registry.others(than: "xyz.machud").values.flatMap(\.frames)
///     strip.setFrame(HUDDockLayout.avoiding(frame: ideal, others: blocked, along: .top, in: visible), display: true)
/// }
/// ```
public final class HUDDockRegistry: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var position: HUDDockPosition
        public var frames: [CGRect]
        public var updatedAt: Date
        /// The publishing process, used to drop entries left behind by a crash.
        public var pid: Int32?

        public init(position: HUDDockPosition, frames: [CGRect], updatedAt: Date = Date(), pid: Int32? = nil) {
            self.position = position
            self.frames = frames
            self.updatedAt = updatedAt
            self.pid = pid
        }

        enum CodingKeys: String, CodingKey { case position, frames, updatedAt, pid }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            position = try c.decode(HUDDockPosition.self, forKey: .position)
            let raw = try c.decodeIfPresent([[Double]].self, forKey: .frames) ?? []
            frames = raw.compactMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            let stamp = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            updatedAt = stamp.flatMap(HUDDockRegistry.parseDate) ?? .distantPast
            pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(position, forKey: .position)
            try c.encode(frames.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }, forKey: .frames)
            try c.encode(HUDDockRegistry.formatDate(updatedAt), forKey: .updatedAt)
            try c.encodeIfPresent(pid, forKey: .pid)
        }

        /// Whether the publishing process is still running (true when unknown).
        public var isLive: Bool {
            guard let pid, pid > 0 else { return true }
            return kill(pid, 0) == 0 || errno != ESRCH
        }
    }

    /// `~/Library/Application Support/MacHUD/docks.json`.
    public static var defaultURL: URL {
        HUDSocket.directory.deletingLastPathComponent().appendingPathComponent("docks.json")
    }

    public let url: URL
    private var lockURL: URL { url.appendingPathExtension("lock") }

    public init(url: URL = HUDDockRegistry.defaultURL) {
        self.url = url
    }

    // MARK: - Reading

    /// Every entry in the file (including stale ones). Missing or unreadable file: empty.
    /// Entries that fail to decode (unknown position, ...) are skipped, not fatal.
    public func entries() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return Self.decode(data)
    }

    public func entry(for appID: String) -> Entry? { entries()[appID] }

    /// Live entries of every other app.
    public func others(than appID: String) -> [String: Entry] {
        entries().filter { $0.key != appID && $0.value.isLive }
    }

    static func decode(_ data: Data) -> [String: Entry] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Entry] = [:]
        for (key, value) in object {
            guard JSONSerialization.isValidJSONObject(value),
                  let d = try? JSONSerialization.data(withJSONObject: value),
                  let entry = try? JSONDecoder().decode(Entry.self, from: d) else { continue }
            out[key] = entry
        }
        return out
    }

    // MARK: - Writing

    /// Records this app's strip. No write happens if position, frames and pid are unchanged.
    public func publish(appID: String, position: HUDDockPosition, frames: [CGRect]) throws {
        let pid = getpid()
        try mutate { all in
            if let old = all[appID], old.position == position, old.frames == frames, old.pid == pid { return false }
            all[appID] = Entry(position: position, frames: frames, updatedAt: Date(), pid: pid)
            return true
        }
    }

    /// Removes this app's strip (e.g. when it stops docking or quits).
    public func remove(appID: String) throws {
        try mutate { all in all.removeValue(forKey: appID) != nil }
    }

    private func mutate(_ change: (inout [String: Entry]) -> Bool) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard lockFD >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: lockURL.path]) }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        flock(lockFD, LOCK_EX)
        var all = entries()
        guard change(&all) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(all).write(to: url, options: .atomic)
    }

    // MARK: - Watching

    /// Calls `handler` on `queue` with all entries whenever the file's contents change
    /// (by any process), coalescing bursts within `debounce` seconds. Watches the directory,
    /// so it survives the atomic replace. Keep the returned cancellable; releasing it stops
    /// the watch.
    public func watch(queue: DispatchQueue = .main, debounce: TimeInterval = 0.1,
                      _ handler: @escaping @Sendable ([String: Entry]) -> Void) -> AnyCancellable {
        let watch = HUDFileWatch(url: url, queue: queue, debounce: debounce) { data in
            handler(data.map(HUDDockRegistry.decode) ?? [:])
        }
        guard watch.isWatching else { return AnyCancellable {} }
        return AnyCancellable { watch.cancel() }
    }

    // MARK: - Dates

    static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
