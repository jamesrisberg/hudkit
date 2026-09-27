import AppKit
import XCTest
@testable import HUDKit

/// `HUDDockStyle` (the MacHUD tool dock's measurements), its run and L geometry, and
/// `HUDDockStripView` laying tiles out from it.
final class DockStripTests: XCTestCase {
    let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    func testStandardIsTheToolDock() {
        let s = HUDDockStyle.standard
        XCTAssertEqual(s.itemSize, 44)
        XCTAssertEqual(s.padding, 10, "the indicator sits in 10 pt of padding")
        XCTAssertEqual(s.spacing, 6)
        XCTAssertEqual(s.thickness, 64)
        XCTAssertEqual(s.dividerRoom, 7)
        XCTAssertEqual(s.cornerRadius, 18)
        XCTAssertEqual(s.borderWidth, 1)
        XCTAssertEqual(s.borderAlphaDark, 0.18)
        XCTAssertEqual(s.borderAlphaLight, 0.12)
        XCTAssertEqual(s.magnification, 1.15)
        XCTAssertEqual(s.magnifyDuration, 0.12)
        XCTAssertEqual(s.indicatorSize, 4)
        XCTAssertEqual(s.dividerAlpha, 0.25)
        XCTAssertEqual(s.pressedAlpha, 0.6)
        XCTAssertEqual(s.highlightRadius, 10)
        XCTAssertEqual(s.fallbackMaterial, .popover)
        // Proportions follow the icon size.
        let small = s.withItemSize(30)
        XCTAssertEqual(small.padding, 7)
        XCTAssertEqual(small.spacing, 4)
        XCTAssertEqual(small.thickness, 44)
        XCTAssertEqual(small.cornerRadius, 18)
    }

