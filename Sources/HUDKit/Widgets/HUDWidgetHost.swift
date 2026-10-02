import AppKit
import SwiftUI

/// Serves an app's desktop widgets: the widget types it registers, the instances MacHUD
/// places, their windows, and the `widget` socket verb.
///
/// An app adds a widget with one manifest panel (`"kind": "widget"`, see `HUDWidgetSpec`) and
/// one `register` call; HUDKit creates, positions, raises and removes the windows.
///
/// ```swift
/// let widgets = HUDWidgetHost()                         // types' specs from the bundle manifest
/// widgets.register("clock") { ClockWidget(context: $0) }
/// control.router.widgetHost = widgets                   // serves `widget`, lists it in `hello`
/// ```
///
/// MacHUD owns the instance records (id, type, size, frame, layer, settings) and sends them;
/// the app keeps them in memory only. `widget` sub-verbs (`action=` or the CLI's bare word):
///
/// | sub-verb | args | reply |
/// |---|---|---|
/// | `create` | `instance= type= [size=] [frame=x,y,w,h] [layer=desktop\|float] [settings=<JSON object>]` | `{instance}` |
/// | `update` | `instance= [size=] [frame=] [layer=] [settings=]` (settings replace) | `{instance}` |
/// | `remove` | `instance=` | `{removed}` |
/// | `list` (default, with no args) | | `{instances, editing, revealed, types}` |
/// | `sync` | `instances=<JSON array of instance objects> [editing=on\|off] [revealed=on\|off]` (replace all, modes default off) | `{instances, rejected, droppedSettings, editing, revealed}` |
/// | `edit` | `state=on\|off` or bare `on`/`off` | `{editing}` |
/// | `reveal` | `state=on\|off` or bare `on`/`off` | `{revealed}` |
/// | `schema` | `type=` | `{type, schema}`: the type's per-instance settings schema |
///
/// What the user does to a widget is reported, not acted on, through `onEvent` (the router
/// publishes it as a `widget` event): `{"instance", "type", "change": "frame"|"size"|"remove"|
/// "configure"|"settings"|"open", ...}`.
@MainActor
public final class HUDWidgetHost {
    public static let subVerbs = ["create", "update", "remove", "list", "sync", "edit", "reveal", "schema"]

    /// The manifest whose `kind: widget` panels describe the types.
    public let manifest: HUDManifest?
    /// Per-type instance settings schemas, loaded from each type's `widget.settingsSchema` in
    /// the bundle. Settable (tests, `swift run`).
    public var schemas: [String: HUDSettingsSchema] = [:]
    /// False keeps windows off screen (tests): they are made and configured, never ordered in.
    public var presentsWindows = true
    /// Receives each user change as an event payload. `HUDControlRouter.widgetHost` sets it to
    /// publish `widget` events to subscribers.
    public var onEvent: (([String: Any]) -> Void)?
    /// Called by `HUDWidgetContext.openApp()`. Without it the host reports `change: open`.
    public var onOpen: ((HUDWidgetContext) -> Void)?

    /// MacHUD's edit mode: widgets unlocked (draggable, with remove/resize/settings controls)
    /// and raised above windows.
    public private(set) var isEditing = false
    /// Desktop-layer widgets temporarily raised above windows.
    public private(set) var isRevealed = false

    /// The registered type names, in registration order.
    public private(set) var types: [String] = []
    /// The instances, in the order they were created (or listed in the last `sync`).
    public var instances: [HUDWidgetInstance] { order.compactMap { controllers[$0]?.instance } }

    private struct Registration {
        var keyable: Bool
        var content: (HUDWidgetContext) -> AnyView
    }
    private var registrations: [String: Registration] = [:]
    private var controllers: [String: WidgetController] = [:]
    private var order: [String] = []
    private var workspaceObservers: [WorkspaceObservation] = []

