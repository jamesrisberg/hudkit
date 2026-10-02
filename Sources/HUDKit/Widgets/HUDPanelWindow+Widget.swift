import AppKit

/// The `.widget` behaviour's recipe values (see `HUDPanelWindow`).
public extension HUDPanelWindow {
    /// Every Space, stationary (Mission Control and Show Desktop leave it where it is), out of
    /// the ⌘` cycle. No `.fullScreenAuxiliary`: widgets stay off full-screen Spaces.
    static let widgetCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    /// The desktop layer: one above the desktop icons, so widgets draw over the wallpaper and
    /// icons and under every app window.
    static let widgetDesktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    /// The window level for a widget layer: `widgetDesktopLevel` or `.floating`.
    static func level(for layer: HUDWidgetLayer) -> NSWindow.Level {
        layer == .float ? .floating : widgetDesktopLevel
    }

    /// The level `applyHUDRecipe(behavior:)` uses when it is not given one.
    static func defaultLevel(for behavior: Behavior) -> NSWindow.Level {
        switch behavior {
        case .hover: return .floating
        case .windowed: return .normal
        case .widget: return widgetDesktopLevel
        }
    }

    /// Locks or unlocks a widget window: locked, it cannot be dragged at all; unlocked (edit
    /// mode), `HUDWidgetHost`'s drag handle moves it. Never movable by its background, so a
    /// click on a widget's content is only ever a click.
    func setWidgetLocked(_ locked: Bool) {
        isMovable = !locked
        isMovableByWindowBackground = false
    }
}
