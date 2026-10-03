// Unit tests for HUDFullscreenObserver. Screens, the window list and the frontmost app are
// injected. The tests that start the observer also inject the settled signal and a
// hand-advanced clock for the re-check timer; `start()` still subscribes to the real
// NSWorkspace notifications, which these tests never post. Only
// testLiveWindowsCarryTheWindowNumberAndAlpha reads the real window server.
//
// Full screen is decided from positive window evidence (a drawn layer-0 window owned by the
// frontmost app whose bounds equal a screen's full frame), not from visibleFrame alone: an
// auto-hidden menu bar and Dock can make visibleFrame reach the screen's frame with no
// full-screen app running, and a merely maximized window's bounds match visibleFrame, not frame.

import XCTest
@testable import HUDKit

@MainActor
final class HUDFullscreenObserverTests: XCTestCase {

    private let screenA = HUDScreenSnapshot(id: "A", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                             visibleFrame: CGRect(x: 0, y: 63, width: 1512, height: 919))
    private let screenB = HUDScreenSnapshot(id: "B", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                             visibleFrame: CGRect(x: 1512, y: 25, width: 1920, height: 1055))

    private let frontmostPID: Int32 = 100

    func testNoWindowEvidenceIsNotFullScreenEvenWithAutoHiddenChrome() {
        // Auto-hide menu bar + auto-hide Dock: visibleFrame reaches the screen's frame with no
        // full-screen app running at all.
        let autoHidden = HUDScreenSnapshot(id: "A", frame: screenA.frame, visibleFrame: screenA.frame)
        let observer = HUDFullscreenObserver(screensProvider: { [autoHidden] },
                                             windowsProvider: { [] },
                                             frontmostApplicationPID: { self.frontmostPID })
        observer.refresh()
        XCTAssertFalse(observer.isFullScreen(screenID: "A"))
    }

