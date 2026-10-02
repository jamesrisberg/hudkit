import AppKit

/// Maps the required MacHUD verbs onto a `HUDPanelHost`:
///
/// | command | args |
/// |---|---|
/// | `hello` | → `{hudkit, app, name, version?, panels:[...], verbs}` (`hudkit` is the contract version, `version` the app's, `verbs` always `requiredVerbs`) |
/// | `panel` | `id=` plus `action=show/hide/toggle/frame/mode` (or the sub-verb as a bare flag, `panel show id=x`); `frame` takes `x y w h`; `mode` takes `mode=compact/full/parked` or the bare mode, plus optional `edge=left/right/top/bottom` and `peek=` for `parked`; `show`/`toggle` take optional `from=<edge> anchor=x,y,w,h reason=hover/click/summon`, `hide` takes `to=<edge>` (plus `anchor`/`reason`), all passed to `showPanel/hidePanel/togglePanel(_:options:)` (see `HUDPanelTransition`) |
/// | `state` | → `{panels:[{id, visible, mode, badge?, status?, onActiveSpace?}]}` (`onActiveSpace`: see `HUDPanelHostDefaults.onActiveSpace`) |
/// | `settings` | `get [key=]` / `set k=v ...` (values the host's schema describes are validated against it first) / `schema` (→ `{schema}`, see `HUDSettingsSchema`) |
/// | `action` | `action <verb> [k=v…]` (bare verb, recorded as `_` by the CLI parser) or `name=<verb>`, plus payload args |
/// | `quit` | replies, then `host.quit()` |
/// | `menu` | → `{items:[{id, title, kind: item/separator/submenu, enabled, state: on/off/mixed, keyEquivalent?, modifiers?, items?}]}`, the app's status menu (`menuProvider`, see `HUDMenuBridge`); `{ok:false, error:"no menu"}` without a provider |
/// | `menu-invoke` | `id=` (from `menu`) plus optional `title=` guard: replies, then performs the item on the main thread |
/// | `widget` | `create/update/remove/list/sync/edit/reveal/schema` on the app's desktop widgets (`widgetHost`, see `HUDWidgetHost`); `{ok:false, error:"no widgets"}` without one |
///
/// `menu` and `menu-invoke` are optional (`optionalVerbs`): `hello` lists them only when the
/// app set `menuProvider`. `widget` likewise (`widgetVerb`): listed only when the app set
/// `widgetHost`, whose user changes the router publishes as `widget` events. `hello` also
/// carries `statusItem` (visibility and the host it follows) once the app attached a
/// `HUDStatusItemPolicy`, and `settings` then serves the policy's `menuBar.consumed` opt-out
/// alongside the host's own settings.
///
/// File drops: a panel whose manifest `capabilities` include `acceptsFileDrop`
/// (`HUDDrop.capability`) gets files dropped on its MacHUD dock button as
/// `action drop paths=<p1|p2>` (plus `id=<panel>` when the app has several panels): paths are percent-encoded then joined with `|`, so
/// decode them with `HUDDrop.urls(from: args)` in `performAction`. Reply `{"ok": true}` once
/// the files are accepted (not necessarily processed); an `{"ok": false, "error": ...}` makes
/// MacHUD bounce the drop back. Panels without the capability never receive drops.
///
/// `subscribe` is served by `HUDSocketServer`; call `publishState()` whenever panel state
/// changes and subscribers receive `{"event": "state", "panels": [...]}`.
///
/// ```swift
/// let server = HUDSocketServer(path: HUDSocket.path(for: "myapp"))
/// let router = HUDControlRouter(host: self, server: server)
/// router.install()
/// server.start()
/// ```
@MainActor
public final class HUDControlRouter {
    public weak var host: HUDPanelHost?
    public let server: HUDSocketServer
    /// Manifest used for `hello`'s app id and name (defaults to the bundle's own).
    public var manifest: HUDManifest?
    /// The app's own version for `hello` (`version`): the bundle's `CFBundleShortVersionString`,
    /// which the shared build script fills from the repo's `VERSION` file. Nil outside a bundle.
    public var appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    public static let requiredVerbs = ["hello", "panel", "state", "subscribe", "settings", "action", "quit"]
    /// Served by every router, but only listed in `hello` when `menuProvider` is set.
    public static let optionalVerbs = ["menu", "menu-invoke"]
    /// Served by every router, but only listed in `hello` when `widgetHost` is set.
    public static let widgetVerb = "widget"
    /// The app's desktop widgets, served by the `widget` verb. Setting it routes the host's
    /// user changes (`onEvent`) to subscribers as `{"event": "widget", ...}`.
    public var widgetHost: HUDWidgetHost? {
        didSet {
            if oldValue !== widgetHost { oldValue?.onEvent = nil }
            widgetHost?.onEvent = { [weak server] payload in server?.publish("widget", payload: payload) }
        }
    }
    /// The app's status menu for `menu`/`menu-invoke`, e.g. `{ [weak self] in self?.statusItem.menu }`.
    public var menuProvider: (() -> NSMenu?)?
    /// The status item policy `hello` and `settings` report; defaults to the first one this
    /// process attached.
    public var statusItemPolicy: HUDStatusItemPolicy? {
        get { explicitPolicy ?? HUDStatusItemPolicy.attached.first }
        set { explicitPolicy = newValue }
    }
    private var explicitPolicy: HUDStatusItemPolicy?
    /// Republishes `state` when a hover panel's Space settles (`onActiveSpace`); removed with
    /// the router.
    private var spaceObserver: NotificationObservation?
    static let panelVerbs = ["show", "hide", "toggle", "frame", "mode"]
    /// Args that address the panel command itself; everything else is an option.
    static let panelReserved: Set<String> = ["id", "action", "_", "show", "hide", "toggle"]

