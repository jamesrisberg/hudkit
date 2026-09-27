import XCTest
import AppKit
@testable import HUDKit

@MainActor
private final class TransitionHost: HUDPanelHost {
    var visible = false
    var shows: [[String: String]] = []
    var hides: [[String: String]] = []
    var plainToggles = 0
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "p", visible: visible)] }
    func showPanel(_ id: String) throws { XCTFail("options variant should be called") }
    func hidePanel(_ id: String) throws { XCTFail("options variant should be called") }
    func togglePanel(_ id: String) throws { plainToggles += 1; visible.toggle() }
    func showPanel(_ id: String, options: [String: String]) throws { shows.append(options); visible = true }
    func hidePanel(_ id: String, options: [String: String]) throws { hides.append(options); visible = false }
    func quit() {}
}

/// Implements only the required members: the options variants must fall back to them.
@MainActor
private final class PlainHost: HUDPanelHost {
    var visible = false
    var calls: [String] = []
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "p", visible: visible)] }
    func showPanel(_ id: String) throws { calls.append("show"); visible = true }
    func hidePanel(_ id: String) throws { calls.append("hide"); visible = false }
    func quit() {}
}

@MainActor
final class TransitionTests: XCTestCase {
    private func call(_ router: HUDControlRouter, _ args: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        router.handle("panel", args: args) { out = $0 }
        return out
    }

    private func router(_ host: HUDPanelHost) -> HUDControlRouter {
        HUDControlRouter(host: host, server: HUDSocketServer(path: "/tmp/unused-\(UUID().uuidString).sock"), manifest: nil)
    }

    func testRouterPassesShowOptions() {
        let host = TransitionHost()
        let r = router(host)
        // What the CLI sends for `panel show id=p from=top anchor=10,20,40,40 reason=hover`.
        var args = HUDSocketClient.parseArguments(["show", "id=p", "from=top", "anchor=10,20,40,40", "reason=hover"])
        XCTAssertEqual(call(r, args)["visible"] as? Bool, true)
        XCTAssertEqual(host.shows.last, ["from": "top", "anchor": "10,20,40,40", "reason": "hover"])
        let t = HUDPanelTransition(host.shows.last!)
        XCTAssertEqual(t, HUDPanelTransition(from: .top, anchor: CGRect(x: 10, y: 20, width: 40, height: 40), reason: .hover))

        args = ["id": "p", "action": "hide", "to": "left", "reason": "click"]
        XCTAssertEqual(call(r, args)["visible"] as? Bool, false)
        XCTAssertEqual(host.hides.last, ["to": "left", "reason": "click"])

        XCTAssertEqual(call(r, ["id": "p", "show": "1"])["ok"] as? Bool, true)
        XCTAssertEqual(host.shows.last, [:], "no options: empty dictionary")
    }

    func testRouterValidatesOptions() {
        let host = TransitionHost()
        let r = router(host)
        XCTAssertEqual(call(r, ["id": "p", "action": "show", "from": "middle"])["error"] as? String,
                       "from must be left, right, top or bottom")
        XCTAssertEqual(call(r, ["id": "p", "action": "hide", "to": "up"])["ok"] as? Bool, false)
        XCTAssertEqual(call(r, ["id": "p", "action": "show", "anchor": "1,2,3"])["error"] as? String, "anchor must be x,y,w,h")
        XCTAssertEqual(call(r, ["id": "p", "action": "show", "anchor": "1,2,3,x"])["ok"] as? Bool, false)
        XCTAssertEqual(host.shows.count, 0)
    }

    func testToggleWithAndWithoutOptions() {
        let host = TransitionHost()
        let r = router(host)
        _ = call(r, ["id": "p"])
        XCTAssertEqual(host.plainToggles, 1, "bare toggle keeps using the host's togglePanel(_:)")
        XCTAssertTrue(host.visible)
        _ = call(r, ["id": "p", "toggle": "1", "from": "bottom", "reason": "click"])
        XCTAssertEqual(host.plainToggles, 1)
        XCTAssertEqual(host.hides.last, ["from": "bottom", "to": "bottom", "reason": "click"], "hiding toggle mirrors from= as to=")
        _ = call(r, ["id": "p", "toggle": "1", "from": "right"])
        XCTAssertEqual(host.shows.last, ["from": "right"])
    }

    func testDefaultExtensionsFallBack() throws {
        let host = PlainHost()
        try host.showPanel("p", options: ["from": "top"])
        try host.hidePanel("p", options: ["to": "top"])
        try host.togglePanel("p", options: ["from": "top"])
        XCTAssertEqual(host.calls, ["show", "hide", "show"])
        XCTAssertThrowsError(try host.togglePanel("nope", options: [:]))
        let r = router(host)
        XCTAssertEqual(call(r, ["id": "p", "action": "hide", "to": "left"])["visible"] as? Bool, false)
        XCTAssertEqual(call(r, ["id": "p", "from": "left"])["visible"] as? Bool, true)
    }

    func testTransitionRoundTrip() {
        let t = HUDPanelTransition(from: .left, to: .right, anchor: CGRect(x: 1.5, y: -2, width: 40, height: 40), reason: .summon)
        XCTAssertEqual(t.options["anchor"], "1.5,-2,40,40")
        XCTAssertEqual(HUDPanelTransition(t.options), t)
        XCTAssertEqual(HUDPanelTransition(["reason": "wiggle", "from": "nowhere"]), HUDPanelTransition())
        XCTAssertNil(HUDPanelTransition.parseAnchor("1,2,3,4,5"))
        XCTAssertEqual(HUDPanelTransition.parseAnchor(" 1, 2 ,3,4"), CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    func testSlideOffsets() {
        let f = CGRect(x: 100, y: 100, width: 10, height: 10)
        XCTAssertEqual(HUDAnimation.offset(f, toward: .top).minY, 124)
        XCTAssertEqual(HUDAnimation.offset(f, toward: .bottom).minY, 76)
        XCTAssertEqual(HUDAnimation.offset(f, toward: .left).minX, 76)
        XCTAssertEqual(HUDAnimation.offset(f, toward: .right, by: 5).minX, 105)
    }

    func testSlideInAndOut() {
        let w = HUDPanelWindow(contentRect: CGRect(x: 200, y: 200, width: 100, height: 100))
        let target = CGRect(x: 300, y: 300, width: 100, height: 100)
        let shown = expectation(description: "shown")
        HUDAnimation.slide(in: w, from: .top, to: target) { shown.fulfill() }
        XCTAssertTrue(w.isVisible)
        wait(for: [shown], timeout: 2)
        XCTAssertEqual(w.frame, target)
        XCTAssertEqual(w.alphaValue, 1, accuracy: 0.01)

        let hidden = expectation(description: "hidden")
        HUDAnimation.slideOut(w, toward: .top) { hidden.fulfill() }
        wait(for: [hidden], timeout: 2)
        XCTAssertFalse(w.isVisible)
        XCTAssertEqual(w.frame, target, "frame restored for the next show")
        XCTAssertEqual(w.alphaValue, 1)

        // A slide-in that interrupts a slide-out wins.
        HUDAnimation.slide(in: w, from: .left, to: target)
        HUDAnimation.slideOut(w, toward: .left)
        HUDAnimation.slide(in: w, from: .left, to: target)
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertTrue(w.isVisible)
        XCTAssertEqual(w.frame, target)
        w.orderOut(nil)
    }
}
