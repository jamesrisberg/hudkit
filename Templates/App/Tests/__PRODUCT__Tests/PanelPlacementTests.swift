import AppKit
import HUDKit
import XCTest
@testable import __PRODUCT__

@MainActor
final class PanelPlacementTests: XCTestCase {
    func testDockShowKeepsTheFrameAssignedToClearBothToolbarArms() async throws {
        let model = AppModel(settingsURL: nil)
        let panel = PanelController(model: model)
        defer { panel.hide(); panel.window.orderOut(nil) }
        let anchor = CGRect(x: 16, y: 760, width: 44, height: 44)
        let toolbar = CGRect(x: 8, y: 832, width: 600, height: 60)
        let assigned = HUDDockLayout.panelFrame(
            size: PanelController.size, anchor: anchor,
            dockFrames: [CGRect(x: 8, y: 200, width: 60, height: 692), toolbar], from: .left,
            in: CGRect(x: 0, y: 0, width: 1200, height: 900))
        panel.setFrame(assigned)
        panel.show(HUDPanelTransition(from: .left, anchor: anchor, reason: .hover))
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(panel.window.frame, assigned)
        XCTAssertFalse(panel.window.frame.intersects(toolbar))
    }

    func testPlainShowDuringConcealmentKeepsTheLatestAssignedFrame() async throws {
        let panel = PanelController(model: AppModel(settingsURL: nil))
        defer { panel.hide(); panel.window.orderOut(nil) }
        panel.setFrame(CGRect(origin: CGPoint(x: 200, y: 200), size: PanelController.size))
        panel.show()
        try await Task.sleep(nanoseconds: 350_000_000)
        panel.hide(HUDPanelTransition(to: .left))
        let latest = CGRect(origin: CGPoint(x: 360, y: 140), size: PanelController.size)
        panel.setFrame(latest)
        panel.show()
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(panel.isShown)
        XCTAssertEqual(panel.window.frame, latest)
    }
}
