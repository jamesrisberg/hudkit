import XCTest
import AppKit
@testable import HUDKit

/// Turns the main run loop until `condition` holds, for what only the window server's own turn
/// can bring about (it learns of an order-in, a tag or a move asynchronously, and AppKit learns
/// of the result after it). It waits on the condition, not for a time: `limit` is only how long
/// a window server that never gets there is waited for, so it is generous. Returns whether the
/// condition held.
@MainActor
@discardableResult
private func waitUntil(limit: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(limit)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

/// The window server's view of Spaces, and ways to put a window where the presence handling
/// must repair it, through SkyLight's private calls, for tests only: HUDKit itself uses public
/// API. Nil where the symbols are missing.
@MainActor
private enum WindowServerSpaces {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CurrentFn = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias TagsFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt32>, Int32) -> Int32
    private typealias MoveFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias MoveWindowFn = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let connection = sym("SLSMainConnectionID", ConnectionFn.self)?()
    private static let current = sym("SLSManagedDisplayGetCurrentSpace", CurrentFn.self)
    private static let spacesFor = sym("SLSCopySpacesForWindows", SpacesFn.self)
    private static let clearTags = sym("SLSClearWindowTags", TagsFn.self)
    private static let move = sym("SLSMoveWindowsToManagedSpace", MoveFn.self)
    private static let moveWindow = sym("SLSMoveWindow", MoveWindowFn.self)

    static var isAvailable: Bool {
        connection != nil && current != nil && spacesFor != nil && clearTags != nil && move != nil
    }

    /// Moves `window` in the window server only, `dx` points right of where it is, so the
    /// server's bounds and AppKit's frame disagree. Returns false where the call is missing.
    static func displace(_ window: NSWindow, dx: CGFloat) -> Bool {
        guard let connection, let moveWindow,
              let server = HUDPresenceKeeper.Probe.serverWindow(number: window.windowNumber) else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin = CGPoint(x: server.bounds.minX + dx, y: primaryHeight - server.bounds.maxY)  // top-left origin
        return moveWindow(connection, UInt32(window.windowNumber), &origin) == 0
    }

    /// The desktop the display showing `window` is on now (with two displays, the
    /// system-wide "active" Space can be the other display's).
    static func currentSpace(for window: NSWindow) -> UInt64? {
        guard let connection, let current, let screen = window.screen ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let name = CFUUIDCreateString(nil, uuid) else { return nil }
        let space = current(connection, name)
        return space == 0 ? nil : space
    }

    static func spaces(of window: NSWindow) -> Set<UInt64> {
        guard let connection, let spacesFor,
              let list = spacesFor(connection, 7, [window.windowNumber] as CFArray)?.takeRetainedValue() as? [UInt64]
        else { return [] }
        return Set(list)
    }

    /// Puts `window` in the state the Spaces handling must repair: the window server's sticky
    /// (all-Spaces) tag cleared while AppKit still holds `.canJoinAllSpaces`, and the window on
    /// one other Space. AppKit cannot produce this itself, and its setter skips an unchanged
    /// value, so a plain order-in leaves the window there.
    static func strand(_ window: NSWindow, on space: UInt64) {
        guard let connection, let clearTags, let move else { return }
        var tags: [UInt32] = [1 << 11, 0]  // kCGSStickyTagBit
        _ = clearTags(connection, UInt32(window.windowNumber), &tags, 64)
        move(connection, [window.windowNumber] as CFArray, space)
    }

    /// `strand` for a window that is ordered in and stays in: the window server keeps a visible
    /// window on the current Space unless the cleared tag has landed before the move, so the
    /// run loop turns until the server lists the window on fewer Spaces than it did. This is
    /// the state a window is left in when the server drops its all-Spaces membership and the
    /// user then switches desktops.
    static func strandVisible(_ window: NSWindow, on space: UInt64) {
        guard let connection, let clearTags, let move else { return }
        let before = spaces(of: window)
        var tags: [UInt32] = [1 << 11, 0]  // kCGSStickyTagBit
        _ = clearTags(connection, UInt32(window.windowNumber), &tags, 64)
        waitUntil { spaces(of: window).count < before.count }
        move(connection, [window.windowNumber] as CFArray, space)
    }
}

