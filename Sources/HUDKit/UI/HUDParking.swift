import AppKit

/// A screen edge a panel parks against.
public enum HUDEdge: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom
}

/// Parking geometry and animation: a parked panel sits almost entirely off-screen with a
/// `peek`-point sliver showing on one edge, and slides back to its rest frame on demand.
/// All rects are AppKit screen coordinates (origin bottom-left).
public enum HUDParking {
    /// `frame` moved (not resized) so it lies inside `bounds`. A frame larger than `bounds`
    /// is aligned to its left/bottom edge.
    public static func restFrame(for frame: CGRect, in bounds: CGRect) -> CGRect {
        var f = frame
        f.origin.x = frame.width >= bounds.width ? bounds.minX : min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        f.origin.y = frame.height >= bounds.height ? bounds.minY : min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        return f
    }

    /// `frame` pushed past `edge` of `bounds` so only `peek` points remain visible. The other
    /// axis is clamped into `bounds` so the sliver is actually on screen.
    public static func offScreenFrame(for frame: CGRect, edge: HUDEdge, peek: CGFloat, in bounds: CGRect) -> CGRect {
        let peek = max(0, min(peek, edge == .left || edge == .right ? frame.width : frame.height))
        var f = restFrame(for: frame, in: bounds)
        switch edge {
        case .left: f.origin.x = bounds.minX - frame.width + peek
        case .right: f.origin.x = bounds.maxX - peek
        case .bottom: f.origin.y = bounds.minY - frame.height + peek
        case .top: f.origin.y = bounds.maxY - peek
        }
        return f
    }

    /// The edge of `bounds` closest to `frame`'s centre.
    public static func nearestEdge(for frame: CGRect, in bounds: CGRect) -> HUDEdge {
        let distances: [(HUDEdge, CGFloat)] = [
            (.left, frame.midX - bounds.minX), (.right, bounds.maxX - frame.midX),
            (.bottom, frame.midY - bounds.minY), (.top, bounds.maxY - frame.midY),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// The screen frame to park against: the screen containing most of `frame`, else the main screen.
    @MainActor
    public static func screenFrame(for frame: CGRect) -> CGRect {
        let best = NSScreen.screens.max { a, b in
            area(a.frame.intersection(frame)) < area(b.frame.intersection(frame))
        }
        if let best, area(best.frame.intersection(frame)) > 0 { return best.frame }
        return NSScreen.main?.frame ?? frame
    }

    /// `offScreenFrame` against the screen `frame` is on.
    @MainActor
    public static func offScreenFrame(for frame: CGRect, edge: HUDEdge, peek: CGFloat) -> CGRect {
        offScreenFrame(for: frame, edge: edge, peek: peek, in: screenFrame(for: frame))
    }

    /// Slides the window to its off-screen frame (conceal timing). Stays ordered in so the peek shows.
    @MainActor
    public static func slideOut(_ window: NSWindow, edge: HUDEdge, peek: CGFloat,
                                completion: (@MainActor () -> Void)? = nil) {
        let target = offScreenFrame(for: window.frame, edge: edge, peek: peek)
        HUDAnimation.conceal(window, to: target, fade: false, completion: completion)
    }

    /// Slides the window back to `restFrame` (reveal timing), ordering it in first if needed.
    @MainActor
    public static func slideIn(_ window: NSWindow, to restFrame: CGRect,
                               completion: (@MainActor () -> Void)? = nil) {
        if !window.isVisible { window.orderFrontRegardless() }
        HUDAnimation.reveal(window, to: restFrame, completion: completion)
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
