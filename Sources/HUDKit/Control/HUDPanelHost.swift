import AppKit

/// How a panel is represented.
public enum HUDPanelMode: String, Codable, CaseIterable, Sendable {
    case compact, full, parked
}

/// One panel's live state, as reported by `state` and pushed to subscribers.
public struct HUDPanelState: Equatable, Sendable {
    public var id: String
    public var visible: Bool
    public var mode: HUDPanelMode
    public var badge: String?
    public var status: String?

    public init(id: String, visible: Bool, mode: HUDPanelMode = .full, badge: String? = nil, status: String? = nil) {
        self.id = id
        self.visible = visible
        self.mode = mode
        self.badge = badge
        self.status = status
    }

    public var json: [String: Any] {
        var d: [String: Any] = ["id": id, "visible": visible, "mode": mode.rawValue]
        if let badge { d["badge"] = badge }
        if let status { d["status"] = status }
        return d
    }
}

/// Where to park, for `panel mode parked`: MacHUD passes the slot's edge and peek so the app
/// parks where the loadout says instead of at its nearest edge. Either may be nil.
public struct HUDPanelModeOptions: Equatable, Sendable {
    public var edge: HUDEdge?
    public var peek: CGFloat?

    public init(edge: HUDEdge? = nil, peek: CGFloat? = nil) {
        self.edge = edge
        self.peek = peek
    }

    /// `edge` if given, else the edge of the screen nearest `frame`.
    @MainActor
    public func edge(for frame: CGRect) -> HUDEdge {
        edge ?? HUDParking.nearestEdge(for: frame, in: HUDParking.screenFrame(for: frame))
    }
}

/// How MacHUD wants a panel to appear or go away, from `panel show|toggle|hide` options.
///
/// | option | meaning |
/// |---|---|
/// | `from=<edge>` | show: the dock edge the panel should slide out of (`left/right/top/bottom`) |
/// | `to=<edge>` | hide: the edge to slide back toward |
/// | `anchor=x,y,w,h` | the dock button's frame, AppKit screen coordinates (origin bottom-left) |
/// | `reason=hover/click/summon` | why: pointer over a hover app's button, a click, or a hotkey/CLI summon |
///
/// ```swift
/// func showPanel(_ id: String, options: [String: String]) throws {
///     let t = HUDPanelTransition(options)
///     HUDAnimation.slide(in: window, from: t.from ?? .top, to: t.panelFrame(size: window.frame.size) ?? window.frame)
/// }
/// ```
public struct HUDPanelTransition: Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case hover, click, summon }

    public var from: HUDEdge?
    public var to: HUDEdge?
    public var anchor: CGRect?
    /// nil when absent or not one of the known reasons (unknown values stay in `options`).
    public var reason: Reason?

    public init(from: HUDEdge? = nil, to: HUDEdge? = nil, anchor: CGRect? = nil, reason: Reason? = nil) {
        self.from = from
        self.to = to
        self.anchor = anchor
        self.reason = reason
    }

    /// Parses the options a host receives. Malformed values read as nil (the router has
    /// already rejected malformed `from`/`to`/`anchor`).
    public init(_ options: [String: String]) {
        from = options["from"].flatMap(HUDEdge.init(rawValue:))
        to = options["to"].flatMap(HUDEdge.init(rawValue:))
        anchor = options["anchor"].flatMap(Self.parseAnchor)
        reason = options["reason"].flatMap(Reason.init(rawValue:))
    }

    /// The wire form, for MacHUD's side: `["from": "top", "anchor": "10,20,40,40", ...]`.
    public var options: [String: String] {
        var o: [String: String] = [:]
        if let from { o["from"] = from.rawValue }
        if let to { o["to"] = to.rawValue }
        if let anchor { o["anchor"] = Self.formatAnchor(anchor) }
        if let reason { o["reason"] = reason.rawValue }
        return o
    }

    /// `"x,y,w,h"` → rect; nil unless exactly four numbers.
    public static func parseAnchor(_ s: String) -> CGRect? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, s.split(separator: ",", omittingEmptySubsequences: false).count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    public static func formatAnchor(_ r: CGRect) -> String {
        [r.minX, r.minY, r.width, r.height].map { v -> String in
            let d = Double(v)
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        }.joined(separator: ",")
    }

    /// Where a panel of `size` sits next to the anchor button, on the side away from `from`
    /// (see `HUDDockLayout.panelFrame`); nil without both `anchor` and `from`.
    @MainActor
    public func panelFrame(size: CGSize, gap: CGFloat = 8) -> CGRect? {
        guard let anchor, let from else { return nil }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -10_000, dy: -10_000)
        return HUDDockLayout.panelFrame(size: size, anchor: anchor, from: from, gap: gap, in: visible)
    }
}

/// Errors a host returns from panel operations; the router turns them into `{"ok": false, "error": ...}`.
public enum HUDControlError: Error, CustomStringConvertible, Equatable {
    case noSuchPanel(String)
    case unsupported(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .noSuchPanel: return "no such panel"
        case .unsupported(let what): return "unsupported: \(what)"
        case .invalid(let why): return why
        }
    }
}

/// What an app implements to get the MacHUD control contract from `HUDControlRouter`.
/// Only `panelStates`, `showPanel` and `hidePanel` are required; everything else has a default.
@MainActor
public protocol HUDPanelHost: AnyObject {
    /// Panel descriptions for `hello`. Defaults to the bundle manifest's panels, else ids from `panelStates`.
    var panelDescriptors: [HUDManifest.Panel] { get }
    var panelStates: [HUDPanelState] { get }

