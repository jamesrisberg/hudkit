import XCTest
@testable import HUDKit

final class ManifestTests: XCTestCase {
    static let planExample = """
    {
      "id": "xyz.viawormhole.wormhole",
      "name": "Wormhole",
      "socket": "wormhole",
      "panels": [
        {
          "id": "portal",
          "title": "Portal",
          "symbol": "circle.dotted",
          "defaultSize": [220, 220],
          "compactSize": [72, 72],
          "capabilities": ["acceptsFileDrop"],
          "verbs": ["show", "hide", "toggle", "select-set"],
          "settingsSchema": "settings.json"
        }
      ]
    }
    """

    func testDecodesPlanExample() throws {
        let m = try HUDManifest.decode(Data(Self.planExample.utf8))
        XCTAssertEqual(m.id, "xyz.viawormhole.wormhole")
        XCTAssertEqual(m.name, "Wormhole")
        XCTAssertEqual(m.socket, "wormhole")
        XCTAssertEqual(m.panels.count, 1)
        let p = try XCTUnwrap(m.panel(id: "portal"))
        XCTAssertEqual(p.title, "Portal")
        XCTAssertEqual(p.symbol, "circle.dotted")
        XCTAssertEqual(p.defaultSize, HUDSize(width: 220, height: 220))
        XCTAssertEqual(p.compactSize?.cgSize, CGSize(width: 72, height: 72))
        XCTAssertEqual(p.capabilities, ["acceptsFileDrop"])
        XCTAssertEqual(p.verbs, ["show", "hide", "toggle", "select-set"])
        XCTAssertEqual(p.settingsSchema, "settings.json")
    }