    public init(manifest: HUDManifest? = HUDManifest.main, bundleURL: URL = Bundle.main.bundleURL) {
        self.manifest = manifest
        // The window server can drop a window's every-Space membership (see `reassertAllSpaces`);
        // waking and Space changes are when that shows, so widgets re-assert it then.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(WorkspaceObservation(center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.repairSpaces() }
            }))
        }
        guard let manifest else { return }
        for panel in manifest.widgetPanels {
            schemas[panel.id] = HUDSettingsSchema.load(widget: panel.id, manifest: manifest, bundleURL: bundleURL)
        }
    }

    // MARK: - Registration

    /// Registers the SwiftUI view for widget type `type` (a `kind: widget` panel id). `keyable`
    /// lets the widget's window take keyboard focus (text input); widgets otherwise never do.
    /// Registering a type again replaces its view in the instances already placed.
    public func register<Content: View>(_ type: String, keyable: Bool = false,
                                        @ViewBuilder content: @escaping (HUDWidgetContext) -> Content) {
        if registrations[type] == nil { types.append(type) }
        let registration = Registration(keyable: keyable, content: { AnyView(content($0)) })
        registrations[type] = registration
        for id in order {
            guard let c = controllers[id], c.instance.type == type else { continue }
            c.setContent(registration.content(c.context), keyable: keyable)
        }
    }

    /// The type's manifest description; the defaults for a registered type the manifest does
    /// not declare; nil for a type that is not registered.
    public func spec(for type: String) -> HUDWidgetSpec? {
        guard registrations[type] != nil else { return nil }
        return manifest?.panel(id: type)?.widget ?? HUDWidgetSpec()
    }

    public func instance(_ id: String) -> HUDWidgetInstance? { controllers[id]?.instance }
    public func context(for id: String) -> HUDWidgetContext? { controllers[id]?.context }
    public func window(for id: String) -> HUDPanelWindow? { controllers[id]?.window }

    // MARK: - The `widget` verb

    /// Handles one `widget` command (what the router calls).
    public func handle(_ args: [String: String]) -> [String: Any] {
        let named = args["action"]
            ?? args["_"].flatMap { Self.subVerbs.contains($0) ? $0 : nil }
            ?? Self.subVerbs.first { args[$0] != nil }
        // Only a bare `widget` lists; args without a sub-verb are a mistake (a `sync` that lost
        // its action must not look like it worked).
        let sub = named ?? (args.isEmpty ? "list" : "")
        do {
            switch sub {
            case "create": return try create(args)
            case "update": return try update(args)
            case "remove":
                guard let id = args["instance"], !id.isEmpty else { throw HUDControlError.invalid("widget remove needs instance=") }
                guard controllers[id] != nil else { throw HUDControlError.invalid("no such widget \(id)") }
                remove(id)
                return ["ok": true, "removed": id]
            case "list":
                return ["ok": true, "instances": instances.map(\.json), "editing": isEditing, "revealed": isRevealed, "types": types]
            case "sync": return try sync(args)
            case "edit":
                setEditing(try Self.onOff(args, verb: "edit"))
                return ["ok": true, "editing": isEditing]
            case "reveal":
                setRevealed(try Self.onOff(args, verb: "reveal"))
                return ["ok": true, "revealed": isRevealed]
            case "schema":
                guard let type = args["type"], !type.isEmpty else { throw HUDControlError.invalid("widget schema needs type=") }
                guard spec(for: type) != nil else { throw unknownType(type) }
                guard let schema = schemas[type] else { throw HUDControlError.unsupported("no settings schema for \(type)") }
                return ["ok": true, "type": type, "schema": schema.json]
            default:
                throw HUDControlError.invalid("widget action must be one of \(Self.subVerbs.joined(separator: ", "))")
            }
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    private func create(_ args: [String: String]) throws -> [String: Any] {
        guard let id = args["instance"], !id.isEmpty else { throw HUDControlError.invalid("widget create needs instance=") }
        guard let type = args["type"], !type.isEmpty else { throw HUDControlError.invalid("widget create needs type=") }
        var fields: [String: Any] = ["instance": id, "type": type]
        for key in ["size", "frame", "layer", "settings"] { fields[key] = args[key] }
        let instance = try validated(fields, among: instances).instance
        place(instance)
        return ["ok": true, "instance": instance.json]
    }

    private func update(_ args: [String: String]) throws -> [String: Any] {
        guard let id = args["instance"], !id.isEmpty else { throw HUDControlError.invalid("widget update needs instance=") }
        guard let current = controllers[id]?.instance, let spec = spec(for: current.type) else {
            throw HUDControlError.invalid("no such widget \(id)")
        }
        var next = current
        if let raw = args["size"] {
            next.size = try Self.size(raw, spec: spec, type: current.type)
            if args["frame"] == nil {
                // Keep the top-left corner; take the nominal size until MacHUD sends a frame.
                let points = next.size.points()
                next.frame = CGRect(x: current.frame.minX, y: current.frame.maxY - points.height,
                                    width: points.width, height: points.height)
            }
        }
        if let raw = args["frame"] { next.frame = try HUDWidgetInstance.parseFrame(raw) }
        if let raw = args["layer"] { next.layer = try HUDWidgetInstance.parseLayer(raw) }
        if let raw = args["settings"] { next.settings = try HUDWidgetInstance.parseSettings(raw, schema: schemas[current.type]) }
        place(next)
        return ["ok": true, "instance": next.json]
    }

    private func sync(_ args: [String: String]) throws -> [String: Any] {
        guard let text = args["instances"] else { throw HUDControlError.invalid("widget sync needs instances=<JSON array>") }
        guard let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] else {
            throw HUDControlError.invalid("instances must be a JSON array")
        }
        // Edit and reveal are part of the state a sync restores: MacHUD may have quit mid-edit.
        let editing = try args["editing"].map { try Self.bool($0, name: "editing") } ?? false
        let revealed = try args["revealed"].map { try Self.bool($0, name: "revealed") } ?? false
        var accepted: [HUDWidgetInstance] = []
        var rejected: [[String: Any]] = []
        var dropped: [[String: Any]] = []
        for entry in list {
            let fields = entry as? [String: Any] ?? [:]
            do {
                let (instance, bad) = try validated(fields, among: accepted, lenientSettings: true)
                accepted.append(instance)
                dropped += bad.map { ["instance": instance.id, "key": $0.key, "error": $0.error] }
            } catch {
                var r: [String: Any] = ["error": "\(error)"]
                if let id = fields["instance"] as? String { r["instance"] = id }
                rejected.append(r)
            }
        }
        let keep = Set(accepted.map(\.id))
        for id in order where !keep.contains(id) { remove(id) }
        order = []
        isEditing = editing
        isRevealed = revealed
        for instance in accepted { place(instance) }
        return ["ok": true, "instances": accepted.map(\.json), "rejected": rejected, "droppedSettings": dropped,
                "editing": isEditing, "revealed": isRevealed]
    }

    /// An instance from wire fields (strings from args, JSON values from `sync`), checked
    /// against the registered types and the instances it would join. With `lenientSettings`, a
    /// setting the schema rejects is dropped and returned instead of failing the instance.
    private func validated(_ fields: [String: Any], among others: [HUDWidgetInstance], lenientSettings: Bool = false) throws
        -> (instance: HUDWidgetInstance, droppedSettings: [(key: String, error: String)]) {
        guard let id = fields["instance"] as? String, !id.isEmpty else { throw HUDControlError.invalid("widget needs instance") }
        guard let type = fields["type"] as? String, !type.isEmpty else { throw HUDControlError.invalid("widget needs type") }
        guard let spec = spec(for: type) else { throw unknownType(type) }
        let size = try (fields["size"] as? String).map { try Self.size($0, spec: spec, type: type) } ?? spec.defaultSize
        let frame = try fields["frame"].map(HUDWidgetInstance.parseFrame) ?? Self.defaultFrame(size)
        let layer = try (fields["layer"] as? String).map(HUDWidgetInstance.parseLayer) ?? .desktop
        let parsed = try fields["settings"].map { try HUDWidgetInstance.parseSettings($0, schema: schemas[type], lenient: lenientSettings) }
        if others.contains(where: { $0.id == id }) { throw HUDControlError.invalid("widget \(id) exists") }
        if !spec.multiple, others.contains(where: { $0.type == type }) {
            throw HUDControlError.invalid("\(type) allows one instance")
        }
        return (HUDWidgetInstance(id: id, type: type, size: size, frame: frame, layer: layer, settings: parsed?.settings ?? [:]),
                parsed?.dropped ?? [])
    }

    private func unknownType(_ type: String) -> HUDControlError {
        .invalid("no widget type \(type) (\(types.joined(separator: ", ")))")
    }

    private static func size(_ raw: String, spec: HUDWidgetSpec, type: String) throws -> HUDWidgetSize {
        let size = try HUDWidgetInstance.parseSize(raw)
        guard spec.sizes.contains(size) else {
            throw HUDControlError.invalid("\(type) size must be one of \(spec.sizes.map(\.rawValue).joined(separator: ", "))")
        }
        return size
    }

    /// Where a widget goes when nobody said: its nominal size, centred on the primary display
    /// (the one with the menu bar; `NSScreen.main` would follow the key window).
    private static func defaultFrame(_ size: HUDWidgetSize) -> CGRect {
        let points = size.points()
        let screen = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: (screen.midX - points.width / 2).rounded(), y: (screen.midY - points.height / 2).rounded(),
                      width: points.width, height: points.height)
    }

    private static func bool(_ raw: String, name: String) throws -> Bool {
        switch raw.lowercased() {
        case "on", "true", "1", "yes": return true
        case "off", "false", "0", "no": return false
        default: throw HUDControlError.invalid("\(name) must be on or off")
        }
    }

    private static func onOff(_ args: [String: String], verb: String) throws -> Bool {
        if let raw = args["state"] {
            switch raw.lowercased() {
            case "on", "true", "1", "yes": return true
            case "off", "false", "0", "no": return false
            default: break
            }
        } else if args["on"] != nil {
            return true
        } else if args["off"] != nil {
            return false
        }
        throw HUDControlError.invalid("widget \(verb) needs on or off")
    }

    // MARK: - Instances and windows

    /// Creates the instance's window, or updates the existing one with the same id, and
    /// (re)shows it with its every-Space membership re-asserted.
    private func place(_ instance: HUDWidgetInstance) {
        if let existing = controllers[instance.id], existing.instance.type == instance.type {
            existing.apply(instance, editing: isEditing, revealed: isRevealed)
            existing.show(presenting: presentsWindows)
        } else {
            if controllers[instance.id] != nil { remove(instance.id) }
            guard let registration = registrations[instance.type], let spec = spec(for: instance.type) else { return }
            let context = HUDWidgetContext(instance: instance, spec: spec, schema: schemas[instance.type],
                                           isEditing: isEditing, host: self)
            let controller = WidgetController(instance: instance, context: context, keyable: registration.keyable,
                                              content: registration.content(context), host: self)
            controllers[instance.id] = controller
            controller.apply(instance, editing: isEditing, revealed: isRevealed)
            controller.show(presenting: presentsWindows)
        }
        if !order.contains(instance.id) { order.append(instance.id) }
    }

    private func remove(_ id: String) {
        controllers.removeValue(forKey: id)?.close()
        order.removeAll { $0 == id }
    }

    /// Re-asserts every widget window's every-Space membership and orders it in. Runs on wake
    /// and on every Space change; idempotent.
    func repairSpaces() {
        for id in order { controllers[id]?.show(presenting: presentsWindows) }
    }

    private func setEditing(_ on: Bool) {
        isEditing = on
        for c in controllers.values { c.apply(c.instance, editing: isEditing, revealed: isRevealed) }
    }

    private func setRevealed(_ on: Bool) {
        isRevealed = on
        for c in controllers.values { c.apply(c.instance, editing: isEditing, revealed: isRevealed) }
    }

    // MARK: - User changes (reported to MacHUD, which persists them and answers)

    private func emit(_ id: String, _ change: String, _ extra: [String: Any] = [:]) {
        guard let instance = controllers[id]?.instance else { return }
        var payload: [String: Any] = ["instance": id, "type": instance.type, "change": change]
        payload.merge(extra) { _, b in b }
        onEvent?(payload)
    }

    /// The user dragged the widget (edit mode) to `frame`: kept, and reported as `frame`.
    func userMoved(_ id: String, to frame: CGRect) {
        guard var instance = controllers[id]?.instance, instance.frame != frame else { return }
        instance.frame = frame
        controllers[id]?.instance = instance
        emit(id, "frame", ["frame": HUDWidgetInstance.frameJSON(frame)])
    }

    /// The edit-mode resize control: reports the next declared size; MacHUD answers with
    /// `update size= frame=`.
    func requestResize(_ id: String) {
        guard let instance = controllers[id]?.instance, let next = spec(for: instance.type).flatMap({ instance.size.next(in: $0.sizes) }) else { return }
        emit(id, "size", ["size": next.rawValue])
    }

    /// The edit-mode remove control; MacHUD answers with `remove`.
    func requestRemove(_ id: String) { emit(id, "remove") }

    /// The edit-mode settings control: MacHUD shows the instance's settings.
    func requestConfigure(_ id: String) { emit(id, "configure") }

    func contextChangedSettings(_ context: HUDWidgetContext) {
        guard var instance = controllers[context.instance]?.instance else { return }
        instance.settings = context.settings
        controllers[context.instance]?.instance = instance
        emit(context.instance, "settings", ["settings": HUDWidgetInstance.settingsJSON(context.settings)])
    }

    func open(_ context: HUDWidgetContext) {
        if let onOpen { onOpen(context) } else { emit(context.instance, "open") }
    }

    // MARK: - Snapshot

    /// Renders widget type `type` at `size` (nominal points, 2x pixels) over a dark stand-in
    /// for the glass, to a PNG: for an app's `--snapshot` path and visual checks. `editing`
    /// draws the edit controls too.
    public func writeSnapshot(type: String, size: HUDWidgetSize, settings: [String: HUDSettingValue] = [:],
                              editing: Bool = false, to url: URL) throws {
        guard let registration = registrations[type], let spec = spec(for: type) else { throw unknownType(type) }
        guard spec.sizes.contains(size) else {
            throw HUDControlError.invalid("\(type) size must be one of \(spec.sizes.map(\.rawValue).joined(separator: ", "))")
        }
        let points = size.points()
        let instance = HUDWidgetInstance(id: "snapshot", type: type, size: size, frame: CGRect(origin: .zero, size: points))
        let context = HUDWidgetContext(instance: instance, spec: spec, schema: schemas[type], isEditing: editing, host: nil)
        context.settings = settings
        let radius = HUDWidgetStyle.cornerRadius
        let view = ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.13))
            HUDWidgetRootView(context: context, content: registration.content(context),
                              canResize: spec.sizes.count > 1, canConfigure: schemas[type] != nil, actions: nil)
        }
        .frame(width: points.width, height: points.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = points
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}

