import AppKit
import HUDKit
import __PRODUCT__Kit

/// __PRODUCT__'s side of the MacHUD contract: serves the control socket at
/// `~/Library/Application Support/MacHUD/sockets/__REPO__.sock` through HUDKit's router.
/// See docs/CONTRACT.md for the verbs.
@MainActor
final class ControlHost: HUDPanelHost {
    nonisolated static let panelID = "main"
    static let actions = ["say", "show", "hide", "toggle"]

    /// Used when running outside a bundle (`swift run`, tests); mirrors Resources/machud.json.
    static let builtinManifest = HUDManifest(id: "xyz.machud.__REPO__", name: "__PRODUCT__", socket: "__REPO__", panels: [
        HUDManifest.Panel(id: panelID, title: "__PRODUCT__", symbol: "sparkles",
                          defaultSize: HUDSize(PanelController.size),
                          verbs: ["show", "hide", "toggle", "frame", "say"],
                          settingsSchema: "settings.json", kind: .hover, order: 90),
    ], iconName: "sparkles")

    let manifest: HUDManifest
    let server: HUDSocketServer
    private(set) var router: HUDControlRouter!
    let model: AppModel
    let panel: PanelController

    init(model: AppModel, panel: PanelController, socketPath: String? = nil) {
        self.model = model
        self.panel = panel
        manifest = HUDManifest.main ?? Self.builtinManifest
        server = HUDSocketServer(path: socketPath ?? HUDSocket.path(for: AppEnvironment.socketName(default: manifest.socket)),
                                 label: "__REPO__.socket")
        router = HUDControlRouter(host: self, server: server, manifest: manifest)
    }

    func start() {
        router.install()
        if !server.start() { NSLog("__PRODUCT__: control socket failed to start at %@", server.path) }
        panel.onStateChange = { [weak self] in self?.router.publishState() }
    }

    func stop() { server.stop() }

    // MARK: - HUDPanelHost

    var panelDescriptors: [HUDManifest.Panel] { manifest.panels }

    var panelStates: [HUDPanelState] {
        [HUDPanelState(id: Self.panelID, visible: panel.isShown, status: model.text)]
    }

    private func check(_ id: String) throws {
        guard id == Self.panelID else { throw HUDControlError.noSuchPanel(id) }
    }

    func showPanel(_ id: String) throws { try check(id); panel.show() }
    func hidePanel(_ id: String) throws { try check(id); panel.hide() }

    func showPanel(_ id: String, options: [String: String]) throws {
        try check(id)
        panel.show(HUDPanelTransition(options))
    }

    func hidePanel(_ id: String, options: [String: String]) throws {
        try check(id)
        panel.hide(HUDPanelTransition(options))
    }

    func setPanelFrame(_ id: String, frame: CGRect) throws {
        try check(id)
        guard frame.width >= 100, frame.height >= 60 else { throw HUDControlError.invalid("frame too small") }
        panel.setFrame(frame)
    }

    // MARK: Settings

    func settings() -> [String: Any] { model.settings.json }

    func updateSettings(_ values: [String: String]) throws {
        do {
            try model.updateSettings(values)
        } catch let error as AppSettings.SettingsError {
            throw HUDControlError.invalid(error.description)
        }
        router.publishState()
    }

    // MARK: Actions

    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        switch name {
        case "say":
            let text = (args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            model.message = text.isEmpty ? nil : text
            router.publishState()
            done(["ok": true, "text": model.text])
        case "show", "hide", "toggle":
            switch name {
            case "show": panel.show()
            case "hide": panel.hide()
            default: panel.toggle()
            }
            done(["ok": true, "visible": panel.isShown])
        default:
            done(["ok": false, "error": "unknown action \(name) (\(Self.actions.joined(separator: ", ")))"])
        }
    }

    func quit() { NSApp.terminate(nil) }
}
