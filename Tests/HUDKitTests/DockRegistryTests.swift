import XCTest
import Combine
@testable import HUDKit

final class DockRegistryTests: XCTestCase {
    private var dir: URL!
    private var registry: HUDDockRegistry!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hudkit-docks-\(UUID().uuidString)")
        registry = HUDDockRegistry(url: dir.appendingPathComponent("docks.json"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testDefaultURL() {
        XCTAssertTrue(HUDDockRegistry.defaultURL.path.hasSuffix("Application Support/MacHUD/docks.json"))
    }

    func testPublishRemoveOthers() throws {
        XCTAssertEqual(registry.entries(), [:], "missing file reads as empty")
        let a = CGRect(x: 0, y: 950, width: 40, height: 40), b = CGRect(x: 0, y: 600, width: 40, height: 390)
        try registry.publish(appID: "machud", position: .topLeft, frames: [a, b])
        try registry.publish(appID: "sift", position: .bottom, frames: [CGRect(x: 500, y: 0, width: 300, height: 44)])

        let machud = try XCTUnwrap(registry.entry(for: "machud"))
        XCTAssertEqual(machud.position, .topLeft)
        XCTAssertEqual(machud.frames, [a, b])
        XCTAssertEqual(machud.pid, getpid())
        XCTAssertEqual(Array(registry.others(than: "machud").keys), ["sift"])

        // The file is the documented shape.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registry.url)) as? [String: [String: Any]])
        XCTAssertEqual(json["machud"]?["position"] as? String, "topLeft")
        XCTAssertEqual(json["machud"]?["frames"] as? [[Double]], [[0, 950, 40, 40], [0, 600, 40, 390]])
        XCTAssertNotNil((json["machud"]?["updatedAt"] as? String).flatMap(HUDDockRegistry.parseDate))

        try registry.remove(appID: "sift")
        XCTAssertEqual(registry.others(than: "machud"), [:])
        try registry.remove(appID: "nobody")
    }

    func testUnchangedPublishDoesNotRewrite() throws {
        try registry.publish(appID: "a", position: .top, frames: [.init(x: 1, y: 2, width: 3, height: 4)])
        let stamp = try XCTUnwrap(registry.entry(for: "a")?.updatedAt)
        try registry.publish(appID: "a", position: .top, frames: [.init(x: 1, y: 2, width: 3, height: 4)])
        XCTAssertEqual(registry.entry(for: "a")?.updatedAt, stamp)
    }

    func testTolerantDecodingAndStaleEntries() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = """
        {"good": {"position": "right", "frames": [[1,2,3,4], [9]], "updatedAt": "2026-01-01T00:00:00Z"},
         "weird": {"position": "middle", "frames": []},
         "dead": {"position": "top", "frames": [], "updatedAt": "2026-01-01T00:00:00Z", "pid": 2147483000}}
        """
        try Data(text.utf8).write(to: registry.url)
        let all = registry.entries()
        XCTAssertEqual(Set(all.keys), ["good", "dead"])
        XCTAssertEqual(all["good"]?.frames, [CGRect(x: 1, y: 2, width: 3, height: 4)])
        XCTAssertEqual(Set(registry.others(than: "me").keys), ["good"], "dead pid is ignored")
        try Data("not json".utf8).write(to: registry.url)
        XCTAssertEqual(registry.entries(), [:])
    }

    func testWatcherFiresOnWrite() throws {
        let fired = expectation(description: "watch fired")
        fired.assertForOverFulfill = false
        let seen = LockedBox<[String: HUDDockRegistry.Entry]>()
        let other = HUDDockRegistry(url: registry.url)
        let watch = registry.watch(queue: .global(), debounce: 0.05) { entries in
            seen.value = entries
            if entries["sift"] != nil { fired.fulfill() }
        }
        try other.publish(appID: "sift", position: .left, frames: [CGRect(x: 0, y: 100, width: 44, height: 300)])
        wait(for: [fired], timeout: 3)
        XCTAssertEqual(seen.value?["sift"]?.position, .left)
        watch.cancel()
    }

    func testWatcherIgnoresNoOpAndStopsWhenCancelled() throws {
        try registry.publish(appID: "a", position: .top, frames: [])
        let count = LockedBox<Int>()
        count.value = 0
        var watch: AnyCancellable? = registry.watch(queue: .global(), debounce: 0.05) { _ in count.value! += 1 }
        try registry.publish(appID: "a", position: .top, frames: [])  // unchanged: no write
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(count.value, 0)
        watch = nil
        try registry.publish(appID: "a", position: .bottom, frames: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(count.value, 0)
        _ = watch
    }
}

final class DockAvoidTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    func testClearFrameUnchanged() {
        let f = CGRect(x: 600, y: 950, width: 400, height: 50)
        XCTAssertEqual(HUDDockLayout.avoiding(frame: f, others: [CGRect(x: 600, y: 0, width: 400, height: 50)], along: .top), f,
                       "a strip on another edge does not block")
        XCTAssertEqual(HUDDockLayout.avoiding(frame: f, others: [], along: .top, in: screen), f)
    }

    func testSlidesTowardMoreRoom() {
        let f = CGRect(x: 600, y: 950, width: 400, height: 50)
        // Blocker on the left part of the strip: more room to the right.
        let blocker = CGRect(x: 500, y: 960, width: 300, height: 40)
        XCTAssertEqual(HUDDockLayout.avoiding(frame: f, others: [blocker], along: .top, in: screen).minX, 800)
        // Blocker near the right edge: room only on the left.
        let right = CGRect(x: 900, y: 950, width: 600, height: 50)
        XCTAssertEqual(HUDDockLayout.avoiding(frame: f, others: [right], along: .top, in: screen).minX, 500)
    }

    func testVerticalEdgeAndNoRoom() {
        let f = CGRect(x: 0, y: 300, width: 44, height: 400)
        let blocker = CGRect(x: 0, y: 600, width: 44, height: 200)
        XCTAssertEqual(HUDDockLayout.avoiding(frame: f, others: [blocker], along: .left, in: screen).maxY, 600)
        let wall = CGRect(x: 0, y: 100, width: 44, height: 800)
        XCTAssertEqual(HUDDockLayout.avoiding(frame: f, others: [wall], along: .left, in: screen), f, "nowhere to go: unchanged")
    }

    func testSkipsPastSeveralBlockers() {
        let f = CGRect(x: 100, y: 0, width: 200, height: 40)
        let others = [CGRect(x: 0, y: 0, width: 250, height: 40), CGRect(x: 250, y: 0, width: 100, height: 40)]
        XCTAssertEqual(HUDDockLayout.avoiding(frame: f, others: others, along: .bottom, in: screen).minX, 350)
        // Unbounded: the shorter move wins.
        let g = CGRect(x: 100, y: 0, width: 100, height: 40)
        XCTAssertEqual(HUDDockLayout.avoiding(frame: g, others: [CGRect(x: 180, y: 0, width: 100, height: 40)], along: .bottom).minX, 80)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
