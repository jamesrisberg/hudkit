import AppKit
import HUDKit
import XCTest
@testable import __PRODUCT__

@MainActor
final class PanelPlacementTests: XCTestCase {
    override func setUp() async throws { _ = NSApplication.shared }

    /// Let AppKit finish on its run loop before checking the exact destination.
    private func waitForFrame(_ frame: CGRect, panel: PanelController) {
        let earliest = Date().addingTimeInterval(HUDAnimation.revealDuration)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { Date() >= earliest && panel.window.frame == frame }
        }, object: nil)
        let result = XCTWaiter.wait(for: [settled], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected \(frame), got \(panel.window.frame)")
    }
    func testDockShowKeepsTheFrameAssignedToClearBothToolbarArms() throws {
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
        waitForFrame(assigned, panel: panel)
        XCTAssertEqual(panel.window.frame, assigned)
        XCTAssertFalse(panel.window.frame.intersects(toolbar))
    }

    func testPlainShowDuringConcealmentKeepsTheLatestAssignedFrame() throws {
        let panel = PanelController(model: AppModel(settingsURL: nil))
        defer { panel.hide(); panel.window.orderOut(nil) }
        panel.setFrame(CGRect(origin: CGPoint(x: 200, y: 200), size: PanelController.size))
        panel.show()
        waitForFrame(CGRect(origin: CGPoint(x: 200, y: 200), size: PanelController.size), panel: panel)
        panel.hide(HUDPanelTransition(to: .left))
        let latest = CGRect(origin: CGPoint(x: 360, y: 140), size: PanelController.size)
        panel.setFrame(latest)
        panel.show()
        waitForFrame(latest, panel: panel)
        XCTAssertTrue(panel.isShown)
        XCTAssertEqual(panel.window.frame, latest)
    }
}
