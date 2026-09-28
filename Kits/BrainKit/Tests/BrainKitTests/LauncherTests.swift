import XCTest
@testable import BrainKit

/// `FoundationProcessLauncher` with real child processes.
@MainActor
final class LauncherTests: XCTestCase {
    private func failureReason(of script: String) async throws -> String {
        let service = ManagedService(id: "t", displayName: "T", readinessMarker: "never printed",
                                     launcher: FoundationProcessLauncher(), scheduler: FakeScheduler())
        service.configure(.success(ProcessSpec(executable: "/bin/sh", arguments: ["-c", script])))
        for _ in 0..<100 {
            if case .backingOff(_, _, let reason) = service.state { return reason }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("no exit reported: \(service.state)")
        return ""
    }

    func testTheLastLineAfterLargeOutputIsTheFailureReason() async throws {
        for _ in 0..<5 {
            let reason = try await failureReason(of: "head -c 200000 /dev/zero | tr '\\0' x; echo; echo FATAL >&2; exit 1")
            XCTAssertEqual(reason, "FATAL")
        }
    }

    func testAFinalLineWithoutNewlineIsDelivered() async throws {
        let reason = try await failureReason(of: "echo starting; printf 'FATAL without newline'; exit 1")
        XCTAssertEqual(reason, "FATAL without newline")
    }

    func testExitIsReportedWhileAGrandchildHoldsTheOutput() async throws {
        let started = Date()
        let reason = try await failureReason(of: "sleep 4 & echo FATAL; exit 3")
        XCTAssertEqual(reason, "FATAL")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5)
    }

    func testTheHostsStdinWriteEndIsNotInherited() throws {
        let process = try FoundationProcessLauncher().launch(
            ProcessSpec(executable: "/bin/cat", arguments: []), onOutput: { _ in }, onExit: { _ in })
        defer { process.terminate() }
        let running = try XCTUnwrap(process as? FoundationProcessLauncher.Running)
        let flags = fcntl(running.stdin.fileHandleForWriting.fileDescriptor, F_GETFD)
        XCTAssertNotEqual(flags & FD_CLOEXEC, 0)
    }
}
