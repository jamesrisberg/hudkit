import XCTest
@testable import HUDKit

@MainActor
private final class DropHost: HUDPanelHost {
    var dropped: [URL] = []
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "p", visible: true)] }
    func showPanel(_ id: String) throws {}
    func hidePanel(_ id: String) throws {}
    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        guard name == HUDDrop.action else { done(["ok": false]); return }
        dropped = HUDDrop.urls(from: args)
        done(["ok": true, "count": dropped.count])
    }
    func quit() {}
}

final class DropTests: XCTestCase {
    func testRoundTripOddNames() {
        let paths = ["/tmp/plain.txt", "/Users/me/a|b.txt", "/Users/me/100% done.pdf", "/Users/me/key=value & more",
                     "/Users/me/Ünïcödé 日本語 🎉.png", "/tmp/new\nline", "/tmp/with,comma;semi#hash?q", "/tmp/%7C literal"]
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let encoded = HUDDrop.encode(urls)
        XCTAssertEqual(encoded.split(separator: "|").count, paths.count, "only the separators are bare pipes")
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(HUDDrop.decode(encoded).map(\.path), paths)
    }

    func testDecodeLenient() {
        XCTAssertEqual(HUDDrop.decode(""), [])
        XCTAssertEqual(HUDDrop.decode("|/a||/b|").map(\.path), ["/a", "/b"])
        XCTAssertEqual(HUDDrop.decode("/bad%zz").map(\.path), ["/bad%zz"], "invalid escapes kept literally")
        XCTAssertEqual(HUDDrop.decode("file:///tmp/x%20y").first?.path, "/tmp/x y")
    }

    func testArgsSurviveCLIParsing() {
        let urls = [URL(fileURLWithPath: "/tmp/a=b|c d")]
        let args = HUDDrop.args(for: urls, panel: "portal")
        let cli = HUDSocketClient.parseArguments(["drop"] + args.map { "\($0.key)=\($0.value)" })
        XCTAssertEqual(cli["id"], "portal")
        XCTAssertEqual(HUDDrop.urls(from: cli), urls)
        XCTAssertEqual(HUDDrop.urls(from: [:]), [])
    }

    @MainActor
    func testRouterDeliversDrop() {
        let host = DropHost()
        let router = HUDControlRouter(host: host, server: HUDSocketServer(path: "/tmp/unused-\(UUID().uuidString).sock"), manifest: nil)
        let urls = [URL(fileURLWithPath: "/tmp/one|two"), URL(fileURLWithPath: "/tmp/three")]
        var out: [String: Any] = [:]
        router.handle("action", args: HUDSocketClient.parseArguments(["drop", "paths=\(HUDDrop.encode(urls))"])) { out = $0 }
        XCTAssertEqual(out["count"] as? Int, 2)
        XCTAssertEqual(host.dropped, urls)
    }
}
