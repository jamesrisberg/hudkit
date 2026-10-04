import AppKit

/// A HUD backdrop, behind a view's content: the window server's blur of what is behind the
/// window (`HUDWindowBlur`) under a tint the view draws in `shape`, black at 20 % in a dark
/// appearance and white at 20 % in a light one. The server blurs only where the window draws,
/// so the tint's shape is the blur's shape. Where the server's blur is missing, while the
/// user has Reduce transparency on (a 20 % tint would stay see-through; the classic blur turns
/// opaque by itself), or when `.visualEffect` is asked for, it is an `NSVisualEffectView`
/// (`.hudWindow`, behind the window) cut to the same shape, with no tint. It switches when the
/// setting changes. It never takes the mouse.
@MainActor
final class HUDBackdropView: NSView {
    enum Shape: Equatable {
        /// The bounds with continuous corners of this radius (0: square).
        case rounded(CGFloat)
        /// A path in this view's coordinates.
        case path(CGPath)
        /// The opaque part of an image stretched over the bounds (`NSVisualEffectView.maskImage`).
        case mask(NSImage)
    }

    /// The tint's opacity over the blur.
    static let tintAlpha: CGFloat = 0.2

    /// The tint in `appearance`: black in a dark appearance, white in a light one.
    static func tint(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (dark ? NSColor.black : NSColor.white).withAlphaComponent(tintAlpha)
    }

    /// The backdrop in use: `.windowBlur`, or `.visualEffect` when asked for or when the
    /// window server's blur is not usable (`HUDWindowBlur.isUsable`).
    private(set) var material: HUDGlassView.Material
    /// The backdrop asked for.
    private let requested: HUDGlassView.Material
    var shape: Shape { didSet { if shape != oldValue { applyShape() } } }
    /// The classic blur (`.visualEffect` only).
    private(set) var effectView: NSVisualEffectView?
    /// The tint of a `.path` shape.
    let tintLayer = CAShapeLayer()
    /// Draws the tint of a `.mask` shape.
    private var maskTint: HUDBackdropMaskTint?
    private let windowBlur: HUDWindowBlur

    init(frame: NSRect, material: HUDGlassView.Material, shape: Shape, windowBlur: HUDWindowBlur) {
        requested = material
        self.material = material == .windowBlur && windowBlur.isUsable ? .windowBlur : .visualEffect
        self.shape = shape
        self.windowBlur = windowBlur
        super.init(frame: frame)
        wantsLayer = true
        setUpMaterial()
        applyShape()
        // Selector-based, so the center lets go of the view when it is deallocated.
        windowBlur.transparency.center.addObserver(self, selector: #selector(accessibilityDisplayOptionsChanged),
                                                   name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Material

    /// The classic blur for `.visualEffect`, none for the window's blur.
    private func setUpMaterial() {
        guard material == .visualEffect else {
            effectView?.removeFromSuperview()
            effectView = nil
            layer?.masksToBounds = false
            return
        }
        guard effectView == nil else { return }
        let effect = HUDBackdropEffectView(frame: bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect, positioned: .below, relativeTo: nil)
        effectView = effect
    }

    /// Reduce transparency was turned on or off: the backdrop follows it.
    @objc private func accessibilityDisplayOptionsChanged(_ note: Notification) {
        let next: HUDGlassView.Material = requested == .windowBlur && windowBlur.isUsable ? .windowBlur : .visualEffect
        guard next != material else { return }
        if material == .windowBlur, let window { windowBlur.detach(self, from: window) }
        material = next
        setUpMaterial()
        applyShape()
        if material == .windowBlur, let window { windowBlur.attach(self, to: window) }
    }

    // MARK: Shape and tint

    private func applyShape() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if case .rounded(let radius) = shape {
            layer?.cornerRadius = radius
            layer?.cornerCurve = .continuous
        } else {
            layer?.cornerRadius = 0
        }
        if let effectView {
            // The classic blur, with no tint: rounded by this view's corners, otherwise by its
            // mask image.
            if case .rounded(let radius) = shape { layer?.masksToBounds = radius > 0 } else { layer?.masksToBounds = false }
            effectView.maskImage = effectMask()
            layer?.backgroundColor = nil
            tintLayer.removeFromSuperlayer()
            maskTint?.removeFromSuperview()
            maskTint = nil
            return
        }
        if case .path(let path) = shape {
            tintLayer.path = path
            tintLayer.frame = bounds
            if tintLayer.superlayer !== layer { layer?.addSublayer(tintLayer) }
        } else {
            tintLayer.removeFromSuperlayer()
        }
        if case .mask(let image) = shape {
            let view = maskTint ?? HUDBackdropMaskTint(frame: bounds)
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            view.mask = image
            if view.superview !== self { addSubview(view) }
            maskTint = view
        } else {
            maskTint?.removeFromSuperview()
            maskTint = nil
        }
        updateTint()
    }

    private func updateTint() {
        guard effectView == nil else { return }
        let tint = Self.tint(for: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case .rounded = shape { layer?.backgroundColor = tint.cgColor } else { layer?.backgroundColor = nil }
        tintLayer.fillColor = tint.cgColor
        maskTint?.color = tint
        CATransaction.commit()
    }

    /// The classic blur's mask for `shape`: none for a rounded rect (this view's corners cut it).
    private func effectMask() -> NSImage? {
        switch shape {
        case .rounded: return nil
        case .mask(let image): return image
        case .path(let path):
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return nil }
            return NSImage(size: size, flipped: false) { _ in
                guard let cg = NSGraphicsContext.current?.cgContext else { return false }
                cg.addPath(path)
                cg.setFillColor(.black)
                cg.fillPath()
                return true
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    override func layout() {
        super.layout()
        // A path's mask image is drawn at the bounds' size.
        if effectView != nil, case .path = shape { effectView?.maskImage = effectMask() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: The window's blur

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if material == .windowBlur, let old = window, old !== newWindow { windowBlur.detach(self, from: old) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if material == .windowBlur, let window { windowBlur.attach(self, to: window) }
    }
}

/// The classic blur inside a backdrop: never takes the mouse.
private final class HUDBackdropEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A tint drawn through a mask image: `color` times the image's alpha, the image stretched over
/// the bounds as `NSVisualEffectView.maskImage` is. The tint of a `.mask` backdrop and of
/// `HUDSoftBackdropView`. It is drawn again when the mask, the colour or the size changes, and
/// AppKit draws it again when the appearance changes, so a dynamic colour follows it.
final class HUDBackdropMaskTint: NSView {
    var mask: NSImage? { didSet { if mask !== oldValue { needsDisplay = true } } }
    var color: NSColor = .clear { didSet { if color != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let mask else { return }
        color.setFill()
        bounds.fill()
        mask.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
    }
}
