import XCTest
import AppKit
@testable import HUDKit

final class DockSnapTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    func testPositionBasics() throws {
        XCTAssertEqual(HUDDockPosition.allCases.count, 8)
        XCTAssertEqual(HUDDockPosition.allCases.filter(\.isCorner).count, 4)
        XCTAssertEqual(HUDDockPosition.topLeft.edges, [.top, .left])
        XCTAssertEqual(HUDDockPosition.bottomRight.edges, [.bottom, .right])
        XCTAssertEqual(HUDDockPosition.left.edges, [.left])
        XCTAssertEqual(HUDDockPosition(corner: .left, .bottom), .bottomLeft)
        XCTAssertNil(HUDDockPosition(corner: .left, .right))
        let data = try JSONEncoder().encode([HUDDockPosition.topLeft])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"["topLeft"]"#)
        XCTAssertEqual(try JSONDecoder().decode([HUDDockPosition].self, from: data), [.topLeft])
    }

    func testNearestSectors() {
        func at(_ fx: CGFloat, _ fy: CGFloat) -> HUDDockPosition {
            HUDDockPosition.nearest(to: CGPoint(x: screen.width * fx, y: screen.height * fy), in: screen)
        }
        XCTAssertEqual(at(0.5, 0.98), .top)
        XCTAssertEqual(at(0.5, 0.02), .bottom)
        XCTAssertEqual(at(0.02, 0.5), .left)
        XCTAssertEqual(at(0.98, 0.5), .right)
        XCTAssertEqual(at(0.1, 0.95), .topLeft)
        XCTAssertEqual(at(0.9, 0.95), .topRight)
        XCTAssertEqual(at(0.1, 0.05), .bottomLeft)
        XCTAssertEqual(at(0.95, 0.1), .bottomRight)
        // Near the left edge but within 25% of its length from the top: the corner.
        XCTAssertEqual(at(0.02, 0.8), .topLeft)
        XCTAssertEqual(at(0.02, 0.7), .left)
        // Sector boundary is 25% of the edge length: just inside/outside on the top edge.
        XCTAssertEqual(at(0.24, 0.99), .topLeft)
        XCTAssertEqual(at(0.26, 0.99), .top)
        XCTAssertEqual(at(0.76, 0.99), .topRight)
        // Outside the rect clamps; offset screens work.
        XCTAssertEqual(HUDDockPosition.nearest(to: CGPoint(x: 800, y: 5000), in: screen), .top)
        let second = CGRect(x: 1600, y: -300, width: 1000, height: 800)
        XCTAssertEqual(HUDDockPosition.nearest(to: CGPoint(x: 2590, y: -290), in: second), .bottomRight)
        XCTAssertEqual(HUDDockPosition.nearest(to: CGPoint(x: 2100, y: 490), in: second), .top)
    }

    func testEdgeFrames() {
        let insets = NSEdgeInsets(top: 4, left: 6, bottom: 8, right: 10)
        XCTAssertEqual(HUDDockLayout.frame(for: .top, thickness: 50, length: 400, insets: insets, in: screen),
                       CGRect(x: 598, y: 946, width: 400, height: 50))
        XCTAssertEqual(HUDDockLayout.frame(for: .bottom, thickness: 50, length: 400, insets: insets, in: screen),
                       CGRect(x: 598, y: 8, width: 400, height: 50))
        XCTAssertEqual(HUDDockLayout.frame(for: .left, thickness: 50, length: 300, insets: insets, in: screen),
                       CGRect(x: 6, y: 352, width: 50, height: 300))
        XCTAssertEqual(HUDDockLayout.frame(for: .right, thickness: 50, length: 300, insets: insets, in: screen),
                       CGRect(x: 1540, y: 352, width: 50, height: 300))
        // Too long clamps to the inset area.
        XCTAssertEqual(HUDDockLayout.frame(for: .left, thickness: 50, length: 5000, in: screen).height, 1000)
    }

    func testCornerFramesAndLArms() {
        for position in HUDDockPosition.allCases where position.isCorner {
            let l = HUDDockLayout.lShape(position: position, thickness: 40, verticalLength: 300,
                                         horizontalLength: 500, in: screen)
            XCTAssertEqual(l.corner.size, CGSize(width: 40, height: 40), "\(position)")
            XCTAssertEqual(l.vertical.size, CGSize(width: 40, height: 300), "\(position)")
            XCTAssertEqual(l.horizontal.size, CGSize(width: 500, height: 40), "\(position)")
            XCTAssertEqual(l.vertical.intersection(l.horizontal), l.corner, "arms overlap only in the corner: \(position)")
            XCTAssertTrue(screen.contains(l.vertical) && screen.contains(l.horizontal), "\(position)")
            // The corner square touches both of the position's edges.
            for edge in position.edges {
                switch edge {
                case .top: XCTAssertEqual(l.corner.maxY, screen.maxY)
                case .bottom: XCTAssertEqual(l.corner.minY, screen.minY)
                case .left: XCTAssertEqual(l.corner.minX, screen.minX)
                case .right: XCTAssertEqual(l.corner.maxX, screen.maxX)
                }
            }
            let bounds = HUDDockLayout.frame(for: position, thickness: 40, length: 300, in: screen)
            XCTAssertEqual(bounds.size, CGSize(width: 300, height: 300), "\(position)")
        }
        let tl = HUDDockLayout.lShape(position: .topLeft, thickness: 40, verticalLength: 300, horizontalLength: 500,
                                      insets: NSEdgeInsets(top: 10, left: 20, bottom: 0, right: 0), in: screen)
        XCTAssertEqual(tl.corner, CGRect(x: 20, y: 950, width: 40, height: 40))
        XCTAssertEqual(tl.vertical, CGRect(x: 20, y: 690, width: 40, height: 300))
        XCTAssertEqual(tl.horizontal, CGRect(x: 20, y: 950, width: 500, height: 40))
        // Arms never shorter than the corner.
        let tiny = HUDDockLayout.lShape(position: .bottomRight, thickness: 40, verticalLength: 1, horizontalLength: 0, in: screen)
        XCTAssertEqual(tiny.vertical, tiny.corner)
        XCTAssertEqual(tiny.horizontal, tiny.corner)
    }

    func testEdgePositionLShapeIsSingleArm() {
        let l = HUDDockLayout.lShape(position: .top, thickness: 40, verticalLength: 300, horizontalLength: 500, in: screen)
        XCTAssertEqual(l.horizontal, HUDDockLayout.frame(for: .top, thickness: 40, length: 500, in: screen))
        XCTAssertEqual(l.vertical, .zero)
    }

    func testItemFrames() {
        let arm = CGRect(x: 100, y: 0, width: 200, height: 40)
        let centered = HUDDockLayout.itemFrames(count: 3, itemSize: CGSize(width: 32, height: 32), spacing: 8,
                                                along: arm, axis: .horizontal)
        XCTAssertEqual(centered.map(\.minX), [144, 184, 224])
        XCTAssertEqual(centered.map(\.minY), [4, 4, 4])
        let leading = HUDDockLayout.itemFrames(count: 2, itemSize: CGSize(width: 32, height: 32), spacing: 8,
                                               along: arm, axis: .horizontal, alignment: .leading)
        XCTAssertEqual(leading.map(\.minX), [100, 140])

        let column = CGRect(x: 0, y: 100, width: 40, height: 300)
        let down = HUDDockLayout.itemFrames(count: 2, itemSize: CGSize(width: 32, height: 32), spacing: 8,
                                            along: column, axis: .vertical, alignment: .leading)
        XCTAssertEqual(down.map(\.maxY), [400, 360], "vertical arms run top to bottom")
        XCTAssertEqual(down.first?.minX, 4)
        let up = HUDDockLayout.itemFrames(count: 2, itemSize: CGSize(width: 32, height: 32), spacing: 8,
                                          along: column, axis: .vertical, alignment: .trailing)
        XCTAssertEqual(up.last?.minY, 100)
        XCTAssertEqual(HUDDockLayout.itemFrames(count: 0, itemSize: .zero, spacing: 0, along: arm, axis: .horizontal), [])
    }

    func testCornerAlignmentPacksTowardCorner() {
        for position in HUDDockPosition.allCases where position.isCorner {
            let l = HUDDockLayout.lShape(position: position, thickness: 40, verticalLength: 400, horizontalLength: 400, in: screen)
            for (arm, axis) in [(l.vertical, HUDDockAxis.vertical), (l.horizontal, .horizontal)] {
                let items = HUDDockLayout.itemFrames(count: 2, itemSize: CGSize(width: 40, height: 40), spacing: 0, along: arm,
                                                     axis: axis, alignment: HUDDockLayout.cornerAlignment(for: position, axis: axis))
                XCTAssertTrue(items.contains(l.corner), "\(position) \(axis)")
            }
        }
        XCTAssertEqual(HUDDockLayout.cornerAlignment(for: .top, axis: .horizontal), .center)
    }

    func testPanelFrameBesideAnchor() {
        let button = CGRect(x: 780, y: 950, width: 40, height: 40)
        XCTAssertEqual(HUDDockLayout.panelFrame(size: CGSize(width: 200, height: 100), anchor: button, from: .top, in: screen),
                       CGRect(x: 700, y: 842, width: 200, height: 100))
        let left = CGRect(x: 0, y: 10, width: 40, height: 40)
        XCTAssertEqual(HUDDockLayout.panelFrame(size: CGSize(width: 200, height: 100), anchor: left, from: .left, in: screen),
                       CGRect(x: 48, y: 0, width: 200, height: 100), "clamped on screen")
    }

    func testCornerPanelSitsInTheCrook() {
        let size = CGSize(width: 300, height: 200)
        for position in HUDDockPosition.allCases where position.isCorner {
            let l = HUDDockLayout.lShape(position: position, thickness: 40, verticalLength: 200, horizontalLength: 300, in: screen)
            let top = position == .topLeft || position == .topRight
            let left = position == .topLeft || position == .bottomLeft
            // The corner button and the one after it on the vertical arm.
            for step in [0, 1] as [CGFloat] {
                let anchor = l.corner.offsetBy(dx: 0, dy: (top ? -40 : 40) * step)
                let f = HUDDockLayout.panelFrame(size: size, anchor: anchor, dockFrames: [l.vertical, l.horizontal],
                                                 from: position.edges[1], gap: 8, in: screen)
                XCTAssertEqual(f.size, size, "\(position)")
                XCTAssertFalse(f.intersects(l.vertical.insetBy(dx: -7, dy: -7)), "\(position) clear of the vertical arm")
                XCTAssertFalse(f.intersects(l.horizontal.insetBy(dx: -7, dy: -7)), "\(position) clear of the horizontal arm")
                XCTAssertEqual(left ? f.minX : f.maxX, left ? l.vertical.maxX + 8 : l.vertical.minX - 8, "\(position) beside the vertical arm")
                if step == 0 {
                    XCTAssertEqual(top ? f.maxY : f.minY, top ? l.horizontal.minY - 8 : l.horizontal.maxY + 8,
                                   "\(position) tucked against the horizontal arm")
                }
                XCTAssertTrue(screen.contains(f), "\(position)")
            }
        }
        // Far enough down the vertical arm the panel centres on its button again.
        let l = HUDDockLayout.lShape(position: .topLeft, thickness: 40, verticalLength: 800, horizontalLength: 300, in: screen)
        let anchor = CGRect(x: 0, y: 500, width: 40, height: 40)
        let f = HUDDockLayout.panelFrame(size: CGSize(width: 300, height: 200), anchor: anchor,
                                         dockFrames: [l.vertical, l.horizontal], from: .left, in: screen)
        XCTAssertEqual(f, CGRect(x: 48, y: 420, width: 300, height: 200))
    }

    func testEdgePanelNeverCoversTheBar() {
        for position in [HUDDockPosition.top, .bottom, .left, .right] {
            let bar = HUDDockLayout.frame(for: position, thickness: 40, length: 400, in: screen)
            let edge = position.edges[0]
            let horizontal = edge == .top || edge == .bottom
            let anchor = horizontal ? CGRect(x: bar.minX + 40, y: bar.minY, width: 40, height: bar.height)
                                    : CGRect(x: bar.minX, y: bar.maxY - 80, width: bar.width, height: 40)
            // Normal size: beside the bar, centred on the button.
            let f = HUDDockLayout.panelFrame(size: CGSize(width: 300, height: 200), anchor: anchor, dockFrames: [bar],
                                             from: edge, in: screen)
            XCTAssertFalse(f.intersects(bar), "\(position)")
            XCTAssertEqual(horizontal ? f.midX : f.midY, horizontal ? anchor.midX : anchor.midY, "\(position)")
            // Bigger than the screen: shrunk into the room, never slid over the bar.
            let huge = HUDDockLayout.panelFrame(size: CGSize(width: 5000, height: 5000), anchor: anchor, dockFrames: [bar],
                                                from: edge, in: screen)
            XCTAssertFalse(huge.intersects(bar.insetBy(dx: -7, dy: -7)), "\(position)")
            XCTAssertTrue(screen.contains(huge), "\(position)")
        }
    }
}
