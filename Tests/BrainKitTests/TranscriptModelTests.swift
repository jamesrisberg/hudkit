import XCTest
@testable import BrainKit

final class TranscriptModelTests: XCTestCase {
    private func approval(_ id: String) -> AgentApproval {
        AgentApproval(id: id, kind: "command", reason: "Outside the workspace", command: "rm x", cwd: "/tmp")
    }

    private func replies(_ model: TranscriptModel) -> [String] {
        model.rows.compactMap {
            if case .reply(let text, let streaming) = $0.kind { return "\(text)|\(streaming)" }
            return nil
        }
    }

    private func resolutions(_ model: TranscriptModel) -> [TranscriptRow.Resolution?] {
        model.rows.compactMap { row -> TranscriptRow.Resolution?? in
            if case .approval(let a) = row.kind { return .some(a.resolution) }
            return nil
        }
    }

    private func progressStates(_ model: TranscriptModel) -> [TranscriptRow.ToolState] {
        model.rows.compactMap {
            if case .progress(_, let state) = $0.kind { return state }
            return nil
        }
    }

    func testStreamingReplyIsSwappedForTheFinalMessageInOneStep() {
        var model = TranscriptModel()
        model.userSaid("what time is it")
        XCTAssertEqual(model.apply(.init(turnId: "t1", status: "running")), [.turnStarted])
        XCTAssertEqual(model.apply(.init(turnId: "t1", status: "running", output: "It is")), [.firstOutput])
        XCTAssertEqual(model.apply(.init(turnId: "t1", status: "running", output: "It is ten")), [])
        let streamingRows = model.rows.map(\.id)
        XCTAssertEqual(replies(model), ["It is ten|true"])

        XCTAssertEqual(model.apply(.init(turnId: "t1", status: "idle", output: "It is ten o'clock.")), [.turnEnded])
        // Same row, same id, final text: nothing shows twice.
        XCTAssertEqual(model.rows.map(\.id), streamingRows)
        XCTAssertEqual(replies(model), ["It is ten o'clock.|false"])
        XCTAssertFalse(model.turnActive)
        XCTAssertEqual(model.rows[0].kind, .user("what time is it"))
        XCTAssertEqual(model.rows[0].turnId, "t1")
    }

    func testRepeatedSnapshotsAreIdempotent() {
        var model = TranscriptModel()
        let snapshot = TranscriptInput(turnId: "t1", status: "running", output: "Hi", progress: "Reading")
        model.userSaid("hello")
        model.apply(snapshot)
        let rows = model.rows
        XCTAssertEqual(model.apply(snapshot), [])
        XCTAssertEqual(model.rows, rows)
    }

    func testProgressLinesSettleAsNewOnesArrive() {
        var model = TranscriptModel()
        model.userSaid("clean up")
        model.apply(.init(turnId: "t1", status: "running", progress: "Listing files"))
        model.apply(.init(turnId: "t1", status: "running", progress: "Measuring sizes"))
        XCTAssertEqual(progressStates(model), [.done, .running])
        model.apply(.init(turnId: "t1", status: "failed", error: "boom"))
        XCTAssertEqual(progressStates(model), [.done, .failed])
        XCTAssertEqual(model.rows.last?.kind, .notice("boom", isError: true))
    }

    func testApprovalAddedThenResolvedByTheHost() {
        var model = TranscriptModel()
        model.userSaid("delete it")
        model.apply(.init(turnId: "t1", status: "running"))
        let events = model.apply(.init(turnId: "t1", status: "approval", approvals: [approval("a1")]))
        XCTAssertEqual(events, [.approvalAdded])
        XCTAssertEqual(model.pendingApprovals.map(\.id), ["a1"])

        model.markDecision(approvalID: "a1", allow: true)
        XCTAssertEqual(model.pendingApprovals.first?.resolution, .delivering(allow: true))
        // Still listed until the companion drops it.
        model.apply(.init(turnId: "t1", status: "approval", progress: "x", approvals: [approval("a1")]))
        XCTAssertEqual(model.pendingApprovals.count, 1)

        model.apply(.init(turnId: "t1", status: "running", progress: "Deleting"))
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertEqual(resolutions(model), [.allowed])
    }