/// The widget look.
public enum HUDWidgetStyle {
    /// The widget corner radius: the family's panel glass radius.
    public static let cornerRadius: CGFloat = HUDGlassView.Style.panel.cornerRadius
}

/// One instance's window: glass, the registered view, edit chrome.
@MainActor
final class WidgetController {
    var instance: HUDWidgetInstance
    let context: HUDWidgetContext
    let window: HUDPanelWindow
    private let hosting: NSHostingView<HUDWidgetRootView>
    private let actions: HUDWidgetRootView.Actions
    private var moveObserver: NSObjectProtocol?
    private var pendingMove: DispatchWorkItem?

    init(instance: HUDWidgetInstance, context: HUDWidgetContext, keyable: Bool, content: AnyView, host: HUDWidgetHost) {
        self.instance = instance
        self.context = context
        window = HUDPanelWindow(contentRect: instance.frame, behavior: .widget)
        window.keyable = keyable
        window.title = "\(instance.type) widget"
        let id = instance.id
        let actions = HUDWidgetRootView.Actions(
            remove: { [weak host] in host?.requestRemove(id) },
            resize: { [weak host] in host?.requestResize(id) },
            configure: { [weak host] in host?.requestConfigure(id) },
            dragged: { [weak host, weak window = window] in
                if let frame = window?.frame { host?.userMoved(id, to: frame) }
            })
        self.actions = actions
        let spec = context.spec
        hosting = NSHostingView(rootView: HUDWidgetRootView(context: context, content: content,
                                                            canResize: spec.sizes.count > 1,
                                                            canConfigure: context.schema != nil, actions: actions))
        let glass = HUDGlassView(style: .panel)
        glass.frame = CGRect(origin: .zero, size: instance.frame.size)
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)
        window.contentView = glass
        // A drag in edit mode may end after `performDrag` returns (the window server moves the
        // window); report the frame once the move settles and the mouse is up.
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window,
                                                              queue: .main) { [weak self, weak host] _ in
            MainActor.assumeIsolated { self?.moved(host: host) }
        }
    }

    private func moved(host: HUDWidgetHost?) {
        guard window.isMovable else { return }
        pendingMove?.cancel()
        let work = DispatchWorkItem { [weak self, weak host] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons != 0 { self.moved(host: host); return }
                host?.userMoved(self.instance.id, to: self.window.frame)
            }
        }
        pendingMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func apply(_ next: HUDWidgetInstance, editing: Bool, revealed: Bool) {
        instance = next
        if window.frame != next.frame { window.setFrame(next.frame, display: true) }
        let raised = next.layer == .float || editing || revealed
        window.level = raised ? .floating : HUDPanelWindow.widgetDesktopLevel
        window.setWidgetLocked(!editing)
        if context.size != next.size { context.size = next.size }
        if context.layer != next.layer { context.layer = next.layer }
        if context.settings != next.settings { context.settings = next.settings }
        if context.isEditing != editing { context.isEditing = editing }
    }

    /// Re-asserts the widget Spaces behaviour (the window server can drop it) and, when
    /// presenting, orders the window in.
    func show(presenting: Bool) {
        window.reassertAllSpaces(HUDPanelWindow.widgetCollectionBehavior)
        if presenting { window.orderFrontRegardless() }
    }

    /// A re-registered type's view.
    func setContent(_ content: AnyView, keyable: Bool) {
        window.keyable = keyable
        let spec = context.spec
        hosting.rootView = HUDWidgetRootView(context: context, content: content, canResize: spec.sizes.count > 1,
                                             canConfigure: context.schema != nil, actions: actions)
    }

    func close() {
        pendingMove?.cancel()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        window.orderOut(nil)
        window.close()
    }
}

