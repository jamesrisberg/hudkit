import Combine
import XCTest
@testable import BrainKit

private func requestBody(_ request: URLRequest) -> Data {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return data
}

private class JSONProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    func respond(_ object: Any, status: Int = 200) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A turn that completes before the POST returns, while a poll still sees the previous turn.
private final class ImmediateCompletionProtocol: JSONProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var complete = false
    static func reset() { lock.lock(); complete = false; lock.unlock() }

    override func startLoading() {
        let isPost = request.httpMethod == "POST"
        // At 500 ms a GET still reports the previous completed turn while POST is in flight.
        DispatchQueue.global().asyncAfter(deadline: .now() + (isPost ? 0.9 : 0)) { [self] in
            Self.lock.lock()
            if isPost { Self.complete = true }
            let completed = Self.complete
            Self.lock.unlock()
            respond([
                "threadId": "thread", "turnId": completed ? "new-turn" : "old-turn", "status": "idle",
                "output": completed ? "New reply" : "Previous reply", "progress": "Done", "approvals": [],
                "revision": completed ? 101 : 100, "instanceId": "one",
                "route": ["tier": "fast", "model": "test-fast", "effort": "low", "reason": "Simple request"],
                "timing": ["startedAt": 1000, "firstResponseMs": 225, "completedMs": 500],
            ])
        }
    }
}

private final class PermissionsProtocol: JSONProtocol, @unchecked Sendable {
    override func startLoading() {
        var permissions: [String: Any] = ["mode": "approvedFolders", "approvedFolders": ["/workspace"]]
        if request.httpMethod == "POST" {
            guard request.url?.path == "/v1/permissions",
                  let body = try? JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any],
                  Set(body.keys) == ["mode", "approvedFolders"],
                  body["approvedFolders"] as? [String] == ["/workspace", "/another folder"]
            else { return respond(["error": "unexpected permissions request"], status: 400) }
            permissions = body
        }
        respond([
            "status": "idle", "output": "", "progress": "Ready", "approvals": [],
            "revision": request.httpMethod == "POST" ? 2 : 1, "instanceId": "permissions-test",
            "permissions": permissions,
        ])
    }
}

private final class RuntimeProtocol: JSONProtocol, @unchecked Sendable {
    override func startLoading() {
        var runtime = "codex"
        if request.httpMethod == "POST" {
            // Only the runtime name crosses the wire.
            guard request.url?.path == "/v1/runtime",
                  (try? JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String]) == ["runtime": "hermes"]
            else { return respond(["error": "unexpected runtime request"], status: 400) }
            runtime = "hermes"
        }
        respond([
            "threadId": runtime == "hermes" ? "brainkit-1" : "thread", "status": "idle", "output": "",
            "progress": "Ready", "approvals": [], "revision": request.httpMethod == "POST" ? 2 : 1,
            "instanceId": "runtime-test", "runtime": runtime,
            "capabilities": ["approvals": true, "folderScope": runtime == "codex", "modelRouting": runtime == "codex",
                             "cancel": true],
        ])
    }
}

private final class ConflictProtocol: JSONProtocol, @unchecked Sendable {
    override func startLoading() { respond(["error": "A turn is already active"], status: 409) }
}