    func showPanel(_ id: String) throws
    func hidePanel(_ id: String) throws
    func togglePanel(_ id: String) throws
    /// `panel show` with MacHUD's options (`from=`, `anchor=`, `reason=`; see
    /// `HUDPanelTransition`). Defaults to `showPanel(_:)`.
    func showPanel(_ id: String, options: [String: String]) throws
    /// `panel hide` with MacHUD's options (`to=`, `anchor=`, `reason=`). Defaults to `hidePanel(_:)`.
    func hidePanel(_ id: String, options: [String: String]) throws
    /// `panel toggle` with options. The default shows or hides by `panelStates` through the
    /// options variants above; when hiding, a `from=` with no `to=` is passed on as `to=`.
    /// Hosts that override `togglePanel(_:)` should override this too.
    func togglePanel(_ id: String, options: [String: String]) throws
    /// Cooperative placement: the frame is in AppKit screen coordinates (origin bottom-left).
    func setPanelFrame(_ id: String, frame: CGRect) throws
    func setPanelMode(_ id: String, mode: HUDPanelMode) throws
    /// `panel mode` with the edge/peek MacHUD asked for. Defaults to `setPanelMode(_:mode:)`,
    /// so hosts that always park at their nearest edge need not implement it.
    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws

    /// Current settings for the shared settings window.
    func settings() -> [String: Any]
    /// Applies settings; values arrive as strings.
    func updateSettings(_ values: [String: String]) throws
    /// Served by `settings schema`. Defaults to the schema the bundle's manifest points at.
    var settingsSchema: HUDSettingsSchema? { get }

    /// App-specific verb from the manifest. Call `done` exactly once.
    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void)

    /// Clean exit. Called after the `quit` response has been sent.
    func quit()

    /// The window that shows panel `id`, so panel replies and `state` can say whether it is on
    /// the Space the user is looking at (`onActiveSpace`). Defaults to
    /// `HUDPanelHostDefaults.panelWindow(_:of:)`; override it when that cannot tell.
    func panelWindow(_ id: String) -> NSWindow?
}

/// Default implementations a host that overrides a requirement can still call.
@MainActor
public enum HUDPanelHostDefaults {
    /// The `HUDPanelWindow` whose `panelID` is `id`; else, for a host with a single panel, the
    /// app's only visible `HUDPanelWindow`; else nil (nothing is claimed).
    public static func panelWindow(_ id: String, of host: HUDPanelHost) -> NSWindow? {
        guard let app = NSApp as NSApplication? else { return nil }  // no app yet (tests, tools)
        let windows = app.windows.compactMap { $0 as? HUDPanelWindow }
        if let tagged = windows.first(where: { $0.panelID == id }) { return tagged }
        guard host.panelStates.count == 1, host.panelStates.first?.id == id else { return nil }
        let visible = windows.filter { $0.isVisible && $0.panelID == nil }
        return visible.count == 1 ? visible[0] : nil
    }

    /// Whether panel `id` is on screen on the active Space: nil unless the host says it is
    /// visible and its window (`panelWindow(_:)`) is ordered in.
    public static func onActiveSpace(_ id: String, of host: HUDPanelHost) -> Bool? {
        guard host.panelState(id)?.visible == true, let window = host.panelWindow(id), window.isVisible else { return nil }
        return window.isOnActiveSpace
    }

    /// `state.json` plus `onActiveSpace` when known: what `state`, `subscribe` events and
    /// panel replies carry.
    public static func stateJSON(_ state: HUDPanelState, of host: HUDPanelHost) -> [String: Any] {
        var d = state.json
        if let on = onActiveSpace(state.id, of: host) { d["onActiveSpace"] = on }
        return d
    }
}

public extension HUDPanelHost {
    var panelDescriptors: [HUDManifest.Panel] {
        HUDManifest.main?.panels ?? panelStates.map { HUDManifest.Panel(id: $0.id, title: $0.id) }
    }

    func panelState(_ id: String) -> HUDPanelState? { panelStates.first { $0.id == id } }

    func togglePanel(_ id: String) throws {
        guard let state = panelState(id) else { throw HUDControlError.noSuchPanel(id) }
        try state.visible ? hidePanel(id) : showPanel(id)
    }

    func showPanel(_ id: String, options: [String: String]) throws { try showPanel(id) }
    func hidePanel(_ id: String, options: [String: String]) throws { try hidePanel(id) }

    func togglePanel(_ id: String, options: [String: String]) throws {
        guard let state = panelState(id) else { throw HUDControlError.noSuchPanel(id) }
        if state.visible {
            var hide = options
            if hide["to"] == nil, let from = hide["from"] { hide["to"] = from }
            try hidePanel(id, options: hide)
        } else {
            try showPanel(id, options: options)
        }
    }

    func setPanelFrame(_ id: String, frame: CGRect) throws { throw HUDControlError.unsupported("panel frame") }
    func setPanelMode(_ id: String, mode: HUDPanelMode) throws { throw HUDControlError.unsupported("panel mode") }
    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        try setPanelMode(id, mode: mode)
    }
    var settingsSchema: HUDSettingsSchema? { HUDSettingsSchema.main }
    func settings() -> [String: Any] { [:] }
    func updateSettings(_ values: [String: String]) throws { throw HUDControlError.unsupported("settings set") }

    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        done(["ok": false, "error": "unknown action \(name)"])
    }

    func quit() { NSApp.terminate(nil) }

    func panelWindow(_ id: String) -> NSWindow? { HUDPanelHostDefaults.panelWindow(id, of: self) }
}
