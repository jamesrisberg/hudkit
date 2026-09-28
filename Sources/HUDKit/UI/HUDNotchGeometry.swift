import AppKit

/// Pure description of one screen's camera-housing (notch) and menu-bar geometry, so anchor
/// math is unit-testable without a display. Real values come from `NSScreen`; tests build them
/// by hand. Frame math (ported from SpeakFree's `OverlayScreenGeometry`/`OverlayLayout`, MIT,
/// see `NOTICE.md`) is generalized here for a panel of any size, not only the recording
/// indicator's pill.
public struct HUDNotchGeometry: Equatable, Sendable {
    public var screenFrame: CGRect
    public var visibleFrame: CGRect
    /// Height of the camera-housing strip (`NSScreen.safeAreaInsets.top`); 0 without one.
    public var safeAreaInsetTop: CGFloat
    /// Width of the camera housing (the gap between `auxiliaryTopLeftArea` and
    /// `auxiliaryTopRightArea`), nil when the screen exposes no measurable housing.
    public var notchWidth: CGFloat?

    public init(screenFrame: CGRect, visibleFrame: CGRect, safeAreaInsetTop: CGFloat = 0, notchWidth: CGFloat? = nil) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.safeAreaInsetTop = safeAreaInsetTop
        self.notchWidth = notchWidth
    }

    /// Reads the live values off a real screen.
    @MainActor
    public init(screen: NSScreen) {
        let inset = screen.safeAreaInsets.top
        var width: CGFloat?
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let gap = right.minX - left.maxX
            if gap > 0 { width = gap }
        }
        self.init(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaInsetTop: inset, notchWidth: width)
    }

    /// An inset alone (e.g. a thin bezel with no camera cutout) is not treated as a notch;
    /// both the inset and a measurable housing width are required.
    public var hasNotch: Bool { safeAreaInsetTop > 0 && (notchWidth ?? 0) > 0 }

    /// The camera housing's rect in screen coordinates, nil when the screen has none.
    public var notchRect: CGRect? {
        guard hasNotch, let notchWidth else { return nil }
        return CGRect(x: screenFrame.midX - notchWidth / 2, y: screenFrame.maxY - safeAreaInsetTop,
                      width: notchWidth, height: safeAreaInsetTop)
    }

    /// Y of the edge a top-anchored panel hangs from: the bottom of the camera housing on a
    /// notch screen, otherwise the bottom of the menu bar — which is the screen's top edge
    /// when the menu bar is hidden, e.g. behind a full-screen app, since `visibleFrame` then
    /// grows to fill the screen.
    public var topAnchorY: CGFloat { hasNotch ? screenFrame.maxY - safeAreaInsetTop : visibleFrame.maxY }

    /// Frame for a panel of `size`, centered under the notch (or hanging from the menu bar,
    /// or the bare screen edge in full screen where there is neither), top edge flush with
    /// `topAnchorY`.
    public func anchorFrame(for size: CGSize) -> CGRect {
        CGRect(x: screenFrame.midX - size.width / 2, y: topAnchorY - size.height, width: size.width, height: size.height)
    }
}
