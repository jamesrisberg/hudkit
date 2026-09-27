import Foundation
import __PRODUCT__Kit

/// What the panel shows. Owns the settings and writes them under `AppEnvironment`'s home.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    /// Set by `__REPO__ say`; the greeting until then.
    @Published var message: String?
    @Published private(set) var opens = 0

    let settingsURL: URL?

    /// `settingsURL` nil keeps everything in memory (tests).
    init(settingsURL: URL?) {
        self.settingsURL = settingsURL
        settings = settingsURL.map(AppSettings.load(from:)) ?? AppSettings()
    }

    var text: String { message ?? settings.greeting }

    func panelOpened() { opens += 1 }

    func updateSettings(_ values: [String: String]) throws {
        let next = try settings.applying(values)
        if let settingsURL { try next.save(to: settingsURL) }
        settings = next
    }
}