@MainActor
final class AgentSessionClientTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:8788")!

    private func client(_ protocolClass: AnyClass, token: String = String(repeating: "a", count: 64),
                        endpoint: URL? = nil) -> AgentSessionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return AgentSessionClient(endpoint: endpoint ?? self.endpoint, token: token,
                                  session: URLSession(configuration: configuration))
    }

    func testImmediateCompletionIsReturnedAndAStalePollIsSuppressed() async throws {
        ImmediateCompletionProtocol.reset()
        let client = client(ImmediateCompletionProtocol.self)
        var oldCompletions = 0
        let observation = client.$snapshot.sink { if $0?.turnId == "old-turn" { oldCompletions += 1 } }
        try await client.connect()
        XCTAssertEqual(oldCompletions, 1)
        let submitted = try await client.submit(text: "New request")
        // The server can finish before it returns turn/start. Its returned turn is authoritative.
        XCTAssertEqual(submitted.turnId, "new-turn")
        XCTAssertEqual(submitted.status, "idle")
        XCTAssertEqual(client.snapshot?.turnId, "new-turn")
        XCTAssertEqual(submitted.route?.model, "test-fast")
        XCTAssertEqual(submitted.route?.effort, "low")
        XCTAssertEqual(submitted.timing?.firstResponseMs, 225)
        XCTAssertEqual(submitted.timing?.completedMs, 500)
        XCTAssertEqual(oldCompletions, 1, "A stale GET was published during the pending POST")
        client.disconnect()
        withExtendedLifetime(observation) {}
    }

    func testPermissionsReachTheirEndpointAndApplyTheConfirmedSnapshot() async throws {
        let client = client(PermissionsProtocol.self, token: String(repeating: "b", count: 64))
        try await client.connect()
        XCTAssertEqual(client.snapshot?.permissions?.mode, .approvedFolders)
        XCTAssertNil(client.snapshot?.route, "A snapshot without a route decodes")
        XCTAssertNil(client.snapshot?.runtime)
        XCTAssertEqual(client.snapshot?.runtimeName, "Codex", "A companion without a runtime field runs Codex")
        let requested = AgentPermissions(mode: .fullAccess, approvedFolders: ["/workspace", "/another folder"])
        let applied = try await client.setPermissions(requested)
        XCTAssertEqual(applied.permissions, requested)
        XCTAssertEqual(client.snapshot?.permissions, requested)
        client.disconnect()
    }

    func testRuntimeChoicePostsOnlyItsName() async throws {
        let client = client(RuntimeProtocol.self, token: String(repeating: "c", count: 64))
        try await client.connect()
        XCTAssertEqual(client.snapshot?.runtimeName, "Codex")
        XCTAssertEqual(client.snapshot?.capabilities?.folderScope, true)
        let switched = try await client.setRuntime(.hermes)
        XCTAssertEqual(switched.runtime, "hermes")
        XCTAssertEqual(switched.runtimeName, "Hermes")
        XCTAssertEqual(switched.threadId, "brainkit-1")
        XCTAssertEqual(switched.capabilities,
                       AgentCapabilities(approvals: true, folderScope: false, modelRouting: false, cancel: true))
        XCTAssertEqual(client.snapshot?.runtime, "hermes")
        client.disconnect()
    }

    func testSnapshotsCarryTheExternalSessionKey() throws {
        let base = #"{"status":"idle","output":"","progress":"Ready","approvals":[],"revision":1,"runtime":"mclaude""#
        let mclaude = try JSONDecoder().decode(AgentSessionSnapshot.self, from: Data((base + #","sessionKey":"claude:abc"}"#).utf8))
        XCTAssertEqual(mclaude.sessionKey, "claude:abc")
        XCTAssertEqual(mclaude.runtimeName, "mclaude")
        let none = try JSONDecoder().decode(AgentSessionSnapshot.self, from: Data((base + #","sessionKey":null}"#).utf8))
        XCTAssertNil(none.sessionKey)
    }

    func testSnapshotsCarryTheToolServerStatus() throws {
        let base = #"{"status":"idle","output":"","progress":"Ready","approvals":[],"revision":1,"runtime":"hermes""#
        let hermes = try JSONDecoder().decode(AgentSessionSnapshot.self, from: Data((base
            + #","toolServers":{"names":["machud"],"active":false,"note":"Hermes cannot use this app's tools (machud)."}}"#).utf8))
        XCTAssertEqual(hermes.toolServers,
                       AgentToolServerStatus(names: ["machud"], active: false, note: "Hermes cannot use this app's tools (machud)."))
        let older = try JSONDecoder().decode(AgentSessionSnapshot.self, from: Data((base + "}").utf8))
        XCTAssertNil(older.toolServers)
    }

    func testServerErrorsCarryStatusAndMessage() async {
        let client = client(ConflictProtocol.self)
        do {
            try await client.submit(text: "Hello")
            XCTFail("expected a server error")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .server(409, "A turn is already active"))
            XCTAssertEqual(client.errorMessage, "Companion (409): A turn is already active")
        }
    }

    func testOnlyLoopbackEndpointsAndWellFormedTokensAreUsed() async {
        for bad in ["http://localhost:8788", "https://127.0.0.1:8788", "http://127.0.0.1:80", "http://127.0.0.1:8788/v1"] {
            do {
                try await client(ConflictProtocol.self, endpoint: URL(string: bad)!).connect()
                XCTFail("\(bad) was accepted")
            } catch {
                XCTAssertEqual(error as? AgentSessionError, .invalidEndpoint, bad)
            }
        }
        do {
            try await client(ConflictProtocol.self, token: "short").connect()
            XCTFail("a malformed token was accepted")
        } catch {
            XCTAssertEqual(error as? AgentSessionError, .missingToken)
        }
    }
}
