// Unit tests for HUDFullscreenObserver, driven entirely through its injected screensProvider,
// windowsProvider and frontmostApplicationPID — no real NSWorkspace notification, CGWindowList
// read or display is needed.
//
// Full screen is decided from positive window evidence (a layer-0 window owned by the
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

    func testNoFrontmostPIDFallsBackToAnyLayerZeroFullScreenWindow() {
        let windows = [HUDWindowSnapshot(ownerPID: 999, layer: 0, bounds: screenA.frame)]
        let observer = HUDFullscreenObserver(screensProvider: { [self.screenA] },
                                             windowsProvider: { windows },
                                             frontmostApplicationPID: { nil })
        observer.refresh()
        XCTAssertTrue(observer.isFullScreen(screenID: "A"))
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
