import AppKit
import XCTest
@testable import HUDKit

/// `HUDDockStripView`'s backdrop: the window server's blur under a tint in the shape of
/// `outline` (one slab, a straight strip or an L), never a layer mask; the classic blur cut to
/// the outline by its `maskImage` where the server's call is missing; the border band along
/// the outline; hit testing outside the arms.
@MainActor
final class DockStripBackdropTests: XCTestCase {
    struct Call: Equatable {
        let window: Int
        let radius: Int
    }

    let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let items = ["a", "b", "c", "d", "e"].map { HUDDockItem(id: $0, title: $0, content: .dot(.red)) }
    var calls: [Call] = []
    var clock: ManualClock!
    var blur: HUDWindowBlur!
    var unavailable: HUDWindowBlur!

    override func setUp() async throws {
        calls = []
        clock = ManualClock()
        blur = HUDWindowBlur(setter: { [unowned self] window, radius in calls.append(Call(window: window, radius: radius)) },
                             scheduler: clock.scheduler, transparency: .fixed(reduced: false))
        unavailable = HUDWindowBlur(setter: nil, scheduler: clock.scheduler, transparency: .fixed(reduced: false))
    }

    private var edge: HUDDockPlacement { HUDDockStyle.standard.placement(groups: [3, 2], position: .bottom, in: visible).local }
    private var corner: HUDDockPlacement { HUDDockStyle.standard.placement(groups: [3, 2], position: .bottomLeft, in: visible).local }

    private func strip(_ p: HUDDockPlacement, blur: HUDWindowBlur? = nil) -> HUDDockStripView {
        let view = HUDDockStripView(frame: p.frame, style: .standard, windowBlur: blur ?? self.blur)
        view.apply(items: Array(items.prefix(p.items.count)), placement: p)
        return view
    }

    private func backdrop(_ strip: HUDDockStripView) throws -> HUDBackdropView {
        try XCTUnwrap(strip.subviews.first as? HUDBackdropView, "the backdrop is the bottom subview")
    }

