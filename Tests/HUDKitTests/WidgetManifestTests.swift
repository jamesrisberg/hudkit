import XCTest
@testable import HUDKit

/// The `widget` panel kind in `machud.json`: the `widget` object, sizes, forward compatibility.
final class WidgetManifestTests: XCTestCase {
    static let manifest = """
    {"id": "xyz.machud.glance", "name": "Glance", "socket": "glance",
     "panels": [
       {"id": "settings", "kind": "windowed", "settingsSchema": "settings.json"},
       {"id": "clock", "title": "Clock", "symbol": "clock", "kind": "widget",
        "widget": {"sizes": ["small", "medium", "large"], "defaultSize": "medium", "multiple": true,
                   "refresh": 1, "settingsSchema": "clock.settings.json"}},
       {"id": "weather", "kind": "widget"},
       {"id": "status", "kind": "hover", "order": 2}
     ]}
    """

    func testDecodesWidgetPanel() throws {
        let m = try HUDManifest.decode(Data(Self.manifest.utf8))
        let clock = try XCTUnwrap(m.panel(id: "clock"))
        XCTAssertEqual(clock.kind, .widget)
        XCTAssertTrue(clock.kind.isKnown)
        XCTAssertFalse(clock.kind.isDockKind)
        XCTAssertEqual(clock.widget, HUDWidgetSpec(sizes: [.small, .medium, .large], defaultSize: .medium,
                                                   multiple: true, refresh: 1, settingsSchema: "clock.settings.json"))
        XCTAssertNil(m.panel(id: "status")?.widget, "only widget panels carry a widget spec")
    }

    func testWidgetObjectDefaults() throws {
        let m = try HUDManifest.decode(Data(Self.manifest.utf8))
        let weather = try XCTUnwrap(m.panel(id: "weather")?.widget, "a widget panel without a widget object gets the defaults")
        XCTAssertEqual(weather, HUDWidgetSpec())
        XCTAssertEqual(weather.sizes, [.small])
        XCTAssertEqual(weather.defaultSize, .small)
        XCTAssertTrue(weather.multiple)
        XCTAssertNil(weather.refresh)
        XCTAssertNil(weather.settingsSchema)
        XCTAssertEqual(HUDManifest.Panel(id: "w", title: "W", kind: .widget).widget, HUDWidgetSpec(),
                       "the code initializer agrees with the decoder, so builtinManifest == the file")
    }

