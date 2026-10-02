/// HUDKit: the shared contract and visual language for MacHUD-aware apps.
///
/// - Socket: `HUDSocket`, `HUDSocketServer`, `HUDSocketClient` (JSON lines over a Unix socket).
/// - Manifest: `HUDManifest`, `HUDManifestScanner` (`Contents/Resources/machud.json`).
/// - Control: `HUDPanelHost`, `HUDControlRouter` (the required verbs), `HUDPanelTransition`, `HUDDrop`.
/// - Dock: `HUDDockPosition`, `HUDDockLayout`, `HUDDockRegistry` (strip snapping and sibling avoidance).
/// - Settings: `HUDSettingsSchema`, `HUDSettingValue` (the shared settings window's schema).
/// - Widgets: `HUDWidgetHost` (the `widget` verb, instance windows), `HUDWidgetContext`,
///   `HUDWidgetSpec`, `HUDWidgetSize`, `HUDWidgetLayer`, `HUDWidgetInstance`.
/// - UI: `HUDGlassView`, `HUDGlass`, `HUDPanelWindow`, `HUDSpring`, `HUDAnimation`, `HUDParking`.
/// - Hotkeys: `HUDHotKey`, `HUDHotKeyCenter`.
/// - Menu bar: `HUDStatusIcon`, `HUDMenuBridge` (`menu`/`menu-invoke`), `HUDStatusItemPolicy` and
///   `HUDMenuHost` (hide the status item while MacHUD hosts the menu).
public enum HUDKit {
    /// Semantic version of the contract this build implements; reported by `hello`.
    public static let version = "0.3.1"
}
