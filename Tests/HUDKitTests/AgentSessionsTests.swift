import XCTest
@testable import HUDKit

final class AgentSessionsTests: XCTestCase {
    func testOpenSessionArgs() {
        XCTAssertEqual(HUDAgentSessions.openSessionArgs(id: "claude:abc"),
                       ["name": "open-session", "id": "claude:abc"])
    }

    func testParseSkipsInvalidEntriesButKeepsTheRest() {
        let reply: [String: Any] = ["ok": true, "sessions": [
            ["id": "claude:1", "title": "Fix the bug", "cwd": "/tmp/work", "state": "running"],
            ["id": "claude:2", "state": "idle"],
            ["title": "no id"],
            "not a dictionary",
        ]]
        let sessions = HUDAgentSession.parseAll(reply)
        XCTAssertEqual(sessions, [
            HUDAgentSession(id: "claude:1", title: "Fix the bug", cwd: "/tmp/work", state: "running"),
            HUDAgentSession(id: "claude:2", title: "claude:2", state: "idle"),
        ])
    }

    func testJSONRoundTrip() {
        let session = HUDAgentSession(id: "claude:1", title: "Fix the bug", cwd: "/tmp/work", state: "running")
        let parsed = HUDAgentSession.parse(session.json)
        XCTAssertEqual(parsed, session)

        let withoutCWD = HUDAgentSession(id: "claude:2", title: "claude:2", state: "idle")
        XCTAssertNil(withoutCWD.json["cwd"])
    }
}
