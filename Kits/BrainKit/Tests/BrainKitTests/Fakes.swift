import Foundation
@testable import BrainKit

@MainActor
final class FakeProcess: ServiceProcess {
    let processIdentifier: Int32
    var terminated = false
    let onExit: @MainActor (Int32) -> Void
    let onOutput: @MainActor (String) -> Void

    init(pid: Int32, onOutput: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32) -> Void) {
        processIdentifier = pid
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func terminate() { terminated = true }
    func say(_ line: String) { onOutput(line) }
    func exit(_ code: Int32) { onExit(code) }
}

@MainActor
final class FakeLauncher: ProcessLaunching {
    var launched: [FakeProcess] = []
    var specs: [ProcessSpec] = []
    var failNext = false
    struct LaunchError: LocalizedError { var errorDescription: String? { "no such file" } }

    func launch(
        _ spec: ProcessSpec, onOutput: @escaping @Sendable @MainActor (String) -> Void,
        onExit: @escaping @Sendable @MainActor (Int32) -> Void
    ) throws -> ServiceProcess {
        specs.append(spec)
        if failNext {
            failNext = false
            throw LaunchError()
        }
        let process = FakeProcess(pid: Int32(100 + launched.count), onOutput: onOutput, onExit: onExit)
        launched.append(process)
        return process
    }

    var last: FakeProcess { launched.last! }
}

@MainActor
final class FakeScheduler: ServiceScheduling {
    final class Item: ScheduledAction {
        let due: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(due: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.due = due
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    var now: TimeInterval = 0
    var items: [Item] = []

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let item = Item(due: now + delay, action: action)
        items.append(item)
        return item
    }

    func advance(_ seconds: TimeInterval) {
        let target = now + seconds
        while let next = items.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = next.due
            next.cancelled = true
            next.action()
        }
        now = target
    }
}

/// A temporary folder removed by the caller.
func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("brainkit-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// A running companion as `BrainService` sees it when it follows the configured runtime:
/// `status` and `runtime` answer the snapshot read; `switchError` fails the next switch.
@MainActor
final class FakeRuntimeControl: CompanionRuntimeControl {
    var runtime = "codex"
    var status = "idle"
    var reads = 0
    var switches: [AgentRuntime] = []
    var switchError: Error?
    var endpoints: [ServiceEndpoint] = []

    func refreshSnapshot() async throws -> AgentSessionSnapshot {
        reads += 1
        return snapshot()
    }

    func setRuntime(_ runtime: AgentRuntime) async throws -> AgentSessionSnapshot {
        switches.append(runtime)
        if let error = switchError {
            switchError = nil
            throw error
        }
        self.runtime = runtime.rawValue
        return snapshot()
    }

    private func snapshot() -> AgentSessionSnapshot {
        let json = #"{"status":"\#(status)","output":"","progress":"","approvals":[],"revision":1,"instanceId":"fake","runtime":"\#(runtime)"}"#
        return try! JSONDecoder().decode(AgentSessionSnapshot.self, from: Data(json.utf8))
    }
}

/// Lets tasks started on the main actor run to their next suspension.
@MainActor
func drainTasks() async {
    for _ in 0..<50 { await Task.yield() }
}
