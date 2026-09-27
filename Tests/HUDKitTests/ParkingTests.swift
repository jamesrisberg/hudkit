import XCTest
@testable import HUDKit

final class ParkingTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let frame = CGRect(x: 100, y: 200, width: 300, height: 400)

    func testOffScreenFrames() {
        XCTAssertEqual(HUDParking.offScreenFrame(for: frame, edge: .left, peek: 8, in: screen),
                       CGRect(x: -292, y: 200, width: 300, height: 400))
        XCTAssertEqual(HUDParking.offScreenFrame(for: frame, edge: .right, peek: 8, in: screen),
                       CGRect(x: 992, y: 200, width: 300, height: 400))
        XCTAssertEqual(HUDParking.offScreenFrame(for: frame, edge: .top, peek: 10, in: screen),
                       CGRect(x: 100, y: 790, width: 300, height: 400))
        XCTAssertEqual(HUDParking.offScreenFrame(for: frame, edge: .bottom, peek: 10, in: screen),
                       CGRect(x: 100, y: -390, width: 300, height: 400))
    }

    func testPeekIsVisibleSliverOnSecondaryScreen() {
        let second = CGRect(x: 1000, y: -200, width: 1200, height: 900)
        let f = CGRect(x: 1500, y: 0, width: 200, height: 100)
        for edge in HUDEdge.allCases {
            let parked = HUDParking.offScreenFrame(for: f, edge: edge, peek: 6, in: second)
            let visible = parked.intersection(second)
            XCTAssertEqual(edge == .left || edge == .right ? visible.width : visible.height, 6, accuracy: 0.001, "\(edge)")
            XCTAssertEqual(parked.size, f.size)
        }
    }

    func testOtherAxisClampedAndPeekBounded() {
        let hanging = CGRect(x: 100, y: 700, width: 300, height: 400) // top overhangs
        XCTAssertEqual(HUDParking.offScreenFrame(for: hanging, edge: .left, peek: 5, in: screen).minY, 400)
        XCTAssertEqual(HUDParking.offScreenFrame(for: frame, edge: .left, peek: 1000, in: screen).minX, 0, "peek capped at the frame size")
        XCTAssertEqual(HUDParking.offScreenFrame(for: frame, edge: .right, peek: -5, in: screen).minX, 1000)
    }

    func testRestFrame() {
        XCTAssertEqual(HUDParking.restFrame(for: frame, in: screen), frame)
        XCTAssertEqual(HUDParking.restFrame(for: CGRect(x: -292, y: 200, width: 300, height: 400), in: screen).origin, CGPoint(x: 0, y: 200))
        XCTAssertEqual(HUDParking.restFrame(for: CGRect(x: 900, y: 700, width: 300, height: 400), in: screen).origin, CGPoint(x: 700, y: 400))
        XCTAssertEqual(HUDParking.restFrame(for: CGRect(x: 50, y: 50, width: 2000, height: 100), in: screen).origin, CGPoint(x: 0, y: 50))
        // Parking then resting round-trips to an on-screen frame of the same size.
        for edge in HUDEdge.allCases {
            let parked = HUDParking.offScreenFrame(for: frame, edge: edge, peek: 8, in: screen)
            XCTAssertTrue(screen.contains(HUDParking.restFrame(for: parked, in: screen)))
        }
    }

    func testNearestEdge() {
        XCTAssertEqual(HUDParking.nearestEdge(for: CGRect(x: 10, y: 300, width: 50, height: 50), in: screen), .left)
        XCTAssertEqual(HUDParking.nearestEdge(for: CGRect(x: 940, y: 300, width: 50, height: 50), in: screen), .right)
        XCTAssertEqual(HUDParking.nearestEdge(for: CGRect(x: 400, y: 760, width: 50, height: 30), in: screen), .top)
        XCTAssertEqual(HUDParking.nearestEdge(for: CGRect(x: 400, y: 5, width: 50, height: 30), in: screen), .bottom)
    }

    func testTimings() {
        XCTAssertEqual(HUDAnimation.revealDuration, 0.22)
        XCTAssertEqual(HUDAnimation.concealDuration, 0.18)
    }

    func testSpringSettles() {
        var s = HUDSpring(0)
        s.target = 100
        var settled = false
        for _ in 0..<600 where !settled { settled = s.step(dt: 1.0 / 120, stiffness: 260, damping: 0.72, epsilon: 0.2) }
        XCTAssertTrue(settled)
        XCTAssertEqual(s.value, 100)
        s.jump(to: 5)
        XCTAssertEqual(s, { var t = HUDSpring(5); t.velocity = 0; return t }())
    }
}
