import AppKit

// Menu bar app (LSUIElement): no Dock icon. Set the policy before launch finishes so the
// icon never bounces.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