    private func borderLayer(_ strip: HUDDockStripView) throws -> CAShapeLayer {
        let shapes = (strip.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        XCTAssertEqual(shapes.count, 1, "the border is the strip's one shape layer")
        return try XCTUnwrap(shapes.first)
    }

    private func assertEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.maxX, b.maxX), (a.maxY, b.maxY)] {
            XCTAssertEqual(x, y, accuracy: accuracy, "\(a) vs \(b)", file: file, line: line)
        }
    }

    func testTheStripIsNeverUnderALayerMask() throws {
        for p in [edge, corner] {
            let view = strip(p)
            XCTAssertNil(view.layer?.mask, "the strip's layer has no mask")
            XCTAssertNil(try backdrop(view).layer?.mask)
            XCTAssertNil(try borderLayer(view).mask)
        }
    }

    func testTheBackdropIsTheTintInTheOutline() throws {
        for p in [edge, corner] {
            let view = strip(p)
            XCTAssertEqual(view.backdropMaterial, .windowBlur)
            let back = try backdrop(view)
            XCTAssertEqual(back.material, .windowBlur)
            XCTAssertEqual(back.frame, view.bounds)
            XCTAssertEqual(back.shape, .path(view.outline))
            XCTAssertEqual(back.tintLayer.path, view.outline)
            XCTAssertEqual(view.subviews.filter { $0 is HUDBackdropView }.count, 1, "one slab, one backdrop")
        }
        // An L's tint covers both arms and leaves the rest of its box clear.
        let p = corner
        let path = try XCTUnwrap(try backdrop(strip(p)).tintLayer.path)
        let vertical = p.segments[0], horizontal = p.segments[1]
        XCTAssertTrue(path.contains(CGPoint(x: vertical.midX, y: vertical.maxY - 30)))
        XCTAssertTrue(path.contains(CGPoint(x: horizontal.maxX - 30, y: horizontal.midY)))
        XCTAssertTrue(path.contains(CGPoint(x: vertical.maxX + 2, y: horizontal.midY)), "the corner joins the arms")
        XCTAssertFalse(path.contains(CGPoint(x: vertical.maxX + 20, y: horizontal.maxY + 20)), "not the empty corner")
    }

    func testANewPlacementReshapesTheBackdrop() throws {
        let view = strip(edge)
        let back = try backdrop(view)
        let corner = self.corner
        view.frame = CGRect(origin: .zero, size: corner.frame.size)
        view.apply(items: Array(items.prefix(corner.items.count)), placement: corner)
        XCTAssertTrue(try backdrop(view) === back, "the same backdrop, reshaped")
        XCTAssertEqual(back.tintLayer.path, view.outline)
        let edge = HUDDockStyle.standard.placement(groups: [2], position: .left, in: visible).local
        view.frame = CGRect(origin: .zero, size: edge.frame.size)
        view.apply(items: Array(items.prefix(2)), placement: edge)
        XCTAssertEqual(back.tintLayer.path, view.outline)
        XCTAssertEqual(back.frame, view.bounds)
        XCTAssertTrue(view.tiles.allSatisfy { view.subviews.firstIndex(of: $0)! > 0 }, "the tiles stay above the backdrop")
    }

    func testARunMovesTheBackdropWithTheBorder() throws {
        let s = HUDDockStyle.standard
        let view = HUDDockStripView(frame: CGRect(x: 0, y: 0, width: 64, height: s.runLength(groups: [2, 1]) + 40),
                                    style: s, windowBlur: blur)
        view.apply(items: Array(items.prefix(3)), groups: [2, 1], edge: .left)
        // The strip grows (as its window animates): the tint and the border follow at once.
        view.frame.size.height += 100
        view.layoutSubtreeIfNeeded()
        let back = try backdrop(view)
        XCTAssertEqual(back.frame, view.bounds)
        assertEqual(try XCTUnwrap(back.tintLayer.path).boundingBoxOfPath, view.bounds)
        assertEqual(try XCTUnwrap(borderLayer(view).path).boundingBoxOfPath, view.bounds)
    }

    func testTheStripBlursItsWindow() throws {
        let p = corner
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: CGRect(x: screen.minX + 40, y: screen.minY + 40, width: p.frame.width, height: p.frame.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = strip(p)
        XCTAssertEqual(calls, [Call(window: window.windowNumber, radius: 25)])
        window.contentView = NSView()
        clock.advance(by: 0)
        XCTAssertEqual(calls.last, Call(window: window.windowNumber, radius: 0))
    }

    func testTheFallbackIsShapedByItsMaskImage() throws {
        let p = corner
        let view = strip(p, blur: unavailable)
        XCTAssertEqual(view.backdropMaterial, .visualEffect)
        XCTAssertNil(view.layer?.mask, "no layer mask on the fallback either")
        let effect = try XCTUnwrap(try backdrop(view).effectView)
        XCTAssertEqual(effect.material, .hudWindow)
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.state, .active)
        XCTAssertEqual(effect.frame, view.bounds)
        let mask = try XCTUnwrap(effect.maskImage, "shaped by maskImage")
        XCTAssertEqual(mask.size, view.bounds.size)
        let vertical = p.segments[0], horizontal = p.segments[1]
        XCTAssertGreaterThan(try alpha(mask, at: CGPoint(x: vertical.midX, y: vertical.maxY - 30)), 0.9, "on the vertical arm")
        XCTAssertGreaterThan(try alpha(mask, at: CGPoint(x: horizontal.maxX - 30, y: horizontal.midY)), 0.9, "on the horizontal arm")
        XCTAssertLessThan(try alpha(mask, at: CGPoint(x: view.bounds.maxX - 5, y: view.bounds.maxY - 5)), 0.1,
                          "clear outside the arms")
        XCTAssertLessThan(try alpha(mask, at: CGPoint(x: vertical.minX + 1, y: vertical.maxY - 1)), 0.1, "a rounded corner")
        // A new placement reshapes it.
        let q = HUDDockStyle.standard.placement(groups: [2], position: .left, in: visible).local
        view.frame = CGRect(origin: .zero, size: q.frame.size)
        view.apply(items: Array(items.prefix(2)), placement: q)
        let next = try XCTUnwrap(effect.maskImage)
        XCTAssertEqual(next.size, q.frame.size)
        XCTAssertGreaterThan(try alpha(next, at: CGPoint(x: q.frame.midX, y: q.frame.midY)), 0.9)
    }

    /// The mask's alpha at `point` (its own coordinates, origin bottom-left).
    private func alpha(_ image: NSImage, at point: CGPoint) throws -> CGFloat {
        let size = image.size
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        // Bitmap rows run top to bottom.
        return try XCTUnwrap(rep.colorAt(x: Int(point.x), y: Int(size.height - 1 - point.y))).alphaComponent
    }

    func testTheBorderIsABandJustInsideTheOutline() throws {
        for windowBlur in [blur!, unavailable!] {
            let p = corner
            let view = strip(p, blur: windowBlur)
            let border = try borderLayer(view)
            let band = try XCTUnwrap(border.path)
            XCTAssertNil(border.mask)
            assertEqual(band.boundingBoxOfPath, view.outline.boundingBoxOfPath)
            let half = HUDDockStyle.standard.borderWidth / 2
            let vertical = p.segments[0], horizontal = p.segments[1]
            // Along the vertical arm's outer side, and along the L's inner (concave) side.
            XCTAssertTrue(band.contains(CGPoint(x: vertical.minX + half / 2, y: vertical.midY)), "just inside the edge")
            XCTAssertFalse(band.contains(CGPoint(x: vertical.minX + half * 2, y: vertical.midY)), "the band is half the border wide")
            XCTAssertFalse(band.contains(CGPoint(x: vertical.midX, y: vertical.midY)), "not across the slab")
            XCTAssertTrue(band.contains(CGPoint(x: vertical.maxX - half / 2, y: vertical.maxY - 40)))
            XCTAssertFalse(band.contains(CGPoint(x: vertical.maxX + half / 2, y: vertical.maxY - 40)), "never outside the slab")
            XCTAssertTrue(band.contains(CGPoint(x: horizontal.maxX - 40, y: horizontal.maxY - half / 2)))
            XCTAssertEqual(border.fillColor, view.borderColor.cgColor)
        }
    }

    func testTheSnapshotDrawsTheBorderAsTheScreenDoes() throws {
        let p = corner
        let view = strip(p)
        let rep = try XCTUnwrap(view.snapshot(scale: 2))
        let vertical = p.segments[0]
        /// The pixel alpha at 2x for a point (view coordinates, origin bottom-left).
        func alpha(_ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
            try XCTUnwrap(rep.colorAt(x: Int(x * 2), y: rep.pixelsHigh - 1 - Int(y * 2))).alphaComponent
        }
        // The L's inner side at x = 64: the band is the half-point just inside it, nothing outside.
        let y = vertical.maxY - 40
        XCTAssertGreaterThan(try alpha(vertical.maxX - 0.25, y), 0.9, "the slab and its border")
        XCTAssertEqual(try alpha(vertical.maxX + 0.25, y), 0, "nothing outside the slab")
    }

    func testTheBorderIsABandOnAStraightStripToo() throws {
        let p = edge
        let view = strip(p)
        let band = try XCTUnwrap(try borderLayer(view).path)
        assertEqual(band.boundingBoxOfPath, view.bounds)
        let half = HUDDockStyle.standard.borderWidth / 2
        let arm = p.segments[0]
        for point in [CGPoint(x: arm.midX, y: arm.minY + half / 2), CGPoint(x: arm.midX, y: arm.maxY - half / 2),
                      CGPoint(x: arm.minX + half / 2, y: arm.midY), CGPoint(x: arm.maxX - half / 2, y: arm.midY)] {
            XCTAssertTrue(band.contains(point), "just inside every side: \(point)")
        }
        XCTAssertFalse(band.contains(CGPoint(x: arm.midX, y: arm.minY + half * 2)), "half the border wide")
        XCTAssertFalse(band.contains(CGPoint(x: arm.midX, y: arm.midY)), "not across the slab")
        XCTAssertFalse(band.contains(CGPoint(x: arm.minX + 1, y: arm.minY + 1)), "outside the rounded corner")
    }

    func testClicksOutsideTheArmsFallThrough() throws {
        let p = corner
        for windowBlur in [blur!, unavailable!] {
            let view = strip(p, blur: windowBlur)
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(contentRect: CGRect(x: screen.minX + 40, y: screen.minY + 40, width: p.frame.width, height: p.frame.height),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer {
                window.contentView = nil
                window.close()
            }
            view.layoutSubtreeIfNeeded()
            let superview = try XCTUnwrap(view.superview)
            let hit = { (local: CGPoint) in view.hitTest(view.convert(local, to: superview)) }
            let vertical = p.segments[0], horizontal = p.segments[1]
            XCTAssertNil(hit(CGPoint(x: vertical.maxX + 20, y: horizontal.maxY + 20)), "the empty part of the L's box")
            XCTAssertTrue(hit(CGPoint(x: vertical.minX + 3, y: vertical.midY)) === view, "an arm's background is the strip's")
            XCTAssertTrue(hit(CGPoint(x: horizontal.maxX - 3, y: horizontal.midY)) === view)
            let tile = view.tiles[0]
            XCTAssertTrue(hit(CGPoint(x: tile.frame.midX, y: tile.frame.midY))?.isDescendant(of: tile) == true, "an item")
        }
    }
}