    public init(host: HUDPanelHost, server: HUDSocketServer, manifest: HUDManifest? = HUDManifest.main) {
        self.host = host
        self.server = server
        self.manifest = manifest
    }

    /// Registers the contract commands on the server. Commands registered afterwards with the
    /// same names replace these.
    public func install() {
        spaceObserver = spaceObserver ?? NotificationObservation(NotificationCenter.default.addObserver(
            forName: HUDPanelWindow.activeSpaceDidSettleNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishState() }
        })
        for verb in Self.requiredVerbs + Self.optionalVerbs + [Self.widgetVerb] where verb != "subscribe" {
            server.register(verb) { [weak self] args, done in
                guard let self else { done(["ok": false, "error": "router gone"]); return }
                self.handle(verb, args: args, done: done)
            }
        }
    }

    /// Pushes the current state to subscribers.
    public func publishState() {
        guard let host else { return }
        server.publish("state", payload: ["panels": host.panelStates.map { HUDPanelHostDefaults.stateJSON($0, of: host) }])
    }

    /// Pushes a single panel's badge/status change (a `state` event restricted to that panel).
    public func publishPanel(_ id: String) {
        guard let host, let state = host.panelState(id) else { return }
        server.publish("state", payload: ["panels": [HUDPanelHostDefaults.stateJSON(state, of: host)]])
    }

    /// Handles one contract command. Exposed for tests and for apps that route manually.
    public func handle(_ verb: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        guard let host else { done(["ok": false, "error": "host gone"]); return }
        do {
            switch verb {
            case "hello":
                var r: [String: Any] = ["ok": true, "hudkit": HUDKit.version,
                                        "panels": host.panelDescriptors.map(\.json),
                                        "verbs": Self.requiredVerbs + (menuProvider == nil ? [] : Self.optionalVerbs)
                                            + (widgetHost == nil ? [] : [Self.widgetVerb])]
                if let manifest { r["app"] = manifest.id; r["name"] = manifest.name }
                if let appVersion { r["version"] = appVersion }
                if let statusItemPolicy { r["statusItem"] = statusItemPolicy.json }
                done(r)
            case "state":
                done(["ok": true, "panels": host.panelStates.map { HUDPanelHostDefaults.stateJSON($0, of: host) }])
            case "panel":
                try handlePanel(host, args: args, done: done)
            case "settings":
                let sub = args["action"] ?? (args["set"] != nil ? "set" : args["schema"] != nil ? "schema" : "get")
                switch sub {
                case "get":
                    var all = host.settings()
                    if let policy = statusItemPolicy { all[HUDStatusItemPolicy.consumedKey] = policy.consumed }
                    if let key = args["key"] {
                        guard let value = all[key] else { throw HUDControlError.invalid("no such setting \(key)") }
                        done(["ok": true, "key": key, "value": value])
                    } else {
                        done(["ok": true, "settings": all])
                    }
                case "set":
                    var values = args
                    // `_` is the bare sub-verb the CLI parser records (`settings set k=v` -> `_: "set"`).
                    for reserved in ["action", "set", "get", "schema", "_"] { values[reserved] = nil }
                    if let key = values.removeValue(forKey: "key") {
                        values[key] = values.removeValue(forKey: "value") ?? ""
                    }
                    guard !values.isEmpty else { throw HUDControlError.invalid("settings set needs key=value") }
                    var consumed: Bool?
                    if statusItemPolicy != nil, let raw = values.removeValue(forKey: HUDStatusItemPolicy.consumedKey) {
                        guard case .bool(let b) = try Self.consumedField.parse(raw) else {
                            throw HUDControlError.invalid("\(HUDStatusItemPolicy.consumedKey) must be true or false")
                        }
                        consumed = b
                    }
                    // Values the schema describes are checked against it (type, enum options,
                    // `min`/`max`) before the host sees any, so a bad value changes nothing.
                    // Keys the schema does not list are left to the host.
                    if let schema = host.settingsSchema {
                        for (key, raw) in values.sorted(by: { $0.key < $1.key }) { _ = try schema.field(key)?.parse(raw) }
                    }
                    if !values.isEmpty { try host.updateSettings(values) }
                    if let consumed { statusItemPolicy?.consumed = consumed }
                    var all = host.settings()
                    if let policy = statusItemPolicy { all[HUDStatusItemPolicy.consumedKey] = policy.consumed }
                    done(["ok": true, "settings": all])
                case "schema":
                    var schema = host.settingsSchema
                    if statusItemPolicy != nil {
                        schema = schema ?? HUDSettingsSchema(settings: [])
                        if !(schema!.settings.contains { $0.key == HUDStatusItemPolicy.consumedKey }) {
                            schema!.settings.append(Self.consumedField)
                        }
                    }
                    guard let schema else { throw HUDControlError.unsupported("no settings schema") }
                    done(["ok": true, "schema": schema.json])
                default:
                    throw HUDControlError.invalid("settings action must be get, set or schema")
                }
            case "action":
                // `action <verb> k=v...` (CLI records the bare verb under `_`) or `action name=<verb> k=v...`.
                var payload = args
                let name: String
                if let positional = args["_"], !positional.isEmpty {
                    name = positional
                    payload["_"] = nil
                    payload[positional] = nil
                } else if let named = args["name"], !named.isEmpty {
                    name = named
                    payload["name"] = nil
                } else {
                    throw HUDControlError.invalid("action verb required: action <verb> or name=<verb>")
                }
                host.performAction(name, args: payload, done: done)
            case "menu":
                guard let menu = menuProvider?() else { throw HUDMenuBridge.Failure.noMenu }
                done(["ok": true, "items": HUDMenuBridge.serialize(menu).map(\.json)])
            case "menu-invoke":
                guard let menu = menuProvider?() else { throw HUDMenuBridge.Failure.noMenu }
                guard let id = args["id"] ?? args["_"], !id.isEmpty else { throw HUDControlError.invalid("menu-invoke needs id=") }
                let item = try HUDMenuBridge.resolve(id, title: args["title"], in: menu)
                done(["ok": true, "id": id, "title": item.title])
                // After the reply, so an item that quits or opens a modal does not hold it up.
                DispatchQueue.main.async { MainActor.assumeIsolated { HUDMenuBridge.perform(item) } }
            case Self.widgetVerb:
                guard let widgetHost else { throw HUDControlError.invalid("no widgets") }
                done(widgetHost.handle(args))
            case "quit":
                done(["ok": true])
                DispatchQueue.main.async { [weak host] in host?.quit() }
            default:
                throw HUDControlError.invalid("unknown command \(verb)")
            }
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    }

    /// The `menuBar.consumed` field added to `settings schema` once a status item policy is attached.
    static let consumedField = HUDSettingsSchema.Field(
        key: HUDStatusItemPolicy.consumedKey, title: "Hide menu bar icon while MacHUD runs", type: .bool,
        default: .bool(true), group: "Menu Bar",
        help: "MacHUD shows this app's menu in its own; turn off to keep this app's icon too.")

    /// The options for `panel show/hide/toggle`: every arg except the command's own, with
    /// `from`/`to`/`anchor` validated.
    static func transitionOptions(_ args: [String: String]) throws -> [String: String] {
        let options = args.filter { !panelReserved.contains($0.key) }
        for key in ["from", "to"] {
            if let raw = options[key], HUDEdge(rawValue: raw) == nil {
                throw HUDControlError.invalid("\(key) must be left, right, top or bottom")
            }
        }
        if let raw = options["anchor"], HUDPanelTransition.parseAnchor(raw) == nil {
            throw HUDControlError.invalid("anchor must be x,y,w,h")
        }
        return options
    }

    private func handlePanel(_ host: HUDPanelHost, args: [String: String], done: @escaping ([String: Any]) -> Void) throws {
        let id = args["id"] ?? ""
        guard host.panelState(id) != nil else { throw HUDControlError.noSuchPanel(id) }
        let sub = args["action"] ?? Self.panelVerbs.first { args[$0] != nil } ?? "toggle"
        switch sub {
        case "show": try host.showPanel(id, options: try Self.transitionOptions(args))
        case "hide": try host.hidePanel(id, options: try Self.transitionOptions(args))
        case "toggle":
            let options = try Self.transitionOptions(args)
            // No options: keep calling the plain toggle so hosts that override only it still work.
            if options.isEmpty { try host.togglePanel(id) } else { try host.togglePanel(id, options: options) }
        case "frame":
            guard let x = args["x"].flatMap(Double.init), let y = args["y"].flatMap(Double.init),
                  let w = args["w"].flatMap(Double.init), let h = args["h"].flatMap(Double.init) else {
                throw HUDControlError.invalid("panel frame needs x= y= w= h=")
            }
            try host.setPanelFrame(id, frame: CGRect(x: x, y: y, width: w, height: h))
        case "mode":
            let raw = args["mode"].flatMap { $0 == "1" ? nil : $0 }
                ?? HUDPanelMode.allCases.map(\.rawValue).first { args[$0] != nil }
            guard let raw, let mode = HUDPanelMode(rawValue: raw) else {
                throw HUDControlError.invalid("panel mode needs compact, full or parked")
            }
            var options = HUDPanelModeOptions()
            if let raw = args["edge"] {
                guard let edge = HUDEdge(rawValue: raw) else {
                    throw HUDControlError.invalid("edge must be left, right, top or bottom")
                }
                options.edge = edge
            }
            options.peek = args["peek"].flatMap(Double.init).map { CGFloat($0) }
            try host.setPanelMode(id, mode: mode, options: options)
        default:
            throw HUDControlError.invalid("panel action must be one of \(Self.panelVerbs.joined(separator: ", "))")
        }
        var response: [String: Any] = ["ok": true]
        if let state = host.panelState(id) {
            response["visible"] = state.visible
            response["mode"] = state.mode.rawValue
            if let on = HUDPanelHostDefaults.onActiveSpace(id, of: host) { response["onActiveSpace"] = on }
        }
        done(response)
        publishState()
    }
}

/// Removes a block-based notification observer when released (a `@MainActor` class's deinit
/// cannot touch its non-Sendable token).
final class NotificationObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