    func testRoundTrip() throws {
        let m = try HUDManifest.decode(Data(Self.planExample.utf8))
        let again = try HUDManifest.decode(m.encoded())
        XCTAssertEqual(m, again)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: m.encoded()) as? [String: Any])
        let panel = try XCTUnwrap((obj["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(panel["defaultSize"] as? [Double], [220, 220], "sizes encode as [w, h] arrays")
    }

    func testOptionalFieldsDefault() throws {
        let m = try HUDManifest.decode(Data(#"{"id":"a.b","name":"A","socket":"a","panels":[{"id":"p"}]}"#.utf8))
        let p = try XCTUnwrap(m.panels.first)
        XCTAssertEqual(p.title, "p")
        XCTAssertNil(p.symbol)
        XCTAssertNil(p.defaultSize)
        XCTAssertEqual(p.capabilities, [])
        XCTAssertEqual(p.verbs, [])
        let bare = try HUDManifest.decode(Data(#"{"id":"a.b","name":"A","socket":"a"}"#.utf8))
        XCTAssertEqual(bare.panels, [])
    }

    func testRejectsBadSizeAndMissingID() {
        XCTAssertThrowsError(try HUDManifest.decode(Data(#"{"id":"a","name":"A","socket":"a","panels":[{"id":"p","defaultSize":[1,2,3]}]}"#.utf8)))
        XCTAssertThrowsError(try HUDManifest.decode(Data(#"{"name":"A","socket":"a"}"#.utf8)))
    }

    func testSocketPath() {
        let m = HUDManifest(id: "a", name: "A", socket: "wormhole")
        XCTAssertTrue(m.socketPath.hasSuffix("Library/Application Support/MacHUD/sockets/wormhole.sock"), m.socketPath)
        XCTAssertEqual(HUDManifest(id: "a", name: "A", socket: "/tmp/x.sock").socketPath, "/tmp/x.sock")
    }

    // MARK: - Bundles and scanner

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hudkit-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeApp(_ path: String, manifest: String?) throws -> URL {
        let app = root.appendingPathComponent(path)
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if let manifest { try Data(manifest.utf8).write(to: resources.appendingPathComponent("machud.json")) }
        return app
    }

    func testLoadFromBundle() throws {
        let app = try makeApp("A/Wormhole.app", manifest: Self.planExample)
        XCTAssertEqual(try HUDManifest.load(fromBundleAt: app).name, "Wormhole")
        let plain = try makeApp("A/Plain.app", manifest: nil)
        XCTAssertThrowsError(try HUDManifest.load(fromBundleAt: plain))
    }

    func testScannerFindsAppsSkipsInvalidAndDedupes() throws {
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        try makeApp("one/Wormhole.app", manifest: Self.planExample)
        try makeApp("one/Plain.app", manifest: nil)
        try makeApp("one/Broken.app", manifest: "{not json")
        try makeApp("one/Utilities/Detox.app", manifest: #"{"id":"dev.detox","name":"Detox","socket":"detox"}"#)
        try makeApp("two/Wormhole.app", manifest: Self.planExample.replacingOccurrences(of: "\"Wormhole\"", with: "\"Wormhole Copy\""))
        try makeApp("two/Deep/Deeper/Hidden.app", manifest: #"{"id":"x","name":"X","socket":"x"}"#)

        let scanner = HUDManifestScanner(extraDirectories: [one, two, root.appendingPathComponent("missing")],
                                         includeStandard: false)
        let report = scanner.scanReport()
        XCTAssertEqual(report.entries.map(\.manifest.id).sorted(), ["dev.detox", "xyz.viawormhole.wormhole"])
        XCTAssertEqual(report.entries.first { $0.manifest.id == "xyz.viawormhole.wormhole" }?.manifest.name, "Wormhole",
                       "earlier directory wins")
        XCTAssertEqual(report.failures.map(\.bundleURL.lastPathComponent), ["Broken.app"])
        XCTAssertEqual(scanner.scan().count, 2)
    }

    func testScannerBundlesAndKeepingDuplicates() throws {
        let one = root.appendingPathComponent("one")
        let first = try makeApp("one/Wormhole.app", manifest: Self.planExample)
        let dev = try makeApp("dev/build/Wormhole.app", manifest: Self.planExample)
        let gone = root.appendingPathComponent("gone/Nothing.app")
        // `first` also listed as a bundle: the same bundle is reported once.
        let scanner = HUDManifestScanner(extraDirectories: [one], includeStandard: false, bundles: [dev, gone, first])
        let paths = { (urls: [URL]) in urls.map { $0.resolvingSymlinksInPath().path } }
        XCTAssertEqual(paths(scanner.scan().map(\.bundleURL)), paths([first]), "deduped by id, directories first")
        let all = scanner.scanReport(keepingDuplicates: true)
        XCTAssertEqual(paths(all.entries.map(\.bundleURL)), paths([first, dev]))
        XCTAssertTrue(all.failures.isEmpty, "a bundle without a manifest is skipped, not a failure")
    }

    func testStandardDirectories() {
        let dirs = HUDManifestScanner().directories.map(\.path)
        XCTAssertEqual(dirs.first, "/Applications")
        XCTAssertTrue(dirs.contains { $0.hasSuffix("/Applications") && $0 != "/Applications" })
    }

    func testPanelKindDefaultsToWindowedAndRoundTrips() throws {
        let json = #"{"id":"a","name":"A","socket":"a","panels":[{"id":"p"},{"id":"h","kind":"hover"}]}"#
        let m = try HUDManifest.decode(Data(json.utf8))
        XCTAssertEqual(m.panels[0].kind, .windowed)
        XCTAssertEqual(m.panels[1].kind, .hover)
        let again = try HUDManifest.decode(try m.encoded())
        XCTAssertEqual(again.panels[1].kind, .hover)
    }
}

final class ManifestOrderIconTests: XCTestCase {
    func testOrderAndIconNameAreOptionalAndRoundTrip() throws {
        let json = #"""
        {"id":"a","name":"A","socket":"a","iconName":"tray.full",
         "panels":[{"id":"w2","order":2},{"id":"w1","order":1},{"id":"h","kind":"hover"},{"id":"w0"},{"id":"x","order":"soon","kind":"floaty"}]}
        """#
        let m = try HUDManifest.decode(Data(json.utf8))
        XCTAssertEqual(m.iconName, "tray.full")
        XCTAssertEqual(m.panels.map(\.order), [2, 1, nil, nil, nil], "malformed order reads as nil")
        XCTAssertEqual(m.panels[4].kind, .unknown("floaty"), "an unknown kind is kept, never read as windowed")
        XCTAssertFalse(m.panels[4].kind.isKnown)
        let again = try HUDManifest.decode(m.encoded())
        XCTAssertEqual(again, m)
        XCTAssertEqual(again.panels[4].json["kind"] as? String, "floaty", "an unknown kind round-trips verbatim")
        XCTAssertEqual(m.panel(id: "w1")?.json["order"] as? Int, 1)
        XCTAssertNil(m.panel(id: "w0")?.json["order"], "nil order is omitted")

        XCTAssertEqual(HUDManifest.dockSorted(m.panels).map(\.id), ["h", "w1", "w2", "w0"], "unknown kinds are not dock panels")

        let bare = try HUDManifest.decode(Data(#"{"id":"b","name":"B","socket":"b"}"#.utf8))
        XCTAssertNil(bare.iconName)
        XCTAssertFalse(String(decoding: try bare.encoded(), as: UTF8.self).contains("iconName"))
        XCTAssertEqual(HUDManifest(id: "c", name: "C", socket: "c", iconName: "star").iconName, "star")
        XCTAssertEqual(HUDManifest.Panel(id: "p", title: "P", order: 3).order, 3)
    }
}
