import AppKit
import XCTest
@testable import HUDKit

/// `HUDDockStripView`'s press handling (click vs drag, hover reports) driven by synthesized
/// events, and its hover labels: placement and the show/hide machine.
@MainActor
final class DockStripInteractionTests: XCTestCase {
    final class Recorder: HUDDockStripDelegate {
        var log: [String] = []
        func dockStrip(_ strip: HUDDockStripView, didClick item: HUDDockItem, tile: HUDDockTile) { log.append("click \(item.id)") }
        func dockStripDidBeginDrag(_ strip: HUDDockStripView) { log.append("begin") }
        func dockStrip(_ strip: HUDDockStripView, didDragTo position: HUDDockPosition, at point: CGPoint, on screen: NSScreen?) {
            log.append("dragTo")
        }
        func dockStripDidEndDrag(_ strip: HUDDockStripView) { log.append("end") }
        func dockStrip(_ strip: HUDDockStripView, didHover item: HUDDockItem?) { log.append("hover \(item?.id ?? "-")") }
    }

    var window: NSWindow!
    var strip: HUDDockStripView!
    var recorder: Recorder!

    override func setUp() async throws {
        let p = HUDDockStyle.standard.placement(groups: [2], position: .bottom,
                                                in: CGRect(x: 0, y: 0, width: 400, height: 300)).local
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: p.frame.width, height: p.frame.height),
                          styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        strip = HUDDockStripView(frame: CGRect(origin: .zero, size: p.frame.size))
        window.contentView = strip
        strip.apply(items: ["a", "b"].map { HUDDockItem(id: $0, title: "\($0.uppercased()): does things", content: .dot(.red)) },
                    placement: p)
        recorder = Recorder()
        strip.delegate = recorder
    }

    override func tearDown() async throws {
        window.contentView = nil
        window.close()
    }

    private func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func enter(_ tile: HUDDockTile, _ on: Bool = true) {
        let e = NSEvent.enterExitEvent(with: on ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                                       userData: nil)!
        if on { tile.mouseEntered(with: e) } else { tile.mouseExited(with: e) }
    }

    private var background: CGPoint { CGPoint(x: 3, y: 3) }
    private func centre(_ tile: HUDDockTile) -> CGPoint { CGPoint(x: tile.frame.midX, y: tile.frame.midY) }

    func testItemLabelDefaultsToTheTitlesFirstSegment() {
        XCTAssertEqual(HUDDockItem(id: "x", title: "Trash: drop files here", content: .dot(.red)).label, "Trash")
        XCTAssertEqual(HUDDockItem(id: "x", title: "Sift — Downloads", content: .dot(.red)).label, "Sift")
        XCTAssertEqual(HUDDockItem(id: "x", title: "Plain", content: .dot(.red)).label, "Plain")
        XCTAssertNil(HUDDockItem(id: "x", title: "", content: .dot(.red)).label)
        XCTAssertNil(HUDDockItem(id: "x", title: "A", content: .dot(.red), label: .none).label)
        XCTAssertEqual(HUDDockItem(id: "x", title: "A", content: .dot(.red), label: .text("B")).label, "B")
        // A labelled item has no native tooltip; an unlabelled one keeps its title as one.
        XCTAssertNil(strip.tiles[0].toolTip)
        var items = strip.items
        items[0].label = nil
        strip.apply(items: items, placement: strip.placement)
        XCTAssertEqual(strip.tiles[0].toolTip, "A: does things")
    }

    func testTileClickWithinTheThreshold() {
        let tile = strip.tiles[0]
        let c = centre(tile)
        tile.mouseDown(with: event(.leftMouseDown, c))
        XCTAssertTrue(tile.isPressed)
        tile.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: c.x + 3, y: c.y + 2)))
        XCTAssertFalse(strip.isDragging, "3.6 pt is still a click")
        XCTAssertEqual(window.frame.origin, CGPoint(x: 200, y: 200))
        tile.mouseUp(with: event(.leftMouseUp, CGPoint(x: c.x + 3, y: c.y + 2)))
        XCTAssertEqual(recorder.log, ["click a"])
        XCTAssertFalse(tile.isPressed)
    }

    func testTileDragMovesTheStripAndIsNotAClick() {
        let tile = strip.tiles[0]
        let c = centre(tile)
        tile.mouseDown(with: event(.leftMouseDown, c))
        tile.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: c.x + 5, y: c.y)))
        XCTAssertTrue(strip.isDragging)
        XCTAssertFalse(tile.isPressed, "a drag is not a press on the item")
        XCTAssertEqual(window.frame.origin, CGPoint(x: 205, y: 200))
        // The window moved with the pointer, so the pointer is at the same place in it.
        tile.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: c.x + 5, y: c.y + 30)))
        XCTAssertEqual(window.frame.origin, CGPoint(x: 210, y: 230))
        tile.mouseUp(with: event(.leftMouseUp, CGPoint(x: c.x, y: c.y)))
        XCTAssertEqual(recorder.log, ["begin", "dragTo", "end"], "one begin, no click")
        XCTAssertFalse(strip.isDragging)
    }

    func testBackgroundPressIsAClickUntilItMoves() {
        strip.mouseDown(with: event(.leftMouseDown, background))
        strip.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: background.x + 4, y: background.y)))
        strip.mouseUp(with: event(.leftMouseUp, CGPoint(x: background.x + 4, y: background.y)))
        XCTAssertEqual(recorder.log, [], "a background click is nothing: no drag, no snap")
        strip.mouseDown(with: event(.leftMouseDown, background))
        strip.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: background.x, y: background.y + 40)))
        strip.mouseDragged(with: event(.leftMouseDragged, background))
        XCTAssertEqual(recorder.log, ["begin"], "begins once")
        XCTAssertEqual(window.frame.origin, CGPoint(x: 200, y: 240))
        strip.mouseUp(with: event(.leftMouseUp, background))
        XCTAssertEqual(recorder.log, ["begin", "dragTo", "end"])
    }

    func testHoverReportsPauseDuringADrag() {
        let a = strip.tiles[0], b = strip.tiles[1]
        enter(a)
        XCTAssertEqual(recorder.log, ["hover a"])
        strip.mouseDown(with: event(.leftMouseDown, background))
        strip.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: background.x + 10, y: background.y)))
        enter(a, false)
        enter(b)
        XCTAssertEqual(recorder.log, ["hover a", "begin"], "no hover reports while dragging")
        strip.mouseUp(with: event(.leftMouseUp, background))
        XCTAssertEqual(recorder.log, ["hover a", "begin", "dragTo", "end", "hover b"], "resumed with what is under the pointer")
        enter(b, false)
        XCTAssertEqual(recorder.log.last, "hover -")
    }

    func testLabelShowsAfterRestingAndHidesOnClickAndDrag() {
        strip.now = { 100 }
        let a = strip.tiles[0], b = strip.tiles[1]
        enter(a)
        XCTAssertNil(strip.shownLabel)
        strip.fireLabel(now: 100.2)
        XCTAssertNil(strip.shownLabel, "not before 250 ms")
        strip.fireLabel(now: 100.25)
        XCTAssertEqual(strip.shownLabel, "a")
        enter(a, false)
        enter(b)
        XCTAssertEqual(strip.shownLabel, "b", "moves at once to the next item")
        // A click hides it, and it stays hidden on that item.
        b.mouseDown(with: event(.leftMouseDown, centre(b)))
        b.mouseUp(with: event(.leftMouseUp, centre(b)))
        XCTAssertNil(strip.shownLabel)
        strip.fireLabel(now: 200)
        XCTAssertNil(strip.shownLabel)
        // Another item: shows again after the delay; a drag hides it.
        enter(b, false)
        enter(a)
        strip.fireLabel(now: 101)
        XCTAssertEqual(strip.shownLabel, "a")
        strip.mouseDown(with: event(.leftMouseDown, background))
        strip.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: background.x + 10, y: background.y)))
        XCTAssertNil(strip.shownLabel)
        strip.mouseUp(with: event(.leftMouseUp, background))
        strip.fireLabel(now: 300)
        XCTAssertNil(strip.shownLabel, "not back on the item the drag ended on")
        enter(a, false)
        XCTAssertEqual(strip.labelState.hovered, nil)
        // Leaving the strip hides at once; an item without a label hides it too.
        enter(b)
        strip.fireLabel(now: 400)
        XCTAssertEqual(strip.shownLabel, "b")
        strip.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       trackingNumber: 0, userData: nil)!)
        XCTAssertNil(strip.shownLabel)
    }

    func testLabelMachine() {
        var m = HUDDockLabelState()
        XCTAssertEqual(m.hover("a", now: 0), [])
        XCTAssertEqual(m.deadline, 0.25)
        XCTAssertEqual(m.hover("b", now: 0.2), [], "moving before it shows restarts the wait")
        XCTAssertEqual(m.fire(now: 0.3), [])
        XCTAssertEqual(m.fire(now: 0.45), [.show("b")])
        XCTAssertNil(m.deadline)
        XCTAssertEqual(m.hover(nil, now: 0.9), [], "between items it waits")
        XCTAssertEqual(m.deadline, 1.2)
        XCTAssertEqual(m.hover("a", now: 1), [.move("a")])
        XCTAssertEqual(m.hover(nil, now: 1.1), [])
        XCTAssertEqual(m.fire(now: 1.4), [.hide], "the grace ran out")
        XCTAssertEqual(m.hover("b", now: 1.5), [])
        XCTAssertEqual(m.fire(now: 1.75), [.show("b")])
        XCTAssertEqual(m.exit(), [.hide], "off the strip: at once")
        XCTAssertEqual(m.hover("a", now: 2), [])
        XCTAssertEqual(m.dismiss(), [], "dismissed before it showed")
        XCTAssertEqual(m.fire(now: 3), [])
        XCTAssertEqual(m.hover(nil, now: 3), [])
        XCTAssertEqual(m.hover("a", now: 4), [], "suppression ends when the pointer leaves")
        XCTAssertEqual(m.fire(now: 4.25), [.show("a")])
        XCTAssertEqual(m.dismiss(), [.hide])
        XCTAssertEqual(m.hover("b", now: 5), [])
        XCTAssertEqual(m.fire(now: 5.25), [.show("b")])
    }

    func testLabelPlacementPerEdge() {
        let size = CGSize(width: 60, height: 20)
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // Bottom strip: above it, centred on the item.
        var arm = CGRect(x: 400, y: 4, width: 200, height: 64)
        var tile = CGRect(x: 410, y: 14, width: 44, height: 44)
        XCTAssertEqual(HUDDockStripView.labelFrame(size: size, tile: tile, arm: arm, edge: .bottom, visible: visible),
                       CGRect(x: 402, y: 74, width: 60, height: 20))
        // Top strip: below it.
        arm = CGRect(x: 400, y: 732, width: 200, height: 64)
        tile = CGRect(x: 410, y: 742, width: 44, height: 44)
        XCTAssertEqual(HUDDockStripView.labelFrame(size: size, tile: tile, arm: arm, edge: .top, visible: visible),
                       CGRect(x: 402, y: 706, width: 60, height: 20))
        // Left strip: to its right, centred vertically.
        arm = CGRect(x: 4, y: 300, width: 64, height: 200)
        tile = CGRect(x: 14, y: 310, width: 44, height: 44)
        XCTAssertEqual(HUDDockStripView.labelFrame(size: size, tile: tile, arm: arm, edge: .left, visible: visible),
                       CGRect(x: 74, y: 322, width: 60, height: 20))
        // Right strip: to its left.
        arm = CGRect(x: 932, y: 300, width: 64, height: 200)
        tile = CGRect(x: 942, y: 310, width: 44, height: 44)
        XCTAssertEqual(HUDDockStripView.labelFrame(size: size, tile: tile, arm: arm, edge: .right, visible: visible),
                       CGRect(x: 866, y: 322, width: 60, height: 20))
        // Clamped to the visible frame: an item at the very left of a bottom strip.
        arm = CGRect(x: 0, y: 4, width: 200, height: 64)
        tile = CGRect(x: 2, y: 14, width: 44, height: 44)
        XCTAssertEqual(HUDDockStripView.labelFrame(size: size, tile: tile, arm: arm, edge: .bottom, visible: visible).minX, 0)
        tile = CGRect(x: 942, y: 790, width: 44, height: 44)
        arm = CGRect(x: 932, y: 600, width: 64, height: 240)
        XCTAssertEqual(HUDDockStripView.labelFrame(size: size, tile: tile, arm: arm, edge: .right, visible: visible).maxY, 800)
    }

    func testStripLabelFrameIsOutsideTheStrip() throws {
        let tile = strip.tiles[0]
        let f = try XCTUnwrap(strip.labelFrame(for: tile, text: "A"))
        XCTAssertEqual(f.minY, window.frame.maxY + HUDDockStripView.labelGap, accuracy: 1, "above a bottom strip")
        XCTAssertEqual(f.midX, window.frame.minX + tile.frame.midX, accuracy: 1)
        XCTAssertEqual(f.height, ceil(("A" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).height) + 8)
    }
}