    func testApprovalAnsweredElsewhereOrDeniedIsLabeled() {
        var model = TranscriptModel()
        model.userSaid("two things")
        model.apply(.init(turnId: "t1", status: "running", progress: "Step one"))
        model.apply(.init(turnId: "t1", status: "approval", approvals: [approval("a1"), approval("a2")]))
        model.markDecision(approvalID: "a2", allow: false)
        model.apply(.init(turnId: "t1", status: "running", progress: "Step one"))
        XCTAssertEqual(resolutions(model), [.resolved, .denied])
        // A denial marks the tool line it interrupted.
        XCTAssertTrue(model.rows.contains { $0.kind == .progress("Step one", state: .denied) })
    }

    func testFailedDeliveryMakesTheApprovalAnswerableAgain() {
        var model = TranscriptModel()
        model.userSaid("go")
        model.apply(.init(turnId: "t1", status: "approval", approvals: [approval("a1")]))
        model.markDecision(approvalID: "a1", allow: true)
        model.decisionFailed(approvalID: "a1", message: "Companion (409): expired")
        XCTAssertEqual(model.pendingApprovals.first?.resolution, .failed("Companion (409): expired"))
        // And the companion later dropping it no longer claims it was allowed.
        model.apply(.init(turnId: "t1", status: "idle", output: "Done"))
        XCTAssertEqual(resolutions(model), [.resolved])
    }

    func testHistoricalCompletionIsShownButNotAnnounced() {
        var model = TranscriptModel()
        XCTAssertEqual(model.apply(.init(turnId: "old", status: "idle", output: "Earlier answer")), [])
        XCTAssertEqual(replies(model), ["Earlier answer|false"])
        XCTAssertFalse(model.turnActive)
    }

    func testFastCompletionAfterUserInputIsALiveTurn() {
        var model = TranscriptModel()
        model.userSaid("quick one")
        XCTAssertEqual(model.apply(.init(turnId: "t9", status: "idle", output: "Done.")),
                       [.turnStarted, .firstOutput, .turnEnded])
    }

    func testInterruptedTurnGetsANotice() {
        var model = TranscriptModel()
        model.userSaid("long job")
        model.apply(.init(turnId: "t1", status: "running", output: "Working on"))
        model.apply(.init(turnId: "t1", status: "interrupted", output: "Working on"))
        XCTAssertEqual(replies(model), ["Working on|false"])
        XCTAssertEqual(model.rows.last?.kind, .notice("Interrupted. Completed changes may remain.", isError: false))
    }

    func testRowsAreBounded() {
        var model = TranscriptModel()
        model.maxRows = 5
        for i in 0..<10 { model.userSaid("line \(i)") }
        XCTAssertEqual(model.rows.count, 5)
        XCTAssertEqual(model.rows.first?.kind, .user("line 5"))
    }

    func testSnapshotInputCarriesTheRenderedFields() {
        let json = """
        {"threadId":"th","turnId":"t1","status":"approval","output":"Hi","progress":"Asking",
         "approvals":[{"id":"a","kind":"tool","reason":"Run it?"}],"error":null,"revision":3,
         "instanceId":"i","requestId":null}
        """
        let snapshot = try! JSONDecoder().decode(AgentSessionSnapshot.self, from: Data(json.utf8))
        let input = TranscriptInput(snapshot)
        XCTAssertEqual(input, TranscriptInput(turnId: "t1", status: "approval", output: "Hi", progress: "Asking",
                                              approvals: [AgentApproval(id: "a", kind: "tool", reason: "Run it?")]))
        XCTAssertTrue(input.isWorking)
    }
}