@MainActor
final class HUDPanelWindowSpacesTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var keepers: [HandDrivenKeeper] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        keepers = []  // after the windows are out: they hold the keeper, which reads its clock
    }

    private func hoverPanel(keyable: Bool = false) -> HUDPanelWindow {
        let w = HUDPanelWindow(contentRect: liveTestFrame(), keyable: keyable)
        w.alphaValue = 0.02
        windows.append(w)
        return w
    }

    /// A hand-driven keeper that lives as long as the test (its windows reach it through their
    /// `presenceKeeper`, and its scheduler reads the clock).
    private func handDrivenKeeper() -> HandDrivenKeeper {
        let keeper = HandDrivenKeeper()
        keepers.append(keeper)
        return keeper
    }

    /// Whether AppKit and the window server both have `window` on the desktop the user is on.
    private func isShownOnTheDesktop(_ window: NSWindow) -> Bool {
        window.isOnActiveSpace && HUDPresenceKeeper.Probe.live.serverWindow(window)?.isOnScreen == true
    }

    /// Waits until every Space check a hover order-in has scheduled (`spaceCheckDelay` later, on
    /// the main queue) has run: the queue runs work in deadline order, so a marker queued with a
    /// later deadline runs after them however long the Mac takes. A window put somewhere the
    /// check would move it from is put there after this, not while the check is still to come.
    private func waitForSpaceChecks() {
        let marker = expectation(description: "the Space checks scheduled so far have run")
        DispatchQueue.main.asyncAfter(deadline: .now() + HUDPanelWindow.spaceCheckDelay + 0.01) { marker.fulfill() }
        wait(for: [marker], timeout: 10)
    }

    /// Orders `window` in and waits for the window server to have it on the user's desktop and
    /// for the show's own Space check to have run, so what a test does next starts from a shown
    /// window with nothing of its own pending.
    private func orderInAndWait(_ window: HUDPanelWindow, file: StaticString = #filePath, line: UInt = #line) {
        window.orderFrontRegardless()
        XCTAssertTrue(waitUntil { isShownOnTheDesktop(window) },
                      "precondition: the window server has the window on the user's desktop", file: file, line: line)
        waitForSpaceChecks()
    }

    // MARK: - AppKit side

    func testHoverShowRestoresTheRecipeBehaviour() {
        let w = hoverPanel()
        w.collectionBehavior = [.managed]
        w.orderFrontRegardless()
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior, "orderFrontRegardless")
        w.orderOut(nil)
        w.collectionBehavior = [.moveToActiveSpace]
        w.orderFront(nil)
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior, "orderFront")
        w.orderOut(nil)
        w.collectionBehavior = []
        w.makeKeyAndOrderFront(nil)
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior, "makeKeyAndOrderFront")
        w.orderOut(nil)
        w.collectionBehavior = [.managed]
        HUDAnimation.fadeIn(w, duration: 0.01)
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior, "HUDAnimation.fadeIn")
    }

    func testDockLabelShowRestoresItsSpacesBehaviour() {
        let label = HUDDockLabelWindow()
        windows.append(label)
        XCTAssertEqual(label.collectionBehavior, HUDDockLabelWindow.spacesBehavior)
        label.collectionBehavior = [.managed]
        label.show(at: CGRect(x: 4, y: 4, width: 10, height: 10))
        XCTAssertEqual(label.collectionBehavior, HUDDockLabelWindow.spacesBehavior, "show (orderFront)")
        label.hide(animated: false)
        label.collectionBehavior = []
        label.orderFrontRegardless()
        XCTAssertEqual(label.collectionBehavior, HUDDockLabelWindow.spacesBehavior, "orderFrontRegardless")
    }

    func testHoverShowKeepsExtraBehaviourBits() {
        let w = hoverPanel()
        w.collectionBehavior = HUDPanelWindow.hoverCollectionBehavior.union(.ignoresCycle)
        w.orderFrontRegardless()
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior.union(.ignoresCycle))
    }

    func testHoverBehaviourKeepingExtras() {
        let hover = HUDPanelWindow.hoverCollectionBehavior
        XCTAssertEqual(HUDPanelWindow.hoverBehavior(keeping: []), hover)
        XCTAssertEqual(HUDPanelWindow.hoverBehavior(keeping: [.managed, .participatesInCycle, .moveToActiveSpace]),
                       hover, "conflicting Spaces bits are replaced")
        XCTAssertEqual(HUDPanelWindow.hoverBehavior(keeping: [.ignoresCycle, .transient]),
                       hover.union(.ignoresCycle), "transient conflicts with stationary")
    }

    func testWindowedShowLeavesSpacesAlone() {
        let w = HUDPanelWindow(contentRect: CGRect(x: 4, y: 4, width: 10, height: 10), behavior: .windowed)
        w.alphaValue = 0.02
        windows.append(w)
        w.orderFrontRegardless()
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.windowedCollectionBehavior)
        XCTAssertFalse(w.collectionBehavior.contains(.canJoinAllSpaces))
    }

    func testHoverShowStillNeverTakesFocus() {
        let w = hoverPanel(keyable: true)
        XCTAssertFalse(w.activateOnShow(HUDPanelTransition(reason: .hover)))
        XCTAssertTrue(w.isVisible)
        XCTAssertFalse(w.isKeyWindow, "reason=hover never makes the panel key")
        XCTAssertEqual(w.isOnActiveSpace, true)
    }

    // MARK: - Window server side

    /// A hover panel whose all-Spaces membership the window server lost, parked on another
    /// desktop: every way of showing it brings it to the desktop the user is on and back onto
    /// every desktop, without taking focus.
    func testStrandedHoverPanelRejoinsEverySpaceOnShow() throws {
        try XCTSkipUnless(WindowServerSpaces.isAvailable, "SkyLight calls unavailable")
        let reference = hoverPanel()
        reference.orderFrontRegardless()
        waitUntil { isShownOnTheDesktop(reference) }
        let all = WindowServerSpaces.spaces(of: reference)
        let active = try XCTUnwrap(WindowServerSpaces.currentSpace(for: reference))
        guard let other = all.subtracting([active]).sorted().first else { throw XCTSkip("needs a second desktop on the main display") }
        reference.orderOut(nil)

        for show in ["orderFrontRegardless", "activateOnShow(hover)", "HUDAnimation.slide"] {
            let w = hoverPanel(keyable: true)
            w.orderFrontRegardless()
            w.orderOut(nil)
            WindowServerSpaces.strand(w, on: other)
            waitUntil { WindowServerSpaces.spaces(of: w) == [other] }
            XCTAssertEqual(WindowServerSpaces.spaces(of: w), [other], "\(show): stranded (precondition)")
            switch show {
            case "orderFrontRegardless": w.orderFrontRegardless()
            case "activateOnShow(hover)": w.activateOnShow(HUDPanelTransition(reason: .hover))
            default: HUDAnimation.slide(in: w, from: .left, to: w.frame, duration: 0.01)
            }
            waitUntil { w.isOnActiveSpace && WindowServerSpaces.spaces(of: w) == all }
            XCTAssertTrue(w.isOnActiveSpace, "\(show): on the user's desktop")
            XCTAssertEqual(WindowServerSpaces.spaces(of: w), all, "\(show): back on every desktop")
            XCTAssertFalse(w.isKeyWindow, "\(show): no focus taken")
            XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior)
        }
    }

    /// A visible hover panel stranded on another desktop (the user switched away and the
    /// window server dropped it there): a hover show brings it over.
    func testVisibleStrandedHoverPanelIsBroughtOverByAHoverShow() throws {
        try XCTSkipUnless(WindowServerSpaces.isAvailable, "SkyLight calls unavailable")
        let w = hoverPanel()
        orderInAndWait(w)
        let all = WindowServerSpaces.spaces(of: w)
        let active = try XCTUnwrap(WindowServerSpaces.currentSpace(for: w))
        guard let other = all.subtracting([active]).sorted().first else { throw XCTSkip("needs a second desktop on the main display") }
        WindowServerSpaces.strandVisible(w, on: other)
        waitUntil { WindowServerSpaces.spaces(of: w) == [other] && !w.isOnActiveSpace }
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), [other], "stranded (precondition)")
        XCTAssertFalse(w.isOnActiveSpace, "precondition: AppKit knows")
        w.orderOut(nil)
        w.orderFrontRegardless()
        waitUntil { w.isOnActiveSpace && WindowServerSpaces.spaces(of: w) == all }
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), all, "a hide and show repairs it")
        waitForSpaceChecks()
        WindowServerSpaces.strandVisible(w, on: other)
        waitUntil { WindowServerSpaces.spaces(of: w) == [other] && !w.isOnActiveSpace }
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), [other], "stranded again (precondition)")
        XCTAssertFalse(w.activateOnShow(HUDPanelTransition(reason: .hover)))
        waitUntil { w.isOnActiveSpace && WindowServerSpaces.spaces(of: w) == all }
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), all)
        XCTAssertTrue(w.isOnActiveSpace)
    }
}