    func testRunLengthAndOffsets() {
        let s = HUDDockStyle.standard
        XCTAssertEqual(s.runLength(groups: []), 64, "empty: a square")
        XCTAssertEqual(s.runLength(groups: [3]), 164)
        // Two groups: 6 spacing + 7 divider room + 6 spacing between them.
        XCTAssertEqual(s.runLength(groups: [2, 1]), 177)
        XCTAssertEqual(s.runLength(groups: [2, 0, 1]), s.runLength(groups: [2, 1]), "empty groups take no divider")
        XCTAssertEqual(s.itemOffsets(groups: [2, 1]), [10, 60, 123])
        let d = s.dividerOffsets(groups: [2, 1])
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0] + 0.5, 113.5, "the divider is centred in the gap (104…123)")
    }

    func testRunMatchesItemFrames() {
        // A single group laid along an arm is HUDDockLayout.itemFrames on the arm less its padding.
        let s = HUDDockStyle.standard
        for edge in HUDEdge.allCases {
            let horizontal = HUDDockAxis(edge: edge) == .horizontal
            let len = s.runLength(groups: [4])
            let arm = horizontal ? CGRect(x: 100, y: 6, width: len, height: 64) : CGRect(x: 6, y: 100, width: 64, height: len)
            let p = s.run(groups: [4], in: arm, edge: edge)
            let inner = horizontal ? arm.insetBy(dx: s.padding, dy: 0) : arm.insetBy(dx: 0, dy: s.padding)
            let expected = HUDDockLayout.itemFrames(count: 4, itemSize: CGSize(width: 44, height: 44), spacing: s.spacing,
                                                    along: inner, axis: HUDDockAxis(edge: edge), alignment: .leading)
            XCTAssertEqual(p.items, expected, "\(edge)")
            XCTAssertEqual(p.itemEdges, Array(repeating: edge, count: 4))
        }
    }

    func testEdgePlacement() {
        let s = HUDDockStyle.standard
        let insets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        let p = s.placement(groups: [5, 2], position: .bottom, insets: insets, in: visible)
        let len = s.runLength(groups: [5, 2])
        XCTAssertEqual(p.frame, CGRect(x: 800 - len / 2, y: 6, width: len, height: 64))
        XCTAssertEqual(p.items.count, 7)
        XCTAssertEqual(p.items[0], CGRect(x: p.frame.minX + 10, y: 16, width: 44, height: 44))
        // As the tool dock drew it: 263 pt along, 8 pt in from the long sides.
        XCTAssertEqual(p.dividers, [CGRect(x: p.frame.minX + 263, y: 14, width: 1, height: 48)])
        XCTAssertEqual(p.local.frame.origin, .zero)
        XCTAssertEqual(p.local.items[0], CGRect(x: 10, y: 10, width: 44, height: 44))
    }

    func testCornerIsAnL() {
        let s = HUDDockStyle.standard
        let p = s.placement(groups: [3, 2], position: .bottomLeft, in: visible)
        XCTAssertEqual(p.segments.count, 2)
        let vertical = p.segments[0], horizontal = p.segments[1]
        XCTAssertEqual(vertical, CGRect(x: 0, y: 0, width: 64, height: s.runLength(groups: [3])))
        XCTAssertEqual(horizontal, CGRect(x: 0, y: 0, width: s.runLength(groups: [1, 2]), height: 64))
        XCTAssertEqual(p.items[0], CGRect(x: 10, y: 10, width: 44, height: 44), "the first item sits in the corner")
        XCTAssertEqual(p.itemEdges, [.left, .left, .left, .bottom, .bottom])
        XCTAssertEqual(p.dividers.count, 1)
        XCTAssertEqual(p.arm(for: 4), horizontal)
        // One group: just its arm.
        XCTAssertEqual(s.placement(groups: [0, 2], position: .topRight, in: visible).segments.count, 1)
    }

    func testFittedShrinksToTheSpan() {
        let s = HUDDockStyle.standard
        let fitted = s.fitted(groups: [30], position: .bottom, span: CGSize(width: 1000, height: 1000))
        XCTAssertLessThan(fitted.itemSize, 44)
        XCTAssertLessThanOrEqual(fitted.runLength(groups: [30]), 1000)
        XCTAssertGreaterThan(fitted.withItemSize(fitted.itemSize + 2).runLength(groups: [30]), 1000, "the largest that fits")
        XCTAssertEqual(s.fitted(groups: [3], position: .bottom, span: CGSize(width: 1000, height: 1000)), s, "never grown")
    }

    func testIndicatorAndMagnification() {
        let s = HUDDockStyle.standard
        let item = CGRect(x: 10, y: 10, width: 44, height: 44)
        XCTAssertEqual(s.indicatorCentre(for: item, edge: .bottom), CGPoint(x: 32, y: 5))
        XCTAssertEqual(s.indicatorRect(for: item, edge: .left), CGRect(x: 3, y: 30, width: 4, height: 4))
        let grown = s.magnified(item, edge: .bottom)
        XCTAssertEqual(grown.minY, item.minY, "grows away from the edge")
        XCTAssertEqual(grown.width, 44 * 1.15, accuracy: 0.001)
        XCTAssertEqual(grown.midX, item.midX, accuracy: 0.001)
    }

    @MainActor
    func testStripViewPlacesTiles() {
        let s = HUDDockStyle.standard
        let p = s.placement(groups: [2, 1], position: .bottom, in: visible).local
        let view = HUDDockStripView(frame: p.frame)
        let items = ["a", "b", "c"].map { HUDDockItem(id: $0, title: $0, content: .symbol("star")) }
        view.apply(items: items, placement: p)
        XCTAssertEqual(view.tiles.map(\.frame), p.items)
        XCTAssertEqual(view.tiles.map(\.item.id), ["a", "b", "c"])
        let first = view.tiles[0]
        // Same ids: tiles are kept; a badge shows.
        var next = items
        next[0].badge = 12
        view.apply(items: next, placement: p)
        XCTAssertTrue(view.tiles[0] === first)
        XCTAssertFalse(first.badgeView.isHidden)
        XCTAssertEqual(first.badgeView.text, "12")
        XCTAssertGreaterThan(first.badgeView.frame.maxX, first.frame.maxX, "the badge overhangs the icon's corner")
        view.setIndicators(["b": .running])
        XCTAssertEqual(view.tiles[1].item.indicator, .running)
        XCTAssertEqual(view.tiles[0].item.indicator, .none)
        XCTAssertNotNil(view.snapshot(scale: 1))
    }

    @MainActor
    func testStripViewRunFillsItsBounds() {
        let s = HUDDockStyle.standard
        let len = s.runLength(groups: [1, 3, 1])
        let view = HUDDockStripView(frame: CGRect(x: 0, y: 0, width: 64, height: len + 40))
        let items = (0..<5).map { HUDDockItem(id: "\($0)", title: "", content: .dot(.red)) }
        view.apply(items: items, groups: [1, 3, 1], edge: .left)
        XCTAssertEqual(view.effectiveStyle, s)
        XCTAssertEqual(view.tiles[0].frame, CGRect(x: 10, y: len + 40 - 20 - 10 - 44, width: 44, height: 44),
                       "centred along, from the top")
        XCTAssertEqual(view.placement.dividers.count, 2)
        // Too short: the icons shrink to fit.
        view.frame.size.height = len - 40
        view.layoutSubtreeIfNeeded()
        view.apply(items: items, groups: [1, 3, 1], edge: .left)
        XCTAssertLessThan(view.effectiveStyle.itemSize, 44)
        XCTAssertEqual(view.tiles[0].frame.width, view.effectiveStyle.itemSize)
    }

    @MainActor
    func testSnapUsesThePointersScreen() {
        guard let screen = NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        XCTAssertEqual(HUDDockStripView.snap(CGPoint(x: v.midX, y: v.minY + 5), screens: [screen]).position, .bottom)
        XCTAssertEqual(HUDDockStripView.snap(CGPoint(x: v.minX + 5, y: v.maxY - 5), screens: [screen]).position, .topLeft)
    }
}
