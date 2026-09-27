import AppKit

/// Hides a MacHUD sibling's status item while MacHUD hosts its menu, and shows it again when
/// MacHUD goes away (quits, crashes, or turns menu consolidation off).
///
/// ```swift
/// HUDStatusItemPolicy.attach(statusItem, appID: manifest.id, store: .home(AppEnvironment.baseDirectory))
/// router.menuProvider = { [weak self] in self?.statusItem.menu }
/// ```
///
/// It watches `HUDMenuHost.defaultURL` (`host.json`) and hides the item while the file says
/// `hostsMenus: true` and its `pid` is alive. While hidden it re-checks every `pollInterval`
/// seconds and whenever an app terminates, so a crashed MacHUD does not leave the icon gone.
/// The user can opt an app out with its `menuBar.consumed` setting (default true), kept in
/// `store` and served by `HUDControlRouter`'s `settings` verb. Pass the app's own data
/// directory (`.home(<the directory <REPO>_HOME points at>)`) so an isolated test instance
/// never writes the user's real preference; the default, `.defaults(.standard)`, is the app's
/// real user defaults.
@MainActor
public final class HUDStatusItemPolicy {
    /// The user-defaults key (and `settings` key) for the opt-out.
    public nonisolated static let consumedKey = "menuBar.consumed"
    public static let pollInterval: TimeInterval = 5

    /// Where the `menuBar.consumed` opt-out is kept.
    public struct Store {
        public let read: () -> Bool?
        public let write: (Bool) -> Void
        /// For `hello`: the file path, or `defaults:<suite>`.
        public let location: String

        public init(location: String, read: @escaping () -> Bool?, write: @escaping (Bool) -> Void) {
            self.location = location
            self.read = read
            self.write = write
        }

        /// A key in `defaults`.
        public static func defaults(_ defaults: UserDefaults) -> Store {
            Store(location: defaults == .standard ? "defaults:standard" : "defaults",
                  read: { defaults.object(forKey: HUDStatusItemPolicy.consumedKey) as? Bool },
                  write: { defaults.set($0, forKey: HUDStatusItemPolicy.consumedKey) })
        }

