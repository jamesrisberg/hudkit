import AppKit
import XCTest
@testable import HUDKit

/// `HUDWindowBlur`: the window server's background blur on a window, set while a backdrop view
/// is in it, with the server call replaced by a recorder.
@MainActor
final class HUDWindowBlurTests: XCTestCase {
    struct Call: Equatable {
        let window: Int
        let radius: Int
    }

    var calls: [Call] = []
    var clock: ManualClock!
    var blur: HUDWindowBlur!
    var windows: [NSWindow] = []

    override func setUp() async throws {
        calls = []
        clock = ManualClock()
        blur = HUDWindowBlur(setter: { [unowned self] window, radius in calls.append(Call(window: window, radius: radius)) },
                             scheduler: clock.scheduler, transparency: .fixed(reduced: false))
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
    }

    /// A window that is never ordered in, with a frame inside the main screen's visible frame.
    private func window(deferred: Bool = false) -> NSWindow {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w = NSWindow(contentRect: CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 120, height: 80),
                         styleMask: .borderless, backing: .buffered, defer: deferred)
        w.isReleasedWhenClosed = false
        windows.append(w)
        return w
    }

    func testTheServerCallIsResolvedAtRunTime() {
        XCTAssertNotNil(HUDWindowBlur.serverSetter(), "CGSMainConnectionID and CGSSetWindowBackgroundBlurRadius resolve")
        XCTAssertTrue(HUDWindowBlur.shared.isAvailable)
        XCTAssertEqual(HUDWindowBlur.radius, 25)
    }

    func testReduceTransparencyMeansTheBlurIsNotUsed() {
        var reduced = false
        let setting = HUDTransparencySetting(isReduced: { reduced }, center: NotificationCenter())
        let blur = HUDWindowBlur(setter: { _, _ in }, scheduler: clock.scheduler, transparency: setting)
        XCTAssertTrue(blur.isUsable)
        reduced = true
        XCTAssertTrue(blur.isAvailable, "the call is still there")
        XCTAssertFalse(blur.isUsable, "but the user asked for less transparency")
        XCTAssertFalse(HUDWindowBlur(setter: nil, scheduler: clock.scheduler, transparency: .fixed(reduced: false)).isUsable)
        XCTAssertEqual(HUDTransparencySetting.system.isReduced(), NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        XCTAssertTrue(HUDTransparencySetting.system.center === NSWorkspace.shared.notificationCenter)
    }

    func testAMissingSymbolMeansNoBlur() {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        for missing in ["CGSMainConnectionID", "CGSSetWindowBackgroundBlurRadius"] {
            XCTAssertNil(HUDWindowBlur.serverSetter(lookup: { $0 == missing ? nil : dlsym(rtldDefault, $0) }), missing)
        }
        let none = HUDWindowBlur(setter: nil, scheduler: clock.scheduler, transparency: .fixed(reduced: false))
        XCTAssertFalse(none.isAvailable)
        none.attach(NSView(), to: window())
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testTheFirstBackdropSetsTheRadiusAndTheLastClearsIt() {
        let w = window()
        let n = w.windowNumber
        XCTAssertGreaterThan(n, 0, "a window made without defer has its number before it is ordered in")
        let a = NSView(), b = NSView()
        blur.attach(a, to: w)
        XCTAssertEqual(calls, [Call(window: n, radius: 25)])
        blur.attach(b, to: w)
        XCTAssertEqual(calls.last, Call(window: n, radius: 25), "set again: harmless")
        let count = calls.count
        blur.detach(a, from: w)
        XCTAssertEqual(calls.count, count, "another backdrop is still in the window")
        blur.detach(b, from: w)
        XCTAssertEqual(calls.last, Call(window: n, radius: 25), "cleared a turn later, not at once")
        clock.advance(by: 0)
        XCTAssertEqual(calls.last, Call(window: n, radius: 0), "the last one out clears it")
        let cleared = calls.count
        blur.detach(b, from: w)
        clock.advance(by: 5)
        XCTAssertEqual(calls.count, cleared, "nothing more for a window with no backdrop")
    }

    func testSetOnceMoreAfterSettling() {
        let w = window()
        blur.attach(NSView(), to: w)
        XCTAssertEqual(clock.pendingDelays, [HUDWindowBlur.settleDelay])
        XCTAssertEqual(HUDWindowBlur.settleDelay, 0.4)
        clock.advance(by: 0.39)
        XCTAssertEqual(calls.count, 1)
        clock.advance(by: 0.01)
        XCTAssertEqual(calls, [Call(window: w.windowNumber, radius: 25), Call(window: w.windowNumber, radius: 25)])
        XCTAssertEqual(clock.pendingCount, 0, "once")
    }

    func testAnOcclusionChangeSetsItAgain() {
        let w = window()
        let view = NSView()
        blur.attach(view, to: w)
        clock.advance(by: 1)
        calls = []
        // Posted when the window comes on screen (ordered in, its desktop shown, the display
        // awake) and when it leaves.
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
        XCTAssertEqual(calls, [Call(window: w.windowNumber, radius: 25)])
        clock.advance(by: HUDWindowBlur.settleDelay)
        XCTAssertEqual(calls.count, 2, "and once more after settling")
        blur.detach(view, from: w)
        clock.advance(by: 0)
        XCTAssertEqual(calls.last, Call(window: w.windowNumber, radius: 0))
        calls = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
        clock.advance(by: 5)
        XCTAssertEqual(calls, [], "no longer watched")
    }

    func testAWindowWithoutANumberWaitsForItsOrderIn() {
        let w = window(deferred: true)
        XCTAssertLessThanOrEqual(w.windowNumber, 0, "a deferred window has no number until it is ordered in")
        let view = NSView()
        blur.attach(view, to: w)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
        clock.advance(by: 1)
        XCTAssertEqual(calls, [], "nothing to set until the window server has the window")
        blur.detach(view, from: w)
        XCTAssertEqual(calls, [])
    }

    func testABackdropReplacingAnotherNeverUnblursTheWindow() {
        // A style rebuild or a new content view: the old backdrop leaves before the new one
        // arrives, in the same turn of the run loop.
        let w = window()
        let old = NSView(), new = NSView()
        blur.attach(old, to: w)
        blur.detach(old, from: w)
        blur.attach(new, to: w)
        clock.advance(by: 5)
        XCTAssertFalse(calls.contains(Call(window: w.windowNumber, radius: 0)), "never cleared in between")
        calls = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
        XCTAssertEqual(calls, [Call(window: w.windowNumber, radius: 25)], "still watched")
    }

    func testWindowsAreSeparate() {
        let w1 = window(), w2 = window()
        let a = NSView(), b = NSView()
        blur.attach(a, to: w1)
        blur.attach(b, to: w2)
        blur.detach(a, from: w1)
        clock.advance(by: 0)
        XCTAssertEqual(calls.last, Call(window: w1.windowNumber, radius: 0))
        calls = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w2)
        XCTAssertEqual(calls, [Call(window: w2.windowNumber, radius: 25)])
    }
}