extension HUDPanelWindowSpacesTests {
    func testBackgroundHoverShowRestoresAllDesktopsWhileAlreadyOnTheActiveDesktop() throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(policy) }
        let (all, _) = try spacesForStranding()
        let w = hoverPanel()
        w.presenceKeeper = handDrivenKeeper().keeper
        orderInAndWait(w)
        let active = try XCTUnwrap(WindowServerSpaces.currentSpace(for: w))
        WindowServerSpaces.strandVisible(w, on: active)
        XCTAssertTrue(waitUntil { WindowServerSpaces.spaces(of: w) == [active] },
                      "precondition: membership in the other desktops was lost")
        XCTAssertTrue(w.isOnActiveSpace, "the panel is already on the current desktop")

        w.orderFrontRegardless()

        XCTAssertTrue(waitUntil { WindowServerSpaces.spaces(of: w) == all },
                      "show restores every desktop even when the current one is healthy")
        XCTAssertFalse(w.isKeyWindow)
    }

    /// Animation shows also repair an ordered-in panel left on another desktop. Its
    /// visibility flag stays true there, including while a dock hide is still fading.
    func testAnimatedShowBringsAVisibleStrandedHoverPanelOntoEveryDesktop() throws {
        let (all, other) = try spacesForStranding()
        for animation in ["slide", "fadeIn"] {
            let w = hoverPanel(keyable: true)
            w.presenceKeeper = handDrivenKeeper().keeper
            orderInAndWait(w)
            WindowServerSpaces.strandVisible(w, on: other)
            XCTAssertTrue(waitUntil { WindowServerSpaces.spaces(of: w) == [other] && !w.isOnActiveSpace },
                          "\(animation): precondition: stranded on another desktop")
            XCTAssertTrue(w.isVisible, "\(animation): ordered in on that desktop")

            if animation == "slide" {
                HUDAnimation.slide(in: w, from: .left, to: w.frame, duration: 0.01)
            } else {
                HUDAnimation.fadeIn(w, duration: 0.01)
            }

            XCTAssertTrue(waitUntil { self.isShownOnTheDesktop(w) && WindowServerSpaces.spaces(of: w) == all },
                          "\(animation): the show brings the panel onto every desktop")
            XCTAssertFalse(w.isKeyWindow, "\(animation): no focus taken")
            w.orderOut(nil)
        }
    }

    func testAnimatedShowsLeaveVisibleWindowedAndWidgetWindowsInPlace() {
        for behavior in [HUDPanelWindow.Behavior.windowed, .widget] {
            let w = RecordingPanel(contentRect: liveTestFrame(), behavior: behavior)
            windows.append(w)
            w.showsInDock = false
            w.presenceKeeper = handDrivenKeeper().keeper
            w.alphaValue = 0.02
            w.orderFrontRegardless()
            w.resetRecords()

            HUDAnimation.slide(in: w, from: .left, to: w.frame, duration: 0.01)
            HUDAnimation.fadeIn(w, duration: 0.01)

            XCTAssertEqual(w.orderIns, 0, "\(behavior): an animation does not raise an already visible window")
            XCTAssertTrue(w.behaviourSets.isEmpty, "\(behavior): its Spaces policy stays unchanged")
            XCTAssertFalse(w.isKeyWindow)
            w.orderOut(nil)
        }
    }

    /// Every Space of the main display, and one that is not current, from a reference hover
    /// panel; skips without the SkyLight calls or a second desktop.
    private func spacesForStranding() throws -> (all: Set<UInt64>, other: UInt64) {
        try XCTSkipUnless(WindowServerSpaces.isAvailable, "SkyLight calls unavailable")
        let reference = hoverPanel()
        reference.orderFrontRegardless()
        waitUntil { isShownOnTheDesktop(reference) }
        let all = WindowServerSpaces.spaces(of: reference)
        let active = try XCTUnwrap(WindowServerSpaces.currentSpace(for: reference))
        reference.orderOut(nil)
        guard let other = all.subtracting([active]).sorted().first else { throw XCTSkip("needs a second desktop on the main display") }
        return (all, other)
    }

    /// The fallback on its own (the show's re-assertion switched off): a keyable hover panel
    /// shown key while stranded on another desktop is brought over, back onto every desktop,
    /// still key; the settle notification comes once AppKit reports it on the active Space,
    /// so what the router publishes then is `onActiveSpace: true`.
    func testFallbackBringsAStrandedPanelOver() throws {
        let (all, other) = try spacesForStranding()
        let w = hoverPanel(keyable: true)
        w.orderFrontRegardless()
        w.orderOut(nil)
        WindowServerSpaces.strand(w, on: other)
        waitUntil { WindowServerSpaces.spaces(of: w) == [other] }
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), [other], "stranded (precondition)")
        w.reassertsSpacesOnShow = false
        w.panelID = "main"
        let host = SpacesHost(window: w)
        var published: Bool?
        let settled = expectation(forNotification: HUDPanelWindow.activeSpaceDidSettleNotification, object: w) { _ in
            // Posted on the main thread.
            MainActor.assumeIsolated {
                published = HUDPanelHostDefaults.stateJSON(HUDPanelState(id: "main", visible: true), of: host)["onActiveSpace"] as? Bool
            }
            return true
        }
        w.makeKeyAndOrderFront(nil)
        let wasKey = w.isKeyWindow
        XCTAssertFalse(w.isOnActiveSpace, "precondition: shown on the other desktop")
        wait(for: [settled], timeout: 10)
        XCTAssertEqual(published, true, "the settled value the router publishes")
        waitUntil { w.isOnActiveSpace && WindowServerSpaces.spaces(of: w) == all }
        XCTAssertTrue(w.isOnActiveSpace)
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), all)
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior)
        XCTAssertEqual(w.isKeyWindow, wasKey, "key status survives the move")
        XCTAssertFalse(w.ensureOnActiveSpace(), "nothing to do once it is here")
        w.resignKey()
    }

    /// A dock label whose all-Spaces membership the window server lost rejoins every desktop
    /// when it is next shown.
    func testStrandedDockLabelRejoinsEverySpaceOnShow() throws {
        let (all, other) = try spacesForStranding()
        let label = HUDDockLabelWindow()
        windows.append(label)
        label.show(at: CGRect(x: 4, y: 4, width: 10, height: 10))
        label.hide(animated: false)
        WindowServerSpaces.strand(label, on: other)
        waitUntil { WindowServerSpaces.spaces(of: label) == [other] }
        XCTAssertEqual(WindowServerSpaces.spaces(of: label), [other], "stranded (precondition)")
        label.show(at: CGRect(x: 4, y: 4, width: 10, height: 10))
        waitUntil { label.isOnActiveSpace && WindowServerSpaces.spaces(of: label) == all }
        XCTAssertEqual(WindowServerSpaces.spaces(of: label), all)
        XCTAssertTrue(label.isOnActiveSpace)
    }

    // MARK: - The presence keeper against the real window server

    private func recordingPanel(_ behavior: HUDPanelWindow.Behavior) -> RecordingPanel {
        let w = RecordingPanel(contentRect: liveTestFrame(), behavior: behavior)
        w.alphaValue = 0.02
        windows.append(w)
        return w
    }

    /// The live probe reads a window's on-screen flag and its bounds, in AppKit coordinates,
    /// once the window server has heard of the order-in (AppKit sends it when the run loop turns).
    func testLiveProbeReadsTheWindowServer() throws {
        let w = hoverPanel()
        w.orderFrontRegardless()
        waitUntil { HUDPresenceKeeper.Probe.live.serverWindow(w)?.isOnScreen == true }
        let shown = try XCTUnwrap(HUDPresenceKeeper.Probe.live.serverWindow(w))
        XCTAssertTrue(shown.isOnScreen)
        XCTAssertEqual(shown.bounds, w.frame)
        w.orderOut(nil)
        waitUntil { HUDPresenceKeeper.Probe.live.serverWindow(w)?.isOnScreen != true }
        XCTAssertNotEqual(HUDPresenceKeeper.Probe.live.serverWindow(w)?.isOnScreen, true, "ordered out: not on screen")
    }

    /// Strands an ordered-in window of `behavior` on another desktop, posts what a desktop
    /// switch posts (to the test keeper's own monitor) and steps the keeper's time by hand
    /// through the settle delay and a repair's follow-up, giving the window server its turn in
    /// between (waiting until it has the window back, not for a time): the keeper reading the
    /// real window server, end to end. Returns the window, the Spaces it was on when healthy,
    /// and what the keeper found about it.
    private func strandShownWindowAndSwitchDesktops(_ behavior: HUDPanelWindow.Behavior) throws
        -> (window: RecordingPanel, healthy: Set<UInt64>, findings: [HUDPresenceKeeper.Finding]) {
        let (_, other) = try spacesForStranding()
        let hand = handDrivenKeeper()
        let w = recordingPanel(behavior)
        w.presenceKeeper = hand.keeper
        orderInAndWait(w)
        let healthy = WindowServerSpaces.spaces(of: w)
        WindowServerSpaces.strandVisible(w, on: other)
        waitUntil {
            WindowServerSpaces.spaces(of: w) == [other] && !w.isOnActiveSpace
                && HUDPresenceKeeper.Probe.live.serverWindow(w)?.isOnScreen == false
        }
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), [other], "\(behavior): precondition: on another desktop only")
        XCTAssertTrue(w.isVisible, "\(behavior): precondition: still ordered in")
        XCTAssertFalse(w.isOnActiveSpace, "\(behavior): precondition: AppKit knows")
        w.resetRecords()
        hand.postDesktopSwitch()
        hand.clock.advance(by: HUDEnvironmentMonitor.defaultSettleDelay)  // the settled check: the repair
        waitUntil { isShownOnTheDesktop(w) }
        hand.clock.advance(by: HUDPanelWindow.spaceCheckDelay)  // the repair's follow-up
        return (w, healthy, hand.findings)
    }

    /// A hover panel that stays ordered in while the window server drops its all-Spaces
    /// membership and the user moves to another desktop (the voice orb's case: ordered in once
    /// at launch and never again) is back on the user's desktop and on every desktop after the
    /// next settled signal, without the app showing it again. The re-assertion alone brings it
    /// back: nothing has to move it.
    func testSettledSignalBringsBackAShownStrandedHoverPanel() throws {
        let (w, healthy, findings) = try strandShownWindowAndSwitchDesktops(.hover)
        XCTAssertEqual(findings.map(\.kind), [.offDesktop], "repaired, and the repair worked")
        XCTAssertEqual(findings.first?.server?.isOnScreen, false, "the window server agreed it was not on screen")
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), healthy, "back on every desktop")
        XCTAssertTrue(w.isOnActiveSpace)
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior)
        XCTAssertEqual(w.moves, 0, "the re-assertion alone was enough")
        XCTAssertEqual(w.orderIns, 0)
    }

    /// The same for a widget, which joins every desktop but full-screen ones.
    func testSettledSignalBringsBackAShownStrandedWidget() throws {
        let (w, healthy, findings) = try strandShownWindowAndSwitchDesktops(.widget)
        XCTAssertEqual(findings.map(\.kind), [.offDesktop], "repaired, and the repair worked")
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), healthy, "back on every desktop it was on")
        XCTAssertTrue(w.isOnActiveSpace)
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.widgetCollectionBehavior)
        XCTAssertEqual(w.moves, 0)
    }

    /// What every HUD window reports to by default: the shared keeper hears the workspace's own
    /// desktop-switch notification through the shared monitor and checks its windows. The
    /// keeper reads a fake window server here (the real one is in the tests above), so what is
    /// waited for is only the chain from the notification to the keeper's first finding.
    func testTheSharedKeeperChecksOnTheWorkspacesDesktopSwitch() {
        let fake = FakePresenceProbe()
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        fake.screens = [HUDScreenSnapshot(id: "main", frame: screen, visibleFrame: screen)]
        let shared = HUDPresenceKeeper.shared
        let probe = shared.probe
        shared.probe = fake.probe
        let w = recordingPanel(.hover)
        var findings: [HUDPresenceKeeper.Finding] = []
        shared.onFinding = { if $0.windowNumber == w.windowNumber { findings.append($0) } }
        addTeardownBlock { @MainActor in
            w.orderOut(nil)  // the keeper drops a window's pending follow-up when it is ordered out
            shared.onFinding = nil
            shared.probe = probe
        }
        w.orderFrontRegardless()
        fake.strand(w)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                   object: NSWorkspace.shared)
        waitUntil { !findings.isEmpty }
        XCTAssertEqual(findings.map(\.kind), [.offDesktop])
        XCTAssertEqual(findings.first?.change, .activeSpace)
    }

    /// Healthy windows, as the real window server reports them, are not touched: no Spaces
    /// toggle, no re-order, no frame set, nothing scheduled that later touches them.
    func testPresenceCheckLeavesHealthyWindowsAlone() {
        let hand = handDrivenKeeper()
        let hover = recordingPanel(.hover)
        let widget = recordingPanel(.widget)
        for w in [hover, widget] {
            w.presenceKeeper = hand.keeper
            orderInAndWait(w)
        }
        hover.resetRecords()
        widget.resetRecords()
        XCTAssertEqual(hand.keeper.check(.activeSpace), [])
        XCTAssertEqual(hand.clock.pendingCount, 0, "nothing scheduled to look at again")
        hand.clock.advance(by: HUDPresenceKeeper.defaultDisplacementRecheckDelay + HUDPanelWindow.spaceCheckDelay)
        XCTAssertEqual(hand.findings, [])
        XCTAssertTrue(hover.untouched)
        XCTAssertTrue(widget.untouched)
    }

    /// A window the window server holds away from its AppKit frame (moved there through a
    /// private call, as no public API can) is reported once the second look confirms it, and
    /// left alone: the keeper does not move it (a frame set would reach the app's delegate as
    /// the user moving the window). Skips where the call is missing or does not move it.
    func testPresenceCheckReportsADisplacedWindowAndLeavesItAlone() throws {
        let hand = handDrivenKeeper()
        for behavior in [HUDPanelWindow.Behavior.hover, .widget] {
            let w = recordingPanel(behavior)
            let frame = w.frame
            w.presenceKeeper = hand.keeper
            orderInAndWait(w)
            try XCTSkipUnless(WindowServerSpaces.displace(w, dx: 300), "SLSMoveWindow unavailable")
            let displacedBounds = frame.offsetBy(dx: 300, dy: 0)
            waitUntil { HUDPresenceKeeper.Probe.live.serverWindow(w)?.bounds == displacedBounds }
            let displaced = HUDPresenceKeeper.Probe.live.serverWindow(w)?.bounds
            try XCTSkipUnless(displaced == displacedBounds,
                              "SLSMoveWindow did not move the window here (\(frame) is now \(String(describing: displaced)))")
            XCTAssertEqual(w.frame, frame, "\(behavior): AppKit's frame unchanged (precondition)")
            w.resetRecords()
            XCTAssertEqual(hand.keeper.check(.activeSpace), [], "\(behavior): not on the first reading")
            hand.clock.advance(by: HUDPresenceKeeper.defaultDisplacementRecheckDelay)  // the second look
            XCTAssertEqual(hand.findings.last?.kind, .displaced, "\(behavior)")
            XCTAssertEqual(hand.findings.last?.windowNumber, w.windowNumber)
            XCTAssertEqual(HUDPresenceKeeper.Probe.live.serverWindow(w)?.bounds, displacedBounds,
                           "\(behavior): not moved")
            XCTAssertTrue(w.untouched, "\(behavior): no frame set, no delegate callback, no re-order")
            w.orderOut(nil)
        }
        XCTAssertEqual(hand.findings.count, 2)
    }

    /// A hover panel on a second display's current desktop counts as on the active Space
    /// (`isOnActiveSpace` covers every display's current Space), so the fallback leaves it
    /// alone instead of ordering it out and in.
    func testPanelOnASecondDisplayIsLeftAlone() throws {
        guard NSScreen.screens.count > 1 else { throw XCTSkip("needs a second display") }
        let second = NSScreen.screens[1].frame
        let w = hoverPanel()
        w.setFrame(CGRect(x: second.minX + 4, y: second.minY + 4, width: 10, height: 10), display: false)
        w.orderFrontRegardless()
        waitUntil { w.isOnActiveSpace }
        XCTAssertTrue(w.screen == NSScreen.screens[1])
        XCTAssertTrue(w.isOnActiveSpace)
        XCTAssertFalse(w.ensureOnActiveSpace())
    }
}

