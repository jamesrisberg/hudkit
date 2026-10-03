import AppKit
import CoreGraphics

/// One screen's geometry at a point in time. A plain value (not `NSScreen`) so
/// `HUDFullscreenObserver` is testable with synthetic data instead of a real display.
public struct HUDScreenSnapshot: Equatable, Sendable {
    /// A key stable across refreshes (`HUDScreenSnapshot.id(for:)` for a real screen); screen
    /// array position is not stable when a display is added or removed.
    public var id: String
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(id: String, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// The display id, which survives a full-screen/menu-bar change (unlike `NSScreen`'s
    /// identity or its position in `NSScreen.screens`).
    @MainActor
    public static func id(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return String(UInt(bitPattern: ObjectIdentifier(screen).hashValue))
        }
        return number.stringValue
    }

    @MainActor
    public init(_ screen: NSScreen) {
        self.init(id: Self.id(for: screen), frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}

/// One on-screen window, enough to tell whether it is covering a screen full screen. A plain
/// value (not the raw `CGWindowListCopyWindowInfo` dictionary) so `HUDFullscreenObserver` is
/// testable with synthetic data instead of real windows.
public struct HUDWindowSnapshot: Equatable, Sendable {
    /// The window server's number for the window (`kCGWindowNumber`); 0 when not known.
    public var windowID: CGWindowID
    public var ownerPID: Int32
    /// The window's level (`kCGWindowLayer`); ordinary app windows, including full-screen ones,
    /// are layer 0.
    public var layer: Int
    /// Bounds in AppKit screen coordinates (origin bottom-left), matching `HUDScreenSnapshot`'s.
    public var bounds: CGRect
    /// The window's alpha (`kCGWindowAlpha`); a window at 0 draws nothing.
    public var alpha: CGFloat

    public init(windowID: CGWindowID = 0, ownerPID: Int32, layer: Int, bounds: CGRect, alpha: CGFloat = 1) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }

    /// A `CGWindowListCopyWindowInfo` entry's `kCGWindowBounds` in AppKit screen coordinates.
    /// The window server's are top-left-origin global display coordinates; AppKit's are
    /// bottom-left-origin, anchored to the primary screen, so they are flipped through
    /// `primaryScreenHeight` to land where `HUDScreenSnapshot`'s frames are.
    static func appKitBounds(of info: [String: AnyObject], primaryScreenHeight: CGFloat) -> CGRect? {
        guard let boundsInfo = info[kCGWindowBounds as String] as? [String: CGFloat],
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return nil }
        return CGRect(x: bounds.minX, y: primaryScreenHeight - bounds.minY - bounds.height,
                      width: bounds.width, height: bounds.height)
    }

    /// The height `appKitBounds(of:primaryScreenHeight:)` flips through: the primary screen's
    /// (the one with the menu bar, first in `NSScreen.screens`).
    @MainActor
    static var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

/// Publishes whether the frontmost app is full screen on each screen, so a host can hide or
/// fall back a notch-anchored panel while a full-screen app owns that part of the screen.
///
/// AppKit has no direct "is the frontmost window full screen" query. `visibleFrame` reaching a
/// screen's full `frame` is not enough evidence on its own: an auto-hidden menu bar and Dock
/// make `visibleFrame` fill the screen with no full-screen app running at all, and a window
/// merely maximized within the menu bar/Dock is `visibleFrame`-sized, not `frame`-sized. Full
/// screen instead requires positive evidence: a layer-0 window owned by the frontmost app,
/// drawn (alpha above 0), whose bounds equal a screen's full frame (`HUDWindowSnapshot`, read
/// from `CGWindowListCopyWindowInfo` — bounds, layer, alpha and owning pid need no Screen
/// Recording permission; only a window's title does, and this never reads one). The window
/// that satisfied the test is kept per screen (`evidence(screenID:)`). While the frontmost app
/// is not known no evidence can be established either way, so each screen keeps its result.
///
/// Between `start()` and `stop()` it re-evaluates at once on `NSWorkspace` app-activation and
/// active-Space-change notifications, again once a Space change, wake or screen change has
/// settled (`HUDEnvironmentMonitor`: AppKit and the window list lag the notifications), and,
/// while any screen is reported full screen, every `recheckInterval`, so a stale "full screen"
/// cannot outlive its window by more than that whichever notification was missed. Each change
/// of a screen's result is logged (`HUDLog.fullscreen`) with the window that caused it.
///
/// `screensProvider`, `windowsProvider` and `frontmostApplicationPID` are the injected
/// sources: tests supply synthetic values instead of a real display or window server; the
/// defaults read `NSScreen.screens`, the live window list and `NSWorkspace`.
@MainActor
public final class HUDFullscreenObserver {
    public var screensProvider: @MainActor () -> [HUDScreenSnapshot]
    public var windowsProvider: @MainActor () -> [HUDWindowSnapshot]
    public var frontmostApplicationPID: @MainActor () -> Int32?
    /// Called after `refresh()` computes a state that differs from the previous one.
    public var onChange: (([String: Bool]) -> Void)?

