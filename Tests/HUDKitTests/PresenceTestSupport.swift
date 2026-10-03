import AppKit
@testable import HUDKit

/// A HUD panel that records what is done to it: every Spaces behaviour set, order-in, frame
/// set and move to the active Space, and every move or resize its delegate is told about.
final class RecordingPanel: HUDPanelWindow {
    var behaviourSets: [NSWindow.CollectionBehavior] = []
    var orderIns = 0
    var frameSets: [CGRect] = []
    var moves = 0
    /// Receives the delegate callbacks an app's window delegate would (`windowDidMove`,
    /// `windowDidResize`), which Scratch and Stash treat as the user moving the panel.
    let recorder = DelegateRecorder()

    override var collectionBehavior: NSWindow.CollectionBehavior {
        didSet { behaviourSets.append(collectionBehavior) }
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { orderIns += 1 }
        super.order(place, relativeTo: otherWin)
    }

    override func orderFrontRegardless() {
        orderIns += 1
        super.orderFrontRegardless()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frameSets.append(frameRect)
        super.setFrame(frameRect, display: flag)
    }

    override func moveToActiveSpace() {
        moves += 1
        super.moveToActiveSpace()
    }

    /// Whether anything at all was done to the window since `resetRecords()`.
    var untouched: Bool {
        behaviourSets.isEmpty && orderIns == 0 && frameSets.isEmpty && moves == 0 && recorder.callbacks.isEmpty
    }

    /// Forgets what was recorded so far (making and showing the window records too), and
    /// starts recording delegate callbacks.
    func resetRecords() {
        delegate = recorder
        behaviourSets = []
        orderIns = 0
        frameSets = []
        moves = 0
        recorder.callbacks = []
    }
}

/// A window delegate that records the move and resize callbacks it gets.
final class DelegateRecorder: NSObject, NSWindowDelegate {
    var callbacks: [String] = []
    func windowDidMove(_ notification: Notification) { callbacks.append("windowDidMove") }
    func windowDidResize(_ notification: Notification) { callbacks.append("windowDidResize") }
}

/// The presence keeper's view of windows, set per window by tests. A window nobody set is
/// healthy: on the active Space, on screen, where its frame says.
@MainActor
final class FakePresenceProbe {
    var onActiveSpace: [ObjectIdentifier: Bool] = [:]
    /// `.some(nil)`: the window server does not list the window.
    var server: [ObjectIdentifier: HUDPresenceKeeper.ServerWindow?] = [:]
    var screens = [HUDScreenSnapshot(id: "main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))]
    var windows: [HUDWindowSnapshot] = []

    var probe: HUDPresenceKeeper.Probe {
        HUDPresenceKeeper.Probe(
            isOnActiveSpace: { [unowned self] in self.onActiveSpace[ObjectIdentifier($0)] ?? true },
            serverWindow: { [unowned self] window in
                if let entry = self.server[ObjectIdentifier(window)] { return entry }
                return HUDPresenceKeeper.ServerWindow(isOnScreen: true, bounds: window.frame)
            },
            screens: { [unowned self] in self.screens },
            windows: { [unowned self] in self.windows })
    }

    /// AppKit and the window server both lose the window (it is on another Space).
    func strand(_ window: NSWindow) {
        onActiveSpace[ObjectIdentifier(window)] = false
        server[ObjectIdentifier(window)] = HUDPresenceKeeper.ServerWindow(isOnScreen: false, bounds: window.frame)
    }

    /// The window server holds the window `dx` points from its frame, on screen.
    func displace(_ window: NSWindow, dx: CGFloat) {
        server[ObjectIdentifier(window)] = HUDPresenceKeeper.ServerWindow(isOnScreen: true,
                                                                          bounds: window.frame.offsetBy(dx: dx, dy: 0))
    }

    func heal(_ window: NSWindow) {
        onActiveSpace[ObjectIdentifier(window)] = nil
        server[ObjectIdentifier(window)] = nil
    }
}
