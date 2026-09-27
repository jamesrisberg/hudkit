import AppKit
import HUDKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panel: PanelController!
    private var control: ControlHost!
    private var statusItem: NSStatusItem!
    /// Pick a combination no sibling app uses (see the MacHUD apps' READMEs).
    static let toggleHotKey = HUDHotKey(key: "h", modifiers: ["control", "option"])

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no main menu, so without this ⌘C/⌘V/⌘X/⌘A/⌘Z do nothing in text fields.
        HUDEditMenu.install(appName: "__PRODUCT__")
        model = AppModel(settingsURL: AppEnvironment.settingsURL)
        panel = PanelController(model: model)
        control = ControlHost(model: model, panel: panel)
        control.start()
        setupStatusItem()
        // Menu bar consolidation: MacHUD shows this menu inside its own (`menu`, `menu-invoke`)
        // and the icon hides while it does. The `menuBar.consumed` opt-out is kept in
        // <home>/menubar.json, so it follows __REPO_UPPER___HOME.
        control.router.menuProvider = { [weak self] in self?.statusItem.menu }
        HUDStatusItemPolicy.attach(statusItem, appID: control.manifest.id, store: .home(AppEnvironment.baseDirectory))
        if AppEnvironment.hotKeysEnabled {
            if HUDHotKeyCenter.shared.register(Self.toggleHotKey, onPress: { [weak self] in self?.panel.toggle() }) == nil {
                NSLog("__PRODUCT__: %@ is taken by another app", Self.toggleHotKey.display)
            }
        }

        // `--snapshot <path.png>`: show the panel, write a PNG of it once it settles, and quit.
        // For docs and for checking the UI without Screen Recording permission.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
            let url = URL(fileURLWithPath: args[i + 1])
            panel.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                do {
                    try self?.panel.writeSnapshot(to: url)
                    print(url.path)
                } catch {
                    FileHandle.standardError.write(Data("__PRODUCT__: snapshot failed: \(error)\n".utf8))
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        control.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // MenuBarIcon.png from hudkit/scripts/hud-icon.sh; the symbol under `swift run`.
        statusItem.button?.image = HUDStatusIcon.image(fallbackSymbol: "sparkles", accessibilityDescription: "__PRODUCT__")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Show/Hide __PRODUCT__", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit __PRODUCT__", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func togglePanel() { panel.toggle() }
}
