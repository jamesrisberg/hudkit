import XCTest
import AppKit
import SwiftUI
@testable import HUDKit

/// `HUDWidgetHost`: the `widget` verb, instance lifecycle, edit/reveal, events, windows.
/// Windows are created and configured but never ordered on screen (`presentsWindows = false`).
@MainActor
final class WidgetHostTests: XCTestCase {
    private var host: HUDWidgetHost!
    private var events: [[String: Any]] = []

    static let manifest = HUDManifest(id: "dev.widgets", name: "Widgets", socket: "widgets", panels: [
        HUDManifest.Panel(id: "clock", title: "Clock", kind: .widget,
                          widget: HUDWidgetSpec(sizes: [.small, .medium], defaultSize: .small, settingsSchema: "clock.json")),
        HUDManifest.Panel(id: "weather", title: "Weather", kind: .widget,
                          widget: HUDWidgetSpec(sizes: [.medium, .large], defaultSize: .medium, multiple: false)),
        HUDManifest.Panel(id: "main", title: "Main", kind: .hover),
    ])
    static let clockSchema = HUDSettingsSchema(settings: [
        HUDSettingsSchema.Field(key: "seconds", type: .bool, default: .bool(false)),
        HUDSettingsSchema.Field(key: "zone", type: .string, default: .string("local")),
        HUDSettingsSchema.Field(key: "scale", type: .number, default: .double(1.25), min: 0.5, max: 2),
    ])

    override func setUp() {
        events = []
        host = HUDWidgetHost(manifest: Self.manifest)
        host.presentsWindows = false
        host.schemas["clock"] = Self.clockSchema
        host.register("clock") { ctx in Text(ctx.instance) }
        host.register("weather") { _ in Text("Sunny") }
        host.onEvent = { [unowned self] in self.events.append($0) }
    }

    private func call(_ args: [String: String]) -> [String: Any] { host.handle(args) }

    @discardableResult
    private func create(_ id: String, type: String = "clock", size: String = "small", frame: String = "10,20,170,170",
                        extra: [String: String] = [:]) -> [String: Any] {
        call(["action": "create", "instance": id, "type": type, "size": size, "frame": frame].merging(extra) { _, b in b })
    }

    private func error(_ r: [String: Any]) -> String? {
        XCTAssertEqual(r["ok"] as? Bool, false, "expected a failure: \(r)")
        return r["error"] as? String
    }

    // MARK: - Registration

    func testTypesAreTheRegisteredOnes() {
        XCTAssertEqual(host.types, ["clock", "weather"])
        XCTAssertEqual(host.spec(for: "weather")?.multiple, false)
        let undeclared = HUDWidgetHost(manifest: nil)
        undeclared.register("x") { _ in EmptyView() }
        XCTAssertEqual(undeclared.spec(for: "x"), HUDWidgetSpec(), "a type missing from the manifest gets the default spec")
        XCTAssertNil(undeclared.spec(for: "y"))
    }

    // MARK: - create

