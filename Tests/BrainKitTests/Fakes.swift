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
