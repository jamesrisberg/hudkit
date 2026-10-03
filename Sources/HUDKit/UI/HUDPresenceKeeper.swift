import AppKit

/// Keeps every HUD window that belongs on all Spaces on the desktop the user is looking at,
/// for as long as it stays ordered in.
///
/// The window server can drop a window's all-Spaces membership while AppKit still holds
/// `.canJoinAllSpaces` (see `reassertAllSpaces`); a window then stays on one desktop and is
/// missing from the others. HUDPanelWindow re-asserts the membership whenever it is ordered in,
/// but some windows (the voice orb, the tool dock, widgets) are ordered in once and left there
/// for days. Every `.hover` and `.widget` HUDPanelWindow reports itself here when it is ordered
/// in, ordered out or closed (apps register nothing), and is held weakly while it is in.
///
/// On each settled signal (`HUDEnvironmentMonitor`) the keeper checks each window meant to be
/// seen (visible, alpha above 0, frame on a screen). A healthy window is not touched.
/// - Off the desktop: AppKit says it is not on the active Space, or the window server does not
///   list it as on screen. The repair is what an order-in does: for hover, re-assert the hover
///   Spaces behaviour and, `HUDPanelWindow.spaceCheckDelay` later, if the window server still
///   has it off screen, move it to the active Space (`moveToActiveSpace`); for a widget,
///   re-assert the widget Spaces behaviour and order it in. A widget on a screen showing a
///   full-screen Space is meant to be absent (widgets have no `.fullScreenAuxiliary`) and is
///   left alone. A repair after which the window server still has the window off screen (a
///   wake still in progress, or a full-screen Space the size test does not recognise, such as
///   Split View) is said once and tried again on later settled signals, at most every
///   `retryInterval` (30 s), saying nothing: unseen, as the window is not on screen. A repair
///   after which only AppKit calls the window away while the window server shows it on screen
///   (or does not list it) is said once and not tried again: the user may be looking at it. A
///   check that finds the window back on the desktop after a failed attempt says so, with the
///   number of attempts. Ordering the window out and in starts afresh.
/// - Displaced: the window server reports the window somewhere other than its AppKit frame.
///   That is how it reports every all-Spaces window while a Space switch is in flight, so it is
///   only reported, never repaired, and only when the window is still displaced by the same
///   amount `displacementRecheckDelay` later and not every window kept on that screen is
///   shifted by one common amount (a swipe held in place).
///
/// Each repair and report is logged (`HUDLog.presence`) with the window, what was wrong and the
/// changes that led to the check; a pass that finds nothing wrong logs nothing.
@MainActor
final class HUDPresenceKeeper {
    static let shared = HUDPresenceKeeper(environment: .shared, scheduler: .main, probe: .live)

    /// The window server's record of one window.
    struct ServerWindow: Equatable {
        /// `kCGWindowIsOnscreen`.
        var isOnScreen: Bool
        /// `kCGWindowBounds`, in AppKit screen coordinates (origin bottom-left).
        var bounds: CGRect
    }

    /// What the keeper reads about windows and screens; tests substitute fakes.
    struct Probe {
        /// AppKit's view: whether the window is on the current Space of some display.
        var isOnActiveSpace: @MainActor (NSWindow) -> Bool
        /// The window server's record of the window; nil when it does not list the window at
        /// all (no evidence either way).
        var serverWindow: @MainActor (NSWindow) -> ServerWindow?
        var screens: @MainActor () -> [HUDScreenSnapshot]
        /// Every app's on-screen windows, to tell a screen showing a full-screen Space.
        var windows: @MainActor () -> [HUDWindowSnapshot]

        static let live = Probe(isOnActiveSpace: { $0.isOnActiveSpace },
                                serverWindow: { serverWindow(number: $0.windowNumber) },
                                screens: { NSScreen.screens.map(HUDScreenSnapshot.init) },
                                windows: { HUDFullscreenObserver.liveWindows() })