    func testFullScreenWindowOnOneScreenOnly() {
        let windows = [HUDWindowSnapshot(ownerPID: frontmostPID, layer: 0, bounds: screenA.frame)]
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA, self.screenB] },
                                             windowsProvider: { windows },
                                             frontmostApplicationPID: { self.frontmostPID })
        observer.refresh()
        XCTAssertTrue(observer.isFullScreen(screenID: "A"))
        XCTAssertFalse(observer.isFullScreen(screenID: "B"))
    }

    func testMaximizedButNotFullScreenWindowIsNotFullScreen() {
        // A window sized to visibleFrame (maximized within the menu bar/Dock) is not full
        // screen: only bounds matching the screen's full frame count as evidence.
        let windows = [HUDWindowSnapshot(ownerPID: frontmostPID, layer: 0, bounds: screenA.visibleFrame)]
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA] },
                                             windowsProvider: { windows },
                                             frontmostApplicationPID: { self.frontmostPID })
        observer.refresh()
        XCTAssertFalse(observer.isFullScreen(screenID: "A"))
    }

    func testNonFrontmostAppsFullScreenSizedWindowDoesNotCount() {
        // A background app's window happens to be screen-sized, but it isn't the frontmost app.
        let windows = [HUDWindowSnapshot(ownerPID: frontmostPID + 1, layer: 0, bounds: screenA.frame)]
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA] },
                                             windowsProvider: { windows },
                                             frontmostApplicationPID: { self.frontmostPID })
        observer.refresh()
        XCTAssertFalse(observer.isFullScreen(screenID: "A"))
    }

    func testNonLayerZeroWindowDoesNotCount() {
        let windows = [HUDWindowSnapshot(ownerPID: frontmostPID, layer: 3, bounds: screenA.frame)]
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA] },
                                             windowsProvider: { windows },
                                             frontmostApplicationPID: { self.frontmostPID })
        observer.refresh()
        XCTAssertFalse(observer.isFullScreen(screenID: "A"))
    }

    /// With no frontmost app known there is no positive evidence either way: each screen keeps
    /// its previous result, rather than any app's screen-sized window counting.
    func testUnknownFrontmostAppKeepsThePreviousResult() {
        var pid: Int32? = frontmostPID
        var windows: [HUDWindowSnapshot] = []
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA, self.screenB] },
                                             windowsProvider: { windows },
                                             frontmostApplicationPID: { pid })
        observer.refresh()
        XCTAssertFalse(observer.isFullScreen(screenID: "A"))
        pid = nil
        windows = [HUDWindowSnapshot(ownerPID: 999, layer: 0, bounds: screenA.frame)]
        observer.refresh()
        XCTAssertFalse(observer.isFullScreen(screenID: "A"), "another app's screen-sized window is not evidence")

        pid = frontmostPID
        let fullScreen = HUDWindowSnapshot(windowID: 42, ownerPID: frontmostPID, layer: 0, bounds: screenA.frame)
        windows = [fullScreen]
        observer.refresh()
        XCTAssertTrue(observer.isFullScreen(screenID: "A"))
        pid = nil
        windows = []
        observer.refresh()
        XCTAssertTrue(observer.isFullScreen(screenID: "A"), "kept until a known frontmost app settles it")
        XCTAssertEqual(observer.evidence(screenID: "A"), fullScreen, "with its evidence")
        XCTAssertFalse(observer.isFullScreen(screenID: "B"))
    }

    // MARK: - Evidence

    func testAWindowAtAlphaZeroIsNotEvidence() {
        var alpha: CGFloat = 0
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA] },
                                             windowsProvider: { [HUDWindowSnapshot(ownerPID: self.frontmostPID, layer: 0,
                                                                                   bounds: self.screenA.frame, alpha: alpha)] },
                                             frontmostApplicationPID: { self.frontmostPID })
        observer.refresh()
        XCTAssertFalse(observer.isFullScreen(screenID: "A"), "an invisible screen-sized window draws nothing")
        alpha = 0.01
        observer.refresh()
        XCTAssertTrue(observer.isFullScreen(screenID: "A"))
    }

    func testEvidenceIsTheWindowThatSatisfiedTheTest() {
        let match = HUDWindowSnapshot(windowID: 42, ownerPID: frontmostPID, layer: 0, bounds: screenB.frame, alpha: 1)
        var windows = [
            HUDWindowSnapshot(windowID: 40, ownerPID: frontmostPID, layer: 3, bounds: screenB.frame),
            HUDWindowSnapshot(windowID: 41, ownerPID: frontmostPID + 1, layer: 0, bounds: screenB.frame),
            match,
            HUDWindowSnapshot(windowID: 43, ownerPID: frontmostPID, layer: 0, bounds: screenB.frame),
        ]
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA, self.screenB] },
                                             windowsProvider: { windows },
                                             frontmostApplicationPID: { self.frontmostPID })
        observer.refresh()
        XCTAssertEqual(observer.evidence(screenID: "B"), match, "the frontmost match in window-list order")
        XCTAssertNil(observer.evidence(screenID: "A"))
        XCTAssertEqual(observer.evidenceByScreenID, ["B": match])
        windows = []
        observer.refresh()
        XCTAssertNil(observer.evidence(screenID: "B"), "gone with the result")
    }

    func testChangesAreDescribedWithTheirEvidence() {
        var windows = [HUDWindowSnapshot(windowID: 42, ownerPID: frontmostPID, layer: 0, bounds: screenA.frame, alpha: 1)]
        var screens = [screenA, screenB]
        let observer = HUDFullscreenObserver(screensProvider: { screens }, windowsProvider: { windows },
                                             frontmostApplicationPID: { self.frontmostPID })
        observer.applicationName = { $0 == self.frontmostPID ? "Keynote" : nil }
        observer.refresh()
        XCTAssertEqual(observer.changeMessages(from: [:], to: observer.fullScreenByScreenID, trigger: .activation,
                                               frontmost: frontmostPID),
                       ["screen A: full screen (app activation; frontmost 100 Keynote): window 42 owner 100 Keynote "
                            + "bounds 0,0,1512,982 layer 0 alpha 1.00"],
                       "B, false before and after, is not a change")
        let before = observer.fullScreenByScreenID
        windows = []
        screens = [screenB]
        observer.refresh()
        XCTAssertEqual(observer.changeMessages(from: before, to: observer.fullScreenByScreenID, trigger: .recheck,
                                               frontmost: nil),
                       ["screen A: not full screen (re-check; frontmost unknown), screen gone"])
        XCTAssertEqual(observer.changeMessages(from: ["B": true], to: ["B": false], trigger: .settled([.wake]),
                                               frontmost: 7),
                       ["screen B: not full screen (settled after wake; frontmost 7 unknown)"])
    }

    // MARK: - Staying current

    private func startedObserver(windows: @escaping @MainActor () -> [HUDWindowSnapshot],
                                 clock: ManualClock, monitor: HUDEnvironmentMonitor) -> HUDFullscreenObserver {
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA] }, windowsProvider: windows,
                                             frontmostApplicationPID: { self.frontmostPID },
                                             environment: monitor, scheduler: clock.scheduler)
        observer.start()
        addTeardownBlock { @MainActor in observer.stop() }
        return observer
    }

    func testRefreshesOnTheSettledSignal() {
        let clock = ManualClock()
        let monitor = HUDEnvironmentMonitor(scheduler: clock.scheduler, workspaceCenter: nil, appCenter: nil)
        var windows: [HUDWindowSnapshot] = []
        let observer = startedObserver(windows: { windows }, clock: clock, monitor: monitor)
        var changes = 0
        observer.onChange = { _ in changes += 1 }
        windows = [HUDWindowSnapshot(ownerPID: frontmostPID, layer: 0, bounds: screenA.frame)]
        monitor.note(.screenParameters)
        clock.advance(by: 0.3)
        XCTAssertFalse(observer.isFullScreen(screenID: "A"), "not before the change has settled")
        clock.advance(by: 0.1)
        XCTAssertTrue(observer.isFullScreen(screenID: "A"), "a screen change, wake or late window list is caught")
        XCTAssertEqual(changes, 1)
    }

    func testRechecksWhileFullScreenAndStopsWhenNot() {
        let clock = ManualClock()
        let monitor = HUDEnvironmentMonitor(scheduler: clock.scheduler, workspaceCenter: nil, appCenter: nil)
        var windows = [HUDWindowSnapshot(ownerPID: frontmostPID, layer: 0, bounds: screenA.frame)]
        let observer = startedObserver(windows: { windows }, clock: clock, monitor: monitor)
        XCTAssertEqual(HUDFullscreenObserver.defaultRecheckInterval, 2)
        XCTAssertTrue(observer.isFullScreen(screenID: "A"))
        XCTAssertEqual(clock.pendingDelays, [2], "re-checks while full screen")

        windows = []   // the full-screen window went away and no notification said so
        clock.advance(by: 1.9)
        XCTAssertTrue(observer.isFullScreen(screenID: "A"))
        clock.advance(by: 0.1)
        XCTAssertFalse(observer.isFullScreen(screenID: "A"), "a stale result lasts at most one interval")
        XCTAssertEqual(clock.pendingCount, 0, "no timer while nothing is full screen")

        windows = [HUDWindowSnapshot(ownerPID: frontmostPID, layer: 0, bounds: screenA.frame)]
        observer.refresh()
        XCTAssertEqual(clock.pendingDelays, [2], "back on while full screen again")
        clock.advance(by: 2)
        XCTAssertEqual(clock.pendingDelays, [2], "and keeps going")
        observer.stop()
        XCTAssertEqual(clock.pendingCount, 0, "stop ends it")
        observer.refresh()
        XCTAssertEqual(clock.pendingCount, 0, "not re-checked while stopped")
    }

    func testRecheckIntervalIsAdjustable() {
        let clock = ManualClock()
        let monitor = HUDEnvironmentMonitor(scheduler: clock.scheduler, workspaceCenter: nil, appCenter: nil)
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA] },
                                             windowsProvider: { [HUDWindowSnapshot(ownerPID: self.frontmostPID, layer: 0,
                                                                                   bounds: self.screenA.frame)] },
                                             frontmostApplicationPID: { self.frontmostPID },
                                             environment: monitor, scheduler: clock.scheduler)
        observer.recheckInterval = 5
        observer.start()
        defer { observer.stop() }
        XCTAssertEqual(clock.pendingDelays, [5])
    }

    // MARK: - The live window list

    /// `liveWindows()` reads each window's number and alpha from the window server.
    func testLiveWindowsCarryTheWindowNumberAndAlpha() throws {
        let w = NSPanel(contentRect: liveTestFrame(), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.alphaValue = 0.25
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))   // the window server hears of it when the run loop turns
        let snapshot = try XCTUnwrap(HUDFullscreenObserver.liveWindows().first { $0.windowID == CGWindowID(w.windowNumber) })
        XCTAssertEqual(snapshot.ownerPID, getpid())
        XCTAssertEqual(snapshot.alpha, 0.25, accuracy: 0.01)
        XCTAssertEqual(snapshot.bounds, w.frame, "in AppKit coordinates")
    }

    func testOnChangeFiresOnlyWhenStateActuallyChanges() {
        var windows: [HUDWindowSnapshot] = []
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA] },
                                             windowsProvider: { windows },
                                             frontmostApplicationPID: { self.frontmostPID })
        var changeCount = 0
        observer.onChange = { _ in changeCount += 1 }

        observer.refresh()
        XCTAssertEqual(changeCount, 1, "first refresh always reports the initial state")

        observer.refresh()
        XCTAssertEqual(changeCount, 1, "no change, no callback")

        windows = [HUDWindowSnapshot(ownerPID: frontmostPID, layer: 0, bounds: screenA.frame)]
        observer.refresh()
        XCTAssertEqual(changeCount, 2)
    }

    func testScreenRemovedFromTheProviderDropsOutOfState() {
        var screens = [screenA]
        let windows = [HUDWindowSnapshot(ownerPID: frontmostPID, layer: 0, bounds: screenA.frame)]
        let observer = HUDFullscreenObserver(screensProvider: { screens },
                                             windowsProvider: { windows },
                                             frontmostApplicationPID: { self.frontmostPID })
        observer.refresh()
        XCTAssertTrue(observer.isFullScreen(screenID: "A"))

        screens = []
        observer.refresh()
        XCTAssertFalse(observer.isFullScreen(screenID: "A"))
    }

    func testUnknownScreenIDIsNotFullScreen() {
        let observer = HUDFullscreenObserver(screensProvider: { [] }, windowsProvider: { [] },
                                             frontmostApplicationPID: { nil })
        XCTAssertFalse(observer.isFullScreen(screenID: "nonexistent"))
    }
}