/// A presence keeper that reads the real window server and whose time is the test's: its own
/// environment monitor (on a private notification center, so what a desktop switch posts
/// reaches it as it does the shared one) and its own clock, advanced by hand. Windows opt in
/// through `presenceKeeper`.
@MainActor
private final class HandDrivenKeeper {
    let clock = ManualClock()
    let keeper: HUDPresenceKeeper
    private(set) var findings: [HUDPresenceKeeper.Finding] = []
    private let workspace = NotificationCenter()

    init() {
        let monitor = HUDEnvironmentMonitor(scheduler: clock.scheduler, workspaceCenter: workspace, appCenter: nil)
        keeper = HUDPresenceKeeper(environment: monitor, scheduler: clock.scheduler, probe: .live)
        keeper.onFinding = { [unowned self] in findings.append($0) }
    }

    /// What a desktop switch posts, to the keeper's monitor only.
    func postDesktopSwitch() {
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
    }
}

@MainActor
private final class SpacesHost: HUDPanelHost {
    let window: HUDPanelWindow
    init(window: HUDPanelWindow) { self.window = window }
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "main", visible: true)] }
    func showPanel(_ id: String) throws {}
    func hidePanel(_ id: String) throws {}
    func panelWindow(_ id: String) -> NSWindow? { window }
    func quit() {}
}

