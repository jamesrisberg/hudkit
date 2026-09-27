import XCTest
import AppKit
@testable import HUDKit

@MainActor
private final class FakeHost: HUDPanelHost {
    var states: [String: HUDPanelState] = ["dock": HUDPanelState(id: "dock", visible: false),
                                           "portal": HUDPanelState(id: "portal", visible: true, badge: "2")]
    var frames: [String: CGRect] = [:]
    var stored: [String: String] = ["theme": "dark"]
    var quitCalled = false
    var actions: [(String, [String: String])] = []

    var panelStates: [HUDPanelState] { states.values.sorted { $0.id < $1.id } }
    var panelDescriptors: [HUDManifest.Panel] { [HUDManifest.Panel(id: "dock", title: "Dock", symbol: "square.grid.2x2")] }

    func showPanel(_ id: String) throws { states[id]?.visible = true }
    func hidePanel(_ id: String) throws { states[id]?.visible = false }
    func setPanelFrame(_ id: String, frame: CGRect) throws { frames[id] = frame }
    func setPanelMode(_ id: String, mode: HUDPanelMode) throws { states[id]?.mode = mode }
    func settings() -> [String: Any] { stored }
    func updateSettings(_ values: [String: String]) throws {
        if values["bad"] != nil { throw HUDControlError.invalid("bad setting") }
        stored.merge(values) { _, b in b }
    }
    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        actions.append((name, args))
        done(["ok": true, "did": name])
    }
    func quit() { quitCalled = true }
}

/// A host that only implements the required members, to check the defaults.
@MainActor
private final class MinimalHost: HUDPanelHost {
    var visible = false
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "only", visible: visible)] }
    func showPanel(_ id: String) throws { visible = true }
    func hidePanel(_ id: String) throws { visible = false }
    func quit() {}
}

@MainActor
final class ControlRouterTests: XCTestCase {
    private var host: FakeHost!
    private var router: HUDControlRouter!
    private let server = HUDSocketServer(path: "/tmp/unused-\(getpid()).sock")

    override func setUp() {
        host = FakeHost()
        router = HUDControlRouter(host: host, server: server,
                                  manifest: HUDManifest(id: "dev.test", name: "Test", socket: "test"))
    }

    private func call(_ verb: String, _ args: [String: String] = [:]) -> [String: Any] {
        var out: [String: Any]?
        router.handle(verb, args: args) { out = $0 }
        return out ?? ["missing": true]
    }

    func testInstallRegistersRequiredVerbs() {
        router.install()
        XCTAssertEqual(Set(server.commands), ["hello", "panel", "state", "settings", "action", "quit", "menu", "menu-invoke"])
        XCTAssertEqual(HUDControlRouter.requiredVerbs, ["hello", "panel", "state", "subscribe", "settings", "action", "quit"])
    }

