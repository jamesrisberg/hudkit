import CoreGraphics
import Foundation

/// Where a widget sits: on the desktop (under every window, raised while MacHUD reveals or
/// edits widgets) or floating above windows.
public enum HUDWidgetLayer: String, Codable, CaseIterable, Sendable {
    case desktop, float
}

/// One placed widget. MacHUD owns these records (it persists them and sends them with
/// `widget create|update|sync`); the app keeps them in memory only and renders them.
///
/// JSON form (`widget list`, `widget sync`, replies):
/// `{"instance": "8F0C…", "type": "clock", "size": "small", "frame": [x, y, w, h],
///   "layer": "desktop", "settings": {"seconds": true}}`; `frame` is AppKit screen
/// coordinates (origin bottom-left of the main display).
public struct HUDWidgetInstance: Equatable, Sendable {
    /// MacHUD's id for the instance; opaque to the app.
    public var id: String
    /// The widget type: the id of a `kind: widget` panel in the manifest.
    public var type: String
    public var size: HUDWidgetSize
    public var frame: CGRect
    public var layer: HUDWidgetLayer
    /// This instance's settings, typed by the type's settings schema where it lists the key.
    public var settings: [String: HUDSettingValue]

    public init(id: String, type: String, size: HUDWidgetSize, frame: CGRect, layer: HUDWidgetLayer = .desktop,
                settings: [String: HUDSettingValue] = [:]) {
        self.id = id
        self.type = type
        self.size = size
        self.frame = frame
        self.layer = layer
        self.settings = settings
    }

    public var json: [String: Any] {
        ["instance": id, "type": type, "size": size.rawValue, "frame": Self.frameJSON(frame), "layer": layer.rawValue,
         "settings": Self.settingsJSON(settings)]
    }

    public static func frameJSON(_ frame: CGRect) -> [Double] {
        [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) }
    }

    public static func settingsJSON(_ settings: [String: HUDSettingValue]) -> [String: Any] {
        settings.mapValues(\.jsonValue)
    }

    // MARK: - Wire parsing (shared by the verb's args and `sync`'s JSON)

    /// A frame from `[x, y, w, h]`, `"x,y,w,h"` or `{"x", "y", "w", "h"}`, with a positive size.
    static func parseFrame(_ value: Any) throws -> CGRect {
        var rect: CGRect?
        if let s = value as? String {
            rect = HUDPanelTransition.parseAnchor(s)
        } else if let a = value as? [Any], a.count == 4 {
            let n = a.compactMap { ($0 as? NSNumber)?.doubleValue }
            if n.count == 4 { rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
        } else if let d = value as? [String: Any] {
            let n = ["x", "y", "w", "h"].compactMap { (d[$0] as? NSNumber)?.doubleValue }
            if n.count == 4 { rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
        }
        guard let rect, [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else {
            throw HUDControlError.invalid("frame must be x,y,w,h")
        }
        guard rect.width > 0, rect.height > 0 else { throw HUDControlError.invalid("frame must have a positive width and height") }
        return rect
    }

    static func parseSize(_ raw: String) throws -> HUDWidgetSize {
        guard let size = HUDWidgetSize(rawValue: raw) else {
            throw HUDControlError.invalid("size must be small, medium, large or extraLarge")
        }
        return size
    }

    static func parseLayer(_ raw: String) throws -> HUDWidgetLayer {
        guard let layer = HUDWidgetLayer(rawValue: raw) else { throw HUDControlError.invalid("layer must be desktop or float") }
        return layer
    }

    /// Settings from a JSON object (or its text), each value checked against `schema` when the
    /// schema lists the key; other keys are kept unchecked (as `settings set` does).
    static func parseSettings(_ value: Any, schema: HUDSettingsSchema?) throws -> [String: HUDSettingValue] {
        var object = value
        if let text = value as? String {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
                throw HUDControlError.invalid("settings must be a JSON object")
            }
            object = parsed
        }
        guard let dict = object as? [String: Any] else { throw HUDControlError.invalid("settings must be a JSON object") }
        var out: [String: HUDSettingValue] = [:]
        for (key, raw) in dict.sorted(by: { $0.key < $1.key }) {
            guard let value = HUDSettingValue(any: raw) else {
                throw HUDControlError.invalid("\(key) must be a string, number or bool")
            }
            out[key] = try validate(key, value, schema: schema)
        }
        return out
    }

    static func validate(_ key: String, _ value: HUDSettingValue, schema: HUDSettingsSchema?) throws -> HUDSettingValue {
        guard let field = schema?.field(key) else { return value }
        var wire = value.wireString
        // A JSON 2.0 is still a whole number for an int field.
        if case .double(let d) = value, field.type == .int, d == d.rounded(), abs(d) < 1e15 { wire = String(Int64(d)) }
        do { return try field.parse(wire) } catch { throw HUDControlError.invalid("\(error)") }
    }
}
