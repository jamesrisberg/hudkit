import AppKit
import SwiftUI

/// Frosted "jelly glass" container: the MacHUD visual language.
///
/// Add content with `addSubview`; it sits above the backdrop and gloss. On macOS 26 the
/// backdrop is an `NSGlassEffectView` (Liquid Glass); earlier systems, and any view with a
/// `maskImage`, use an `NSVisualEffectView` with the `.hudWindow` material.
open class HUDGlassView: NSView {
    public enum Material: Sendable {
        /// Liquid Glass where available, otherwise `.visualEffect`.
        case automatic
        /// Always `NSVisualEffectView(.hudWindow)`.
        case visualEffect
    }

    public struct Style: Equatable, Sendable {
        public var cornerRadius: CGFloat
        public var borderWidth: CGFloat
        public var borderAlpha: CGFloat
        /// Draw the jelly sheen (top highlight band, accent tint at the bottom).
        public var gloss: Bool
        public var material: Material

        public init(cornerRadius: CGFloat = 20, borderWidth: CGFloat = 1, borderAlpha: CGFloat = 0.28,
                    gloss: Bool = true, material: Material = .automatic) {
            self.cornerRadius = cornerRadius
            self.borderWidth = borderWidth
            self.borderAlpha = borderAlpha
            self.gloss = gloss
            self.material = material
        }

        /// Floating toolbar: radius 20, 1 pt border at 28 %, gloss.
        public static let panel = Style()
        /// Edge strip / drawer: radius 22, hairline border at 15 %, gloss.
        public static let strip = Style(cornerRadius: 22, borderWidth: 0.5, borderAlpha: 0.15)
        /// Plain frosted background (window content, masked shapes): no corners, border or gloss.
        public static let plain = Style(cornerRadius: 0, borderWidth: 0, borderAlpha: 0, gloss: false)
    }

    public var style: Style { didSet { if style != oldValue { rebuild() } } }

    /// Shape mask (e.g. a ring). Forces the visual-effect backdrop, which supports masking.
    public var maskImage: NSImage? {
        didSet {
            if (maskImage == nil) != (oldValue == nil) { rebuild() }
            (backdrop as? NSVisualEffectView)?.maskImage = maskImage
        }
    }

    /// True when the backdrop is Liquid Glass.
    public var usesLiquidGlass: Bool { !(backdrop is NSVisualEffectView) }

    private var backdrop: NSView?
    private var glossView: HUDGlossView?

    public init(frame: NSRect = .zero, style: Style = .panel) {
        self.style = style
        super.init(frame: frame)
        wantsLayer = true
        rebuild()
    }

    public required init?(coder: NSCoder) {
        style = .panel
        super.init(coder: coder)
        wantsLayer = true
        rebuild()
    }

    private func rebuild() {
        backdrop?.removeFromSuperview()
        glossView?.removeFromSuperview()

        layer?.cornerRadius = style.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = style.cornerRadius > 0
        layer?.borderWidth = style.borderWidth
        layer?.borderColor = NSColor.white.withAlphaComponent(style.borderAlpha).cgColor

        let back = Self.makeBackdrop(style: style, masked: maskImage != nil)
        (back as? NSVisualEffectView)?.maskImage = maskImage
        back.frame = bounds
        back.autoresizingMask = [.width, .height]
        addSubview(back, positioned: .below, relativeTo: nil)
        backdrop = back

        if style.gloss {
            let gloss = HUDGlossView(frame: bounds)
            gloss.autoresizingMask = [.width, .height]
            addSubview(gloss, positioned: .above, relativeTo: back)
            glossView = gloss
        } else {
            glossView = nil
        }
    }

    private static func makeBackdrop(style: Style, masked: Bool) -> NSView {
        #if compiler(>=6.2)
        if style.material == .automatic, !masked, #available(macOS 26, *) {
            let glass = PassthroughGlassEffectView()
            glass.cornerRadius = style.cornerRadius
            return glass
        }
        #endif
        let effect = PassthroughVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }
}

/// Backdrops never take mouse events, so clicks reach the container (drag handles) or content.
private final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#if compiler(>=6.2)
@available(macOS 26, *)
private final class PassthroughGlassEffectView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

/// Non-interactive gradient overlay that gives glass its "jelly" sheen.
public final class HUDGlossView: NSView {
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSColor.white.withAlphaComponent(0.06).setFill()
        r.fill()
        // Top highlight band.
        let top = CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0.02)])?
            .draw(in: top, angle: -90)
        // Bottom tint.
        let bottom = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.35)
        NSGradient(colors: [NSColor.controlAccentColor.withAlphaComponent(0.0), NSColor.controlAccentColor.withAlphaComponent(0.12)])?
            .draw(in: bottom, angle: -90)
    }
}

// MARK: - SwiftUI

/// SwiftUI backdrop backed by `HUDGlassView`. Use as a background or via `.hudGlass()`.
public struct HUDGlass: NSViewRepresentable {
    public var style: HUDGlassView.Style

    public init(style: HUDGlassView.Style = .panel) { self.style = style }

    public func makeNSView(context: Context) -> HUDGlassView { HUDGlassView(style: style) }
    public func updateNSView(_ view: HUDGlassView, context: Context) { view.style = style }
}

public extension View {
    /// Puts the content on HUD glass, clipped to the style's corner radius.
    func hudGlass(_ style: HUDGlassView.Style = .panel) -> some View {
        background(HUDGlass(style: style))
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
    }
}
