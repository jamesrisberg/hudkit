import XCTest
import AppKit
@testable import HUDKit

final class SocketTests: XCTestCase {
    private var dir: URL!
    private var server: HUDSocketServer!

    override func setUpWithError() throws {
        // Short path: sun_path is only 104 bytes.
        dir = URL(fileURLWithPath: "/tmp/hudkit-\(getpid())-\(Int.random(in: 0..<1_000_000))")
        let path = HUDSocket.path(for: "t", in: dir)
        server = HUDSocketServer(path: path, label: "hudkit.test")
        server.register("echo") { args, done in done(["ok": true, "args": args, "main": Thread.isMainThread]) }
        server.register("fail") { _, done in done(["ok": false, "error": "nope"]) }
        server.register("slow") { _, done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done(["ok": true]) } }
        server.register("twice") { _, done in done(["ok": true, "n": 1]); done(["ok": true, "n": 2]) }
        server.register("never") { _, _ in }
        XCTAssertTrue(server.start())
    }

    func testSecondServerDoesNotTakeOverLiveSocket() throws {
        let path = HUDSocket.path(for: "t", in: dir)
        let second = HUDSocketServer(path: path, label: "hudkit.test2")
        XCTAssertFalse(second.start(), "a live socket must not be unlinked by a second instance")
        // The first server still answers.
        let r = try offMain { try HUDSocketClient(path: path).request("echo", args: ["a": "1"]) }
        XCTAssertEqual(r["ok"] as? Bool, true)
        // A stale socket file (no listener) is still replaced.
        let stale = HUDSocket.path(for: "stale", in: dir)
        FileManager.default.createFile(atPath: stale, contents: nil)
        let third = HUDSocketServer(path: stale, label: "hudkit.test3")
        XCTAssertTrue(third.start())
        third.stop()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Requests block until the main thread runs the handler, so do them off-main while the
    /// test spins the run loop.
    private func offMain<T>(_ work: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>?
        DispatchQueue.global().async {
            let r = Result { try work() }
            DispatchQueue.main.async { result = r }
        }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return try XCTUnwrap(result).get()
    }

    func testPathConventionAndPermissions() throws {
        XCTAssertEqual(server.path, dir.appendingPathComponent("t.sock").path)
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
        let sockMode = try FileManager.default.attributesOfItem(atPath: server.path)[.posixPermissions] as? Int
        XCTAssertEqual(sockMode, 0o600)
        XCTAssertTrue(HUDSocket.path(for: "wormhole").hasSuffix("/Library/Application Support/MacHUD/sockets/wormhole.sock"))
    }

    func testRequestResponseRoundTrip() throws {
        let client = HUDSocketClient(path: server.path, timeout: 5)
        let r = try offMain { try client.request("echo", args: ["a": "1", "n": 5]) }
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["args"] as? [String: String], ["a": "1", "n": "5"], "arg values arrive as strings")
        XCTAssertEqual(r["main"] as? Bool, true, "handlers run on the main thread")

        let fail = try offMain { try client.request("fail") }
        XCTAssertEqual(fail["error"] as? String, "nope")
        let slow = try offMain { try client.request("slow") }
        XCTAssertEqual(slow["ok"] as? Bool, true)
        let twice = try offMain { try client.request("twice") }
        XCTAssertEqual(twice["n"] as? Int, 1, "only the first done() counts")
    }

    func testHelpUnknownAndMalformed() throws {
        let client = HUDSocketClient(path: server.path, timeout: 5)
        let help = try offMain { try client.request("help") }
        XCTAssertEqual(help["commands"] as? [String], ["echo", "fail", "never", "slow", "twice"])
        let unknown = try offMain { try client.request("bogus") }
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        XCTAssertEqual(unknown["error"] as? String, "unknown command bogus")

        let raw = try offMain { () -> String in
            let fd = try HUDSocket.connect(to: self.server.path)
            defer { close(fd) }
            HUDSocket.writeAll(fd, Data("not json\n".utf8))
            return HUDLineReader(fd: fd).next() ?? ""
        }
        XCTAssertTrue(raw.contains("malformed request"), raw)
    }

    func testHandlerTimeout() throws {
        server.handlerTimeout = 0.2
        let r = try offMain { try HUDSocketClient(path: self.server.path, timeout: 5).request("never") }
        XCTAssertEqual(r["error"] as? String, "timeout")
    }

    func testNotRunningAndPathTooLong() {
        let client = HUDSocketClient(path: dir.appendingPathComponent("absent.sock").path)
        XCTAssertFalse(client.isServerRunning)
        XCTAssertThrowsError(try client.request("ping")) { error in
            guard case HUDSocketError.notRunning = error else { return XCTFail("\(error)") }
        }
        let long = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        XCTAssertThrowsError(try HUDSocketClient(path: long).request("ping")) { error in
            guard case HUDSocketError.pathTooLong = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(HUDSocketServer(path: long).start())
    }

    func testCLIFailureMessageNamesTheRealReason() {
        let absent = dir.appendingPathComponent("absent.sock").path
        XCTAssertThrowsError(try HUDSocketClient(path: absent).request("ping")) { error in
            XCTAssertEqual(HUDSocketClient.failureMessage(for: error, path: absent, appName: "tally"),
                           "tally is not running (no socket at \(absent))")
        }
        let long = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        XCTAssertThrowsError(try HUDSocketClient(path: long).request("ping")) { error in
            let message = HUDSocketClient.failureMessage(for: error, path: long, appName: "tally")
            XCTAssertFalse(message.contains("not running"), message)
            XCTAssertTrue(message.contains("socket path too long (210 bytes, the limit is \(HUDSocket.maxPathLength))"), message)
            XCTAssertTrue(message.contains(long), message)
        }
        XCTAssertEqual(HUDSocketClient.failureMessage(for: HUDSocketError.timeout, path: absent, appName: "tally"), "tally: timeout")
    }

    func testSubscribePush() throws {
        let client = HUDSocketClient(path: server.path, timeout: 5)
        let received = Received()
        let closed = expectation(description: "closed")
        let all = try client.subscribe(onEvent: { received.append("all", $0) }, onClose: { closed.fulfill() })
        let filtered = try client.subscribe(events: ["badge"], onEvent: { received.append("badge", $0) })

        let deadline = Date().addingTimeInterval(5)
        while server.subscriberCount < 2 && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(server.subscriberCount, 2)

        server.publish("state", payload: ["panels": [["id": "p", "visible": true]]])
        server.publish("badge", payload: ["id": "p", "badge": "3"])

        while received.count < 3 && Date() < deadline { usleep(10_000) }
        let events = received.snapshot
        XCTAssertEqual(events.filter { $0.0 == "all" }.map { $0.1["event"] as? String }, ["state", "badge"])
        XCTAssertEqual(events.filter { $0.0 == "badge" }.map { $0.1["event"] as? String }, ["badge"])
        let state = try XCTUnwrap(events.first { $0.1["event"] as? String == "state" }?.1)
        XCTAssertEqual((state["panels"] as? [[String: Any]])?.first?["id"] as? String, "p")

        // Request/response still works alongside open subscriptions.
        XCTAssertEqual(try offMain { try client.request("echo") }["ok"] as? Bool, true)

        all.cancel()
        wait(for: [closed], timeout: 5)
        XCTAssertFalse(all.isActive)
        // The server notices the disconnect (on read EOF or on the next failed write).
        while server.subscriberCount > 1 && Date() < deadline {
            server.publish("tick")
            usleep(10_000)
        }
        XCTAssertEqual(server.subscriberCount, 1)
        XCTAssertTrue(filtered.isActive)
        filtered.cancel()
    }

    func testServerStopEndsSubscriptions() throws {
        let closed = expectation(description: "closed")
        _ = try HUDSocketClient(path: server.path, timeout: 5).subscribe(onEvent: { _ in }, onClose: { closed.fulfill() })
        let deadline = Date().addingTimeInterval(5)
        while server.subscriberCount < 1 && Date() < deadline { usleep(10_000) }
        server.stop()
        wait(for: [closed], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.path))
    }

    func testAdditionalPathsShareHandlers() throws {
        let extra = dir.appendingPathComponent("legacy.sock").path
        let multi = HUDSocketServer(path: HUDSocket.path(for: "m", in: dir), additionalPaths: [extra])
        multi.register("who") { _, done in done(["ok": true, "me": "multi"]) }
        XCTAssertTrue(multi.start())
        for path in multi.paths {
            let r = try offMain { try HUDSocketClient(path: path, timeout: 5).request("who") }
            XCTAssertEqual(r["me"] as? String, "multi", path)
        }
        multi.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: extra))
        XCTAssertFalse(HUDSocketClient(path: multi.path).isServerRunning)
    }

    func testAppTerminationRemovesSocket() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.path))
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertFalse(server.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.path))
    }

    func testParseArguments() {
        XCTAssertEqual(HUDSocketClient.parseArguments(["id=dock", "show", "expr=a=b"]),
                       ["id": "dock", "show": "1", "expr": "a=b", "_": "show"])
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, [String: Any])] = []
    func append(_ tag: String, _ obj: [String: Any]) { lock.lock(); items.append((tag, obj)); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var snapshot: [(String, [String: Any])] { lock.lock(); defer { lock.unlock() }; return items }
}
