import AppKit
import QuartzCore

/// Damped spring on a scalar. Slightly under-damped settings make snaps visibly "spring".
public struct HUDSpring: Equatable, Sendable {
    public var value: Double
    public var velocity: Double = 0
    public var target: Double

    public init(_ v: Double) { value = v; target = v }

    /// Advances by `dt` seconds. Returns true when settled (value snapped to target).
    public mutating func step(dt: Double, stiffness k: Double, damping zeta: Double, epsilon: Double) -> Bool {
        let c = 2 * zeta * k.squareRoot()
        let a = -k * (value - target) - c * velocity
        velocity += a * dt
        value += velocity * dt
        if abs(value - target) < epsilon && abs(velocity) < epsilon * 30 {
            value = target
            velocity = 0
            return true
        }
        return false
    }

    public mutating func jump(to v: Double) { value = v; target = v; velocity = 0 }
}

/// Window slide/fade helpers with the MacHUD timings: things come *out* (appear) in
/// 0.22 s ease-out and go back *in* (disappear) in 0.18 s ease-in.
@MainActor
public enum HUDAnimation {
    /// Appearing: drawer sliding out, panel sliding onto screen.
    nonisolated public static let revealDuration: TimeInterval = 0.22
    /// Disappearing: drawer sliding back in, panel sliding off screen.
    nonisolated public static let concealDuration: TimeInterval = 0.18

    public static var revealTiming: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    public static var concealTiming: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeIn) }

    /// Animates a window's frame and/or alpha.
    public static func animate(_ window: NSWindow, to frame: CGRect? = nil, alpha: CGFloat? = nil,
                               duration: TimeInterval, timing: CAMediaTimingFunction,
                               completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = timing
            if let frame { window.animator().setFrame(frame, display: true) }
            if let alpha { window.animator().alphaValue = alpha }
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    /// Slides (and fades in) to `frame` with reveal timing.
    public static func reveal(_ window: NSWindow, to frame: CGRect, completion: (@MainActor () -> Void)? = nil) {
        animate(window, to: frame, alpha: 1, duration: revealDuration, timing: revealTiming, completion: completion)
    }

    /// Slides (and fades out) to `frame` with conceal timing.
    public static func conceal(_ window: NSWindow, to frame: CGRect, fade: Bool = true,
                               completion: (@MainActor () -> Void)? = nil) {
        animate(window, to: frame, alpha: fade ? 0 : nil, duration: concealDuration, timing: concealTiming,
                completion: completion)
    }

    /// Orders the window in (if needed) and fades it to opaque. Cancels a fade-out in
    /// flight so its completion cannot order the window out again.
    public static func fadeIn(_ window: NSWindow, duration: TimeInterval = revealDuration) {
        fadeGeneration[ObjectIdentifier(window)] = (fadeGeneration[ObjectIdentifier(window)] ?? 0) &+ 1
        slideRest[ObjectIdentifier(window)] = nil
        if !window.isVisible { window.alphaValue = 0; window.orderFrontRegardless() }
        animate(window, alpha: 1, duration: duration, timing: revealTiming)
    }

    /// Fades the window out, orders it out and restores its alpha. If `fadeIn` (or another
    /// `fadeOut`) starts before this one finishes, the stale completion does nothing.
    public static func fadeOut(_ window: NSWindow, duration: TimeInterval = concealDuration,
                               completion: (@MainActor () -> Void)? = nil) {
        let key = ObjectIdentifier(window)
        let generation = (fadeGeneration[key] ?? 0) &+ 1
        fadeGeneration[key] = generation
        slideRest[key] = nil
        animate(window, alpha: 0, duration: duration, timing: concealTiming) {
            guard fadeGeneration[key] == generation else { return }
            window.orderOut(nil)
            window.alphaValue = 1
            completion?()
        }
    }

    // MARK: - Sliding out of the dock

    /// How far a panel travels when it slides out of (or back into) the dock.
    nonisolated public static let slideTravel: CGFloat = 24

    /// `frame` moved `distance` points toward `edge` (up for `.top`, left for `.left`, ...).
    nonisolated public static func offset(_ frame: CGRect, toward edge: HUDEdge, by distance: CGFloat = slideTravel) -> CGRect {
        switch edge {
        case .top: return frame.offsetBy(dx: 0, dy: distance)
        case .bottom: return frame.offsetBy(dx: 0, dy: -distance)
        case .left: return frame.offsetBy(dx: -distance, dy: 0)
        case .right: return frame.offsetBy(dx: distance, dy: 0)
        }
    }

    /// Shows `window` at `frame` by sliding it `slideTravel` points out of `edge` (the dock's
    /// side, `HUDPanelTransition.from`) while fading in, with reveal timing. If the window is
    /// still on screen (e.g. mid `slideOut`) it animates from where it is, and the pending
    /// slide-out's order-out is cancelled.
    public static func slide(in window: NSWindow, from edge: HUDEdge, to frame: CGRect,
                             duration: TimeInterval = revealDuration,
                             completion: (@MainActor () -> Void)? = nil) {
        let key = ObjectIdentifier(window)
        let generation = bumpGeneration(window)
        slideRest[key] = frame
        if !window.isVisible {
            window.alphaValue = 0
            window.setFrame(offset(frame, toward: edge), display: false)
            window.orderFrontRegardless()
        }
        animate(window, to: frame, alpha: 1, duration: duration, timing: revealTiming) {
            // The slide-in landed: from now on the live frame is the truth (the user may drag
            // the panel or MacHUD may re-frame it), so a later slideOut must not use this.
            if fadeGeneration[key] == generation { slideRest[key] = nil }
            completion?()
        }
    }

    /// Hides `window` by sliding it `slideTravel` points toward `edge` while fading out
    /// (conceal timing), then orders it out and restores its frame and alpha so the next show
    /// starts clean. A `slide(in:)`/`fadeIn` that starts before this finishes wins.
    public static func slideOut(_ window: NSWindow, toward edge: HUDEdge,
                                duration: TimeInterval = concealDuration,
                                completion: (@MainActor () -> Void)? = nil) {
        let key = ObjectIdentifier(window)
        let generation = bumpGeneration(window)
        // Mid slide-in the live frame is partway there; restore the frame it was headed for.
        // Otherwise the live frame is the rest frame.
        let rest = slideRest.removeValue(forKey: key) ?? window.frame
        animate(window, to: offset(rest, toward: edge), alpha: 0, duration: duration, timing: concealTiming) {
            guard fadeGeneration[key] == generation else { return }
            window.orderOut(nil)
            window.setFrame(rest, display: false)
            window.alphaValue = 1
            completion?()
        }
    }

    @MainActor private static var slideRest: [ObjectIdentifier: CGRect] = [:]

    @discardableResult
    private static func bumpGeneration(_ window: NSWindow) -> UInt {
        let key = ObjectIdentifier(window)
        let next = (fadeGeneration[key] ?? 0) &+ 1
        fadeGeneration[key] = next
        return next
    }

    /// Per-window token so a show that interrupts a fade-out wins (fixes the hide→show race).
    @MainActor private static var fadeGeneration: [ObjectIdentifier: UInt] = [:]
}