/// The widget's content plus, in edit mode, HUDKit's controls: a drag surface over the whole
/// widget, remove (top left), settings (top right, when the type has per-instance settings)
/// and resize to the next declared size (bottom right).
struct HUDWidgetRootView: View {
    struct Actions {
        var remove: () -> Void
        var resize: () -> Void
        var configure: () -> Void
        var dragged: () -> Void
    }

    @ObservedObject var context: HUDWidgetContext
    let content: AnyView
    let canResize: Bool
    let canConfigure: Bool
    /// Nil when rendered off screen (snapshots): the controls are drawn but inert, and the
    /// AppKit drag surface, which an `ImageRenderer` cannot draw, is left out.
    let actions: Actions?

    var body: some View {
        ZStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!context.isEditing)
                .opacity(context.isEditing ? 0.55 : 1)
            if context.isEditing {
                if let actions { WidgetDragSurface(onDragEnd: actions.dragged) }
                RoundedRectangle(cornerRadius: HUDWidgetStyle.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .allowsHitTesting(false)
                VStack {
                    HStack {
                        chromeButton("minus.circle.fill", help: "Remove") { actions?.remove() }
                        Spacer()
                        if canConfigure { chromeButton("gearshape.fill", help: "Settings") { actions?.configure() } }
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        if canResize {
                            chromeButton("arrow.up.left.and.arrow.down.right.circle.fill", help: "Next size") { actions?.resize() }
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private func chromeButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color(white: 0.32))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Edit mode's drag surface: a mouse-down drags the window (`performDrag`, which returns on
/// mouse-up) and then reports the new frame.
private struct WidgetDragSurface: NSViewRepresentable {
    var onDragEnd: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDragEnd = onDragEnd
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.onDragEnd = onDragEnd }

    final class DragView: NSView {
        var onDragEnd: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let before = window.frame
            window.performDrag(with: event)
            if window.frame != before { onDragEnd?() }
        }
    }
}

/// A block observer on NSWorkspace's notification center, removed when released.
private final class WorkspaceObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol
    init(_ center: NotificationCenter, _ token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }
    deinit { center.removeObserver(token) }
}
