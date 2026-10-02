import XCTest
import AppKit
@testable import HUDKit

/// The window server's view of Spaces, through SkyLight's private calls, for tests only:
/// HUDKit itself uses public AppKit. Nil where the symbols are missing.
@MainActor
private enum WindowServerSpaces {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CurrentFn = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias TagsFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt32>, Int32) -> Int32
    private typealias MoveFn = @convention(c) (Int32, CFArray, UInt64) -> Void

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

    static var isAvailable: Bool {
        connection != nil && current != nil && spacesFor != nil && clearTags != nil && move != nil
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
}

@MainActor
final class HUDPanelWindowSpacesTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func hoverPanel(keyable: Bool = false) -> HUDPanelWindow {
        let w = HUDPanelWindow(contentRect: CGRect(x: 4, y: 4, width: 10, height: 10), keyable: keyable)
        w.alphaValue = 0.02
        windows.append(w)
        return w
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

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
        settle()
        let all = WindowServerSpaces.spaces(of: reference)
        let active = try XCTUnwrap(WindowServerSpaces.currentSpace(for: reference))
        guard let other = all.subtracting([active]).sorted().first else { throw XCTSkip("needs a second desktop on the main display") }
        reference.orderOut(nil)

        for show in ["orderFrontRegardless", "activateOnShow(hover)", "HUDAnimation.slide"] {
            let w = hoverPanel(keyable: true)
            w.orderFrontRegardless()
            w.orderOut(nil)
            WindowServerSpaces.strand(w, on: other)
            settle()
            XCTAssertEqual(WindowServerSpaces.spaces(of: w), [other], "\(show): stranded (precondition)")
            switch show {
            case "orderFrontRegardless": w.orderFrontRegardless()
            case "activateOnShow(hover)": w.activateOnShow(HUDPanelTransition(reason: .hover))
            default: HUDAnimation.slide(in: w, from: .left, to: w.frame, duration: 0.01)
            }
            settle()
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
        w.orderFrontRegardless()
        settle()
        let all = WindowServerSpaces.spaces(of: w)
        let active = try XCTUnwrap(WindowServerSpaces.currentSpace(for: w))
        guard let other = all.subtracting([active]).sorted().first else { throw XCTSkip("needs a second desktop on the main display") }
        WindowServerSpaces.strand(w, on: other)
        w.orderOut(nil)
        w.orderFrontRegardless()  // AppKit now knows it is elsewhere
        settle()
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), all, "a hide and show repairs it")
        WindowServerSpaces.strand(w, on: other)
        settle()
        XCTAssertFalse(w.activateOnShow(HUDPanelTransition(reason: .hover)))
        settle()
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), all)
        XCTAssertTrue(w.isOnActiveSpace)
    }
}

extension HUDPanelWindowSpacesTests {
    /// Every Space of the main display, and one that is not current, from a reference hover
    /// panel; skips without the SkyLight calls or a second desktop.
    private func spacesForStranding() throws -> (all: Set<UInt64>, other: UInt64) {
        try XCTSkipUnless(WindowServerSpaces.isAvailable, "SkyLight calls unavailable")
        let reference = hoverPanel()
        reference.orderFrontRegardless()
        settle()
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
        settle()
        XCTAssertEqual(WindowServerSpaces.spaces(of: w), [other], "stranded (precondition)")
        w.reassertsSpacesOnShow = false
        w.panelID = "main"
        let host = SpacesHost(window: w)
        var published: Bool?
        let settled = expectation(forNotification: HUDPanelWindow.activeSpaceDidSettleNotification, object: w) { _ in
            published = HUDPanelHostDefaults.stateJSON(HUDPanelState(id: "main", visible: true), of: host)["onActiveSpace"] as? Bool
            return true
        }
        w.makeKeyAndOrderFront(nil)
        let wasKey = w.isKeyWindow
        XCTAssertFalse(w.isOnActiveSpace, "precondition: shown on the other desktop")
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(published, true, "the settled value the router publishes")
        settle()
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
        settle()
        XCTAssertEqual(WindowServerSpaces.spaces(of: label), [other], "stranded (precondition)")
        label.show(at: CGRect(x: 4, y: 4, width: 10, height: 10))
        settle()
        XCTAssertEqual(WindowServerSpaces.spaces(of: label), all)
        XCTAssertTrue(label.isOnActiveSpace)
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
        settle()
        XCTAssertTrue(w.screen == NSScreen.screens[1])
        XCTAssertTrue(w.isOnActiveSpace)
        XCTAssertFalse(w.ensureOnActiveSpace())
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
}
