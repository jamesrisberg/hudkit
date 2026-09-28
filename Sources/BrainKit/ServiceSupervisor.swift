import Combine
import Foundation

/// A child process a host starts: executable, arguments and environment.
public struct ProcessSpec: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String] = [:],
                currentDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

/// The supervisor drives processes, launchers and schedulers on the main actor only.
@MainActor
public protocol ServiceProcess: AnyObject {
    var processIdentifier: Int32 { get }
    func terminate()
}

/// Starts processes. Callbacks are delivered on the main actor, output one line at a time.
@MainActor
public protocol ProcessLaunching {
    func launch(
        _ spec: ProcessSpec, onOutput: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> ServiceProcess
}

public protocol ScheduledAction { func cancel() }

/// Delayed work. Tests advance a fake clock instead of waiting.
@MainActor
public protocol ServiceScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction
}

/// Why a service cannot run as configured (missing tool, no workspace).
public struct ServiceUnavailable: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Keeps one child process running: waits for its readiness line, restarts it with
/// exponential backoff when it exits, and gives up after repeated failures until asked
/// again. Late callbacks from an older process are ignored by generation.
@MainActor
public final class ManagedService: ObservableObject, Identifiable {
    public enum State: Equatable, Sendable {
        case stopped
        /// Cannot be started as configured (missing tool, not installed, no workspace).
        case unavailable(String)
        case starting
        case running
        case backingOff(attempt: Int, delay: TimeInterval, reason: String)
        case failed(String)

        public var isRunning: Bool { self == .running }
        public var summary: String {
            switch self {
            case .stopped: return "Stopped"
            case .unavailable(let reason): return reason
            case .starting: return "Starting…"
            case .running: return "Running"
            case .backingOff(let attempt, let delay, let reason):
                return "Restarting in \(Int(delay.rounded()))s (attempt \(attempt)) · \(reason)"
            case .failed(let reason): return "Stopped after repeated failures · \(reason)"
            }
        }
    }

    public struct Policy: Equatable, Sendable {
        public var initialDelay: TimeInterval = 1
        public var maximumDelay: TimeInterval = 30
        /// Consecutive failed starts before giving up.
        public var maximumAttempts = 6
        /// Time without a readiness line before a start counts as failed.
        public var readinessTimeout: TimeInterval = 45
        /// Running this long resets the failure count.
        public var stableAfter: TimeInterval = 60

        public init() {}
    }

    public let id: String
    public let displayName: String
    @Published public private(set) var state: State = .stopped
    @Published public private(set) var log: [String] = []
    /// Called every time the service reports ready.
    public var onReady: (() -> Void)?

    private let readinessMarker: String
    private let launcher: ProcessLaunching
    private let scheduler: ServiceScheduling
    private let policy: Policy
    public private(set) var spec: ProcessSpec?
    private var process: ServiceProcess?
    public var processIdentifier: Int32? { process?.processIdentifier }
    private var generation = 0
    public private(set) var failures = 0
    private var timers: [ScheduledAction] = []
    private var lastLine = ""
    private static let logLimit = 200

    public init(
        id: String, displayName: String, readinessMarker: String, launcher: ProcessLaunching,
        scheduler: ServiceScheduling, policy: Policy = Policy()
    ) {
        self.id = id
        self.displayName = displayName
        self.readinessMarker = readinessMarker
        self.launcher = launcher
        self.scheduler = scheduler
        self.policy = policy
    }

    /// Run `spec`, or report why the service cannot run. Restarts only when the spec changed
    /// or the service is not already up; `force` restarts regardless and clears failures.
    public func configure(_ spec: Result<ProcessSpec, ServiceUnavailable>, force: Bool = false) {
        switch spec {
        case .failure(let unavailable):
            stopProcess()
            self.spec = nil
            failures = 0
            state = .unavailable(unavailable.reason)
        case .success(let spec):
            let changed = spec != self.spec
            self.spec = spec
            if changed || force {
                stopProcess()
                failures = 0
                launch()
            } else if case .stopped = state {
                launch()
            } else if case .unavailable = state {
                launch()
            }
        }
    }

    /// Remember a new spec for the next start without interrupting the running process.
    public func replaceSpecWithoutRestart(_ spec: ProcessSpec) {
        guard self.spec != nil else { return configure(.success(spec)) }
        self.spec = spec
    }