// MARK: - Reporting onActiveSpace

@MainActor
private final class WindowHost: HUDPanelHost {
    let window: HUDPanelWindow
    var visible = false
    var overrideWindow = true

    init(window: HUDPanelWindow) { self.window = window }

    var panelStates: [HUDPanelState] { [HUDPanelState(id: "main", visible: visible), HUDPanelState(id: "other", visible: false)] }
    func showPanel(_ id: String) throws { visible = true; window.orderFrontRegardless() }
    func hidePanel(_ id: String) throws { visible = false; window.orderOut(nil) }
    func panelWindow(_ id: String) -> NSWindow? {
        overrideWindow ? (id == "main" ? window : nil) : HUDPanelHostDefaults.panelWindow(id, of: self)
    }
    func quit() {}
}

@MainActor
private final class SinglePanelHost: HUDPanelHost {
    let window: HUDPanelWindow
    var visible = false
    init(window: HUDPanelWindow) { self.window = window }
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "only", visible: visible)] }
    func showPanel(_ id: String) throws { visible = true; window.orderFrontRegardless() }
    func hidePanel(_ id: String) throws { visible = false; window.orderOut(nil) }
    func quit() {}
}

@MainActor
final class HUDPanelWindowActiveSpaceReportTests: XCTestCase {
    private let server = HUDSocketServer(path: "/tmp/unused-spaces-\(getpid()).sock")

