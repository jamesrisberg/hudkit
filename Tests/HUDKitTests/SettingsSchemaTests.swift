import XCTest
import AppKit
@testable import HUDKit

final class SettingsSchemaTests: XCTestCase {
    /// Sift's Resources/settings.json, verbatim.
    static let sift = """
    {
      "version": 1,
      "settings": [
        {"key": "defaultFolder", "title": "Default folder", "type": "path",
         "help": "Folder Sift opens at launch. Empty reopens the last folder."},
        {"key": "collisionPolicy", "title": "When names collide", "type": "enum",
         "options": [
           {"value": "keepBoth", "title": "Keep both"},
           {"value": "replace", "title": "Replace (old item goes to the Trash)"},
           {"value": "skip", "title": "Skip"}
         ],
         "default": "keepBoth"},
        {"key": "showHidden", "title": "Show hidden files", "type": "bool", "default": false},
        {"key": "rulesAutoApply", "title": "Apply rules automatically in watched folders", "type": "bool", "default": false}
      ]
    }
    """

    func testDecodesSiftSchema() throws {
        let schema = try HUDSettingsSchema.decode(Data(Self.sift.utf8))
        XCTAssertEqual(schema.version, 1)
        XCTAssertEqual(schema.settings.map(\.key), ["defaultFolder", "collisionPolicy", "showHidden", "rulesAutoApply"])
        XCTAssertEqual(schema.field("defaultFolder")?.type, .path)
        XCTAssertNil(schema.field("defaultFolder")?.default)
        XCTAssertEqual(schema.field("defaultFolder")?.help, "Folder Sift opens at launch. Empty reopens the last folder.")
        let policy = try XCTUnwrap(schema.field("collisionPolicy"))
        XCTAssertEqual(policy.type, .enum)
        XCTAssertEqual(policy.options.map(\.value), ["keepBoth", "replace", "skip"])
        XCTAssertEqual(policy.options[0].title, "Keep both")
        XCTAssertEqual(policy.default, .string("keepBoth"))
        XCTAssertEqual(schema.field("showHidden")?.default, .bool(false))
        XCTAssertEqual(schema.groups, [nil])
        XCTAssertEqual(schema.defaults["showHidden"] as? Bool, false)
    }

    func testFieldTypesOptionsAndGroups() throws {
        let json = """
        {"settings": [
          {"key": "gap", "type": "integer", "default": 8, "group": "Layout"},
          {"key": "theme", "type": "enum", "options": ["dark", "light"], "group": "Look"},
          {"key": "name", "default": "x"},
          {"key": "future", "type": "colour", "group": "Layout"}
        ]}
        """
        let schema = try HUDSettingsSchema.decode(Data(json.utf8))
        XCTAssertEqual(schema.version, HUDSettingsSchema.currentVersion)
        XCTAssertEqual(schema.field("gap")?.type, .int)
        XCTAssertEqual(schema.field("gap")?.default, .int(8))
        XCTAssertEqual(schema.field("gap")?.title, "gap")
        XCTAssertEqual(schema.field("theme")?.options, [.init(value: "dark"), .init(value: "light")])
        XCTAssertEqual(schema.field("name")?.type, .string)
        XCTAssertEqual(schema.field("future")?.type, .string)
        XCTAssertEqual(schema.groups, ["Layout", "Look", nil])
    }

    func testParseAndValidate() throws {
        let schema = try HUDSettingsSchema.decode(Data(Self.sift.utf8))
        XCTAssertEqual(try schema.field("showHidden")?.parse("yes"), .bool(true))
        XCTAssertEqual(try schema.field("showHidden")?.parse("0"), .bool(false))
        XCTAssertThrowsError(try schema.field("showHidden")?.parse("maybe"))
        XCTAssertEqual(try schema.field("collisionPolicy")?.parse("skip"), .string("skip"))
        XCTAssertThrowsError(try schema.field("collisionPolicy")?.parse("merge"))
        XCTAssertEqual(try HUDSettingsSchema.Field(key: "n", type: .int).parse(" 12 "), .int(12))
        XCTAssertThrowsError(try HUDSettingsSchema.Field(key: "n", type: .int).parse("1.5"))
        XCTAssertThrowsError(try schema.validate(["nope": "1"])) { error in
            XCTAssertEqual(error as? HUDSettingsError, .unknownKey("nope"))
        }
        XCTAssertEqual(try schema.validate(["showHidden": "true", "defaultFolder": "~/x"]),
                       ["showHidden": .bool(true), "defaultFolder": .string("~/x")])
    }

