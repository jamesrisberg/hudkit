import AppKit
import XCTest
@testable import HUDKit

@MainActor
final class HUDPanelWindowSpaceRecoveryTests: XCTestCase {
    private var clock: ManualClock!
    private var probe: FakePresenceProbe!
    private var window: RecordingPanel!

    override func setUp() {
        clock = ManualClock()
        probe = FakePresenceProbe()
        let frame = liveTestFrame()
        probe.screens = [HUDScreenSnapshot(id: "test", frame: frame.insetBy(dx: -20, dy: -20), visibleFrame: frame)]
        window = RecordingPanel(contentRect: frame)
        window.alphaValue = 0.02
        let environment = HUDEnvironmentMonitor(scheduler: clock.scheduler, workspaceCenter: nil, appCenter: nil)
        window.presenceKeeper = HUDPresenceKeeper(environment: environment, scheduler: clock.scheduler, probe: probe.probe)
        window.spaceScheduler = clock.scheduler
        window.orderFrontRegardless()
        window.resetRecords()
    }

    override func tearDown() {
        window.orderOut(nil)
        window = nil
        clock = nil
        probe = nil
    }

    func testMoveKeepsItsBehaviourUntilAppKitCanProcessIt() {
        window.collectionBehavior.insert(.ignoresCycle)
        window.moveToActiveSpace()

        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        clock.advance(by: HUDPanelWindow.spaceCheckDelay / 2)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        clock.advance(by: HUDPanelWindow.spaceCheckDelay / 2)
        XCTAssertEqual(window.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior.union(.ignoresCycle))
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(window.frameSets.isEmpty)
    }

    func testHideCancelsThePendingMoveAndDoesNotReopenThePanel() {
        window.moveToActiveSpace()
        window.orderOut(nil)
        XCTAssertEqual(window.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior)
        clock.advance(by: 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior)
    }

    func testAnEnvironmentRepairDoesNotClearAMoveInFlight() {
        window.moveToActiveSpace()
        window.rejoinAllSpaces()
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        clock.advance(by: HUDPanelWindow.spaceCheckDelay)
        XCTAssertEqual(window.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior)
    }

    func testNewShowAndMoveAreNotFinishedByAnOlderMove() {
        window.moveToActiveSpace()
        clock.advance(by: HUDPanelWindow.spaceCheckDelay / 2)
        window.orderOut(nil)
        window.orderFrontRegardless()
        window.moveToActiveSpace()
        clock.advance(by: HUDPanelWindow.spaceCheckDelay / 2)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        clock.advance(by: HUDPanelWindow.spaceCheckDelay / 2)
        XCTAssertEqual(window.collectionBehavior, HUDPanelWindow.hoverCollectionBehavior)
    }

    func testRecipeChangeCancelsTheMoveWithoutRestoringHoverLater() {
        window.moveToActiveSpace()
        window.showsInDock = false
        window.applyHUDRecipe(behavior: .windowed)
        clock.advance(by: 1)
        XCTAssertEqual(window.collectionBehavior, HUDPanelWindow.windowedCollectionBehavior)
        XCTAssertEqual(window.behavior, .windowed)
    }

    func testServerOnScreenVetoesAMoveFromAStaleAppKitReading() {
        probe.onActiveSpace[ObjectIdentifier(window)] = false
        XCTAssertFalse(window.ensureOnActiveSpace())
        XCTAssertTrue(window.untouched)
    }

    func testServerOffScreenOverridesAStaleAppKitReading() {
        probe.server[ObjectIdentifier(window)] = HUDPresenceKeeper.ServerWindow(isOnScreen: false, bounds: window.frame)
        XCTAssertTrue(window.ensureOnActiveSpace())
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
    }

    func testTransparentAndOffDisplayPanelsAreNotMoved() {
        probe.strand(window)
        window.alphaValue = 0
        XCTAssertFalse(window.ensureOnActiveSpace())
        window.alphaValue = 0.02
        window.setFrameOrigin(CGPoint(x: -100_000, y: -100_000))
        XCTAssertFalse(window.ensureOnActiveSpace())
        XCTAssertEqual(window.moves, 0)
    }
}
