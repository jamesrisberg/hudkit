import CoreGraphics
import Foundation

/// The `widget` object of a `kind: widget` manifest panel: what one widget type offers.
///
/// ```json
/// {"id": "clock", "title": "Clock", "symbol": "clock", "kind": "widget",
///  "widget": {"sizes": ["small", "medium"], "defaultSize": "small", "multiple": true,
///             "refresh": 1, "settingsSchema": "clock.widget.json"}}
/// ```
///
/// Every key is optional and decoding is lenient, so a newer manifest still loads: unknown
/// sizes are skipped, a malformed value reads as its default.
public struct HUDWidgetSpec: Codable, Equatable, Hashable, Sendable {
    /// The sizes the type can be placed at, in the manifest's order. Never empty.
    public var sizes: [HUDWidgetSize]
    /// The size a new instance gets. Always one of `sizes`.
    public var defaultSize: HUDWidgetSize
    /// Whether the type can be placed more than once (each instance has its own settings).
    public var multiple: Bool
    /// How often the content changes, in seconds: a hint (MacHUD's gallery, the app's own
    /// timers). HUDKit does not redraw on it.
    public var refresh: Double?
    /// Per-instance settings schema (`HUDSettingsSchema`), relative to `Contents/Resources`.
    /// Not the app's settings: those stay on the panel-level `settingsSchema`.
    public var settingsSchema: String?

    public init(sizes: [HUDWidgetSize] = [.small], defaultSize: HUDWidgetSize? = nil, multiple: Bool = true,
                refresh: Double? = nil, settingsSchema: String? = nil) {
        let sizes = sizes.isEmpty ? [defaultSize ?? .small] : sizes
        self.sizes = sizes
        self.defaultSize = defaultSize.flatMap { sizes.contains($0) ? $0 : nil } ?? sizes[0]
        self.multiple = multiple
        self.refresh = refresh
        self.settingsSchema = settingsSchema
    }

    private enum CodingKeys: String, CodingKey { case sizes, defaultSize, multiple, refresh, settingsSchema }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String].self, forKey: .sizes)) ?? []
        let sizes = raw.compactMap(HUDWidgetSize.init(rawValue:))
        let defaultSize = (try? c.decodeIfPresent(String.self, forKey: .defaultSize)).flatMap(HUDWidgetSize.init(rawValue:))
        self.init(sizes: sizes, defaultSize: defaultSize,
                  multiple: (try? c.decodeIfPresent(Bool.self, forKey: .multiple)) ?? true,
                  refresh: try? c.decodeIfPresent(Double.self, forKey: .refresh),
                  settingsSchema: try? c.decodeIfPresent(String.self, forKey: .settingsSchema))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sizes.map(\.rawValue), forKey: .sizes)
        try c.encode(defaultSize.rawValue, forKey: .defaultSize)
        try c.encode(multiple, forKey: .multiple)
        try c.encodeIfPresent(refresh, forKey: .refresh)
        try c.encodeIfPresent(settingsSchema, forKey: .settingsSchema)
    }
}

/// A widget's footprint in grid cells. MacHUD chooses the real cell size and gap and sends
/// frames; HUDKit's nominal cell (170 pt, 16 pt gap) is for snapshots and for frames nobody
/// sent.
///
/// | size | cells (columns × rows) | nominal points |
/// |---|---|---|
/// | `small` | 1 × 1 | 170 × 170 |
/// | `medium` | 2 × 1 | 356 × 170 |
/// | `large` | 2 × 2 | 356 × 356 |
/// | `extraLarge` | 4 × 2 | 728 × 356 |
public enum HUDWidgetSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large, extraLarge

    public struct Cells: Equatable, Hashable, Sendable {
        public var columns: Int
        public var rows: Int
        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    public static let nominalCell: CGFloat = 170
    public static let nominalGap: CGFloat = 16

    public var cells: Cells {
        switch self {
        case .small: return Cells(columns: 1, rows: 1)
        case .medium: return Cells(columns: 2, rows: 1)
        case .large: return Cells(columns: 2, rows: 2)
        case .extraLarge: return Cells(columns: 4, rows: 2)
        }
    }

    /// The size in points for a grid of `cell`-point squares `gap` points apart.
    public func points(cell: CGFloat = nominalCell, gap: CGFloat = nominalGap) -> CGSize {
        let c = cells
        return CGSize(width: CGFloat(c.columns) * cell + CGFloat(c.columns - 1) * gap,
                      height: CGFloat(c.rows) * cell + CGFloat(c.rows - 1) * gap)
    }

    /// The size after this one among `sizes` (wrapping), for the edit-mode resize control; the
    /// first size when this one is not among them; nil when there is nothing else to go to.
    public func next(in sizes: [HUDWidgetSize]) -> HUDWidgetSize? {
        guard let first = sizes.first else { return nil }
        guard let i = sizes.firstIndex(of: self) else { return first }
        let next = sizes[(i + 1) % sizes.count]
        return next == self ? nil : next
    }
}
