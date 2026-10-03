import AppKit

/// Tells observers when the desktop around HUD windows has changed and settled: a Space
/// switch, the Mac waking, displays waking, or the screen arrangement changing (a display
/// added or removed, docking, a resolution change).
///
/// Each of those arrives as a burst of notifications, and AppKit (`isOnActiveSpace`, `NSScreen`)
/// and the window server's window list catch up only after the last one. Code that inspects
/// windows or screens acts once the burst has been quiet for 0.35 s, not on the raw
/// notification: observers are called once per burst with every kind of change seen in it
/// (and at the latest 2 s after its first notification, if they keep coming).
///
/// ```swift
/// // Keep the observation; releasing or cancelling it stops the calls.
/// settled = HUDEnvironmentMonitor.shared.observeSettled { [weak self] change in
///     if change.contains(.screenParameters) { self?.relayout() }
///     self?.reconcileWindows()
/// }
/// ```
///
/// `HUDFullscreenObserver` runs on this signal.
@MainActor
public final class HUDEnvironmentMonitor {
    /// The kinds of change seen in a burst.
    public struct Change: OptionSet, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// `NSWorkspace.activeSpaceDidChangeNotification`: the user switched desktops (or a
        /// full-screen app's Space came or went).
        public static let activeSpace = Change(rawValue: 1 << 0)
        /// `NSWorkspace.didWakeNotification`: the Mac woke from sleep.
        public static let wake = Change(rawValue: 1 << 1)
        /// `NSWorkspace.screensDidWakeNotification`: the displays woke.
        public static let screensWake = Change(rawValue: 1 << 2)
        /// `NSApplication.didChangeScreenParametersNotification`: displays added, removed,
        /// moved or resized.
        public static let screenParameters = Change(rawValue: 1 << 3)

        private static let names: [(Change, String)] = [
            (.activeSpace, "activeSpace"), (.wake, "wake"), (.screensWake, "screensWake"),
            (.screenParameters, "screenParameters"),
        ]

        /// The kinds, comma-separated (`"activeSpace,wake"`); `"none"` for none.
        public var description: String {
            let seen = Self.names.filter { contains($0.0) }.map(\.1)
            return seen.isEmpty ? "none" : seen.joined(separator: ",")
        }
    }

    /// A registered observer. The handler is called on each settle until the observation is
    /// cancelled or released.
    public final class Observation {
        fileprivate var handler: (@MainActor (Change) -> Void)?

        fileprivate init(_ handler: @escaping @MainActor (Change) -> Void) { self.handler = handler }

        /// Stops further calls.
        public func cancel() { handler = nil }
    }

    /// The monitor HUDKit uses, watching the system's notifications.
    public static let shared = HUDEnvironmentMonitor(scheduler: .main,
                                                     workspaceCenter: NSWorkspace.shared.notificationCenter,
                                                     appCenter: NotificationCenter.default)

    static let defaultSettleDelay: TimeInterval = 0.35
    static let defaultMaxSettleWait: TimeInterval = 2

    /// How long the last notification of a burst must be quiet before observers are called.
    var settleDelay: TimeInterval = HUDEnvironmentMonitor.defaultSettleDelay
    /// The longest a burst waits after its first notification: notifications that keep
    /// arriving less than `settleDelay` apart still settle then.
    var maxSettleWait: TimeInterval = HUDEnvironmentMonitor.defaultMaxSettleWait

    /// The kinds of change seen since the last settle; empty when settled.
    private(set) var pendingChanges: Change = []

    private let scheduler: HUDScheduler
    private var pendingSettle: HUDScheduledWork?
    private var burstDeadline: HUDScheduledWork?
    private var observations: [Weak] = []
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    private struct Weak {
        weak var observation: Observation?
    }

    /// `workspaceCenter` and `appCenter` are where the workspace and screen-parameter
    /// notifications arrive (nil: not observed; tests post their own or call `note`).
    init(scheduler: HUDScheduler, workspaceCenter: NotificationCenter?, appCenter: NotificationCenter?) {
        self.scheduler = scheduler
        let workspace: [(Notification.Name, Change)] = [
            (NSWorkspace.activeSpaceDidChangeNotification, .activeSpace),
            (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.screensDidWakeNotification, .screensWake),
        ]
        if let workspaceCenter {
            for (name, change) in workspace { observe(name, on: workspaceCenter, as: change) }
        }
        if let appCenter {
            observe(NSApplication.didChangeScreenParametersNotification, on: appCenter, as: .screenParameters)
        }
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter, as change: Change) {
        // Delivered on the posting thread (AppKit posts these on the main thread), so the
        // change is noted before `post` returns.
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.note(change) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.note(change) } }
            }
        }
        tokens.append((center, token))
    }

    /// Calls `handler` once each burst of changes has settled, with the kinds seen in it.
    /// Keep the returned observation for as long as the calls are wanted.
    public func observeSettled(_ handler: @escaping @MainActor (Change) -> Void) -> Observation {
        let observation = Observation(handler)
        observations.append(Weak(observation: observation))
        return observation
    }

    /// Records a change as if its notification had arrived, restarting the settle wait (but
    /// not the burst's deadline).
    func note(_ change: Change) {
        pendingChanges.formUnion(change)
        pendingSettle?.cancel()
        pendingSettle = scheduler.after(settleDelay) { [weak self] in self?.settle() }
        if burstDeadline == nil {
            burstDeadline = scheduler.after(maxSettleWait) { [weak self] in self?.settle() }
        }
    }

    private func settle() {
        pendingSettle?.cancel()
        pendingSettle = nil
        burstDeadline?.cancel()
        burstDeadline = nil
        let change = pendingChanges
        pendingChanges = []
        observations.removeAll { $0.observation?.handler == nil }
        // Each handler is read when its turn comes, so one cancelled by an earlier handler
        // in this settle is not called.
        for entry in observations { entry.observation?.handler?(change) }
    }
}