    func testCreate() throws {
        let r = create("a", extra: ["settings": #"{"seconds": true}"#])
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        let json = try XCTUnwrap(r["instance"] as? [String: Any])
        XCTAssertEqual(json["instance"] as? String, "a")
        XCTAssertEqual(json["type"] as? String, "clock")
        XCTAssertEqual(json["size"] as? String, "small")
        XCTAssertEqual(json["frame"] as? [Double], [10, 20, 170, 170])
        XCTAssertEqual(json["layer"] as? String, "desktop")
        XCTAssertEqual((json["settings"] as? [String: Any])?["seconds"] as? Bool, true)

        let instance = try XCTUnwrap(host.instance("a"))
        XCTAssertEqual(instance, HUDWidgetInstance(id: "a", type: "clock", size: .small,
                                                   frame: CGRect(x: 10, y: 20, width: 170, height: 170),
                                                   layer: .desktop, settings: ["seconds": .bool(true)]))
        let window = try XCTUnwrap(host.window(for: "a"))
        XCTAssertEqual(window.frame, CGRect(x: 10, y: 20, width: 170, height: 170))
        XCTAssertEqual(window.behavior, .widget)
        XCTAssertEqual(window.level, HUDPanelWindow.widgetDesktopLevel)
        XCTAssertFalse(window.isMovable, "widgets are locked outside edit mode")
        XCTAssertFalse(window.canBecomeKey)

        let ctx = try XCTUnwrap(host.context(for: "a"))
        XCTAssertEqual(ctx.instance, "a")
        XCTAssertEqual(ctx.type, "clock")
        XCTAssertEqual(ctx.size, .small)
        XCTAssertEqual(ctx.settings, ["seconds": .bool(true)])
        XCTAssertEqual(ctx["seconds"], .bool(true))
        XCTAssertEqual(ctx["zone"], .string("local"), "unset keys read the schema default")
        XCTAssertNil(ctx["nope"])
        XCTAssertFalse(ctx.isEditing)
        XCTAssertTrue(events.isEmpty, "MacHUD's own commands do not echo events")
    }

    func testCreateDefaults() throws {
        XCTAssertEqual(call(["action": "create", "instance": "w", "type": "weather"])["ok"] as? Bool, true)
        let w = try XCTUnwrap(host.instance("w"))
        XCTAssertEqual(w.size, .medium, "the declared default size")
        XCTAssertEqual(w.layer, .desktop)
        XCTAssertEqual(w.frame.size, HUDWidgetSize.medium.points(), "no frame: the nominal size")
        XCTAssertEqual(w.settings, [:])
    }

    func testCreateErrors() {
        XCTAssertEqual(error(call(["action": "create", "type": "clock"])), "widget create needs instance=")
        XCTAssertEqual(error(create("a", type: "")), "widget create needs type=")
        XCTAssertEqual(error(create("a", type: "radar")), "no widget type radar (clock, weather)")
        XCTAssertEqual(error(create("a", size: "large")), "clock size must be one of small, medium")
        XCTAssertEqual(error(create("a", size: "huge")), "size must be small, medium, large or extraLarge")
        XCTAssertEqual(error(create("a", frame: "1,2,3")), "frame must be x,y,w,h")
        XCTAssertEqual(error(create("a", frame: "1,2,0,5")), "frame must have a positive width and height")
        XCTAssertEqual(error(create("a", extra: ["layer": "sky"])), "layer must be desktop or float")
        XCTAssertEqual(error(create("a", extra: ["settings": "[1]"])), "settings must be a JSON object")
        XCTAssertEqual(error(create("a", extra: ["settings": #"{"scale": 9}"#])), "scale must be at most 2")
        XCTAssertEqual(error(create("a", extra: ["settings": #"{"seconds": "maybe"}"#])), "seconds must be true or false")
        XCTAssertTrue(host.instances.isEmpty, "a failed create changes nothing")

        create("a")
        XCTAssertEqual(error(create("a")), "widget a exists")
        XCTAssertEqual(call(["action": "create", "instance": "w1", "type": "weather"])["ok"] as? Bool, true)
        XCTAssertEqual(error(call(["action": "create", "instance": "w2", "type": "weather"])), "weather allows one instance")
    }

    func testSettingsAreTypedByTheSchemaAndUnknownKeysKept() throws {
        create("a", extra: ["settings": #"{"seconds": "on", "scale": 2, "extra": "kept"}"#])
        XCTAssertEqual(host.instance("a")?.settings,
                       ["seconds": .bool(true), "scale": .double(2), "extra": .string("kept")])
    }

    func testCLIForm() {
        let args = HUDSocketClient.parseArguments(["create", "instance=a", "type=clock", "frame=0,0,170,170", "layer=float"])
        XCTAssertEqual(call(args)["ok"] as? Bool, true)
        XCTAssertEqual(host.instance("a")?.layer, .float)
        XCTAssertEqual(call(HUDSocketClient.parseArguments(["list"]))["ok"] as? Bool, true)
        XCTAssertEqual(call(HUDSocketClient.parseArguments(["edit", "on"]))["editing"] as? Bool, true)
        XCTAssertEqual(call(HUDSocketClient.parseArguments(["edit", "off"]))["editing"] as? Bool, false)
        XCTAssertEqual(call(HUDSocketClient.parseArguments(["remove", "instance=a"]))["ok"] as? Bool, true)
        XCTAssertEqual(call([:])["ok"] as? Bool, true, "no sub-verb lists")
        XCTAssertEqual(error(call(["action": "explode"])),
                       "widget action must be one of create, update, remove, list, sync, edit, reveal, schema")
    }

    // MARK: - update, remove, list

    func testUpdate() throws {
        create("a")
        let r = call(["action": "update", "instance": "a", "frame": "100,200,356,170", "size": "medium", "layer": "float",
                      "settings": #"{"zone": "UTC"}"#])
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        let a = try XCTUnwrap(host.instance("a"))
        XCTAssertEqual(a.frame, CGRect(x: 100, y: 200, width: 356, height: 170))
        XCTAssertEqual(a.size, .medium)
        XCTAssertEqual(a.layer, .float)
        XCTAssertEqual(a.settings, ["zone": .string("UTC")], "settings= replaces the instance's settings")
        XCTAssertEqual(host.window(for: "a")?.level, .floating)
        XCTAssertEqual(host.window(for: "a")?.frame, a.frame)
        XCTAssertEqual(host.context(for: "a")?.size, .medium)
        XCTAssertEqual(host.context(for: "a")?.layer, .float)

        // size alone keeps the top-left corner and takes the nominal size
        XCTAssertEqual(call(["action": "update", "instance": "a", "size": "small"])["ok"] as? Bool, true)
        XCTAssertEqual(host.instance("a")?.frame, CGRect(x: 100, y: 200, width: 170, height: 170).offsetBy(dx: 0, dy: 0))

        XCTAssertEqual(error(call(["action": "update", "instance": "zz", "layer": "float"])), "no such widget zz")
        XCTAssertEqual(error(call(["action": "update", "instance": "a", "size": "large"])), "clock size must be one of small, medium")
        XCTAssertEqual(host.instance("a")?.size, .small, "a failed update changes nothing")
        XCTAssertEqual(error(call(["action": "update", "instance": "a", "settings": #"{"scale": 0}"#])), "scale must be at least 0.5")
    }

    func testRemoveAndList() throws {
        create("a")
        create("b", frame: "200,20,170,170", extra: ["layer": "float"])
        let list = call(["action": "list"])
        XCTAssertEqual((list["instances"] as? [[String: Any]])?.compactMap { $0["instance"] as? String }, ["a", "b"])
        XCTAssertEqual(list["editing"] as? Bool, false)
        XCTAssertEqual(list["revealed"] as? Bool, false)
        XCTAssertEqual(list["types"] as? [String], ["clock", "weather"])

        let window = try XCTUnwrap(host.window(for: "a"))
        let r = call(["action": "remove", "instance": "a"])
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["removed"] as? String, "a")
        XCTAssertNil(host.instance("a"))
        XCTAssertNil(host.window(for: "a"))
        XCTAssertNil(host.context(for: "a"))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(error(call(["action": "remove", "instance": "a"])), "no such widget a")
        XCTAssertEqual(error(call(["action": "remove"])), "widget remove needs instance=")
        XCTAssertEqual(host.instances.map(\.id), ["b"])
    }

    // MARK: - sync

    func testSyncReplacesEverythingAndKeepsWindowsOfSurvivors() throws {
        create("a")
        create("b")
        let aWindow = try XCTUnwrap(host.window(for: "a"))
        let instances = #"""
        [{"instance": "a", "type": "clock", "size": "medium", "frame": [5, 6, 356, 170], "layer": "float", "settings": {"seconds": true}},
         {"instance": "c", "type": "weather", "frame": "1,2,356,170"},
         {"instance": "d", "type": "radar", "frame": [0, 0, 10, 10]},
         {"type": "clock"}]
        """#
        let r = call(["action": "sync", "instances": instances])
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        XCTAssertEqual(host.instances.map(\.id), ["a", "c"])
        XCTAssertTrue(host.window(for: "a") === aWindow, "a surviving instance keeps its window")
        XCTAssertEqual(host.instance("a")?.frame, CGRect(x: 5, y: 6, width: 356, height: 170))
        XCTAssertEqual(host.instance("a")?.layer, .float)
        XCTAssertEqual(host.instance("a")?.settings, ["seconds": .bool(true)])
        XCTAssertEqual(host.instance("c")?.size, .medium)
        XCTAssertNil(host.window(for: "b"), "b was not in the list")
        let rejected = try XCTUnwrap(r["rejected"] as? [[String: Any]])
        XCTAssertEqual(rejected.map { $0["instance"] as? String }, ["d", nil])
        XCTAssertEqual(rejected.map { $0["error"] as? String }, ["no widget type radar (clock, weather)", "widget needs instance"])
        XCTAssertEqual((r["instances"] as? [[String: Any]])?.count, 2)

        XCTAssertEqual(error(call(["action": "sync", "instances": "{}"])), "instances must be a JSON array")
        XCTAssertEqual(error(call(["action": "sync"])), "widget sync needs instances=<JSON array>")
        XCTAssertEqual(call(["action": "sync", "instances": "[]"])["ok"] as? Bool, true)
        XCTAssertTrue(host.instances.isEmpty)
    }

    func testSyncHonoursMultipleFalse() {
        let r = call(["action": "sync", "instances": #"[{"instance": "w1", "type": "weather"}, {"instance": "w2", "type": "weather"}]"#])
        XCTAssertEqual(host.instances.map(\.id), ["w1"])
        XCTAssertEqual((r["rejected"] as? [[String: Any]])?.first?["error"] as? String, "weather allows one instance")
    }

    // MARK: - edit and reveal

    func testEditModeUnlocksAndRaises() throws {
        create("a")
        create("f", extra: ["layer": "float"])
        let r = call(["action": "edit", "state": "on"])
        XCTAssertEqual(r["editing"] as? Bool, true)
        XCTAssertTrue(host.isEditing)
        let a = try XCTUnwrap(host.window(for: "a"))
        XCTAssertTrue(a.isMovable)
        XCTAssertFalse(a.isMovableByWindowBackground, "dragged by the edit-mode drag surface, which reports the move")
        XCTAssertEqual(a.level, .floating, "editing raises desktop widgets so they can be reached")
        XCTAssertEqual(host.context(for: "a")?.isEditing, true)

        create("late")
        XCTAssertEqual(host.context(for: "late")?.isEditing, true, "a widget created while editing starts in edit mode")
        XCTAssertTrue(host.window(for: "late")?.isMovable ?? false)

        XCTAssertEqual(call(["action": "edit", "state": "off"])["editing"] as? Bool, false)
        XCTAssertFalse(a.isMovable)
        XCTAssertEqual(a.level, HUDPanelWindow.widgetDesktopLevel)
        XCTAssertEqual(host.window(for: "f")?.level, .floating, "a float widget stays floating")
        XCTAssertEqual(host.context(for: "a")?.isEditing, false)
        XCTAssertEqual(error(call(["action": "edit", "state": "sideways"])), "widget edit needs on or off")
        XCTAssertEqual(error(call(["action": "edit"])), "widget edit needs on or off")
    }

    func testRevealRaisesDesktopWidgets() throws {
        create("a")
        XCTAssertEqual(call(["action": "reveal", "on": "1"])["revealed"] as? Bool, true)
        XCTAssertEqual(host.window(for: "a")?.level, .floating)
        XCTAssertFalse(host.window(for: "a")?.isMovable ?? true, "reveal does not unlock")
        XCTAssertEqual(call(["action": "reveal", "state": "false"])["revealed"] as? Bool, false)
        XCTAssertEqual(host.window(for: "a")?.level, HUDPanelWindow.widgetDesktopLevel)
    }

    func testSchema() throws {
        let r = call(["action": "schema", "type": "clock"])
        XCTAssertEqual(r["type"] as? String, "clock")
        let schema = try XCTUnwrap(HUDSettingsSchema(json: try XCTUnwrap(r["schema"])))
        XCTAssertEqual(schema, Self.clockSchema)
        XCTAssertEqual(error(call(["action": "schema", "type": "weather"])), "unsupported: no settings schema for weather")
        XCTAssertEqual(error(call(["action": "schema", "type": "radar"])), "no widget type radar (clock, weather)")
        XCTAssertEqual(error(call(["action": "schema"])), "widget schema needs type=")
    }

    func testSchemasLoadFromTheBundle() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("W-\(UUID().uuidString).app")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Self.clockSchema.encoded().write(to: resources.appendingPathComponent("clock.json"))
        XCTAssertEqual(HUDSettingsSchema.load(widget: "clock", manifest: Self.manifest, bundleURL: bundle), Self.clockSchema)
        XCTAssertNil(HUDSettingsSchema.load(widget: "weather", manifest: Self.manifest, bundleURL: bundle))
        XCTAssertNil(HUDSettingsSchema.load(widget: "main", manifest: Self.manifest, bundleURL: bundle), "not a widget panel")
        XCTAssertEqual(HUDWidgetHost(manifest: Self.manifest, bundleURL: bundle).schemas, ["clock": Self.clockSchema])
    }

    // MARK: - Events (user changes, reported for MacHUD to persist)

    func testUserMoveEmitsFrame() throws {
        create("a")
        host.userMoved("a", to: CGRect(x: 300, y: 400, width: 170, height: 170))
        XCTAssertEqual(host.instance("a")?.frame, CGRect(x: 300, y: 400, width: 170, height: 170))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["instance"] as? String, "a")
        XCTAssertEqual(events[0]["type"] as? String, "clock")
        XCTAssertEqual(events[0]["change"] as? String, "frame")
        XCTAssertEqual(events[0]["frame"] as? [Double], [300, 400, 170, 170])
        host.userMoved("a", to: CGRect(x: 300, y: 400, width: 170, height: 170))
        XCTAssertEqual(events.count, 1, "no event for a move to where it already is")
    }

    func testChromeRequestsEmitEventsWithoutActing() throws {
        create("a")
        host.requestResize("a")
        XCTAssertEqual(events.last?["change"] as? String, "size")
        XCTAssertEqual(events.last?["size"] as? String, "medium", "the next declared size")
        XCTAssertEqual(host.instance("a")?.size, .small, "MacHUD answers with update size= frame=")
        host.requestRemove("a")
        XCTAssertEqual(events.last?["change"] as? String, "remove")
        XCTAssertNotNil(host.instance("a"), "MacHUD answers with remove")
        host.requestConfigure("a")
        XCTAssertEqual(events.last?["change"] as? String, "configure")
        XCTAssertEqual(events.count, 3)
    }

    func testContextSettingsChangeAppliesAndEmits() throws {
        create("a", extra: ["settings": #"{"zone": "UTC"}"#])
        let ctx = try XCTUnwrap(host.context(for: "a"))
        try ctx.updateSettings(["seconds": .bool(true)])
        XCTAssertEqual(ctx.settings, ["zone": .string("UTC"), "seconds": .bool(true)], "merged into the current settings")
        XCTAssertEqual(host.instance("a")?.settings, ctx.settings)
        XCTAssertEqual(events.last?["change"] as? String, "settings")
        let sent = try XCTUnwrap(events.last?["settings"] as? [String: Any])
        XCTAssertEqual(sent["seconds"] as? Bool, true)
        XCTAssertEqual(sent["zone"] as? String, "UTC")

        XCTAssertThrowsError(try ctx.updateSettings(["scale": .double(5)]))
        XCTAssertEqual(events.count, 1, "a rejected change emits nothing")
        XCTAssertNil(ctx.settings["scale"])
    }

    func testOpenAppCallsTheHandlerElseEmits() throws {
        create("a")
        let ctx = try XCTUnwrap(host.context(for: "a"))
        ctx.openApp()
        XCTAssertEqual(events.last?["change"] as? String, "open", "no handler: MacHUD may summon the app")
        var opened: String?
        host.onOpen = { opened = $0.instance }
        ctx.openApp()
        XCTAssertEqual(opened, "a")
        XCTAssertEqual(events.count, 1)
    }

    func testRouterPublishesWidgetEvents() throws {
        let dir = URL(fileURLWithPath: "/tmp/hudkit-w-\(getpid())")
        let server = HUDSocketServer(path: HUDSocket.path(for: "w", in: dir))
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        let panels = WidgetPanelsHost()
        let router = HUDControlRouter(host: panels, server: server, manifest: Self.manifest)
        router.install()
        let widgets = HUDWidgetHost(manifest: Self.manifest)
        widgets.presentsWindows = false
        widgets.register("clock") { _ in EmptyView() }
        router.widgetHost = widgets
        XCTAssertTrue(server.start())

        let got = expectation(description: "widget event")
        let client = HUDSocketClient(path: server.path, timeout: 5)
        let sub = try client.subscribe(events: ["widget"], onEvent: { obj in
            if obj["event"] as? String == "widget", obj["change"] as? String == "frame", obj["instance"] as? String == "a" { got.fulfill() }
        })
        defer { sub.cancel() }
        var created: [String: Any]?
        router.handle("widget", args: ["action": "create", "instance": "a", "type": "clock"]) { created = $0 }
        XCTAssertEqual(created?["ok"] as? Bool, true)
        widgets.userMoved("a", to: CGRect(x: 1, y: 2, width: 170, height: 170))
        wait(for: [got], timeout: 5)
    }

    // MARK: - Window recipe

    func testWidgetWindowRecipe() {
        let w = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 170, height: 170), behavior: .widget)
        XCTAssertEqual(w.behavior, .widget)
        XCTAssertTrue(w.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(w.styleMask.contains(.borderless))
        XCTAssertEqual(w.collectionBehavior, HUDPanelWindow.widgetCollectionBehavior)
        XCTAssertEqual(HUDPanelWindow.widgetCollectionBehavior, [.canJoinAllSpaces, .stationary, .ignoresCycle])
        XCTAssertEqual(w.level, HUDPanelWindow.widgetDesktopLevel)
        XCTAssertEqual(HUDPanelWindow.widgetDesktopLevel.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        XCTAssertLessThan(HUDPanelWindow.widgetDesktopLevel.rawValue, NSWindow.Level.normal.rawValue, "below every app window")
        XCTAssertEqual(HUDPanelWindow.level(for: .desktop), HUDPanelWindow.widgetDesktopLevel)
        XCTAssertEqual(HUDPanelWindow.level(for: .float), .floating)
        XCTAssertFalse(w.canBecomeKey)
        XCTAssertFalse(w.canBecomeMain)
        XCTAssertFalse(w.isMovable)
        XCTAssertFalse(w.hidesOnDeactivate)
        if let prevents = w.preventsActivation { XCTAssertTrue(prevents, "a click never activates the app") }
        w.keyable = true
        XCTAssertTrue(w.canBecomeKey, "a widget with text input opts in")
        w.orderOut(nil)
    }

    func testKeyableRegistration() {
        host.register("note", keyable: true) { _ in TextField("", text: .constant("")) }
        XCTAssertEqual(call(["action": "create", "instance": "n", "type": "note"])["ok"] as? Bool, true)
        XCTAssertTrue(host.window(for: "n")?.canBecomeKey ?? false)
    }

    // MARK: - Snapshot

    func testSnapshotRendersATypeAtASize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try host.writeSnapshot(type: "clock", size: .medium, settings: ["seconds": .bool(true)], to: url)
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertEqual(image.size, HUDWidgetSize.medium.points())
        XCTAssertThrowsError(try host.writeSnapshot(type: "radar", size: .small, to: url))
        XCTAssertThrowsError(try host.writeSnapshot(type: "clock", size: .large, to: url), "a size the type does not declare")
    }
}

@MainActor
private final class WidgetPanelsHost: HUDPanelHost {
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "main", visible: false)] }
    func showPanel(_ id: String) throws {}
    func hidePanel(_ id: String) throws {}
    func quit() {}
}
