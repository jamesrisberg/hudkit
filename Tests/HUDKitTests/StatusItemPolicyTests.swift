import XCTest
import AppKit
@testable import HUDKit

@MainActor
final class StatusItemPolicyTests: XCTestCase {
    private var dir: URL!
    private var hostURL: URL { dir.appendingPathComponent("host.json") }
    private var defaults: UserDefaults!
    private var suite: String!
    private var alive: Set<Int32> = []
    private var applied: [Bool] = []
    private var policy: HUDStatusItemPolicy!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hudkit-host-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "hudkit-policy-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        alive = []
        applied = []
        policy = HUDStatusItemPolicy(appID: "dev.test", hostURL: hostURL, store: .defaults(defaults), ownPID: 1,
                                     isAlive: { [unowned self] in self.alive.contains($0.pid) },
                                     apply: { [unowned self] in self.applied.append($0) })
    }

    override func tearDown() {
        policy.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeHost(pid: Int32 = 4242, hostsMenus: Bool = true) throws {
        try HUDMenuHost(pid: pid, bundleID: "xyz.machud", hostsMenus: hostsMenus).write(to: hostURL)
    }

    func testShouldShowTable() {
        let host = HUDMenuHost(pid: 10, bundleID: "xyz.machud", hostsMenus: true)
        let yes: (HUDMenuHost) -> Bool = { _ in true }, no: (HUDMenuHost) -> Bool = { _ in false }
        XCTAssertTrue(HUDStatusItemPolicy.shouldShow(host: nil, consumed: true, ownPID: 1, isAlive: yes))
        XCTAssertFalse(HUDStatusItemPolicy.shouldShow(host: host, consumed: true, ownPID: 1, isAlive: yes))
        XCTAssertTrue(HUDStatusItemPolicy.shouldShow(host: host, consumed: true, ownPID: 1, isAlive: no), "dead pid")
        XCTAssertTrue(HUDStatusItemPolicy.shouldShow(host: host, consumed: false, ownPID: 1, isAlive: yes), "opted out")
        XCTAssertTrue(HUDStatusItemPolicy.shouldShow(host: host, consumed: true, ownPID: 10, isAlive: yes), "never hides itself")
        var off = host
        off.hostsMenus = false
        XCTAssertTrue(HUDStatusItemPolicy.shouldShow(host: off, consumed: true, ownPID: 1, isAlive: yes))
    }

    func testHideOnHostAppearShowOnVanishAndDeadPid() throws {
        policy.evaluate()
        XCTAssertEqual(applied, [true])
        XCTAssertFalse(policy.isPolling)

        alive = [4242]
        try writeHost()
        policy.evaluate()
        XCTAssertFalse(policy.isVisible)
        XCTAssertEqual(applied.last, false)
        XCTAssertTrue(policy.isPolling, "polls for a crashed host while hidden")

        // Crash: file stays, pid dies.
        alive = []
        policy.evaluate()
        XCTAssertTrue(policy.isVisible)
        XCTAssertFalse(policy.isPolling)

        alive = [4242]
        policy.evaluate()
        XCTAssertFalse(policy.isVisible)
        try FileManager.default.removeItem(at: hostURL)
        policy.evaluate()
        XCTAssertTrue(policy.isVisible, "host quit")

        try writeHost(hostsMenus: false)
        policy.evaluate()
        XCTAssertTrue(policy.isVisible, "consolidation turned off")
    }

    func testOptOutPersistsAndReEvaluates() throws {
        alive = [4242]
        try writeHost()
        policy.evaluate()
        XCTAssertFalse(policy.isVisible)
        XCTAssertTrue(policy.consumed, "default true")
        policy.consumed = false
        XCTAssertTrue(policy.isVisible)
        XCTAssertEqual(defaults.object(forKey: HUDStatusItemPolicy.consumedKey) as? Bool, false)
        policy.consumed = true
        XCTAssertFalse(policy.isVisible)
    }

    func testHomeStoreKeepsTheOptOutInTheAppsDirectory() throws {
        let home = dir.appendingPathComponent("app-home")
        let isolated = HUDStatusItemPolicy(appID: "dev.test", hostURL: hostURL, store: .home(home), ownPID: 1,
                                           isAlive: { _ in true }, apply: { _ in })
        let file = home.appendingPathComponent("menubar.json")
        XCTAssertTrue(isolated.consumed, "default true with no file")
        XCTAssertEqual(isolated.store.location, file.path)
        isolated.consumed = false
        XCTAssertFalse(isolated.consumed)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(saved?["menuBar.consumed"] as? Bool, false)
        XCTAssertNil(defaults.object(forKey: HUDStatusItemPolicy.consumedKey), "nothing written to user defaults")
        // Other keys in the file survive a write; a fresh policy reads the saved choice.
        try Data(#"{"menuBar.consumed": false, "note": "x"}"#.utf8).write(to: file)
        let again = HUDStatusItemPolicy(appID: "dev.test", hostURL: hostURL, store: .home(home), ownPID: 1,
                                        isAlive: { _ in true }, apply: { _ in })
        XCTAssertFalse(again.consumed)
        again.consumed = true
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(rewritten?["note"] as? String, "x")
        XCTAssertEqual(rewritten?["menuBar.consumed"] as? Bool, true)
        // A non-bool value reads as unset (default true).
        try Data(#"{"menuBar.consumed": 0}"#.utf8).write(to: file)
        XCTAssertTrue(again.consumed)
    }

    func testWatchesTheFile() throws {
        alive = [4242]
        var changes: [Bool] = []
        policy.onChange = { changes.append($0) }
        policy.start()
        XCTAssertTrue(HUDStatusItemPolicy.attached.contains { $0 === policy })
        XCTAssertTrue(policy.isVisible)
        try writeHost()
        let deadline = Date().addingTimeInterval(3)
        while policy.isVisible && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(policy.isVisible, "file watch hid the item")
        HUDMenuHost.remove(at: hostURL, ifOwnedBy: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostURL.path), "another pid's file is left alone")
        HUDMenuHost.remove(at: hostURL, ifOwnedBy: 4242)
        let deadline2 = Date().addingTimeInterval(3)
        while !policy.isVisible && Date() < deadline2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(policy.isVisible)
        XCTAssertEqual(changes, [false, true])
        policy.stop()
        XCTAssertFalse(HUDStatusItemPolicy.attached.contains { $0 === policy })
    }

    func testHostFileShapeAndLiveness() throws {
        try HUDMenuHost(pid: getpid(), bundleID: "", hostsMenus: true).write(to: hostURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hostURL)) as? [String: Any])
        XCTAssertEqual(json["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(json["hostsMenus"] as? Bool, true)
        XCTAssertNotNil((json["updatedAt"] as? String).flatMap(HUDDockRegistry.parseDate))
        XCTAssertTrue(try XCTUnwrap(HUDMenuHost.read(from: hostURL)).isAlive)
        XCTAssertFalse(HUDMenuHost(pid: 2_147_483_000, bundleID: "x", hostsMenus: true).isAlive)
        XCTAssertFalse(HUDMenuHost(pid: getpid(), bundleID: "not.this.app", hostsMenus: true).isAlive
                       && NSRunningApplication.current.bundleIdentifier != nil, "a reused pid is another app")
        XCTAssertTrue(HUDMenuHost.defaultURL.path.hasSuffix("MacHUD/host.json")
                      || ProcessInfo.processInfo.environment["MACHUD_HOST_FILE"] != nil)
    }

    func testRouterReportsAndServesTheOptOut() throws {
        alive = [4242]
        try writeHost()
        policy.evaluate()
        let host = SettingsHost()
        let router = HUDControlRouter(host: host, server: HUDSocketServer(path: "/tmp/unused-pol-\(getpid()).sock"),
                                      manifest: HUDManifest(id: "dev.test", name: "Test", socket: "test"))
        router.statusItemPolicy = policy
        func call(_ verb: String, _ args: [String: String] = [:]) -> [String: Any] {
            var out: [String: Any] = [:]
            router.handle(verb, args: args) { out = $0 }
            return out
        }
        let item = try XCTUnwrap(call("hello")["statusItem"] as? [String: Any])
        XCTAssertEqual(item["visible"] as? Bool, false)
        XCTAssertEqual((item["host"] as? [String: Any])?["pid"] as? Int, 4242)
        XCTAssertEqual((call("settings")["settings"] as? [String: Any])?["menuBar.consumed"] as? Bool, true)
        let set = call("settings", ["action": "set", "menuBar.consumed": "false", "theme": "light"])
        XCTAssertEqual(set["ok"] as? Bool, true)
        XCTAssertEqual((set["settings"] as? [String: Any])?["theme"] as? String, "light", "other keys still reach the host")
        XCTAssertTrue(policy.isVisible)
        XCTAssertEqual(call("settings", ["action": "set", "menuBar.consumed": "maybe"])["ok"] as? Bool, false)
        let reply = call("settings", ["action": "schema"])
        let schema = try XCTUnwrap(reply["schema"] as? [String: Any], "\(reply)")
        XCTAssertTrue((schema["settings"] as? [[String: Any]] ?? []).contains { $0["key"] as? String == "menuBar.consumed" })
    }
}

@MainActor
private final class SettingsHost: HUDPanelHost {
    var stored: [String: String] = ["theme": "dark"]
    var panelStates: [HUDPanelState] { [] }
    var settingsSchema: HUDSettingsSchema? { nil }
    func showPanel(_ id: String) throws {}
    func hidePanel(_ id: String) throws {}
    func settings() -> [String: Any] { stored }
    func updateSettings(_ values: [String: String]) throws { stored.merge(values) { _, b in b } }
    func quit() {}
}
