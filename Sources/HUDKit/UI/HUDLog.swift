import CoreGraphics
import Foundation
import os

/// HUDKit's unified-log channels, read with `log show --predicate 'subsystem == "xyz.machud.hudkit"'`.
/// Every line is `.notice`, which the unified log keeps and `log show` prints by default. Each
/// message is built as one string and logged with `privacy: .public`; the default would
/// redact it to `<private>`.
enum HUDLog {
    static let subsystem = "xyz.machud.hudkit"
    /// What the presence keeper found wrong with a window it keeps (off the user's desktop,
    /// displaced) and what it did about it.
    static let presence = Logger(subsystem: subsystem, category: "presence")
    /// Each change of a screen's full-screen result, with the window that satisfied the test.
    static let fullscreen = Logger(subsystem: subsystem, category: "fullscreen")
    /// How each soft backdrop (`HUDSoftBackdropView`) draws and why, when that is chosen, and
    /// each episode of putting its blur back after AppKit replaced it.
    static let softBackdrop = Logger(subsystem: subsystem, category: "softbackdrop")

    /// A rect as `x,y,w,h` in whole points.
    static func format(_ rect: CGRect) -> String {
        String(format: "%.0f,%.0f,%.0f,%.0f", rect.minX, rect.minY, rect.width, rect.height)
    }
}
