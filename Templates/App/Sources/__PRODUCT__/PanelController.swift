import AppKit
import HUDKit
import SwiftUI

/// Owns the hover panel: a non-activating `HUDPanelWindow` whose content is a `HUDGlassView`
/// (Liquid Glass on macOS 26) hosting the SwiftUI `PanelView`. (A SwiftUI-only panel can use
/// `.hudGlass()` instead; the AppKit container keeps `--snapshot` able to draw the content alone.)
/// MacHUD shows it from its dock button (`panel show from= anchor= reason=hover`) and hides it
/// when the pointer leaves (`panel hide to=`).
@MainActor
final class PanelController {
    static let size = CGSize(width: 320, height: 160)

    let model: AppModel
    let window: HUDPanelWindow
    private let glass = HUDGlassView(style: .panel)
    private let host: NSHostingView<PanelView>
    /// Whether the panel is meant to be on screen (`isVisible` stays true during a fade-out).
    private(set) var isShown = false
    /// Called when visibility changes (for `state` events).
    var onStateChange: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        window = HUDPanelWindow(contentRect: CGRect(origin: .zero, size: Self.size))
        window.title = "__PRODUCT__"
        host = NSHostingView(rootView: PanelView(model: model))
        glass.frame = CGRect(origin: .zero, size: Self.size)
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        window.contentView = glass
        center()
    }

    /// Shows the panel. With MacHUD's `from=`/`anchor=` it slides out of the dock next to the
    /// button; otherwise it fades in where it is. Never takes focus: a hover panel must not
    /// steal the keyboard from the app the user is in.
    func show(_ transition: HUDPanelTransition = HUDPanelTransition()) {
        if !isShown { model.panelOpened() }
        isShown = true
        if let from = transition.from {
            let frame = transition.panelFrame(size: window.frame.size) ?? window.frame
            HUDAnimation.slide(in: window, from: from, to: frame)
        } else {
            HUDAnimation.fadeIn(window)
        }
        onStateChange?()
    }

    /// Hides the panel, sliding toward `to=` (the dock) when given.
    func hide(_ transition: HUDPanelTransition = HUDPanelTransition()) {
        guard isShown else { return }
        isShown = false
        if let to = transition.to {
            HUDAnimation.slideOut(window, toward: to)
        } else {
            HUDAnimation.fadeOut(window)
        }
        onStateChange?()
    }

    func toggle() { isShown ? hide() : show() }

    func setFrame(_ frame: CGRect) { window.setFrame(frame, display: true) }

    private func center() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(CGPoint(x: screen.midX - Self.size.width / 2, y: screen.midY - Self.size.height / 2))
    }

    /// `--snapshot <png>`: renders the panel's content over a dark stand-in for the glass (the
    /// real backdrop needs Screen Recording to capture), for docs and UI checks.
    func writeSnapshot(to url: URL) throws {
        let view: NSView = host
        let size = view.bounds.size
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rect = CGRect(origin: .zero, size: size)
        let radius = HUDGlassView.Style.panel.cornerRadius
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
