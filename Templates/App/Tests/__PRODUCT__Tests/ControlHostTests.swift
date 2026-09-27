import Foundation
import HUDKit
import XCTest
@testable import __PRODUCT__

@MainActor
final class ControlHostTests: XCTestCase {
    private var host: ControlHost!

    override func setUp() async throws {
        let model = AppModel(settingsURL: nil)
        // Never started: the router is driven directly, so no socket is created.
        host = ControlHost(model: model, panel: PanelController(model: model),
                           socketPath: NSTemporaryDirectory() + "unused-\(UUID().uuidString).sock")
    }

    private func call(_ verb: String, _ args: [String: String] = [:]) -> [String: Any] {
        var out: [String: Any] = [:]
        host.router.handle(verb, args: args) { out = $0 }
        return out
    }

    func testHello() {
        let hello = call("hello")
        XCTAssertEqual(hello["ok"] as? Bool, true)
        XCTAssertEqual(hello["hudkit"] as? String, HUDKit.version)
        XCTAssertEqual(hello["app"] as? String, "xyz.machud.__REPO__")
    }

    func testSayChangesTheTextAndEmptyRestoresTheGreeting() {
        XCTAssertEqual(call("action", ["name": "say", "text": "hi"])["text"] as? String, "hi")
        XCTAssertEqual((call("state")["panels"] as? [[String: Any]])?.first?["status"] as? String, "hi")
        XCTAssertEqual(call("action", ["name": "say"])["text"] as? String, host.model.settings.greeting)
    }

    func testSettingsSetValidates() {
        XCTAssertEqual(call("settings", ["action": "set", "showCount": "0"])["ok"] as? Bool, true)
        XCTAssertEqual(host.model.settings.showCount, false)
        XCTAssertEqual(call("settings", ["action": "set", "showCount": "maybe"])["ok"] as? Bool, false)
    }

    func testUnknownPanel() {
        XCTAssertEqual(call("panel", ["id": "nope", "action": "show"])["ok"] as? Bool, false)
    }
}
