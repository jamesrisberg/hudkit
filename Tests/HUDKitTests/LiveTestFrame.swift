import AppKit

/// A small frame for a test window that appears on the user's real desktop: just inside the
/// main screen's visible frame (clear of the menu bar and the Dock, on any display size).
@MainActor
func liveTestFrame(width: CGFloat = 10, height: CGFloat = 10) -> CGRect {
    let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    return CGRect(x: visible.minX + 4, y: visible.minY + 4, width: width, height: height)
}
