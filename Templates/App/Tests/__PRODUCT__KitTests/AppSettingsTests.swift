import Foundation
import XCTest
@testable import __PRODUCT__Kit

final class AppSettingsTests: XCTestCase {
    func testApplyingParsesStrings() throws {
        let next = try AppSettings().applying(["greeting": "  hi  ", "showCount": "off"])
        XCTAssertEqual(next, AppSettings(greeting: "hi", showCount: false))
    }

    func testApplyingRejectsBadValuesWithoutPartialChanges() {
        let settings = AppSettings()
        XCTAssertThrowsError(try settings.applying(["showCount": "maybe"])) {
            XCTAssertEqual($0 as? AppSettings.SettingsError, .invalid(key: "showCount", value: "maybe"))
        }
        XCTAssertThrowsError(try settings.applying(["greeting": " "]))
        XCTAssertThrowsError(try settings.applying(["colour": "red"])) {
            XCTAssertEqual($0 as? AppSettings.SettingsError, .unknownKey("colour"))
        }
    }

    func testSaveAndLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("preferences.json")
        XCTAssertEqual(AppSettings.load(from: url), AppSettings(), "missing file reads as defaults")
        let custom = AppSettings(greeting: "yo", showCount: false)
        try custom.save(to: url)
        XCTAssertEqual(AppSettings.load(from: url), custom)
    }

    func testLoadMergesSavedValuesOverDefaultsKeyByKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("preferences.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Written before showCount existed, plus a key a later version dropped.
        try Data(#"{"greeting": "yo", "retired": 3}"#.utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings(greeting: "yo", showCount: true))
        // One value of the wrong type falls back alone; the rest are kept.
        try Data(#"{"greeting": "yo", "showCount": "sometimes"}"#.utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings(greeting: "yo", showCount: true))
        try Data(#"{"greeting": 7, "showCount": false}"#.utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings(showCount: false))
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings())
    }

    func testJSONCoversEveryKey() {
        XCTAssertEqual(Set(AppSettings().json.keys), AppSettings.keys)
    }
}
