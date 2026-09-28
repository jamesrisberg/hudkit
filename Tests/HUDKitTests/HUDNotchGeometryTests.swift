// Unit tests for HUDNotchGeometry: pure frame math for a panel anchored under the notch (or
// the menu bar on a screen without one), against hand-built screen values. No NSScreen, no
// display attached — mirrors SpeakFree's OverlayPlacementTests fixtures.

import XCTest
@testable import HUDKit

final class HUDNotchGeometryTests: XCTestCase {

    // A 1512x982 MacBook Pro 14" screen: 37pt camera housing, Dock at the bottom.
    private let notched = HUDNotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 982 - 80 - 37),
        safeAreaInsetTop: 37, notchWidth: 180)

    // An external 1920x1080 display: 25pt menu bar, no notch, Dock at the bottom.
    private let plain = HUDNotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 70, width: 1920, height: 1080 - 70 - 25))

    // A mixed setup: secondary screen offset from the origin, no notch.
    private let secondary = HUDNotchGeometry(
        screenFrame: CGRect(x: 1920, y: 200, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1920, y: 200, width: 1920, height: 1055))

    private let panel = CGSize(width: 260, height: 44)

    // MARK: - Notch detection

    func testHasNotchRequiresBothInsetAndMeasurableWidth() {
        XCTAssertTrue(notched.hasNotch)
        XCTAssertFalse(plain.hasNotch)
        let insetOnly = HUDNotchGeometry(screenFrame: notched.screenFrame, visibleFrame: notched.visibleFrame,
                                          safeAreaInsetTop: 37, notchWidth: nil)
        XCTAssertFalse(insetOnly.hasNotch)
    }

    func testNotchRectIsNilWithoutANotch() {
        XCTAssertNil(plain.notchRect)
        XCTAssertNotNil(notched.notchRect)
    }

    func testNotchRectIsCenteredAtTheTopOfTheScreen() {
        guard let rect = notched.notchRect else { return XCTFail("expected a notch rect") }
        XCTAssertEqual(rect.width, 180)
        XCTAssertEqual(rect.height, 37)
        XCTAssertEqual(rect.midX, notched.screenFrame.midX, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, notched.screenFrame.maxY)
    }

    // MARK: - Top anchor edge

    func testTopAnchorYIsTheBottomOfTheHousingWhenPresent() {
        XCTAssertEqual(notched.topAnchorY, 982 - 37)
    }

    func testTopAnchorYIsTheMenuBarBottomWithoutANotch() {
        XCTAssertEqual(plain.topAnchorY, plain.visibleFrame.maxY)
    }

    func testTopAnchorYReachesTheScreenEdgeWhenTheMenuBarIsHidden() {
        // Full-screen app: visibleFrame grows to fill the screen.
        let fullscreen = HUDNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                           visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(fullscreen.topAnchorY, 1080)
    }

    // MARK: - Anchor frame

    func testAnchorFrameHangsFromTheNotch() {
        let f = notched.anchorFrame(for: panel)
        XCTAssertEqual(f.maxY, notched.topAnchorY)
        XCTAssertEqual(f.midX, notched.screenFrame.midX, accuracy: 0.001)
        XCTAssertEqual(f.size, panel)
    }

    func testAnchorFrameHangsFromTheMenuBarWithoutANotch() {
        let f = plain.anchorFrame(for: panel)
        XCTAssertEqual(f.maxY, plain.visibleFrame.maxY)
        XCTAssertEqual(f.midX, plain.screenFrame.midX, accuracy: 0.001)
    }

    func testAnchorFrameOnASecondaryScreenUsesThatScreensOrigin() {
        let f = secondary.anchorFrame(for: panel)
        XCTAssertEqual(f.maxY, secondary.visibleFrame.maxY)
        XCTAssertEqual(f.midX, secondary.screenFrame.midX, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(f.minX, secondary.screenFrame.minX)
    }

    // MARK: - Notch-body path

    func testBodyPathFillsExactlyTheGivenSize() {
        let path = HUDNotchGeometry.bodyPath(width: 180, height: 32, bottomRadius: 14)
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.width, 180, accuracy: 0.01)
        XCTAssertEqual(box.height, 32, accuracy: 0.01)
        XCTAssertEqual(box.minX, 0, accuracy: 0.01)
        XCTAssertEqual(box.minY, 0, accuracy: 0.01)
    }

    func testBodyPathHasSquareTopCornersByDefault() {
        // Flush with the housing: the default `topRadius` is 0, so the top-left corner point
        // itself is inside the fill, unlike a rounded corner which cuts it away.
        let path = HUDNotchGeometry.bodyPath(width: 180, height: 32, bottomRadius: 14)
        XCTAssertTrue(path.contains(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertTrue(path.contains(CGPoint(x: 179.5, y: 0.5)))
    }

    func testBodyPathRoundsTheBottomCorners() {
        let path = HUDNotchGeometry.bodyPath(width: 180, height: 32, bottomRadius: 14)
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 31.5)), "the bottom-left corner is cut by the radius")
        XCTAssertFalse(path.contains(CGPoint(x: 179.5, y: 31.5)), "the bottom-right corner is cut by the radius")
        XCTAssertTrue(path.contains(CGPoint(x: 90, y: 31.5)), "the bottom edge's middle is unaffected")
    }

    func testBodyPathTopRadiusSoftensTheTopCornersToo() {
        let path = HUDNotchGeometry.bodyPath(width: 22, height: 22, bottomRadius: 11, topRadius: 11)
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 0.5)), "a nonzero topRadius rounds the top corner away")
    }

    func testBodyPathInRectOffsetsTheSameShape() {
        let origin = HUDNotchGeometry.bodyPath(width: 180, height: 32, bottomRadius: 14)
        let offset = HUDNotchGeometry.bodyPath(in: CGRect(x: 40, y: 10, width: 180, height: 32), topRadius: 0, bottomRadius: 14)
        XCTAssertEqual(offset.boundingBoxOfPath, origin.boundingBoxOfPath.offsetBy(dx: 40, dy: 10))
    }
}
