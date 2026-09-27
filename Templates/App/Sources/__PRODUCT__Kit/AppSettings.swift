import Foundation

/// __PRODUCT__'s settings: the values behind Resources/settings.json, persisted as JSON in
/// `<home>/preferences.json`. Values arrive over the socket as strings (`settings set k=v`),
/// so `applying(_:)` parses and validates them all before changing anything.
public struct AppSettings: Codable, Equatable, Sendable {
    public var greeting: String
    public var showCount: Bool

    public init(greeting: String = AppSettings.defaultGreeting, showCount: Bool = true) {
        self.greeting = greeting
        self.showCount = showCount
    }

    public static let defaultGreeting = "Hello from __PRODUCT__"
    /// The keys `settings get` reports and `settings set` accepts (Resources/settings.json).
    public static let keys: Set<String> = ["greeting", "showCount"]

    /// Saved values are merged over the defaults key by key: a key missing from
    /// `preferences.json` (written before the setting existed) or one that does not decode
    /// keeps its default, and every other saved value is kept. With the synthesized decoder one
    /// new field made the whole file fail to decode and every saved setting reset.
    /// Add each new field here with `Self.value(_:_:default:)`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        greeting = Self.value(c, .greeting, default: d.greeting)
        showCount = Self.value(c, .showCount, default: d.showCount)
    }

    private static func value<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K, default fallback: T) -> T {
        ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    public enum SettingsError: Error, Equatable, CustomStringConvertible {
        case unknownKey(String)
        case invalid(key: String, value: String)

        public var description: String {
            switch self {
            case .unknownKey(let key): return "unknown setting \(key)"
            case .invalid(let key, let value): return "invalid value \(value) for \(key)"
            }
        }
    }

    /// The settings with `values` applied; throws on the first unknown key or bad value.
    public func applying(_ values: [String: String]) throws -> AppSettings {
        var next = self
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "greeting":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw SettingsError.invalid(key: key, value: value) }
                next.greeting = trimmed
            case "showCount":
                guard let flag = Self.bool(value) else { throw SettingsError.invalid(key: key, value: value) }
                next.showCount = flag
            default:
                throw SettingsError.unknownKey(key)
            }
        }
        return next
    }

    /// `settings get`'s payload.
    public var json: [String: Any] { ["greeting": greeting, "showCount": showCount] }

    static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    // MARK: Persistence

    /// Reads the settings at `url`, saved values over the defaults (see `init(from:)`); defaults
    /// when the file is missing or not a JSON object.
    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
