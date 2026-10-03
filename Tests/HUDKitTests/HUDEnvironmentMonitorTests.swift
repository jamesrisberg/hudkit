import XCTest
import AppKit
@testable import HUDKit

/// `HUDEnvironmentMonitor`: a burst of Space, wake and screen notifications becomes one settled
/// call with every kind seen. Driven by a hand-advanced clock and private notification centers,
/// so nothing sleeps and nothing reaches other observers in the process.
@MainActor
final class HUDEnvironmentMonitorTests: XCTestCase {
    private var clock: ManualClock!
    private var workspace: NotificationCenter!
    private var app: NotificationCenter!
    private var monitor: HUDEnvironmentMonitor!

    override func setUp() {
        clock = ManualClock()
        workspace = NotificationCenter()
        app = NotificationCenter()
        monitor = HUDEnvironmentMonitor(scheduler: clock.scheduler, workspaceCenter: workspace, appCenter: app)
    }

    func testDefaults() {
        XCTAssertEqual(HUDEnvironmentMonitor.defaultSettleDelay, 0.35)
        XCTAssertEqual(HUDEnvironmentMonitor.shared.settleDelay, 0.35)
        XCTAssertEqual(monitor.settleDelay, 0.35)
    }

    func testABurstSettlesOnceWithEveryKindSeen() {
        var calls: [HUDEnvironmentMonitor.Change] = []
        let observation = monitor.observeSettled { calls.append($0) }
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        clock.advance(by: 0.3)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        clock.advance(by: 0.3)
        app.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(monitor.pendingChanges, [.activeSpace, .wake, .screenParameters])
        clock.advance(by: 0.34)
        XCTAssertEqual(calls, [], "each notification restarts the wait")
        clock.advance(by: 0.02)
        XCTAssertEqual(calls, [[.activeSpace, .wake, .screenParameters]])
        XCTAssertEqual(monitor.pendingChanges, [])
        XCTAssertEqual(clock.pendingCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testEachSettleCarriesOnlyItsOwnChanges() {
        var calls: [HUDEnvironmentMonitor.Change] = []
        let observation = monitor.observeSettled { calls.append($0) }
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        clock.advance(by: 1)
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        clock.advance(by: 1)
        XCTAssertEqual(calls, [.screensWake, .activeSpace])
        withExtendedLifetime(observation) {}
    }

    func testEveryObserverIsCalledUntilCancelledOrReleased() {
        var first = 0, second = 0, third = 0
        let a = monitor.observeSettled { _ in first += 1 }
        let b = monitor.observeSettled { _ in second += 1 }
        var c: HUDEnvironmentMonitor.Observation? = monitor.observeSettled { _ in third += 1 }
        monitor.note(.wake)
        clock.advance(by: 1)
        XCTAssertEqual([first, second, third], [1, 1, 1])
        b.cancel()
        c = nil
        monitor.note(.wake)
        clock.advance(by: 1)
        XCTAssertEqual([first, second, third], [2, 1, 1])
        withExtendedLifetime((a, c)) {}
    }

    /// Notifications that keep coming with gaps shorter than the settle delay still settle,
    /// 2 s after the first of the burst.
    func testAStreamWithShortGapsSettlesByTheDeadline() {
        XCTAssertEqual(HUDEnvironmentMonitor.defaultMaxSettleWait, 2)
        var calls: [HUDEnvironmentMonitor.Change] = []
        let observation = monitor.observeSettled { calls.append($0) }
        monitor.note(.screenParameters)
        for _ in 0..<6 {
            clock.advance(by: 0.3)
            monitor.note(.activeSpace)
        }
        XCTAssertEqual(calls, [], "1.8 s in")
        clock.advance(by: 0.2)
        XCTAssertEqual(calls, [[.screenParameters, .activeSpace]], "settled at the deadline")
        monitor.note(.wake)
        clock.advance(by: 0.35)
        XCTAssertEqual(calls.last, .wake, "the next burst starts its own deadline and settles as usual")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(clock.pendingCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testAnObserverCancelledDuringASettleIsNotCalled() {
        var order: [String] = []
        var second: HUDEnvironmentMonitor.Observation?
        let first = monitor.observeSettled { _ in
            order.append("first")
            second?.cancel()
        }
        second = monitor.observeSettled { _ in order.append("second") }
        monitor.note(.wake)
        clock.advance(by: 1)
        XCTAssertEqual(order, ["first"])
        withExtendedLifetime((first, second)) {}
    }

    func testSettleDelayIsAdjustable() {
        var calls = 0
        let observation = monitor.observeSettled { _ in calls += 1 }
        monitor.settleDelay = 1
        monitor.note(.activeSpace)
        clock.advance(by: 0.9)
        XCTAssertEqual(calls, 0)
        clock.advance(by: 0.1)
        XCTAssertEqual(calls, 1)
        withExtendedLifetime(observation) {}
    }

    func testOtherNotificationsAreIgnored() {
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(monitor.pendingChanges, [])
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testChangeDescription() {
        XCTAssertEqual(HUDEnvironmentMonitor.Change([.screenParameters, .activeSpace]).description, "activeSpace,screenParameters")
        XCTAssertEqual(HUDEnvironmentMonitor.Change([.wake, .screensWake]).description, "wake,screensWake")
        XCTAssertEqual(HUDEnvironmentMonitor.Change().description, "none")
    }
}
