import AppKit

/// The menu bar image of a MacHUD app: the family's template glyph (`MenuBarIcon.png` and
/// `MenuBarIcon@2x.png` in the bundle's Resources, rendered by `scripts/hud-icon.sh`), or an
/// SF Symbol when the bundle has none (e.g. under `swift run`).
public enum HUDStatusIcon {
    /// The resource name `hud-icon.sh` writes.
    public static let resourceName = "MenuBarIcon"

    /// A template image for an `NSStatusItem` button: the bundled glyph, sized 18×18 pt, or
    /// `fallbackSymbol`. Nil only when neither exists.
    public static func image(fallbackSymbol: String, accessibilityDescription: String?, bundle: Bundle = .main) -> NSImage? {
        let image: NSImage
        if let bundled = bundle.image(forResource: resourceName) {
            image = bundled
            image.size = NSSize(width: 18, height: 18)
        } else if let symbol = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: accessibilityDescription) {
            image = symbol
        } else {
            return nil
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