        /// A key in the JSON object at `url` (created on first write; other keys are kept).
        public static func file(_ url: URL) -> Store {
            Store(location: url.path, read: {
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return (object[HUDStatusItemPolicy.consumedKey] as? NSNumber).flatMap {
                    CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil
                }
            }, write: { value in
                var object = (try? Data(contentsOf: url))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                object[HUDStatusItemPolicy.consumedKey] = value
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: url, options: .atomic)
                } catch {
                    NSLog("HUDStatusItemPolicy: could not save %@: %@", url.path, "\(error)")
                }
            })
        }

        /// `<directory>/menubar.json`: the app's data directory, the one `<REPO>_HOME` replaces.
        public static func home(_ directory: URL) -> Store {
            file(directory.appendingPathComponent(HUDStatusItemPolicy.homeFileName))
        }
    }

    /// The file `Store.home` keeps the opt-out in.
    public nonisolated static let homeFileName = "menubar.json"

    /// Policies attached in this process; `HUDControlRouter` reports the first in `hello`.
    public private(set) static var attached: [HUDStatusItemPolicy] = []

    public let appID: String
    public let hostURL: URL
    public let store: Store
    private let isAlive: (HUDMenuHost) -> Bool
    private let ownPID: Int32
    private let apply: (Bool) -> Void
    private var watch: HUDFileWatch?
    private var poll: Timer?
    private var terminationObserver: NSObjectProtocol?

    /// What `host.json` said at the last check (nil: missing or unreadable).
    public private(set) var host: HUDMenuHost?
    /// Whether the status item is currently shown.
    public private(set) var isVisible = true
    /// Called after every visibility change.
    public var onChange: ((Bool) -> Void)?

    /// Hides `item` while MacHUD hosts menus. Keep using the item as before; the policy only
    /// sets its `isVisible`.
    /// `store` keeps the user's `menuBar.consumed` choice: pass `.home(<the app's data
    /// directory>)` so it follows `<REPO>_HOME` like the app's other settings.
    @discardableResult
    public static func attach(_ item: NSStatusItem, appID: String, hostURL: URL = HUDMenuHost.defaultURL,
                              store: Store = .defaults(.standard)) -> HUDStatusItemPolicy {
        let policy = HUDStatusItemPolicy(appID: appID, hostURL: hostURL, store: store) { [weak item] visible in
            item?.isVisible = visible
        }
        policy.start()
        return policy
    }

    @available(*, deprecated, message: "pass store: .home(<the app's data directory>) or .defaults(_:)")
    @discardableResult
    public static func attach(_ item: NSStatusItem, appID: String, hostURL: URL = HUDMenuHost.defaultURL,
                              defaults: UserDefaults) -> HUDStatusItemPolicy {
        attach(item, appID: appID, hostURL: hostURL, store: .defaults(defaults))
    }

    /// For tests: `isAlive` and `apply` replace the pid check and the status item.
    public init(appID: String, hostURL: URL = HUDMenuHost.defaultURL, store: Store = .defaults(.standard),
                ownPID: Int32 = getpid(), isAlive: ((HUDMenuHost) -> Bool)? = nil,
                apply: @escaping (Bool) -> Void) {
        self.appID = appID
        self.hostURL = hostURL
        self.store = store
        self.ownPID = ownPID
        self.isAlive = isAlive ?? { host in MainActor.assumeIsolated { host.isAlive } }
        self.apply = apply
    }

    @available(*, deprecated, message: "pass store: .defaults(_:) or .home(<the app's data directory>)")
    public convenience init(appID: String, hostURL: URL = HUDMenuHost.defaultURL, defaults: UserDefaults,
                            ownPID: Int32 = getpid(), isAlive: ((HUDMenuHost) -> Bool)? = nil,
                            apply: @escaping (Bool) -> Void) {
        self.init(appID: appID, hostURL: hostURL, store: .defaults(defaults), ownPID: ownPID, isAlive: isAlive, apply: apply)
    }

    /// The opt-out: false keeps the app's own status item even while MacHUD hosts menus.
    public var consumed: Bool {
        get { store.read() ?? true }
        set {
            store.write(newValue)
            evaluate()
        }
    }

    /// The decision, pure: hide only when the app lets itself be consumed and a live host
    /// other than this process says it hosts menus.
    public nonisolated static func shouldShow(host: HUDMenuHost?, consumed: Bool, ownPID: Int32,
                                              isAlive: (HUDMenuHost) -> Bool) -> Bool {
        guard consumed, let host, host.hostsMenus, host.pid != ownPID else { return true }
        return !isAlive(host)
    }

    /// Re-reads `host.json` and applies the result.
    public func evaluate() {
        host = HUDMenuHost.read(from: hostURL)
        let show = Self.shouldShow(host: host, consumed: consumed, ownPID: ownPID, isAlive: isAlive)
        let changed = show != isVisible
        isVisible = show
        apply(show)
        updatePolling()
        if changed { onChange?(show) }
    }

    /// Applies the current state and starts watching. Registers the policy in `attached`.
    public func start() {
        if !Self.attached.contains(where: { $0 === self }) { Self.attached.append(self) }
        watch = HUDFileWatch(url: hostURL, queue: .main, debounce: 0.1) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.evaluate()
            }
        }
        evaluate()
    }

    /// Stops watching and shows the item again.
    public func stop() {
        watch?.cancel()
        watch = nil
        poll?.invalidate()
        poll = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        Self.attached.removeAll { $0 === self }
        isVisible = true
        apply(true)
    }

    /// Whether the liveness poll is running (only while hidden).
    public var isPolling: Bool { poll != nil }

    private func updatePolling() {
        if isVisible {
            poll?.invalidate()
            poll = nil
        } else if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            poll?.tolerance = 1
        }
    }

    /// For `hello`'s `statusItem` field.
    public var json: [String: Any] {
        var d: [String: Any] = ["visible": isVisible, "consumed": consumed, "hostFile": hostURL.path,
                                "store": store.location]
        if let host {
            d["host"] = ["pid": Int(host.pid), "bundleID": host.bundleID, "hostsMenus": host.hostsMenus,
                         "alive": isAlive(host)]
        }
        return d
    }
}
