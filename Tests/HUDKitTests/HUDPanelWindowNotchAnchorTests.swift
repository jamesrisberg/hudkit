// HUDPanelWindow's notch-anchor placement: the frame math delegates to HUDNotchGeometry
// (covered by HUDNotchGeometryTests), so this only pins the window-level and wiring.

import XCTest
@testable import HUDKit

final class HUDPanelWindowNotchAnchorTests: XCTestCase {

    @MainActor
    func testNotchAnchorLevelDrawsAboveTheMenuBar() {
        // The menu bar itself draws at .mainMenu; a panel anchored under the notch must be
        // strictly above that layer or the menu bar would cover it.
        XCTAssertGreaterThan(HUDPanelWindow.notchAnchorLevel.rawValue, NSWindow.Level.mainMenu.rawValue)
    }

    @MainActor
    func testAnchorUnderNotchSetsLevelAndFrame() {
        let window = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), behavior: .hover)
        let geometry = HUDNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 865),
                                         safeAreaInsetTop: 37, notchWidth: 180)
        let size = CGSize(width: 260, height: 44)

        window.anchorUnderNotch(size: size, geometry: geometry)

        XCTAssertEqual(window.level, HUDPanelWindow.notchAnchorLevel)
        XCTAssertEqual(window.frame, geometry.anchorFrame(for: size))
    }
}