    public private(set) var fullScreenByScreenID: [String: Bool] = [:]
    /// For each screen reported full screen, the window that satisfied the test.
    public private(set) var evidenceByScreenID: [String: HUDWindowSnapshot] = [:]

    public static let defaultRecheckInterval: TimeInterval = 2
    /// While any screen is reported full screen, how often the result is re-checked.
    public var recheckInterval: TimeInterval = HUDFullscreenObserver.defaultRecheckInterval

    /// The app name logged with a pid (tests substitute their own).
    var applicationName: @MainActor (Int32) -> String? = { NSRunningApplication(processIdentifier: $0)?.localizedName }

    private let environment: HUDEnvironmentMonitor
    private let scheduler: HUDScheduler
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var settled: HUDEnvironmentMonitor.Observation?
    private var recheck: HUDScheduledWork?
    private var isRunning = false

    public convenience init(screensProvider: @escaping @MainActor () -> [HUDScreenSnapshot] = { NSScreen.screens.map(HUDScreenSnapshot.init) },
                            windowsProvider: @escaping @MainActor () -> [HUDWindowSnapshot] = { HUDFullscreenObserver.liveWindows() },
                            frontmostApplicationPID: @escaping @MainActor () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.init(screensProvider: screensProvider, windowsProvider: windowsProvider,
                  frontmostApplicationPID: frontmostApplicationPID, environment: .shared, scheduler: .main)
    }

    init(screensProvider: @escaping @MainActor () -> [HUDScreenSnapshot],
         windowsProvider: @escaping @MainActor () -> [HUDWindowSnapshot],
         frontmostApplicationPID: @escaping @MainActor () -> Int32?,
         environment: HUDEnvironmentMonitor, scheduler: HUDScheduler) {
        self.screensProvider = screensProvider
        self.windowsProvider = windowsProvider
        self.frontmostApplicationPID = frontmostApplicationPID
        self.environment = environment
        self.scheduler = scheduler
    }

    /// Whether the frontmost app is full screen on the screen `screenID` names; false for a
    /// screen not seen by the last `refresh()`.
    public func isFullScreen(screenID: String) -> Bool { fullScreenByScreenID[screenID] ?? false }

    /// The window that made the screen `screenID` full screen; nil while it is not.
    public func evidence(screenID: String) -> HUDWindowSnapshot? { evidenceByScreenID[screenID] }

