import Foundation

/// Describes an app's settings so MacHUD's shared settings window can render them without
/// knowing the app. Lives next to `machud.json` (the panel's `settingsSchema`, relative to
/// `Contents/Resources`) and is served by `settings schema` over the socket.
///
/// ```json
/// {"version": 1, "settings": [
///   {"key": "collisionPolicy", "title": "When names collide", "type": "enum", "group": "Files",
///    "options": [{"value": "keepBoth", "title": "Keep both"}, "skip"], "default": "keepBoth"},
///   {"key": "showHidden", "title": "Show hidden files", "type": "bool", "default": false}]}
/// ```
///
/// Values travel as strings over `settings set` (`true`/`false` for bools); `Field.parse`
/// validates one the way an app should before applying it.
///
/// Types: `string`, `bool`, `int`, `number` (a decimal, `Double`), `enum`, `path`. `int` and
/// `number` take optional `min`, `max` (inclusive bounds `parse` enforces) and `step` (the
/// increment a settings window's stepper uses):
///
/// ```json
/// {"key": "autosaveDelay", "title": "Autosave delay (seconds)", "type": "number",
///  "min": 0.1, "max": 10, "step": 0.05, "default": 0.75}
/// ```
public struct HUDSettingsSchema: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var settings: [Field]

    public init(version: Int = HUDSettingsSchema.currentVersion, settings: [Field]) {
        self.version = version
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        settings = try c.decodeIfPresent([Field].self, forKey: .settings) ?? []
    }

    public enum FieldType: String, Codable, CaseIterable, Sendable {
        case string, bool, int, number, `enum`, path

        /// Unknown types read as `string`, so a newer schema still renders.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
            switch raw {
            case "boolean": self = .bool
            case "integer": self = .int
            case "double", "float", "decimal": self = .number
            case "text": self = .string
            default: self = FieldType(rawValue: raw) ?? .string
            }
        }
    }

    /// An enum choice. Decodes from `{"value", "title"}` or a bare string.
    public struct Option: Codable, Equatable, Sendable {
        public var value: String
        public var title: String

        public init(value: String, title: String? = nil) {
            self.value = value
            self.title = title ?? value
        }

        public init(from decoder: Decoder) throws {
            if let bare = try? decoder.singleValueContainer().decode(String.self) {
                self.init(value: bare)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let value = try c.decode(String.self, forKey: .value)
            self.init(value: value, title: try c.decodeIfPresent(String.self, forKey: .title))
        }
    }

    public struct Field: Codable, Equatable, Sendable {
        public var key: String
        public var title: String
        public var type: FieldType
        public var `default`: HUDSettingValue?
        /// Choices for `enum`.
        public var options: [Option]
        /// Section heading in the settings window; nil groups under the app's name.
        public var group: String?
        /// One line of explanation under the control.
        public var help: String?
        /// Inclusive bounds for `int` and `number`, enforced by `parse`.
        public var min: Double?
        public var max: Double?
        /// The increment a settings window's stepper uses for `int` and `number` (informational).
        public var step: Double?

        private enum CodingKeys: String, CodingKey { case key, title, type, `default`, options, group, help, min, max, step }

        public init(key: String, title: String? = nil, type: FieldType, default value: HUDSettingValue? = nil,
                    options: [Option] = [], group: String? = nil, help: String? = nil,
                    min: Double? = nil, max: Double? = nil, step: Double? = nil) {
            self.key = key
            self.title = title ?? key
            self.type = type
            self.default = value
            self.options = options
            self.group = group
            self.help = help
            self.min = min
            self.max = max
            self.step = step
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? key
            type = try c.decodeIfPresent(FieldType.self, forKey: .type) ?? .string
            `default` = try c.decodeIfPresent(HUDSettingValue.self, forKey: .default)
            options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
            group = try c.decodeIfPresent(String.self, forKey: .group)
            help = try c.decodeIfPresent(String.self, forKey: .help)
            min = try? c.decodeIfPresent(Double.self, forKey: .min)
            max = try? c.decodeIfPresent(Double.self, forKey: .max)
            step = (try? c.decodeIfPresent(Double.self, forKey: .step)).flatMap { $0 > 0 ? $0 : nil }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(title, forKey: .title)
            try c.encode(type, forKey: .type)
            try c.encodeIfPresent(`default`, forKey: .default)
            if !options.isEmpty { try c.encode(options, forKey: .options) }
            try c.encodeIfPresent(group, forKey: .group)
            try c.encodeIfPresent(help, forKey: .help)
            try c.encodeIfPresent(min, forKey: .min)
            try c.encodeIfPresent(max, forKey: .max)
            try c.encodeIfPresent(step, forKey: .step)
        }

        /// Validates a wire value (a string from `settings set`) for this field.
        public func parse(_ raw: String) throws -> HUDSettingValue {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            switch type {
            case .string, .path:
                return .string(raw)
            case .bool:
                switch trimmed.lowercased() {
                case "true", "1", "yes", "on": return .bool(true)
                case "false", "0", "no", "off": return .bool(false)
                default: throw HUDSettingsError.invalid(key: key, reason: "must be true or false")
                }
            case .int:
                guard let n = Int(trimmed) else { throw HUDSettingsError.invalid(key: key, reason: "must be a whole number") }
                try checkBounds(Double(n))
                return .int(n)
            case .number:
                guard let d = Double(trimmed), d.isFinite else { throw HUDSettingsError.invalid(key: key, reason: "must be a number") }
                try checkBounds(d)
                return .double(d)
            case .enum:
                guard options.isEmpty || options.contains(where: { $0.value == trimmed }) else {
                    throw HUDSettingsError.invalid(key: key, reason: "must be one of \(options.map(\.value).joined(separator: ", "))")
                }
                return .string(trimmed)
            }
        }

        private func checkBounds(_ value: Double) throws {
            if let min, value < min { throw HUDSettingsError.invalid(key: key, reason: "must be at least \(Self.format(min))") }
            if let max, value > max { throw HUDSettingsError.invalid(key: key, reason: "must be at most \(Self.format(max))") }
        }

        /// `10` rather than `10.0` in messages.
        static func format(_ value: Double) -> String {
            value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        }
    }

    public func field(_ key: String) -> Field? { settings.first { $0.key == key } }

    /// Group names in first-appearance order (nil for ungrouped fields).
    public var groups: [String?] {
        var seen: [String?] = []
        for field in settings where !seen.contains(field.group) { seen.append(field.group) }
        return seen
    }

    /// Validates every value before any is applied; unknown keys are rejected.
    public func validate(_ values: [String: String]) throws -> [String: HUDSettingValue] {
        var out: [String: HUDSettingValue] = [:]
        for (key, raw) in values {
            guard let field = field(key) else { throw HUDSettingsError.unknownKey(key) }
            out[key] = try field.parse(raw)
        }
        return out
    }

    /// The defaults, as a `settings get` reply would carry them.
    public var defaults: [String: Any] {
        var d: [String: Any] = [:]
        for field in settings { if let v = field.default { d[field.key] = v.jsonValue } }
        return d
    }

    // MARK: - Loading

    public static func decode(_ data: Data) throws -> HUDSettingsSchema {
        try JSONDecoder().decode(HUDSettingsSchema.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The JSON object form served by `settings schema`.
    public var json: [String: Any] {
        let data = (try? encoded()) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["version": version, "settings": []]
    }

    /// Reads it back from `json` (as received over a socket).
    public init?(json: Any) {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json),
              let schema = try? Self.decode(data) else { return nil }
        self = schema
    }

    /// The schema the manifest's first panel with a `settingsSchema` points at, read from
    /// the app bundle without launching the app. nil when none is declared or it is unreadable.
    public static func load(manifest: HUDManifest, bundleURL: URL) -> HUDSettingsSchema? {
        guard let name = manifest.panels.lazy.compactMap(\.settingsSchema).first else { return nil }
        let url = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true).appendingPathComponent(name)
        return (try? Data(contentsOf: url)).flatMap { try? decode($0) }
    }

    /// The running app's own schema (from its bundle's manifest).
    public static var main: HUDSettingsSchema? {
        HUDManifest.main.flatMap { load(manifest: $0, bundleURL: Bundle.main.bundleURL) }
    }
}

/// A setting's value: what the schema's `default` holds and what `settings get` returns.
public enum HUDSettingValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        }
    }

    /// From a JSONSerialization value (NSNumber booleans stay booleans).
    public init?(any value: Any) {
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue); return }
            if CFNumberIsFloatType(n) { self = .double(n.doubleValue); return }
            self = .int(n.intValue)
            return
        }
        if let s = value as? String { self = .string(s); return }
        return nil
    }

    /// The form `settings set` takes.
    public var wireString: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        }
    }

    public var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .string(let s): return ["true", "1", "yes", "on"].contains(s.lowercased()) ? true
            : (["false", "0", "no", "off", ""].contains(s.lowercased()) ? false : nil)
        case .double: return nil
        }
    }

    /// The value as a number (`int`, `double`, or a numeric string); nil for bools and text.
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool: return nil
        }
    }
}

public enum HUDSettingsError: Error, CustomStringConvertible, Equatable {
    case unknownKey(String)
    case invalid(key: String, reason: String)

    public var description: String {
        switch self {
        case .unknownKey(let key): return "unknown setting \(key)"
        case .invalid(let key, let reason): return "\(key) \(reason)"
        }
    }
}