        /// Reads one window's entry from `CGWindowListCopyWindowInfo` (public API; a window's
        /// own app needs no permission for it). The on-screen key is absent for a window that
        /// is not on screen.
        @MainActor
        static func serverWindow(number: Int) -> ServerWindow? {
            guard number > 0,
                  let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: AnyObject]],
                  let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == number }),
                  let bounds = HUDWindowSnapshot.appKitBounds(of: info, primaryScreenHeight: HUDWindowSnapshot.primaryScreenHeight)
            else { return nil }
            let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            return ServerWindow(isOnScreen: onScreen, bounds: bounds)
        }
    }

    /// Something the keeper found about a window, and logged.
    struct Finding: Equatable {
        enum Kind: String, Equatable {
            /// Off the user's desktop: repaired (the first attempt of an episode).
            case offDesktop
            /// Still off the desktop after a repair: tried again later while the window server
            /// has it off screen (`retryInterval`), else not until it is seen there.
            case stillOffDesktop
            /// Back on the desktop after one or more failed attempts (`attempts`).
            case back
            /// On screen, but reported away from its AppKit frame: not repaired.
            case displaced
        }

        var kind: Kind
        var window: String
        var windowNumber: Int
        var behavior: HUDPanelWindow.Behavior
        var frame: CGRect
        var onActiveSpace: Bool
        var server: ServerWindow?
        var change: HUDEnvironmentMonitor.Change
        /// `.back`: the repair attempts the episode took.
        var attempts = 0
        /// `.stillOffDesktop`: how often it is tried again; nil when it is not.
        var retryInterval: TimeInterval?

        @MainActor
        init(_ kind: Kind, _ window: HUDPanelWindow, onActiveSpace: Bool, server: ServerWindow?,
             change: HUDEnvironmentMonitor.Change, attempts: Int = 0, retryInterval: TimeInterval? = nil) {
            self.kind = kind
            self.attempts = attempts
            self.retryInterval = retryInterval
            self.window = window.logName
            windowNumber = window.windowNumber
            behavior = window.behavior
            frame = window.frame
            self.onActiveSpace = onActiveSpace
            self.server = server
            self.change = change
        }

        /// The log line.
        var message: String {
            let onScreen = server.map { String($0.isOnScreen) } ?? "unlisted"
            let bounds = server.map { HUDLog.format($0.bounds) } ?? "unlisted"
            let state = "isOnActiveSpace=\(onActiveSpace) serverOnScreen=\(onScreen)"
            switch kind {
            case .offDesktop:
                return "restoring \(window) (\(behavior.rawValue)), off the user's desktop: frame \(HUDLog.format(frame)) "
                    + "\(state) serverBounds \(bounds) after \(change)"
            case .stillOffDesktop:
                let next = retryInterval.map {
                    "it is tried again at most every \(String(format: "%.0f", $0)) s while the window server has it off screen "
                        + "(expected while its screen shows a full-screen Space)"
                } ?? "the window server does not have it off screen, so it is not repaired again until it is seen on the desktop"
                return "\(window) (\(behavior.rawValue)) is still off the user's desktop after a repair; \(next): "
                    + "frame \(HUDLog.format(frame)) \(state) serverBounds \(bounds) after \(change)"
            case .back:
                return "\(window) (\(behavior.rawValue)) is back on the user's desktop after \(attempts) "
                    + "attempt\(attempts == 1 ? "" : "s"): frame \(HUDLog.format(frame)) \(state) serverBounds \(bounds) "
                    + "after \(change)"
            case .displaced:
                return "\(window) (\(behavior.rawValue)) is displaced, not repaired: frame \(HUDLog.format(frame)) "
                    + "serverBounds \(bounds) \(state) after \(change)"
            }
        }
    }

    static let defaultDisplacementRecheckDelay: TimeInterval = 0.5
    static let defaultRetryInterval: TimeInterval = 30

    var probe: Probe
    /// How long after a failed repair a window the window server still has off screen waits
    /// before the next attempt.
    var retryInterval = HUDPresenceKeeper.defaultRetryInterval
    /// How long after a displaced reading the keeper looks again.
    var displacementRecheckDelay = HUDPresenceKeeper.defaultDisplacementRecheckDelay
    /// Called with each finding, after it is logged (tests).
    var onFinding: ((Finding) -> Void)?

    private let environment: HUDEnvironmentMonitor
    private let scheduler: HUDScheduler
    private var settled: HUDEnvironmentMonitor.Observation?
    private var tracked: [Weak] = []
    /// A repair's pending follow-up, per window.
    private var followUps: [ObjectIdentifier: HUDScheduledWork] = [:]
    /// Repair attempts in each window's current episode off the desktop.
    private var attempts: [ObjectIdentifier: Int] = [:]
    /// Windows with a failed attempt in the current episode (said once).
    private var failed = Set<ObjectIdentifier>()
    /// Windows the window server still had off screen after a failed attempt: not tried again
    /// until this runs out (`retryInterval`).
    private var retryGates: [ObjectIdentifier: HUDScheduledWork] = [:]
    /// Windows a repair did not bring back although the window server does not have them off
    /// screen: not repaired again until a check finds them on the desktop.
    private var givenUp = Set<ObjectIdentifier>()
    /// Windows reported displaced: not reported again until a reading finds them at their frame.
    private var reportedDisplaced = Set<ObjectIdentifier>()
    /// The pending second look at a pass's displaced readings.
    private var secondLook: HUDScheduledWork?

    private struct Weak {
        weak var window: HUDPanelWindow?
    }

    /// One window's place at a check: the screen showing it and how far the window server
    /// has it from its frame (nil: where its frame says).
    private struct Reading {
        weak var window: HUDPanelWindow?
        let key: ObjectIdentifier
        let screen: CGRect
        let offset: Displacement?
    }

    init(environment: HUDEnvironmentMonitor, scheduler: HUDScheduler, probe: Probe) {
        self.environment = environment
        self.scheduler = scheduler
        self.probe = probe
    }

    /// The windows being kept, oldest order-in first.
    var trackedWindows: [HUDPanelWindow] {
        tracked.removeAll { $0.window == nil }
        return tracked.compactMap(\.window)
    }

    func isTracking(_ window: HUDPanelWindow) -> Bool {
        tracked.contains { $0.window === window }
    }

    /// Tracks `window` while it is ordered in and its behaviour puts it on every Space; stops
    /// otherwise. HUDPanelWindow calls this on every order-in, order-out, close and recipe change.
    func update(_ window: HUDPanelWindow) {
        if window.isVisible && window.behavior.joinsAllSpaces {
            guard !isTracking(window) else { return }
            tracked.append(Weak(window: window))
            if settled == nil {
                settled = environment.observeSettled { [weak self] change in _ = self?.check(change) }
            }
        } else {
            forget(window)
        }
    }

    /// Stops tracking `window` and drops what the keeper knew about it.
    func forget(_ window: HUDPanelWindow) {
        tracked.removeAll { $0.window == nil || $0.window === window }
        let key = ObjectIdentifier(window)
        followUps.removeValue(forKey: key)?.cancel()
        endEpisode(key)
        reportedDisplaced.remove(key)
    }

    /// Forgets a window's attempts, failures and pending retry.
    private func endEpisode(_ key: ObjectIdentifier) {
        attempts.removeValue(forKey: key)
        failed.remove(key)
        givenUp.remove(key)
        retryGates.removeValue(forKey: key)?.cancel()
    }

    /// Checks every tracked window, repairs the ones off the user's desktop and schedules a
    /// second look at displaced ones. Returns the repairs logged now (a retry is not logged).
    @discardableResult
    func check(_ change: HUDEnvironmentMonitor.Change) -> [Finding] {
        let windows = trackedWindows
        guard !windows.isEmpty else { return [] }
        let screens = probe.screens().map(\.frame)
        var onScreenWindows: [HUDWindowSnapshot]?
        var repairs: [Finding] = []
        var readings: [Reading] = []
        for window in windows {
            let key = ObjectIdentifier(window)
            guard followUps[key] == nil, let screen = Self.screenShowing(window, among: screens) else { continue }
            let onActiveSpace = probe.isOnActiveSpace(window)
            let server = probe.serverWindow(window)
            if Self.isOffDesktop(onActiveSpace: onActiveSpace, server: server) {
                guard retryGates[key] == nil, !givenUp.contains(key) else { continue }
                if window.behavior == .widget {
                    let list = onScreenWindows ?? probe.windows()
                    onScreenWindows = list
                    if Self.showsFullScreen(screen, windows: list) { continue }
                }
                let attempt = (attempts[key] ?? 0) + 1
                attempts[key] = attempt
                if attempt == 1 {
                    let repair = Finding(.offDesktop, window, onActiveSpace: onActiveSpace, server: server, change: change)
                    report(repair)
                    repairs.append(repair)
                }
                restore(window, onActiveSpaceBefore: onActiveSpace, change: change)
            } else {
                if failed.contains(key) {
                    report(Finding(.back, window, onActiveSpace: onActiveSpace, server: server, change: change,
                                   attempts: attempts[key] ?? 0))
                }
                endEpisode(key)
                guard let server else { continue }
                let offset = Self.displacement(window.frame, server.bounds)
                if offset == nil { reportedDisplaced.remove(key) }
                readings.append(Reading(window: window, key: key, screen: screen, offset: offset))
            }
        }
        if secondLook == nil, readings.contains(where: { $0.offset != nil }) {
            secondLook = scheduler.after(displacementRecheckDelay) { [weak self] in
                self?.secondLook = nil
                self?.lookAgain(at: readings, change: change)
            }
        }
        return repairs
    }

    private func report(_ finding: Finding) {
        HUDLog.presence.notice("\(finding.message, privacy: .public)")
        onFinding?(finding)
    }

    /// The frame of the screen showing most of the window, if it is meant to be seen: an
    /// all-Spaces window, ordered in, drawn, with its frame on a screen.
    private static func screenShowing(_ window: HUDPanelWindow, among screens: [CGRect]) -> CGRect? {
        guard window.behavior.joinsAllSpaces, window.isVisible, window.alphaValue > 0 else { return nil }
        return HUDParking.screenFrame(for: window.frame, among: screens)
    }

    private static func isOffDesktop(onActiveSpace: Bool, server: ServerWindow?) -> Bool {
        !onActiveSpace || server?.isOnScreen == false
    }

    // MARK: Off the desktop

    private func restore(_ window: HUDPanelWindow, onActiveSpaceBefore: Bool, change: HUDEnvironmentMonitor.Change) {
        window.rejoinAllSpaces()
        if window.behavior == .widget { window.orderFrontRegardless() }
        scheduleFollowUp(window, onActiveSpaceBefore: onActiveSpaceBefore, change: change, moved: false)
    }

    private func scheduleFollowUp(_ window: HUDPanelWindow, onActiveSpaceBefore: Bool,
                                  change: HUDEnvironmentMonitor.Change, moved: Bool) {
        let key = ObjectIdentifier(window)
        followUps[key]?.cancel()
        followUps[key] = scheduler.after(HUDPanelWindow.spaceCheckDelay) { [weak self, weak window] in
            self?.followUps[key] = nil
            guard let self, let window else { return }
            self.followUp(window, onActiveSpaceBefore: onActiveSpaceBefore, change: change, moved: moved)
        }
    }

    /// After a repair. A hover window the window server still has off screen is moved to the
    /// active Space; AppKit alone saying it is elsewhere never moves it (ordering out and in is
    /// seen when the window is in fact on screen, and resigns key). A window still off the
    /// desktop after that has failed this attempt: the first failure of an episode is said; the
    /// window is tried again after `retryInterval` if the window server has it off screen, else
    /// not until a check finds it on the desktop. A window back after earlier failures is said
    /// to be back. A hover window's settled `onActiveSpace` is announced
    /// (`activeSpaceDidSettleNotification`, which the router publishes) when it changed or the
    /// window was moved.
    private func followUp(_ window: HUDPanelWindow, onActiveSpaceBefore: Bool,
                          change: HUDEnvironmentMonitor.Change, moved: Bool) {
        guard window.behavior.joinsAllSpaces, window.isVisible, isTracking(window) else { return }
        let key = ObjectIdentifier(window)
        let onActiveSpace = probe.isOnActiveSpace(window)
        let server = probe.serverWindow(window)
        let stillOff = Self.isOffDesktop(onActiveSpace: onActiveSpace, server: server)
        if stillOff, !moved, window.behavior == .hover, server?.isOnScreen == false {
            if attempts[key] == 1 {
                HUDLog.presence.notice("moving \(window.logName, privacy: .public) to the active Space: the window server still has it off screen")
            }
            window.moveToActiveSpace()
            // AppKit reports where the move put the window only after a moment.
            scheduleFollowUp(window, onActiveSpaceBefore: onActiveSpaceBefore, change: change, moved: true)
            return
        }
        if stillOff {
            let retries = server?.isOnScreen == false
            if retries {
                retryGates[key] = scheduler.after(retryInterval) { [weak self] in
                    _ = self?.retryGates.removeValue(forKey: key)
                }
            } else {
                givenUp.insert(key)
            }
            if failed.insert(key).inserted {
                report(Finding(.stillOffDesktop, window, onActiveSpace: onActiveSpace, server: server, change: change,
                               retryInterval: retries ? retryInterval : nil))
            }
        } else {
            if failed.contains(key) {
                report(Finding(.back, window, onActiveSpace: onActiveSpace, server: server, change: change,
                               attempts: attempts[key] ?? 0))
            }
            endEpisode(key)
        }
        if window.behavior == .hover, moved || onActiveSpace != onActiveSpaceBefore {
            NotificationCenter.default.post(name: HUDPanelWindow.activeSpaceDidSettleNotification, object: window)
        }
    }

    /// Whether some app's window covers the screen the way a full-screen Space does: on
    /// screen, layer 0, drawn, bounds equal to the screen's frame.
    static func showsFullScreen(_ screen: CGRect, windows: [HUDWindowSnapshot]) -> Bool {
        windows.contains { $0.layer == 0 && $0.alpha > 0 && HUDFullscreenObserver.matches($0.bounds, screen) }
    }

    // MARK: Displaced

    /// Reads the windows of a pass again and reports each one still displaced by the same
    /// amount (a different amount means it is moving: a transition still in flight, or its app
    /// animating the frame), unless the whole screen is shifted together. Reported once per
    /// episode; nothing is done to the window.
    private func lookAgain(at first: [Reading], change: HUDEnvironmentMonitor.Change) {
        let screens = probe.screens().map(\.frame)
        var again: [(first: Reading, window: HUDPanelWindow, offset: Displacement?, server: ServerWindow)] = []
        for reading in first {
            guard let window = reading.window, isTracking(window), followUps[reading.key] == nil,
                  Self.screenShowing(window, among: screens) != nil,
                  probe.isOnActiveSpace(window), let server = probe.serverWindow(window), server.isOnScreen
            else { continue }
            let offset = Self.displacement(window.frame, server.bounds)
            if offset == nil { reportedDisplaced.remove(reading.key) }
            again.append((reading, window, offset, server))
        }
        var screensSeen: [CGRect] = []
        for entry in again where !screensSeen.contains(entry.first.screen) { screensSeen.append(entry.first.screen) }
        for screen in screensSeen {
            let group = again.filter { $0.first.screen == screen }
            if Self.isHeldTransition(group.map { ($0.first.offset, $0.offset) }) { continue }
            for entry in group {
                guard let before = entry.first.offset, let now = entry.offset, now.isClose(to: before),
                      !reportedDisplaced.contains(entry.first.key) else { continue }
                reportedDisplaced.insert(entry.first.key)
                report(Finding(.displaced, entry.window, onActiveSpace: true, server: entry.server, change: change))
            }
        }
    }

    /// Whether every window read on a screen was shifted by one common amount at both
    /// readings: the desktop is mid-transition (a swipe held in place), which carries every
    /// all-Spaces window with it. Needs two windows or more; one gives nothing to compare.
    static func isHeldTransition(_ offsets: [(first: Displacement?, second: Displacement?)]) -> Bool {
        guard offsets.count >= 2, let common = offsets.first?.first else { return false }
        return offsets.allSatisfy { reading in
            guard let first = reading.first, let second = reading.second else { return false }
            return first.isClose(to: common) && second.isClose(to: common)
        }
    }

    /// How far the window server's bounds are from the AppKit frame, edge by edge.
    struct Displacement: Equatable {
        /// How far apart two readings may be and still count as the same (float round-tripping
        /// through the coordinate flip).
        static let tolerance: CGFloat = 1

        var dx, dy, dw, dh: CGFloat

        func isClose(to other: Displacement) -> Bool {
            let t = Self.tolerance
            return abs(dx - other.dx) <= t && abs(dy - other.dy) <= t && abs(dw - other.dw) <= t && abs(dh - other.dh) <= t
        }
    }

    /// The displacement of `serverBounds` from `frame`; nil within `Displacement.tolerance`.
    static func displacement(_ frame: CGRect, _ serverBounds: CGRect) -> Displacement? {
        let offset = Displacement(dx: serverBounds.minX - frame.minX, dy: serverBounds.minY - frame.minY,
                                  dw: serverBounds.width - frame.width, dh: serverBounds.height - frame.height)
        return offset.isClose(to: Displacement(dx: 0, dy: 0, dw: 0, dh: 0)) ? nil : offset
    }
}

extension HUDPanelWindow.Behavior {
    /// Hover and widget windows are on every Space; windowed ones on the Space they were put on.
    var joinsAllSpaces: Bool { self != .windowed }
}
