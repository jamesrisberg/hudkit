import XCTest
@testable import BrainKit

@MainActor
final class ServiceSupervisorTests: XCTestCase {
    private let spec = ProcessSpec(executable: "/usr/bin/node", arguments: ["server.mjs"])

    private func make(_ launcher: FakeLauncher, _ scheduler: FakeScheduler) -> ManagedService {
        ManagedService(id: "companion", displayName: "Companion", readinessMarker: "ready at",
                       launcher: launcher, scheduler: scheduler)
    }

    func testBecomesRunningOnReadinessLine() {
        let launcher = FakeLauncher()
        let service = make(launcher, FakeScheduler())
        var readyCount = 0
        service.onReady = { readyCount += 1 }
        service.configure(.success(spec))
        XCTAssertEqual(service.state, .starting)
        launcher.last.say("loading")
        XCTAssertEqual(service.state, .starting)
        launcher.last.say("Brain companion ready at http://127.0.0.1:8790")
        XCTAssertEqual(service.state, .running)
        XCTAssertEqual(readyCount, 1)
        XCTAssertTrue(service.log.contains("loading"))
    }

    func testCrashesRestartWithExponentialBackoffThenGiveUp() {
        let launcher = FakeLauncher()
        let scheduler = FakeScheduler()
        let service = make(launcher, scheduler)
        service.configure(.success(spec))
        var delays: [TimeInterval] = []
        for _ in 1..<6 {
            launcher.last.say("EADDRINUSE")
            launcher.last.exit(1)
            guard case .backingOff(_, let delay, let reason) = service.state else {
                return XCTFail("expected backoff, got \(service.state)")
            }
            XCTAssertEqual(reason, "EADDRINUSE")
            delays.append(delay)
            scheduler.advance(delay)
            XCTAssertEqual(service.state, .starting)
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16])
        XCTAssertEqual(launcher.launched.count, 6)
        launcher.last.exit(1)
        XCTAssertEqual(service.state, .failed("exited with status 1"))
        scheduler.advance(120)
        XCTAssertEqual(launcher.launched.count, 6)
        // An explicit restart tries again from scratch.
        service.restart()
        XCTAssertEqual(service.state, .starting)
        XCTAssertEqual(launcher.launched.count, 7)
        XCTAssertEqual(service.failures, 0)
    }

    func testStableRunResetsFailureCount() {
        let launcher = FakeLauncher()
        let scheduler = FakeScheduler()
        let service = make(launcher, scheduler)
        service.configure(.success(spec))
        launcher.last.exit(1)
        scheduler.advance(1)
        launcher.last.exit(1)
        XCTAssertEqual(service.failures, 2)
        scheduler.advance(2)
        launcher.last.say("ready at x")
        scheduler.advance(60)
        XCTAssertEqual(service.failures, 0)
        launcher.last.exit(1)
        XCTAssertEqual(service.state, .backingOff(attempt: 1, delay: 1, reason: "ready at x"))
    }

    func testStopCancelsPendingRestartAndIgnoresLateExit() {
        let launcher = FakeLauncher()
        let scheduler = FakeScheduler()
        let service = make(launcher, scheduler)
        service.configure(.success(spec))
        launcher.last.exit(1)
        service.stop()
        XCTAssertEqual(service.state, .stopped)
        scheduler.advance(60)
        XCTAssertEqual(launcher.launched.count, 1)

        service.configure(.success(spec))
        let second = launcher.last
        service.stop()
        XCTAssertTrue(second.terminated)
        second.exit(15)
        XCTAssertEqual(service.state, .stopped)
    }

    func testUnavailableConfigurationNeverLaunches() {
        let launcher = FakeLauncher()
        let service = make(launcher, FakeScheduler())
        service.configure(.failure(ServiceUnavailable(reason: "Node.js 22 or later not found")))
        XCTAssertEqual(service.state, .unavailable("Node.js 22 or later not found"))
        XCTAssertTrue(launcher.launched.isEmpty)
        service.configure(.success(spec))
        XCTAssertEqual(service.state, .starting)
    }

    func testLaunchErrorBacksOff() {
        let launcher = FakeLauncher()
        launcher.failNext = true
        let scheduler = FakeScheduler()
        let service = make(launcher, scheduler)
        service.configure(.success(spec))
        XCTAssertEqual(service.state, .backingOff(attempt: 1, delay: 1, reason: "Could not start: no such file"))
        scheduler.advance(1)
        XCTAssertEqual(service.state, .starting)
        XCTAssertEqual(launcher.launched.count, 1)
    }

    func testUnchangedSpecKeepsRunningProcessAndChangedSpecRestarts() {
        let launcher = FakeLauncher()
        let service = make(launcher, FakeScheduler())
        service.configure(.success(spec))
        launcher.last.say("ready at")
        service.configure(.success(spec))
        XCTAssertEqual(launcher.launched.count, 1)
        XCTAssertEqual(service.state, .running)
        var changed = spec
        changed.arguments.append("--cwd")
        let old = launcher.last
        service.configure(.success(changed))
        XCTAssertTrue(old.terminated)
        // The new process waits for the old one to exit, so the port is free.
        XCTAssertEqual(launcher.launched.count, 1)
        XCTAssertEqual(service.state, .starting)
        // The replaced process exiting does not count as a crash.
        old.exit(0)
        XCTAssertEqual(launcher.launched.count, 2)
        XCTAssertEqual(launcher.specs.last, changed)
        XCTAssertEqual(service.state, .starting)
        XCTAssertEqual(service.failures, 0)
    }

    func testRestartWaitsForTheOldProcessButNotForever() {
        let launcher = FakeLauncher()
        let scheduler = FakeScheduler()
        let service = make(launcher, scheduler)
        service.configure(.success(spec))
        launcher.last.say("ready at")
        service.restart()
        XCTAssertTrue(launcher.last.terminated)
        XCTAssertEqual(launcher.launched.count, 1)
        scheduler.advance(9)
        XCTAssertEqual(launcher.launched.count, 1)
        // An old process that never reports its exit does not block the service.
        scheduler.advance(1)
        XCTAssertEqual(launcher.launched.count, 2)
        launcher.launched[0].exit(0)
        XCTAssertEqual(launcher.launched.count, 2)
        XCTAssertEqual(service.state, .starting)
    }

    func testStopWhileWaitingLaunchesNothingAndALaterStartStillWaits() {
        let launcher = FakeLauncher()
        let scheduler = FakeScheduler()
        let service = make(launcher, scheduler)
        service.configure(.success(spec))
        let first = launcher.last
        var changed = spec
        changed.arguments.append("--x")
        service.configure(.success(changed))
        service.stop()
        XCTAssertEqual(service.state, .stopped)
        service.configure(.success(spec))
        XCTAssertEqual(launcher.launched.count, 1)
        first.exit(0)
        XCTAssertEqual(launcher.launched.count, 2)
        scheduler.advance(30)
        XCTAssertEqual(launcher.launched.count, 2)
    }

    func testMissingReadinessLineTerminatesAndRetries() {
        let launcher = FakeLauncher()
        let scheduler = FakeScheduler()
        let service = make(launcher, scheduler)
        service.configure(.success(spec))
        scheduler.advance(45)
        XCTAssertTrue(launcher.last.terminated)
        launcher.last.exit(15)
        XCTAssertEqual(service.state, .backingOff(attempt: 1, delay: 1, reason: "did not become ready"))
    }

    func testLineSplitterHandlesPartialLines() {
        let splitter = LineSplitter()
        XCTAssertTrue(splitter.feed(Data("hel".utf8)).isEmpty)
        XCTAssertEqual(splitter.feed(Data("lo\nwor".utf8)), ["hello"])
        XCTAssertEqual(splitter.feed(Data("ld\n\n".utf8)), ["world", ""])
    }
}