    func testNumberTypeWithBounds() throws {
        let json = """
        {"settings": [
          {"key": "autosaveDelay", "title": "Autosave delay", "type": "number", "min": 0.1, "max": 10, "step": 0.05, "default": 0.75},
          {"key": "ratio", "type": "double"},
          {"key": "count", "type": "integer", "min": 1, "max": 5},
          {"key": "legacy", "type": "int"}
        ]}
        """
        let schema = try HUDSettingsSchema.decode(Data(json.utf8))
        let delay = try XCTUnwrap(schema.field("autosaveDelay"))
        XCTAssertEqual(delay.type, .number)
        XCTAssertEqual(delay.min, 0.1)
        XCTAssertEqual(delay.max, 10)
        XCTAssertEqual(delay.step, 0.05)
        XCTAssertEqual(delay.default, .double(0.75))
        XCTAssertEqual(schema.field("ratio")?.type, .number)
        XCTAssertEqual(try delay.parse(" 0.5 "), .double(0.5))
        XCTAssertEqual(try delay.parse("10"), .double(10))
        XCTAssertThrowsError(try delay.parse("0.05")) {
            XCTAssertEqual($0 as? HUDSettingsError, .invalid(key: "autosaveDelay", reason: "must be at least 0.1"))
        }
        XCTAssertThrowsError(try delay.parse("11")) {
            XCTAssertEqual($0 as? HUDSettingsError, .invalid(key: "autosaveDelay", reason: "must be at most 10"))
        }
        XCTAssertThrowsError(try delay.parse("soon"))
        XCTAssertThrowsError(try delay.parse("nan"))
        XCTAssertThrowsError(try delay.parse("inf"))
        // Bounds apply to int too; an int without bounds is unchanged.
        XCTAssertEqual(try schema.field("count")?.parse("5"), .int(5))
        XCTAssertThrowsError(try schema.field("count")?.parse("0"))
        XCTAssertThrowsError(try schema.field("count")?.parse("2.5"))
        XCTAssertEqual(try schema.field("legacy")?.parse("-40"), .int(-40))
        // min/max/step survive encoding and the JSON form `settings schema` serves.
        XCTAssertEqual(try HUDSettingsSchema.decode(schema.encoded()), schema)
        XCTAssertEqual(HUDSettingsSchema(json: schema.json), schema)
        let served = try XCTUnwrap((schema.json["settings"] as? [[String: Any]])?.first)
        XCTAssertEqual(served["type"] as? String, "number")
        XCTAssertEqual(served["min"] as? Double, 0.1)
        XCTAssertEqual(served["step"] as? Double, 0.05)
        XCTAssertNil((schema.json["settings"] as? [[String: Any]])?[3]["min"], "absent bounds are omitted")
        XCTAssertEqual(HUDSettingValue.double(0.75).doubleValue, 0.75)
        XCTAssertEqual(HUDSettingValue.string("2").doubleValue, 2)
        XCTAssertNil(HUDSettingValue.bool(true).doubleValue)
    }

    func testRoundTripAndJSONForm() throws {
        let schema = try HUDSettingsSchema.decode(Data(Self.sift.utf8))
        XCTAssertEqual(try HUDSettingsSchema.decode(schema.encoded()), schema)
        XCTAssertEqual(HUDSettingsSchema(json: schema.json), schema)
        XCTAssertNil(HUDSettingsSchema(json: ["settings": "nope"]))
    }

    func testSettingValueFromJSONObjects() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"b": true, "i": 3, "d": 1.5, "s": "x"}"#.utf8)) as! [String: Any]
        XCTAssertEqual(HUDSettingValue(any: object["b"]!), .bool(true))
        XCTAssertEqual(HUDSettingValue(any: object["i"]!), .int(3))
        XCTAssertEqual(HUDSettingValue(any: object["d"]!), .double(1.5))
        XCTAssertEqual(HUDSettingValue(any: object["s"]!), .string("x"))
        XCTAssertEqual(HUDSettingValue.bool(true).wireString, "true")
        XCTAssertEqual(HUDSettingValue.string("off").boolValue, false)
    }

    func testLoadsFromBundle() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString).app")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Data(Self.sift.utf8).write(to: resources.appendingPathComponent("settings.json"))
        let manifest = HUDManifest(id: "a.b", name: "A", socket: "a",
                                   panels: [HUDManifest.Panel(id: "p", title: "P"),
                                            HUDManifest.Panel(id: "q", title: "Q", settingsSchema: "settings.json")])
        XCTAssertEqual(HUDSettingsSchema.load(manifest: manifest, bundleURL: bundle)?.settings.count, 4)
        XCTAssertNil(HUDSettingsSchema.load(manifest: HUDManifest(id: "a.b", name: "A", socket: "a"), bundleURL: bundle))
    }
}