    private func call(_ router: HUDControlRouter, _ verb: String, _ args: [String: String] = [:]) -> [String: Any] {
        var out: [String: Any]?
        router.handle(verb, args: args) { out = $0 }
        return out ?? ["missing": true]
    }

    private func panel() -> HUDPanelWindow {
        let w = HUDPanelWindow(contentRect: CGRect(x: 4, y: 4, width: 10, height: 10))
        w.alphaValue = 0.02
        addTeardownBlock { @MainActor in w.orderOut(nil) }
        return w
    }

    func testPanelRepliesAndStateCarryOnActiveSpace() {
        let host = WindowHost(window: panel())
        let router = HUDControlRouter(host: host, server: server)
        let shown = call(router, "panel", ["id": "main", "action": "show"])
        XCTAssertEqual(shown["visible"] as? Bool, true)
        XCTAssertEqual(shown["onActiveSpace"] as? Bool, true)
        let state = call(router, "state")["panels"] as? [[String: Any]]
        XCTAssertEqual(state?.first { $0["id"] as? String == "main" }?["onActiveSpace"] as? Bool, true)
        XCTAssertNil(state?.first { $0["id"] as? String == "other" }?["onActiveSpace"], "no window, no claim")
        let hidden = call(router, "panel", ["id": "main", "action": "hide"])
        XCTAssertEqual(hidden["visible"] as? Bool, false)
        XCTAssertNil(hidden["onActiveSpace"], "only reported while the panel is on screen")
    }

