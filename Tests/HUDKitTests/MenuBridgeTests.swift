import XCTest
import AppKit
@testable import HUDKit

@MainActor
private final class MenuTarget: NSObject, NSMenuDelegate, NSMenuItemValidation {
    var fired: [String] = []
    var refreshes = 0
    var twoPane = true
    @objc func alpha(_ sender: NSMenuItem) { fired.append("alpha") }
    @objc func nested(_ sender: NSMenuItem) { fired.append("nested:\(sender.title)") }
    @objc func never(_ sender: NSMenuItem) { fired.append("never") }
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshes += 1
        menu.item(withTitle: "Two-Pane")?.state = twoPane ? .on : .off
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { item.action != #selector(never(_:)) }
}

@MainActor
final class MenuBridgeTests: XCTestCase {
    private var target: MenuTarget!
    private var menu: NSMenu!

    override func setUp() {
        target = MenuTarget()
        menu = NSMenu()
        menu.delegate = target
        let alpha = NSMenuItem(title: "Alpha", action: #selector(MenuTarget.alpha(_:)), keyEquivalent: "/")
        alpha.keyEquivalentModifierMask = [.option]
        menu.addItem(alpha)                                                    // 0
        menu.addItem(.separator())                                             // 1
        menu.addItem(NSMenuItem(title: "Disabled", action: #selector(MenuTarget.never(_:)), keyEquivalent: "")) // 2
        menu.addItem(NSMenuItem(title: "Two-Pane", action: #selector(MenuTarget.alpha(_:)), keyEquivalent: "")) // 3
        let hidden = NSMenuItem(title: "Hidden", action: #selector(MenuTarget.alpha(_:)), keyEquivalent: "")
        hidden.isHidden = true
        menu.addItem(hidden)                                                   // 4 (not listed)
        let sub = NSMenu()
        let a = NSMenuItem(title: "Keep Both", action: #selector(MenuTarget.nested(_:)), keyEquivalent: "")
        a.state = .mixed
        sub.addItem(a)                                                         // 5.0
        sub.addItem(.separator())                                              // 5.1
        let b = NSMenuItem(title: "Skip", action: #selector(MenuTarget.nested(_:)), keyEquivalent: "k")
        b.keyEquivalentModifierMask = [.command, .shift]
        sub.addItem(b)                                                         // 5.2
        let parent = NSMenuItem(title: "When Names Collide", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)                                                   // 5
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")) // 6
        for item in menu.items + sub.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = target }
    }

    func testSerializeShapesIdsStatesAndRefreshes() throws {
        target.twoPane = true
        let items = HUDMenuBridge.serialize(menu)
        XCTAssertGreaterThan(target.refreshes, 0, "menuNeedsUpdate runs before listing")
        XCTAssertEqual(items.map(\.id), ["0", "1", "2", "3", "5", "6"], "hidden item skipped, ids keep their index")
        XCTAssertEqual(items[0], HUDMenuBridge.Item(id: "0", title: "Alpha", keyEquivalent: "/", modifiers: ["option"]))
        XCTAssertEqual(items[1].kind, .separator)
        XCTAssertFalse(items[2].enabled, "validateMenuItem said no")
        XCTAssertEqual(items[3].state, .on)
        let sub = try XCTUnwrap(items[4].items)
        XCTAssertEqual(items[4].kind, .submenu)
        XCTAssertEqual(sub.map(\.id), ["5.0", "5.1", "5.2"])
        XCTAssertEqual(sub[0].state, .mixed)
        XCTAssertEqual(sub[1].kind, .separator)
        XCTAssertEqual(sub[2].modifiers, ["shift", "command"])
        XCTAssertEqual(sub[2].modifierFlags, [.command, .shift])

        target.twoPane = false
        XCTAssertEqual(HUDMenuBridge.serialize(menu)[3].state, .off, "state follows the delegate")
    }

    func testJSONRoundTrip() throws {
        let items = HUDMenuBridge.serialize(menu)
        let wire = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: items.map(\.json)))
        XCTAssertEqual(HUDMenuBridge.Item.list(wire), items)
        XCTAssertNil(HUDMenuBridge.Item(json: ["title": "no id"]))
    }

    func testInvokeByIdIncludingNested() throws {
        try HUDMenuBridge.invoke("0", in: menu)
        try HUDMenuBridge.invoke("5.2", title: "Skip", in: menu)
        XCTAssertEqual(target.fired, ["alpha", "nested:Skip"])
    }

    func testInvokeFailures() {
        func failure(_ id: String, title: String? = nil) -> HUDMenuBridge.Failure? {
            do { try HUDMenuBridge.invoke(id, title: title, in: menu); return nil } catch { return error as? HUDMenuBridge.Failure }
        }
        XCTAssertEqual(failure("2"), .disabled("2"))
        XCTAssertEqual(failure("1"), .notAnAction("1"))
        XCTAssertEqual(failure("5"), .notAnAction("5"))
        XCTAssertEqual(failure("9"), .noSuchItem("9"))
        XCTAssertEqual(failure("0.1"), .noSuchItem("0.1"))
        XCTAssertEqual(failure("x"), .noSuchItem("x"))
        XCTAssertEqual(failure("0", title: "Beta"), .changed("0"))
        XCTAssertEqual(target.fired, [])
    }

    func testRouterMenuVerbs() throws {
        let host = TinyHost()
        let router = HUDControlRouter(host: host, server: HUDSocketServer(path: "/tmp/unused-menu-\(getpid()).sock"),
                                      manifest: HUDManifest(id: "dev.test", name: "Test", socket: "test"))
        func call(_ verb: String, _ args: [String: String] = [:]) -> [String: Any] {
            var out: [String: Any] = [:]
            router.handle(verb, args: args) { out = $0 }
            return out
        }
        XCTAssertEqual(call("menu")["error"] as? String, "no menu")
        XCTAssertEqual(call("menu-invoke", ["id": "0"])["error"] as? String, "no menu")
        XCTAssertFalse((call("hello")["verbs"] as? [String] ?? []).contains("menu"))

        router.menuProvider = { [menu] in menu }
        XCTAssertTrue((call("hello")["verbs"] as? [String] ?? []).contains("menu-invoke"))
        let items = HUDMenuBridge.Item.list(call("menu")["items"])
        XCTAssertEqual(items.first?.title, "Alpha")
        XCTAssertEqual(items.last?.title, "Quit")

        let reply = call("menu-invoke", ["id": "5.0"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["title"] as? String, "Keep Both")
        XCTAssertEqual(target.fired, [], "performed after the reply")
        let deadline = Date().addingTimeInterval(2)
        while target.fired.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(target.fired, ["nested:Keep Both"])

        XCTAssertEqual(call("menu-invoke", ["id": "2"])["error"] as? String, "menu item 2 is disabled")
        XCTAssertEqual(call("menu-invoke")["error"] as? String, "menu-invoke needs id=")
    }
}

@MainActor
private final class TinyHost: HUDPanelHost {
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "p", visible: false)] }
    func showPanel(_ id: String) throws {}
    func hidePanel(_ id: String) throws {}
    func quit() {}
}
