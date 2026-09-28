import AppKit

/// One screen's geometry at a point in time, enough to tell whether the frontmost app is full
/// screen on it. A plain value (not `NSScreen`) so `HUDFullscreenObserver` is testable with
/// synthetic data instead of a real display.
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

    /// A full-screen app hides the menu bar and (on a notch screen) the camera-housing inset,
    /// so `visibleFrame` grows to fill `frame`; this is the same signal
    /// `HUDNotchGeometry.topAnchorY` uses to fall back to the bare screen edge.
    public var isFullScreen: Bool { visibleFrame.height >= frame.height && visibleFrame.width >= frame.width }

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

/// Publishes whether the frontmost app is full screen on each screen, so a host can hide or
/// fall back a notch-anchored panel while a full-screen app owns that part of the screen.
///
/// AppKit has no direct "is the frontmost window full screen" query; this infers it from each
/// screen's `visibleFrame` reaching its full `frame` (see `HUDScreenSnapshot.isFullScreen`) and
/// re-evaluates on `NSWorkspace` app-activation and active-Space-change notifications rather
/// than polling — both fire when a full-screen app is entered, left, or brought to another
/// screen's Space. `screensProvider` is the injected source: tests supply synthetic snapshots
/// instead of a real display; the default reads `NSScreen.screens`.
@MainActor
public final class HUDFullscreenObserver {
    public var screensProvider: @MainActor () -> [HUDScreenSnapshot]
    /// Called after `refresh()` computes a state that differs from the previous one.
    public var onChange: (([String: Bool]) -> Void)?

    public private(set) var fullScreenByScreenID: [String: Bool] = [:]

    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    public init(screensProvider: @escaping @MainActor () -> [HUDScreenSnapshot] = { NSScreen.screens.map(HUDScreenSnapshot.init) }) {
        self.screensProvider = screensProvider
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

    /// Re-reads `screensProvider` and calls `onChange` if the result changed.
    public func refresh() {
        var next: [String: Bool] = [:]
        for screen in screensProvider() { next[screen.id] = screen.isFullScreen }
        guard next != fullScreenByScreenID else { return }
        fullScreenByScreenID = next
        onChange?(next)
    }
}