    public func restart() {
        guard let spec else { return }
        configure(.success(spec), force: true)
    }

    public func stop() {
        stopProcess()
        spec = nil
        failures = 0
        state = .stopped
    }

    private func launch() {
        guard let spec else { return }
        cancelTimers()
        generation += 1
        let current = generation
        lastLine = ""
        state = .starting
        append("$ \(([spec.executable] + spec.arguments).joined(separator: " "))")
        do {
            process = try launcher.launch(
                spec,
                onOutput: { [weak self] line in
                    guard let self, self.generation == current else { return }
                    self.received(line)
                },
                onExit: { [weak self] code in
                    guard let self, self.generation == current else { return }
                    self.exited(code)
                })
        } catch {
            process = nil
            failed("Could not start: \(error.localizedDescription)")
            return
        }
        timers.append(
            scheduler.schedule(after: policy.readinessTimeout) { [weak self] in
                guard let self, self.generation == current, self.state == .starting else { return }
                self.append("No ready signal after \(Int(self.policy.readinessTimeout))s; restarting.")
                // Wait for the exit so the port is free before the next attempt.
                self.lastLine = "did not become ready"
                self.process?.terminate()
            })
    }

    private func received(_ line: String) {
        append(line)
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastLine = line }
        guard state == .starting, line.contains(readinessMarker) else { return }
        state = .running
        let current = generation
        timers.append(
            scheduler.schedule(after: policy.stableAfter) { [weak self] in
                guard let self, self.generation == current, self.state == .running else { return }
                self.failures = 0
            })
        onReady?()
    }

    private func exited(_ code: Int32) {
        process = nil
        append("Exited with status \(code).")
        let reason = lastLine.isEmpty ? "exited with status \(code)" : lastLine
        failed(reason)
    }

    private func failed(_ reason: String) {
        cancelTimers()
        failures += 1
        guard failures < policy.maximumAttempts else {
            state = .failed(reason)
            return
        }
        let delay = min(policy.maximumDelay, policy.initialDelay * pow(2, Double(failures - 1)))
        state = .backingOff(attempt: failures, delay: delay, reason: reason)
        let current = generation
        timers.append(
            scheduler.schedule(after: delay) { [weak self] in
                guard let self, self.generation == current else { return }
                if case .backingOff = self.state { self.launch() }
            })
    }

    private func stopProcess() {
        generation += 1
        cancelTimers()
        process?.terminate()
        process = nil
        lastLine = ""
    }

    private func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}

// MARK: - Live implementations

/// Launches with `Process`, stdout and stderr merged into one line stream.
public final class FoundationProcessLauncher: ProcessLaunching {
    private final class Running: ServiceProcess {
        let process: Process
        /// Held open for the child's lifetime. A child that watches its stdin (the companion
        /// with `BRAINKIT_PARENT_PIPE=1`) exits when it closes, so it never outlives the host,
        /// even after a crash.
        let stdin: Pipe

        init(process: Process, stdin: Pipe) {
            self.process = process
            self.stdin = stdin
        }

        var processIdentifier: Int32 { process.processIdentifier }

        func terminate() {
            guard process.isRunning else { return }
            process.terminate()
            let process = self.process
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    public nonisolated init() {}

    public func launch(
        _ spec: ProcessSpec, onOutput: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> ServiceProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = spec.environment.isEmpty ? nil : spec.environment
        if let directory = spec.currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        let splitter = LineSplitter()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in splitter.feed(data) { Task { @MainActor in onOutput(line) } }
        }
        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            Task { @MainActor in onExit(status) }
        }
        try process.run()
        return Running(process: process, stdin: input)
    }
}

/// Splits a byte stream into lines; thread-confined to the pipe's handler queue.
public final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    public init() {}

    public func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > 16_384 {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        return lines
    }
}

/// Schedules on the main queue.
public struct DispatchServiceScheduler: ServiceScheduling {
    private final class Item: ScheduledAction {
        let work: DispatchWorkItem
        init(_ work: DispatchWorkItem) { self.work = work }
        func cancel() { work.cancel() }
    }

    public nonisolated init() {}

    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return Item(work)
    }
}