    func testHello() {
        let r = call("hello")
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["hudkit"] as? String, HUDKit.version)
        XCTAssertEqual(r["app"] as? String, "dev.test")
        XCTAssertEqual(r["name"] as? String, "Test")
        let panels = r["panels"] as? [[String: Any]]
        XCTAssertEqual(panels?.first?["id"] as? String, "dock")
        XCTAssertEqual(panels?.first?["symbol"] as? String, "square.grid.2x2")
    }

    func testHelloReportsAppVersion() {
        router.appVersion = "1.2.3"
        XCTAssertEqual(call("hello")["version"] as? String, "1.2.3")
        router.appVersion = nil
        XCTAssertNil(call("hello")["version"], "no version outside a bundle")
    }

    func testState() {
        let panels = call("state")["panels"] as? [[String: Any]]
        XCTAssertEqual(panels?.map { $0["id"] as? String }, ["dock", "portal"])
        XCTAssertEqual(panels?.last?["badge"] as? String, "2")
        XCTAssertEqual(panels?.first?["mode"] as? String, "full")
        XCTAssertNil(panels?.first?["badge"])
    }

    func testPanelShowHideToggleForms() {
        XCTAssertEqual(call("panel", ["id": "dock", "action": "show"])["visible"] as? Bool, true)
        XCTAssertEqual(call("panel", ["id": "dock", "hide": "1"])["visible"] as? Bool, false, "bare sub-verb (CLI: panel hide id=dock)")
        XCTAssertEqual(call("panel", ["id": "dock"])["visible"] as? Bool, true, "no sub-verb toggles")
        XCTAssertEqual(call("panel", ["id": "dock", "toggle": "1"])["visible"] as? Bool, false)
        let missing = call("panel", ["id": "nope", "action": "show"])
        XCTAssertEqual(missing["ok"] as? Bool, false)
        XCTAssertEqual(missing["error"] as? String, "no such panel")
        XCTAssertEqual(call("panel", ["id": "dock", "action": "explode"])["ok"] as? Bool, false)
    }

    func testPanelFrameAndMode() {
        XCTAssertEqual(call("panel", ["id": "portal", "action": "frame", "x": "10", "y": "20", "w": "300", "h": "200.5"])["ok"] as? Bool, true)
        XCTAssertEqual(host.frames["portal"], CGRect(x: 10, y: 20, width: 300, height: 200.5))
        XCTAssertEqual(call("panel", ["id": "portal", "frame": "1", "x": "1"])["ok"] as? Bool, false)

        XCTAssertEqual(call("panel", ["id": "portal", "action": "mode", "mode": "compact"])["mode"] as? String, "compact")
        XCTAssertEqual(call("panel", ["id": "portal", "mode": "1", "parked": "1"])["mode"] as? String, "parked", "CLI: panel mode parked id=portal")
        XCTAssertEqual(call("panel", ["id": "portal", "mode": "sideways"])["ok"] as? Bool, false)
    }

    func testSettings() {
        XCTAssertEqual(call("settings")["settings"] as? [String: String], ["theme": "dark"])
        XCTAssertEqual(call("settings", ["get": "1", "key": "theme"])["value"] as? String, "dark")
        XCTAssertEqual(call("settings", ["key": "missing"])["ok"] as? Bool, false)
        XCTAssertEqual(call("settings", ["set": "1", "theme": "light", "size": "2"])["ok"] as? Bool, true)
        XCTAssertEqual(host.stored, ["theme": "light", "size": "2"])
        XCTAssertEqual(call("settings", ["action": "set", "key": "k", "value": "v"])["ok"] as? Bool, true)
        XCTAssertEqual(host.stored["k"], "v")
        XCTAssertEqual(call("settings", ["set": "1"])["ok"] as? Bool, false)
        XCTAssertEqual(call("settings", ["set": "1", "bad": "x"])["error"] as? String, "bad setting")
        // What `runCLI` sends for `app settings set theme=blue`: the bare word is also under `_`.
        let parsed = HUDSocketClient.parseArguments(["set", "theme=blue"])
        XCTAssertEqual(call("settings", parsed)["ok"] as? Bool, true)
        XCTAssertEqual(host.stored["theme"], "blue")
        XCTAssertNil(host.stored["_"])
    }

    func testActionAndQuit() {
        let r = call("action", ["name": "select-set", "set": "3"])
        XCTAssertEqual(r["did"] as? String, "select-set")
        XCTAssertEqual(host.actions.first?.1, ["set": "3"])
        XCTAssertEqual(call("action")["ok"] as? Bool, false)

        XCTAssertEqual(call("quit")["ok"] as? Bool, true)
        XCTAssertFalse(host.quitCalled, "quit happens after the response is sent")
        let e = expectation(description: "quit")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1)
        XCTAssertTrue(host.quitCalled)
    }

    func testActionBareVerbWithNamePayload() {
        // `action select-set name=default` from the CLI: the bare verb wins and name= stays in the payload.
        let args = HUDSocketClient.parseArguments(["select-set", "name=default"])
        let r = call("action", args)
        XCTAssertEqual(r["did"] as? String, "select-set")
        XCTAssertEqual(host.actions.last?.1, ["name": "default"])
    }

    func testDefaults() {
        let minimal = MinimalHost()
        let r = HUDControlRouter(host: minimal, server: server, manifest: nil)
        var out: [String: Any] = [:]
        r.handle("panel", args: ["id": "only"]) { out = $0 }
        XCTAssertEqual(out["visible"] as? Bool, true, "default toggle uses panelStates")
        r.handle("panel", args: ["id": "only", "action": "frame", "x": "0", "y": "0", "w": "1", "h": "1"]) { out = $0 }
        XCTAssertEqual(out["error"] as? String, "unsupported: panel frame")
        r.handle("settings", args: [:]) { out = $0 }
        XCTAssertEqual((out["settings"] as? [String: Any])?.count, 0)
        r.handle("action", args: ["name": "x"]) { out = $0 }
        XCTAssertEqual(out["error"] as? String, "unknown action x")
        r.handle("hello", args: [:]) { out = $0 }
        XCTAssertEqual((out["panels"] as? [[String: Any]])?.first?["id"] as? String, "only")
        XCTAssertNil(out["app"])
    }

    func testRouterOverSocketWithSubscribe() throws {
        let dir = URL(fileURLWithPath: "/tmp/hudkit-r-\(getpid())")
        let live = HUDSocketServer(path: HUDSocket.path(for: "r", in: dir))
        defer { live.stop(); try? FileManager.default.removeItem(at: dir) }
        let router = HUDControlRouter(host: host, server: live, manifest: nil)
        router.install()
        XCTAssertTrue(live.start())

        let got = expectation(description: "state pushed")
        let client = HUDSocketClient(path: live.path, timeout: 5)
        let sub = try client.subscribe(events: ["state"], onEvent: { obj in
            if (obj["panels"] as? [[String: Any]])?.contains(where: { $0["id"] as? String == "dock" && $0["visible"] as? Bool == true }) == true {
                got.fulfill()
            }
        })
        defer { sub.cancel() }

        var response: [String: Any]?
        DispatchQueue.global().async {
            let r = try? client.request("panel", args: ["id": "dock", "action": "show"])
            DispatchQueue.main.async { response = r }
        }
        wait(for: [got], timeout: 5)
        let deadline = Date().addingTimeInterval(5)
        while response == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(response?["visible"] as? Bool, true)
    }
}