    func testDefaultWindowLookupByPanelID() {
        let host = WindowHost(window: panel())
        host.overrideWindow = false
        let router = HUDControlRouter(host: host, server: server)
        XCTAssertNil(call(router, "panel", ["id": "main", "action": "show"])["onActiveSpace"],
                     "two panels and an untagged window: nothing to go on")
        host.window.panelID = "main"
        XCTAssertEqual(call(router, "panel", ["id": "main", "action": "show"])["onActiveSpace"] as? Bool, true)
    }

    func testDefaultWindowLookupForASinglePanelApp() {
        // Other tests' windows must not count as this app's panel.
        NSApp.windows.filter { $0 is HUDPanelWindow && $0.isVisible }.forEach { $0.orderOut(nil) }
        let host = SinglePanelHost(window: panel())
        let router = HUDControlRouter(host: host, server: server)
        XCTAssertEqual(call(router, "panel", ["id": "only", "action": "show"])["onActiveSpace"] as? Bool, true,
                       "a one-panel app's only visible HUDPanelWindow is its panel")
        let extra = panel()
        extra.orderFrontRegardless()
        XCTAssertNil(call(router, "panel", ["id": "only", "action": "show"])["onActiveSpace"], "ambiguous: not reported")
    }

    func testWidgetWindowsAreNeverTakenForAPanel() {
        NSApp.windows.filter { $0 is HUDPanelWindow && $0.isVisible }.forEach { $0.orderOut(nil) }
        let host = SinglePanelHost(window: panel())
        let router = HUDControlRouter(host: host, server: server)
        let widget = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 170, height: 170), behavior: .widget)
        widget.orderFrontRegardless()
        defer { widget.orderOut(nil) }
        XCTAssertEqual(call(router, "panel", ["id": "only", "action": "show"])["onActiveSpace"] as? Bool, true,
                       "a visible widget window does not make the app's one panel ambiguous")
        host.window.orderOut(nil)
        XCTAssertNil(HUDPanelHostDefaults.panelWindow("only", of: host), "nor stands in for it")
    }
}
