import XCTest
@testable import HUDKit

/// `HUDAnnounce` against a fake MacHUD that captures the `apps announce` request.
final class AnnounceTests: XCTestCase {
    private var dir: URL!
    private var fake: HUDSocketServer!
    private var socketPath: String!
    private var captured: [[String: String]] = []

    override func setUpWithError() throws {
        // Short path: sun_path is only 104 bytes.
        dir = URL(fileURLWithPath: "/tmp/hudkit-ann-\(getpid())-\(Int.random(in: 0..<1_000_000))")
        socketPath = HUDSocket.path(for: "machud", in: dir)
        fake = HUDSocketServer(path: socketPath, label: "hudkit.fake-machud")
        fake.register("apps") { [weak self] args, done in
            self?.captured.append(args)
            done(["ok": true, "changed": true])
        }
        XCTAssertTrue(fake.start())
    }

    override func tearDownWithError() throws {
        fake.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeApp(_ name: String, manifest: Bool) throws -> URL {
        let app = dir.appendingPathComponent(name)
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if manifest {
            try Data(#"{"id":"dev.test.app","name":"Test","socket":"test"}"#.utf8)
                .write(to: resources.appendingPathComponent("machud.json"))
        }
        return app
    }

    /// Spins the main run loop (the fake's handler runs there) until `done` or 5 s.
    private func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testAnnouncesBundleWithManifest() throws {
        let app = try makeApp("Test.app", manifest: true)
        let box = ResponseBox()
        XCTAssertTrue(HUDAnnounce.announce(bundleURL: app, socketPath: socketPath, environment: [:]) { box.set($0) })
        spin { box.isSet }
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?["action"], "announce")
        XCTAssertEqual(captured.first?["path"], app.path)
        XCTAssertEqual(box.value?["ok"] as? Bool, true)
    }

    func testSkips() throws {
        let app = try makeApp("Test.app", manifest: true)
        let plain = try makeApp("Plain.app", manifest: false)
        XCTAssertNil(HUDAnnounce.skipReason(bundleURL: app, socketPath: socketPath, environment: [:]))
        XCTAssertNotNil(HUDAnnounce.skipReason(bundleURL: app, socketPath: socketPath, environment: ["HUD_NO_ANNOUNCE": "1"]))
        XCTAssertNotNil(HUDAnnounce.skipReason(bundleURL: plain, socketPath: socketPath, environment: [:]), "no manifest")
        XCTAssertNotNil(HUDAnnounce.skipReason(bundleURL: URL(fileURLWithPath: "/usr/bin"), socketPath: socketPath,
                                               environment: [:]), "not an app bundle (CLI)")
        XCTAssertNotNil(HUDAnnounce.skipReason(bundleURL: app, socketPath: dir.appendingPathComponent("none.sock").path,
                                               environment: [:]), "MacHUD not running")
        XCTAssertNotNil(HUDAnnounce.skipReason(bundleURL: app, socketPath: socketPath, ownPaths: [socketPath],
                                               environment: [:]), "MacHUD announcing to itself")
        XCTAssertFalse(HUDAnnounce.announce(bundleURL: plain, socketPath: socketPath, environment: [:]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(captured.isEmpty)
    }

    func testFailureIsIgnored() throws {
        let app = try makeApp("Test.app", manifest: true)
        // A socket file with nothing listening: the request fails, completion gets nil.
        let stale = dir.appendingPathComponent("stale.sock").path
        FileManager.default.createFile(atPath: stale, contents: nil)
        let box = ResponseBox()
        XCTAssertTrue(HUDAnnounce.announce(bundleURL: app, socketPath: stale, environment: [:]) { box.set($0) })
        spin { box.isSet }
        XCTAssertTrue(box.isSet)
        XCTAssertNil(box.value)
    }

    func testSocketPathHonoursMachudSocket() {
        XCTAssertEqual(HUDAnnounce.machudSocketPath(environment: ["MACHUD_SOCKET": "/tmp/x.sock"]), "/tmp/x.sock")
        XCTAssertEqual(HUDAnnounce.machudSocketPath(environment: [:]), HUDSocket.path(for: "machud"))
    }

    func testTestRunnerIsNotAnApp() {
        // `swift test` runs from a CLI, so starting a server there never announces.
        XCTAssertNotNil(HUDAnnounce.skipReason(bundleURL: Bundle.main.bundleURL, socketPath: socketPath, environment: [:]))
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [String: Any]?
    private var _set = false
    func set(_ v: [String: Any]?) { lock.lock(); _value = v; _set = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return _set }
    var value: [String: Any]? { lock.lock(); defer { lock.unlock() }; return _value }
}