@MainActor
private final class ParkingHost: HUDPanelHost {
    var mode: HUDPanelMode = .full
    var lastOptions: HUDPanelModeOptions?
    var schema: HUDSettingsSchema? = HUDSettingsSchema(settings: [.init(key: "on", type: .bool, default: .bool(true))])
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "p", visible: true, mode: mode)] }
    var settingsSchema: HUDSettingsSchema? { schema }
    func showPanel(_ id: String) throws {}
    func hidePanel(_ id: String) throws {}
    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        self.mode = mode
        lastOptions = options
    }
}

@MainActor
final class ControlRouterModeOptionTests: XCTestCase {
    private func call(_ router: HUDControlRouter, _ verb: String, _ args: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        router.handle(verb, args: args) { out = $0 }
        return out
    }

    func testParkedModePassesEdgeAndPeek() {
        let host = ParkingHost()
        let router = HUDControlRouter(host: host, server: HUDSocketServer(path: "/tmp/unused-\(UUID().uuidString).sock"))
        let r = call(router, "panel", ["id": "p", "mode": "parked", "edge": "right", "peek": "14"])
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["mode"] as? String, "parked")
        XCTAssertEqual(host.lastOptions, HUDPanelModeOptions(edge: .right, peek: 14))
        let bad = call(router, "panel", ["id": "p", "mode": "parked", "edge": "middle"])
        XCTAssertEqual(bad["ok"] as? Bool, false)
        _ = call(router, "panel", ["id": "p", "mode": "full"])
        XCTAssertEqual(host.lastOptions, HUDPanelModeOptions())
    }

    func testSettingsSchemaVerb() {
        let host = ParkingHost()
        let router = HUDControlRouter(host: host, server: HUDSocketServer(path: "/tmp/unused-\(UUID().uuidString).sock"))
        let r = call(router, "settings", ["schema": "1"])
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(HUDSettingsSchema(json: r["schema"] as Any), host.schema)
        host.schema = nil
        XCTAssertEqual(call(router, "settings", ["action": "schema"])["ok"] as? Bool, false)
    }
}

@MainActor
private final class NumberSettingsHost: HUDPanelHost {
    var applied: [[String: String]] = []
    var settingsSchema: HUDSettingsSchema? = HUDSettingsSchema(settings: [
        .init(key: "delay", type: .number, default: .double(0.75), min: 0.1, max: 10),
        .init(key: "mode", type: .enum, options: [.init(value: "a"), .init(value: "b")]),
    ])
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "p", visible: false)] }
    func showPanel(_ id: String) throws {}
    func hidePanel(_ id: String) throws {}
    func settings() -> [String: Any] { ["delay": 0.75, "mode": "a"] }
    func updateSettings(_ values: [String: String]) throws { applied.append(values) }
}

@MainActor
final class ControlRouterSettingsValidationTests: XCTestCase {
    private func call(_ router: HUDControlRouter, _ args: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        router.handle("settings", args: args) { out = $0 }
        return out
    }

    func testSetValidatesSchemaFieldsBeforeTheHostSeesAny() {
        let host = NumberSettingsHost()
        let router = HUDControlRouter(host: host, server: HUDSocketServer(path: "/tmp/unused-\(UUID().uuidString).sock"))
        XCTAssertEqual(call(router, ["action": "set", "delay": "1.5"])["ok"] as? Bool, true)
        XCTAssertEqual(host.applied, [["delay": "1.5"]])
        let tooBig = call(router, ["action": "set", "delay": "12", "mode": "b"])
        XCTAssertEqual(tooBig["error"] as? String, "delay must be at most 10")
        XCTAssertEqual(call(router, ["action": "set", "delay": "fast"])["error"] as? String, "delay must be a number")
        XCTAssertEqual(call(router, ["action": "set", "mode": "c"])["ok"] as? Bool, false)
        XCTAssertEqual(host.applied.count, 1, "a rejected set reaches the host with nothing")
        // Keys the schema does not describe are the host's to judge.
        XCTAssertEqual(call(router, ["action": "set", "other": "x"])["ok"] as? Bool, true)
        XCTAssertEqual(host.applied.last, ["other": "x"])
    }
}