    func testWidgetSpecIsLenient() throws {
        let json = #"{"sizes": ["small", "tall", "extraLarge"], "defaultSize": "huge", "multiple": "no", "refresh": "often"}"#
        let spec = try JSONDecoder().decode(HUDWidgetSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.sizes, [.small, .extraLarge], "unknown sizes (a newer contract's) are skipped")
        XCTAssertEqual(spec.defaultSize, .small, "a default that is not a declared size falls back to the first size")
        XCTAssertTrue(spec.multiple, "a malformed multiple reads as the default")
        XCTAssertNil(spec.refresh)
        let none = try JSONDecoder().decode(HUDWidgetSpec.self, from: Data(#"{"sizes": [], "defaultSize": "large"}"#.utf8))
        XCTAssertEqual(none.sizes, [.large], "no sizes: the default size alone")
        XCTAssertEqual(HUDWidgetSpec(sizes: [.medium], defaultSize: .small).defaultSize, .medium)
    }

    func testWidgetPanelRoundTrips() throws {
        let m = try HUDManifest.decode(Data(Self.manifest.utf8))
        XCTAssertEqual(try HUDManifest.decode(m.encoded()), m)
        let clock = try XCTUnwrap(m.panel(id: "clock")?.json)
        XCTAssertEqual(clock["kind"] as? String, "widget")
        let widget = try XCTUnwrap(clock["widget"] as? [String: Any], "hello carries the widget object")
        XCTAssertEqual(widget["sizes"] as? [String], ["small", "medium", "large"])
        XCTAssertEqual(widget["defaultSize"] as? String, "medium")
        XCTAssertEqual(widget["multiple"] as? Bool, true)
        XCTAssertEqual(widget["refresh"] as? Double, 1)
        XCTAssertEqual(widget["settingsSchema"] as? String, "clock.settings.json")
        XCTAssertNil(m.panel(id: "status")?.json["widget"])
    }

    func testDockSortedAndWidgetPanels() throws {
        let m = try HUDManifest.decode(Data(Self.manifest.utf8))
        XCTAssertEqual(HUDManifest.dockSorted(m.panels).map(\.id), ["status", "settings"], "widgets are not dock panels")
        XCTAssertEqual(m.dockPanels.map(\.id), ["status", "settings"])
        XCTAssertEqual(m.widgetPanels.map(\.id), ["clock", "weather"])
        let widgetsOnly = HUDManifest(id: "a", name: "A", socket: "a", panels: [HUDManifest.Panel(id: "c", title: "C", kind: .widget)])
        XCTAssertEqual(widgetsOnly.dockPanels, [], "an app with only widgets has no dock button")
    }

    func testKindRawValues() {
        XCTAssertEqual(HUDManifest.Panel.Kind(rawValue: "hover"), .hover)
        XCTAssertEqual(HUDManifest.Panel.Kind(rawValue: "windowed"), .windowed)
        XCTAssertEqual(HUDManifest.Panel.Kind(rawValue: "widget"), .widget)
        XCTAssertEqual(HUDManifest.Panel.Kind(rawValue: "sidecar"), .unknown("sidecar"))
        XCTAssertEqual(HUDManifest.Panel.Kind.unknown("sidecar").rawValue, "sidecar")
        XCTAssertEqual(HUDManifest.Panel.Kind.widget.rawValue, "widget")
        XCTAssertEqual(HUDManifest.Panel.Kind.unknown("hover"), .unknown("hover"), "unknown(_) is only made by the caller")
        XCTAssertTrue(HUDManifest.Panel.Kind.hover.isDockKind)
        XCTAssertTrue(HUDManifest.Panel.Kind.windowed.isDockKind)
        XCTAssertFalse(HUDManifest.Panel.Kind.unknown("x").isDockKind)
    }

    func testMissingOrMalformedKindStaysWindowed() throws {
        let json = #"{"id":"a","name":"A","socket":"a","panels":[{"id":"p"},{"id":"n","kind":3}]}"#
        let m = try HUDManifest.decode(Data(json.utf8))
        XCTAssertEqual(m.panels.map(\.kind), [.windowed, .windowed], "manifests without kind (contract 0.1) are windowed")
    }

    func testWidgetSizeGrid() {
        XCTAssertEqual(HUDWidgetSize.allCases.map(\.rawValue), ["small", "medium", "large", "extraLarge"])
        XCTAssertEqual(HUDWidgetSize.small.cells, HUDWidgetSize.Cells(columns: 1, rows: 1))
        XCTAssertEqual(HUDWidgetSize.medium.cells, HUDWidgetSize.Cells(columns: 2, rows: 1))
        XCTAssertEqual(HUDWidgetSize.large.cells, HUDWidgetSize.Cells(columns: 2, rows: 2))
        XCTAssertEqual(HUDWidgetSize.extraLarge.cells, HUDWidgetSize.Cells(columns: 4, rows: 2))
        XCTAssertEqual(HUDWidgetSize.small.points(), CGSize(width: 170, height: 170))
        XCTAssertEqual(HUDWidgetSize.medium.points(), CGSize(width: 356, height: 170))
        XCTAssertEqual(HUDWidgetSize.large.points(), CGSize(width: 356, height: 356))
        XCTAssertEqual(HUDWidgetSize.extraLarge.points(), CGSize(width: 728, height: 356))
        XCTAssertEqual(HUDWidgetSize.medium.points(cell: 100, gap: 10), CGSize(width: 210, height: 100))
        XCTAssertEqual(HUDWidgetSize.small.next(in: [.small, .medium, .large]), .medium)
        XCTAssertEqual(HUDWidgetSize.large.next(in: [.small, .medium, .large]), .small, "wraps")
        XCTAssertEqual(HUDWidgetSize.large.next(in: [.small]), .small, "a size not declared goes to the first")
        XCTAssertNil(HUDWidgetSize.small.next(in: [.small]), "one size: nothing to resize to")
    }
}
