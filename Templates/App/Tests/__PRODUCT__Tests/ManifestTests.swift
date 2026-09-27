import Foundation
import HUDKit
import XCTest
@testable import __PRODUCT__
import __PRODUCT__Kit

/// The shipped machud.json and settings.json are what MacHUD reads without launching
/// __PRODUCT__; keep them valid and in step with the code.
final class ManifestTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/__PRODUCT__/Resources")
    }

    private func manifest() throws -> HUDManifest {
        try HUDManifest.decode(Data(contentsOf: resources.appendingPathComponent(HUDManifest.fileName)))
    }

    func testManifestFollowsTheConventions() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.id, "xyz.machud.__REPO__")
        XCTAssertEqual(manifest.socket, "__REPO__", "socket name = CLI name = repo name")
        let panel = try XCTUnwrap(manifest.panel(id: ControlHost.panelID))
        XCTAssertEqual(panel.kind, .hover)
    }

    @MainActor
    func testBuiltinManifestMirrorsTheFile() throws {
        XCTAssertEqual(ControlHost.builtinManifest, try manifest())
    }

    func testSettingsSchemaMatchesAppSettings() throws {
        let name = try XCTUnwrap(try manifest().panels.first?.settingsSchema)
        let data = try Data(contentsOf: resources.appendingPathComponent(name))
        let schema = try HUDSettingsSchema.decode(data)
        XCTAssertEqual(Set(schema.settings.map(\.key)), AppSettings.keys)
    }

    func testInfoPlist() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "xyz.machud.__REPO__")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "__PRODUCT__")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertNotNil(plist["NSHumanReadableCopyright"])
    }
}