    /// Re-evaluates every screen, applies the current state, and keeps it current until `stop()`.
    public func start() {
        stop()
        isRunning = true
        refresh(trigger: .start)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(trigger: .activation) }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(trigger: .activeSpace) }
        }
        settled = environment.observeSettled { [weak self] change in self?.refresh(trigger: .settled(change)) }
    }

    public func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        activationObserver = nil
        spaceObserver = nil
        settled?.cancel()
        settled = nil
        recheck?.cancel()
        recheck = nil
        isRunning = false
    }

    /// Re-reads the injected sources and calls `onChange` if the result changed. A screen is
    /// full screen when a drawn layer-0 window owned by the frontmost app has bounds matching
    /// its full frame; with no frontmost app known, each screen keeps its previous result.
    public func refresh() { refresh(trigger: .refresh) }

    /// What made the observer re-evaluate, for the log.
    enum Trigger: Equatable, CustomStringConvertible {
        case start, refresh, activation, activeSpace, recheck
        case settled(HUDEnvironmentMonitor.Change)

        var description: String {
            switch self {
            case .start: return "start"
            case .refresh: return "refresh"
            case .activation: return "app activation"
            case .activeSpace: return "Space change"
            case .recheck: return "re-check"
            case .settled(let change): return "settled after \(change)"
            }
        }
    }

    func refresh(trigger: Trigger) {
        let pid = frontmostApplicationPID()
        var next: [String: Bool] = [:]
        var evidence: [String: HUDWindowSnapshot] = [:]
        if let pid {
            let windows = windowsProvider()
            for screen in screensProvider() {
                let match = windows.first { window in
                    window.ownerPID == pid && window.layer == 0 && window.alpha > 0
                        && Self.matches(window.bounds, screen.frame)
                }
                next[screen.id] = match != nil
                evidence[screen.id] = match
            }
        } else {
            for screen in screensProvider() {
                next[screen.id] = fullScreenByScreenID[screen.id] ?? false
                evidence[screen.id] = evidenceByScreenID[screen.id]
            }
        }
        let previous = fullScreenByScreenID
        fullScreenByScreenID = next
        evidenceByScreenID = evidence
        if next != previous {
            for message in changeMessages(from: previous, to: next, trigger: trigger, frontmost: pid) {
                HUDLog.fullscreen.notice("\(message, privacy: .public)")
            }
            onChange?(next)
        }
        updateRecheck()
    }

    /// Keeps a re-check scheduled while running and any screen is reported full screen.
    private func updateRecheck() {
        guard isRunning, fullScreenByScreenID.values.contains(true) else {
            recheck?.cancel()
            recheck = nil
            return
        }
        guard recheck == nil else { return }
        recheck = scheduler.after(recheckInterval) { [weak self] in
            guard let self else { return }
            self.recheck = nil
            self.refresh(trigger: .recheck)
        }
    }

    /// One log line per screen whose result changed (a screen that is not reported counts as
    /// not full screen), with the evidence when it turned full screen.
    func changeMessages(from previous: [String: Bool], to next: [String: Bool], trigger: Trigger,
                        frontmost pid: Int32?) -> [String] {
        let ids = Set(previous.keys).union(next.keys).sorted()
        let frontmost = pid.map { "\($0) \(applicationName($0) ?? "unknown")" } ?? "unknown"
        return ids.compactMap { id in
            let was = previous[id] ?? false
            let now = next[id] ?? false
            guard was != now else { return nil }
            let context = "(\(trigger); frontmost \(frontmost))"
            guard now, let window = evidenceByScreenID[id] else {
                return "screen \(id): not full screen \(context)" + (next[id] == nil ? ", screen gone" : "")
            }
            return "screen \(id): full screen \(context): window \(window.windowID) owner \(window.ownerPID) "
                + "\(applicationName(window.ownerPID) ?? "unknown") bounds \(HUDLog.format(window.bounds)) "
                + "layer \(window.layer) alpha \(String(format: "%.2f", window.alpha))"
        }
    }

    /// Sub-point tolerance for comparing a window's bounds to a screen's frame, so float
    /// round-tripping through `CGWindowListCopyWindowInfo`'s coordinate conversion doesn't miss
    /// a real match.
    private static let matchTolerance: CGFloat = 1
    static func matches(_ windowBounds: CGRect, _ screenFrame: CGRect) -> Bool {
        abs(windowBounds.minX - screenFrame.minX) <= matchTolerance &&
        abs(windowBounds.minY - screenFrame.minY) <= matchTolerance &&
        abs(windowBounds.width - screenFrame.width) <= matchTolerance &&
        abs(windowBounds.height - screenFrame.height) <= matchTolerance
    }

    /// Every on-screen window `CGWindowListCopyWindowInfo` reports (`refresh` filters to layer
    /// 0), front to back, in AppKit's bottom-left screen coordinates
    /// (`HUDWindowSnapshot.appKitBounds`). Reading `kCGWindowNumber`, `kCGWindowBounds`,
    /// `kCGWindowLayer`, `kCGWindowAlpha` and `kCGWindowOwnerPID` needs no Screen Recording
    /// permission (only `kCGWindowName`, never read here, does).
    @MainActor
    public static func liveWindows() -> [HUDWindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: AnyObject]] else { return [] }
        let primaryHeight = HUDWindowSnapshot.primaryScreenHeight
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = HUDWindowSnapshot.appKitBounds(of: info, primaryScreenHeight: primaryHeight) else { return nil }
            let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1
            return HUDWindowSnapshot(windowID: number, ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
    }
}
