import Foundation

public extension HUDSettingsSchema {
    /// Widget type `type`'s per-instance schema (its `kind: widget` panel's
    /// `widget.settingsSchema`), read from the app bundle without launching the app. nil when
    /// the type declares none or it is unreadable.
    static func load(widget type: String, manifest: HUDManifest, bundleURL: URL) -> HUDSettingsSchema? {
        guard let panel = manifest.panel(id: type), panel.kind == .widget, let name = panel.widget?.settingsSchema else { return nil }
        let url = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true).appendingPathComponent(name)
        return (try? Data(contentsOf: url)).flatMap { try? decode($0) }
    }
}
