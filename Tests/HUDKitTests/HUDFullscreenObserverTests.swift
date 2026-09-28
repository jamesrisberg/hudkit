// Unit tests for HUDFullscreenObserver, driven entirely through its injected screensProvider —
// no real NSWorkspace notification or display is needed.

import XCTest
@testable import HUDKit

@MainActor
final class HUDFullscreenObserverTests: XCTestCase {

    func testScreenSnapshotDetectsFullScreenFromTheVisibleFrame() {
        let normal = HUDScreenSnapshot(id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                        visibleFrame: CGRect(x: 0, y: 70, width: 1920, height: 1010))
        XCTAssertFalse(normal.isFullScreen)

        let fullscreen = HUDScreenSnapshot(id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertTrue(fullscreen.isFullScreen)
    }

    func testRefreshComputesPerScreenState() {
        var snapshots: [HUDScreenSnapshot] = [
            HUDScreenSnapshot(id: "main", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: CGRect(x: 0, y: 63, width: 1512, height: 919)),
            HUDScreenSnapshot(id: "external", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080)),
        ]
        let observer = HUDFullscreenObserver(screensProvider: { snapshots })
        observer.refresh()

        XCTAssertFalse(observer.isFullScreen(screenID: "main"))
        XCTAssertTrue(observer.isFullScreen(screenID: "external"))
        XCTAssertFalse(observer.isFullScreen(screenID: "unknown"))

        snapshots[0] = HUDScreenSnapshot(id: "main", frame: snapshots[0].frame, visibleFrame: snapshots[0].frame)
        observer.refresh()
        XCTAssertTrue(observer.isFullScreen(screenID: "main"))
    }

    func testOnChangeFiresOnlyWhenStateActuallyChanges() {
        var snapshots = [HUDScreenSnapshot(id: "main", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                            visibleFrame: CGRect(x: 0, y: 50, width: 1000, height: 750))]
        let observer = HUDFullscreenObserver(screensProvider: { snapshots })
        var changeCount = 0
        observer.onChange = { _ in changeCount += 1 }

        observer.refresh()
        XCTAssertEqual(changeCount, 1, "first refresh always reports the initial state")

        observer.refresh()
        XCTAssertEqual(changeCount, 1, "no change, no callback")

        snapshots[0] = HUDScreenSnapshot(id: "main", frame: snapshots[0].frame, visibleFrame: snapshots[0].frame)
        observer.refresh()
        XCTAssertEqual(changeCount, 2)
    }

    func testScreenRemovedFromTheProviderDropsOutOfState() {
        var snapshots = [
            HUDScreenSnapshot(id: "a", frame: .init(x: 0, y: 0, width: 100, height: 100), visibleFrame: .init(x: 0, y: 0, width: 100, height: 100)),
        ]
        let observer = HUDFullscreenObserver(screensProvider: { snapshots })
        observer.refresh()
        XCTAssertTrue(observer.isFullScreen(screenID: "a"))

        snapshots = []
        observer.refresh()
        XCTAssertFalse(observer.isFullScreen(screenID: "a"))
    }
}
