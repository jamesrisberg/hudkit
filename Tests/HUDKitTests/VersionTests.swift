import Foundation
import XCTest
@testable import HUDKit

/// The repo's VERSION file and `HUDKit.version` (what `hello` reports) must agree.
final class VersionTests: XCTestCase {
    func testVersionFileMatchesHUDKitVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        XCTAssertEqual(file.trimmingCharacters(in: .whitespacesAndNewlines), HUDKit.version)
    }

    func testChangelogHasTheCurrentVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        XCTAssertTrue(changelog.contains("## [\(HUDKit.version)]"))
    }
}
