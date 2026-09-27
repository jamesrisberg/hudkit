import Foundation

/// `Contents/Resources/machud.json`: what a MacHUD-aware app offers, readable without launching it.
///
/// ```json
/// {"id": "xyz.viawormhole.wormhole", "name": "Wormhole", "socket": "wormhole", "iconName": "circle.dotted",
///  "panels": [{"id": "portal", "title": "Portal", "symbol": "circle.dotted", "kind": "hover", "order": 1,
///              "defaultSize": [220, 220], "compactSize": [72, 72],
///              "capabilities": ["acceptsFileDrop"], "verbs": ["show", "hide", "toggle"],
///              "settingsSchema": "settings.json"}]}
/// ```
public struct HUDManifest: Codable, Equatable, Sendable {
    public static let fileName = "machud.json"

    /// Bundle identifier of the app.
    public var id: String
    public var name: String
    /// Socket name; the path is `HUDSocket.path(for: socket)`. An absolute path is used as is.
    public var socket: String
    public var panels: [Panel]
    /// SF Symbol MacHUD shows for the app when its bundle icon is missing.
    public var iconName: String?

    public init(id: String, name: String, socket: String, panels: [Panel] = [], iconName: String? = nil) {
        self.id = id
        self.name = name
        self.socket = socket
        self.panels = panels
        self.iconName = iconName
    }

    public struct Panel: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// SF Symbol name.
        public var symbol: String?
        public var defaultSize: HUDSize?
        public var compactSize: HUDSize?
        public var capabilities: [String]
        /// Verbs the panel accepts beyond the required set (and the required ones it supports).
        public var verbs: [String]
        /// Path of a settings schema, relative to `Contents/Resources`.
        public var settingsSchema: String?
        /// How MacHUD presents the panel in its tool dock: `windowed` panels are placed,
        /// parked, dismissed and summoned by click; `hover` panels drop down while the
        /// pointer is over their dock button and go away when it leaves.
        public var kind: Kind
        /// Sort key within its `kind` group on the MacHUD dock (ascending; panels without one
        /// come after those with one, in manifest order).
        public var order: Int?

        public enum Kind: String, Codable, Sendable { case windowed, hover }

        public init(id: String, title: String, symbol: String? = nil, defaultSize: HUDSize? = nil,
                    compactSize: HUDSize? = nil, capabilities: [String] = [], verbs: [String] = [],
                    settingsSchema: String? = nil, kind: Kind = .windowed, order: Int? = nil) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.defaultSize = defaultSize
            self.compactSize = compactSize
            self.capabilities = capabilities
            self.verbs = verbs
            self.settingsSchema = settingsSchema
            self.kind = kind
            self.order = order
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
            defaultSize = try c.decodeIfPresent(HUDSize.self, forKey: .defaultSize)
            compactSize = try c.decodeIfPresent(HUDSize.self, forKey: .compactSize)
            capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
            verbs = try c.decodeIfPresent([String].self, forKey: .verbs) ?? []
            settingsSchema = try c.decodeIfPresent(String.self, forKey: .settingsSchema)
            kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .windowed
            order = try? c.decodeIfPresent(Int.self, forKey: .order)
        }

        /// The JSON object form used by `hello`.
        public var json: [String: Any] {
            let data = (try? JSONEncoder().encode(self)) ?? Data()
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["id": id, "title": title]
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        socket = try c.decode(String.self, forKey: .socket)
        panels = try c.decodeIfPresent([Panel].self, forKey: .panels) ?? []
        iconName = try? c.decodeIfPresent(String.self, forKey: .iconName)
    }

    public func panel(id: String) -> Panel? { panels.first { $0.id == id } }

    /// MacHUD dock order: hover panels first, then windowed; within a kind by `order`
    /// (panels without one last), ties kept in their given order.
    public static func dockSorted(_ panels: [Panel]) -> [Panel] {
        panels.enumerated().sorted { a, b in
            let ka = a.element.kind == .hover ? 0 : 1, kb = b.element.kind == .hover ? 0 : 1
            if ka != kb { return ka < kb }
            switch (a.element.order, b.element.order) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Where this app's control socket lives.
    public var socketPath: String {
        socket.hasPrefix("/") ? socket : HUDSocket.path(for: socket)
    }

    // MARK: - Loading

    public static func decode(_ data: Data) throws -> HUDManifest {
        try JSONDecoder().decode(HUDManifest.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// `<bundle>/Contents/Resources/machud.json`.
    public static func manifestURL(inBundleAt bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true).appendingPathComponent(fileName)
    }

    /// Reads the manifest of the app bundle at `bundleURL`.
    public static func load(fromBundleAt bundleURL: URL) throws -> HUDManifest {
        try decode(Data(contentsOf: manifestURL(inBundleAt: bundleURL)))
    }

    /// The running app's own manifest, if its bundle has one.
    public static var main: HUDManifest? {
        try? load(fromBundleAt: Bundle.main.bundleURL)
    }
}

/// A width/height pair encoded as a two-element JSON array: `[220, 220]`.
public struct HUDSize: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) { self.init(width: Double(size.width), height: Double(size.height)) }

    public var cgSize: CGSize { CGSize(width: width, height: height) }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        width = try c.decode(Double.self)
        height = try c.decode(Double.self)
        if !c.isAtEnd {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "size must be [width, height]")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(width)
        try c.encode(height)
    }
}
