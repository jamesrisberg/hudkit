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
    public var ownerPID: Int32
    /// The window's level (`kCGWindowLayer`); ordinary app windows, including full-screen ones,
    /// are layer 0.
    public var layer: Int
    /// Bounds in AppKit screen coordinates (origin bottom-left), matching `HUDScreenSnapshot`'s.
    public var bounds: CGRect

    public init(ownerPID: Int32, layer: Int, bounds: CGRect) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
    }
}

/// Publishes whether the frontmost app is full screen on each screen, so a host can hide or
/// fall back a notch-anchored panel while a full-screen app owns that part of the screen.
///
/// AppKit has no direct "is the frontmost window full screen" query. `visibleFrame` reaching a
/// screen's full `frame` is not enough evidence on its own: an auto-hidden menu bar and Dock
/// make `visibleFrame` fill the screen with no full-screen app running at all, and a window
/// merely maximized within the menu bar/Dock is `visibleFrame`-sized, not `frame`-sized. Full
/// screen instead requires positive evidence: a layer-0 window owned by the frontmost app whose
/// bounds equal a screen's full frame (`HUDWindowSnapshot`, read from
/// `CGWindowListCopyWindowInfo` — bounds, layer and owning pid need no Screen Recording
/// permission; only a window's title does, and this never reads one).
///
/// Re-evaluates on `NSWorkspace` app-activation and active-Space-change notifications rather
/// than polling — both fire when a full-screen app is entered, left, or brought to another
/// screen's Space. `screensProvider`, `windowsProvider` and `frontmostApplicationPID` are the
/// injected sources: tests supply synthetic values instead of a real display or window server;
/// the defaults read `NSScreen.screens`, the live window list and `NSWorkspace`.
@MainActor
public final class HUDFullscreenObserver {
    public var screensProvider: @MainActor () -> [HUDScreenSnapshot]
    public var windowsProvider: @MainActor () -> [HUDWindowSnapshot]
    public var frontmostApplicationPID: @MainActor () -> Int32?
    /// Called after `refresh()` computes a state that differs from the previous one.
    public var onChange: (([String: Bool]) -> Void)?

    public private(set) var fullScreenByScreenID: [String: Bool] = [:]

    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    public init(screensProvider: @escaping @MainActor () -> [HUDScreenSnapshot] = { NSScreen.screens.map(HUDScreenSnapshot.init) },
                windowsProvider: @escaping @MainActor () -> [HUDWindowSnapshot] = { HUDFullscreenObserver.liveWindows() },
                frontmostApplicationPID: @escaping @MainActor () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.screensProvider = screensProvider
        self.windowsProvider = windowsProvider
        self.frontmostApplicationPID = frontmostApplicationPID
    }

    /// Whether the frontmost app is full screen on the screen `screenID` names; false for a
    /// screen not seen by the last `refresh()`.
    public func isFullScreen(screenID: String) -> Bool { fullScreenByScreenID[screenID] ?? false }

    /// Re-evaluates every screen and applies the current state.
    public func start() {
        refresh()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        activationObserver = nil
        spaceObserver = nil
    }

    /// Re-reads the injected sources and calls `onChange` if the result changed. A screen is
    /// full screen when a layer-0 window — owned by the frontmost app, when one is known —
    /// has bounds matching its full frame.
    public func refresh() {
        let windows = windowsProvider()
        let pid = frontmostApplicationPID()
        var next: [String: Bool] = [:]
        for screen in screensProvider() {
            next[screen.id] = windows.contains { window in
                window.layer == 0 && (pid == nil || window.ownerPID == pid)
                    && Self.matches(window.bounds, screen.frame)
            }
        }
        guard next != fullScreenByScreenID else { return }
        fullScreenByScreenID = next
        onChange?(next)
    }

    /// Sub-point tolerance for comparing a window's bounds to a screen's frame, so float
    /// round-tripping through `CGWindowListCopyWindowInfo`'s coordinate conversion doesn't miss
    /// a real match.
    private static let matchTolerance: CGFloat = 1
    private static func matches(_ windowBounds: CGRect, _ screenFrame: CGRect) -> Bool {
        abs(windowBounds.minX - screenFrame.minX) <= matchTolerance &&
        abs(windowBounds.minY - screenFrame.minY) <= matchTolerance &&
        abs(windowBounds.width - screenFrame.width) <= matchTolerance &&
        abs(windowBounds.height - screenFrame.height) <= matchTolerance
    }

    /// Every on-screen window `CGWindowListCopyWindowInfo` reports (`refresh` filters to layer
    /// 0), converted to AppKit's bottom-left screen coordinates. Reading `kCGWindowBounds`,
    /// `kCGWindowLayer` and `kCGWindowOwnerPID` needs no Screen Recording permission (only
    /// `kCGWindowName`, never read here, does).
    @MainActor
    public static func liveWindows() -> [HUDWindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: AnyObject]] else { return [] }
        // CGWindowList bounds are top-left-origin, global display coordinates; AppKit screen
        // frames are bottom-left-origin, anchored to the primary screen. Flip through the
        // primary screen's height to land in the same coordinate space as HUDScreenSnapshot.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsInfo = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return nil }
            let flipped = CGRect(x: bounds.minX, y: primaryHeight - bounds.minY - bounds.height,
                                 width: bounds.width, height: bounds.height)
            return HUDWindowSnapshot(ownerPID: pid, layer: layer, bounds: flipped)
        }
    }
}
