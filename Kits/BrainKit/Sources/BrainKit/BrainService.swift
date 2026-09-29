import Combine
import CryptoKit
import Foundation

/// How to run the brain companion. A plain value: the host fills it from its own settings
/// (`BrainSettings.serviceConfiguration`) and chooses where state lives and which port to use.
public struct BrainServiceConfiguration: Equatable, Sendable {
    /// The runtime the companion runs. A change keeps the running process and switches it
    /// between turns (see `BrainService`).
    public var runtime: AgentRuntime
    /// The agent's workspace (`--cwd`), an existing folder.
    public var workingDirectory: String
    /// Private companion state (`--state-dir`): token, conversation ids, permissions. One per
    /// workspace; `stateDirectory(forWorkspace:under:)` derives one.
    public var stateDirectory: String
    /// Loopback port (`--port`), 1024-65535.
    public var port: Int
    /// `node` override; empty finds Node.js on PATH and the common install folders.
    public var nodePath: String
    /// `codex`, `claude` and `mclaude` overrides; empty finds them the same way.
    public var codexPath: String
    public var claudePath: String
    public var mclaudePath: String
    /// Hermes API server (`--runtime-url`); empty lets the companion read `~/.hermes/.env`.
    public var hermesURL: String
    /// Name the voice instructions give the assistant (`--assistant-name`); empty names none.
    public var assistantName: String
    /// MCP servers whose tools the agent gets (`--tool-servers`, a file in the state directory).
    public var toolServers: [BrainToolServer]
    /// Markdown describing the host's world to the agent, appended to the runtime's
    /// instructions after the voice instructions (`--host-context`, a file in the state
    /// directory); empty adds nothing.
    public var hostContext: String

    public init(runtime: AgentRuntime, workingDirectory: String, stateDirectory: String, port: Int,
                nodePath: String = "", codexPath: String = "", claudePath: String = "",
                mclaudePath: String = "", hermesURL: String = "", assistantName: String = "",
                toolServers: [BrainToolServer] = [], hostContext: String = "") {
        self.runtime = runtime
        self.workingDirectory = workingDirectory
        self.stateDirectory = stateDirectory
        self.port = port
        self.nodePath = nodePath
        self.codexPath = codexPath
        self.claudePath = claudePath
        self.mclaudePath = mclaudePath
        self.hermesURL = hermesURL
        self.assistantName = assistantName
        self.toolServers = toolServers
        self.hostContext = hostContext
    }

    /// The files the companion reads `--tool-servers` and `--host-context` from.
    public static let toolServersFileName = "tool-servers.json"
    public static let hostContextFileName = "host-context.md"
    /// The companion's limit on the host context (UTF-16 code units, like JavaScript's length).
    public static let hostContextLimit = 65536

    /// `<base>/<hash of the canonical workspace path>`: the companion refuses a state
    /// directory that belongs to another workspace, so each workspace gets its own.
    public static func stateDirectory(forWorkspace workspace: String, under base: URL) -> URL {
        let canonical = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonical.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent(digest, isDirectory: true)
    }
}

/// Where a running companion answers, and its bearer token.
public struct ServiceEndpoint: Equatable, Sendable {
    public let url: URL
    public let token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }
}

/// Launches and supervises the bundled companion (`node server.mjs`) for one configuration
/// and hands out clients for it.
///
/// The child runs with `BRAINKIT_PARENT_PIPE=1` and the supervisor holds its stdin, so it
/// exits with the host. The first configuration applies at once; later ones apply after
/// `debounce` (0.4 s) without another change, so a settings field being typed into does not
/// restart the companion per keystroke. A configuration that differs only in `runtime` keeps
/// the running process, and the service switches it (`POST /v1/runtime`) once it is between
/// turns; the new flag applies at the next start. The companion keeps each runtime's
/// conversation, so switching back resumes it. Any other change restarts it, after the old
/// process exits. That includes the tool servers and host context: they are written to
/// private files in the state directory and the companion reads them once at start.
@MainActor
public final class BrainService: ObservableObject {
    /// The line the companion prints once it listens.
    public static let readinessMarker = "Brain companion ready at"
    public static let minimumNodeMajorVersion = 22

    /// The supervised process: state, log, restart.
    public let service: ManagedService
    /// Which Node.js runs the companion, or why none can.
    @Published public private(set) var nodeStatus = ""
    /// Last detection of each brain for the current configuration.
    @Published public private(set) var detections: [AgentRuntime: BrainCatalog.Detection] = [:]
    /// The configuration last asked for; it may still be waiting out the debounce.
    public private(set) var configuration: BrainServiceConfiguration?
    /// The configuration the process runs with.
    private var applied: BrainServiceConfiguration?
    private var pendingApply: ScheduledAction?
    private let scheduler: ServiceScheduling
    private let debounce: TimeInterval

    private let locatorProvider: () -> ExecutableLocator
    private let nodeVersion: (String) -> String?
    private let companionDirectory: () -> URL?
    private let baseEnvironment: [String: String]
    private let fileManager = FileManager.default
    private var nodeVersions: [String: Int?] = [:]
    private var lastKey: [String]?
    private var cancellables = Set<AnyCancellable>()
    /// Bumped whenever the runtime to follow or the process changes; a stale attempt stops.
    private var runtimeFollow = 0
    private var runtimeRetry: ScheduledAction?
    /// How long a switch waits before asking again: a turn is running, or the companion
    /// refused because one began.
    nonisolated static let runtimeRetryInterval: TimeInterval = 1
    /// What the service talks to the running companion's runtime through (tests use a fake).
    var makeRuntimeControl: (ServiceEndpoint) -> CompanionRuntimeControl = {
        AgentSessionClient(endpoint: $0.url, token: $0.token)
    }

    /// Every dependency is injectable for tests: the launcher and scheduler behind the
    /// supervisor, tool lookup, `node --version`, the companion folder and the environment
    /// the child inherits.
    public init(
        launcher: ProcessLaunching = FoundationProcessLauncher(),
        scheduler: ServiceScheduling = DispatchServiceScheduler(),
        policy: ManagedService.Policy = ManagedService.Policy(),
        locator: @escaping () -> ExecutableLocator = { .live },
        nodeVersion: @escaping (String) -> String? = { BrainService.runVersion($0) },
        companionDirectory: @escaping () -> URL? = { BrainCompanion.directory },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        debounce: TimeInterval = 0.4
    ) {
        self.scheduler = scheduler
        self.debounce = debounce
        service = ManagedService(
            id: "brain", displayName: "Brain companion", readinessMarker: Self.readinessMarker,
            launcher: launcher, scheduler: scheduler, policy: policy)
        locatorProvider = locator
        self.nodeVersion = nodeVersion
        self.companionDirectory = companionDirectory
        baseEnvironment = environment
        service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // `$state` publishes before the change lands, so the new value is passed on.
        service.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.serviceStateChanged(state) }
        }
        .store(in: &cancellables)
    }

    /// Run the companion as configured, or stop it (`nil`, applied at once).
    public func configure(_ configuration: BrainServiceConfiguration?) {
        self.configuration = configuration
        pendingApply?.cancel()
        pendingApply = nil
        guard let configuration else { return apply(nil) }
        guard applied != nil else { return apply(configuration) }
        pendingApply = scheduler.schedule(after: debounce) { [weak self] in
            self?.pendingApply = nil
            self?.apply(configuration)
        }
    }

    /// Restart the process now, clearing the failure count.
    public func restart() { service.restart() }

    public func stop() { configure(nil) }

    /// Look the brains and Node.js up again (after an install or upgrade); the next start uses
    /// what is found.
    public func refreshDetections() {
        detect(configuration)
        nodeVersions.removeAll()
    }

    /// The running companion's address and token. Nil until this process has reported ready,
    /// so a token left by an earlier run is never paired with a process that is not listening.
    /// The token file must be a private (0600), regular, user-owned file, as the companion
    /// itself requires.
    public func endpoint() -> ServiceEndpoint? {
        guard service.state == .running else { return nil }
        return companionEndpoint()
    }

    /// The applied configuration's address and token, whatever the process state.
    private func companionEndpoint() -> ServiceEndpoint? {
        guard let applied,
              let token = Self.readToken(URL(fileURLWithPath: applied.stateDirectory).appendingPathComponent("token")),
              let url = URL(string: "http://127.0.0.1:\(applied.port)")
        else { return nil }
        return ServiceEndpoint(url: url, token: token)
    }

    /// A client for the running companion; nil until it is ready.
    public func makeClient() -> AgentSessionClient? {
        endpoint().map { AgentSessionClient(endpoint: $0.url, token: $0.token) }
    }

    private func apply(_ configuration: BrainServiceConfiguration?) {
        applied = configuration
        guard let configuration else {
            service.stop()
            lastKey = nil
            return
        }
        detect(configuration)
        switch processSpec(for: configuration) {
        case .success(let built):
            if built.key == lastKey, service.spec != nil {
                service.replaceSpecWithoutRestart(built.spec)
                if service.state == .running { followRuntime() }
            } else {
                // Forced: a changed host file leaves the command line as it was.
                service.configure(.success(built.spec), force: true)
            }
            lastKey = built.key
        case .failure(let reason):
            service.configure(.failure(reason))
            lastKey = nil
        }
    }

    // MARK: Runtime

    private func serviceStateChanged(_ state: ManagedService.State) {
        // Each start runs the spec's `--runtime`, but the configuration may have changed while it
        // started; a stopped process has nothing to switch.
        if state == .running { followRuntime() } else { stopFollowingRuntime() }
    }

    /// Brings the running companion to the applied configuration's runtime: reads its snapshot
    /// and, when it runs another runtime, switches between turns, asking again every
    /// `runtimeRetryInterval` while a turn runs.
    private func followRuntime() {
        stopFollowingRuntime()
        guard let wanted = applied?.runtime, let endpoint = companionEndpoint() else { return }
        attemptRuntime(wanted, control: makeRuntimeControl(endpoint), follow: runtimeFollow)
    }

    private func stopFollowingRuntime() {
        runtimeFollow += 1
        runtimeRetry?.cancel()
        runtimeRetry = nil
    }

    private func attemptRuntime(_ wanted: AgentRuntime, control: CompanionRuntimeControl, follow: Int) {
        Task { [weak self] in
            let settled = await Self.bringRuntime(control, to: wanted)
            guard let self, follow == runtimeFollow, !settled else { return }
            runtimeRetry = scheduler.schedule(after: Self.runtimeRetryInterval) { [weak self] in
                guard let self, follow == runtimeFollow else { return }
                attemptRuntime(wanted, control: control, follow: follow)
            }
        }
    }

    /// One attempt; true when there is nothing more to do: the companion runs `wanted`, or it
    /// failed to start it (the snapshot says why; asking again would only restart it again).
    static func bringRuntime(_ control: CompanionRuntimeControl, to wanted: AgentRuntime) async -> Bool {
        do {
            let snapshot = try await control.refreshSnapshot()
            // A snapshot without a runtime comes from a companion running Codex.
            if (snapshot.runtime ?? AgentRuntime.codex.rawValue) == wanted.rawValue { return true }
            // The companion refuses a switch during a turn and never cuts one off.
            if snapshot.isWorking { return false }
            _ = try await control.setRuntime(wanted)
            return true
        } catch AgentSessionError.server(let status, _) {
            // 409: a turn began in the meantime.
            return status != 409
        } catch {
            // Unreachable for now; a process that goes away stops the follow.
            return false
        }
    }

    private func detect(_ configuration: BrainServiceConfiguration?) {
        let locator = locatorProvider()
        var result: [AgentRuntime: BrainCatalog.Detection] = [:]
        for runtime in AgentRuntime.allCases {
            let override: String
            switch runtime {
            case .codex: override = configuration?.codexPath ?? ""
            case .claude: override = configuration?.claudePath ?? ""
            case .mclaude: override = configuration?.mclaudePath ?? ""
            case .hermes: override = ""
            }
            result[runtime] = BrainCatalog.detect(runtime, locator: locator, override: override)
        }
        detections = result
    }

    /// Reads a companion token like the companion does: no symlink, a regular file owned by
    /// this user and readable by no one else, 64 hex digits.
    static func readToken(_ url: URL) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0,
              let data = try? handle.read(upToCount: 256)
        else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count == 64, token.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        return token
    }

    // MARK: Spec

    struct BuiltSpec {
        let spec: ProcessSpec
        /// Everything but `--runtime`: a change here needs a restart.
        let key: [String]
    }

    func processSpec(for configuration: BrainServiceConfiguration) -> Result<BuiltSpec, ServiceUnavailable> {
        let workspace = configuration.workingDirectory
        var isDirectory: ObjCBool = false
        guard !workspace.isEmpty, fileManager.fileExists(atPath: workspace, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .failure(ServiceUnavailable(reason: "Choose a workspace folder for the agent."))
        }
        let stateDirectory = configuration.stateDirectory
        guard stateDirectory.hasPrefix("/") else {
            return .failure(ServiceUnavailable(reason: "The brain's state directory must be an absolute path."))
        }
        guard (1024...65535).contains(configuration.port) else {
            return .failure(ServiceUnavailable(reason: "The brain's port must be between 1024 and 65535."))
        }
        guard let server = companionDirectory()?.appendingPathComponent("server.mjs"),
              fileManager.fileExists(atPath: server.path)
        else {
            return .failure(ServiceUnavailable(reason: "The brain companion is missing from this build."))
        }
        let node: String
        switch nodeExecutable(override: configuration.nodePath) {
        case .success(let path): node = path
        case .failure(let reason): return .failure(reason)
        }
        let name = configuration.assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        // The companion's own rule (server.mjs): one line of 1-64 UTF-16 code units.
        guard name.utf16.count <= 64, !name.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else {
            return .failure(ServiceUnavailable(reason: "The assistant name must be one line of at most 64 characters."))
        }
        for server in configuration.toolServers {
            guard BrainToolServer.isValidName(server.name) else {
                return .failure(ServiceUnavailable(reason: "The tool server name \"\(server.name)\" must be letters, digits, _ or - (at most 64)."))
            }
            guard !server.command.isEmpty, !server.command.contains(where: \.isNewline) else {
                return .failure(ServiceUnavailable(reason: "The tool server \(server.name) needs a command."))
            }
        }
        guard Set(configuration.toolServers.map(\.name)).count == configuration.toolServers.count else {
            return .failure(ServiceUnavailable(reason: "Each tool server needs its own name."))
        }
        let hostContext = configuration.hostContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hostContext.utf16.count <= BrainServiceConfiguration.hostContextLimit else {
            return .failure(ServiceUnavailable(reason: "The brain's host context is too long."))
        }
        try? fileManager.createDirectory(
            atPath: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // An existing directory keeps its mode on create; the token and conversation state are private.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory)
        let state = URL(fileURLWithPath: stateDirectory, isDirectory: true)
        let toolServersFile = state.appendingPathComponent(BrainServiceConfiguration.toolServersFileName)
        let hostContextFile = state.appendingPathComponent(BrainServiceConfiguration.hostContextFileName)
        var toolServersJSON = ""
        if configuration.toolServers.isEmpty {
            try? fileManager.removeItem(at: toolServersFile)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(configuration.toolServers),
                  Self.writePrivate(data, to: toolServersFile)
            else { return .failure(ServiceUnavailable(reason: "The brain's tool servers could not be saved in \(stateDirectory).")) }
            toolServersJSON = String(decoding: data, as: UTF8.self)
        }
        if hostContext.isEmpty {
            try? fileManager.removeItem(at: hostContextFile)
        } else if !Self.writePrivate(Data(hostContext.utf8), to: hostContextFile) {
            return .failure(ServiceUnavailable(reason: "The brain's host context could not be saved in \(stateDirectory)."))
        }
        var arguments = [
            server.path, "--cwd", workspace, "--state-dir", stateDirectory, "--port", String(configuration.port),
        ]
        if let codex = detections[.codex]?.executable { arguments += ["--codex", codex] }
        if let claude = detections[.claude]?.executable { arguments += ["--claude", claude] }
        if let mclaude = detections[.mclaude]?.executable { arguments += ["--mclaude", mclaude] }
        let hermesURL = configuration.hermesURL.trimmingCharacters(in: .whitespaces)
        if !hermesURL.isEmpty { arguments += ["--runtime-url", hermesURL] }
        if !name.isEmpty { arguments += ["--assistant-name", name] }
        if !toolServersJSON.isEmpty { arguments += ["--tool-servers", toolServersFile.path] }
        if !hostContext.isEmpty { arguments += ["--host-context", hostContextFile.path] }
        // The files' contents are part of the key: the companion reads them only at start.
        let key = [node] + arguments + [toolServersJSON, hostContext]
        arguments += ["--runtime", configuration.runtime.rawValue]
        let toolDirectories = detections.values.compactMap { $0.executable }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        var environment = baseEnvironment
        environment["PATH"] = locatorProvider().childPath(
            prepending: [URL(fileURLWithPath: node).deletingLastPathComponent().path] + toolDirectories)
        environment["HOME"] = locatorProvider().home
        environment["BRAINKIT_PARENT_PIPE"] = "1"
        let spec = ProcessSpec(executable: node, arguments: arguments, environment: environment,
                               currentDirectory: workspace)
        return .success(BuiltSpec(spec: spec, key: key))
    }

    /// Writes `data` as a private (0600) file, replacing any file or link there atomically:
    /// the companion refuses a host file anyone else can read or that is a symlink.
    static func writePrivate(_ data: Data, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlink(temporary.path)
            return false
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    /// Node.js 22 or later, from the override or the usual places; sets `nodeStatus`.
    public func nodeExecutable(override: String) -> Result<String, ServiceUnavailable> {
        guard let node = locatorProvider().locate("node", override: override) else {
            let reason = override.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Node.js \(Self.minimumNodeMajorVersion) or later is needed. Install it from nodejs.org or with Homebrew (brew install node)."
                : "The Node.js path \(override) is not an executable."
            nodeStatus = reason
            return .failure(ServiceUnavailable(reason: reason))
        }
        let major: Int?
        if let cached = nodeVersions[node] {
            major = cached
        } else {
            major = nodeVersion(node).flatMap(ExecutableLocator.nodeMajorVersion)
            nodeVersions[node] = major
        }
        guard let major, major >= Self.minimumNodeMajorVersion else {
            let found = major.map { "Node.js \($0)" } ?? "not a working Node.js"
            let reason = "\(node) is \(found); version \(Self.minimumNodeMajorVersion) or later is needed."
            nodeStatus = reason
            return .failure(ServiceUnavailable(reason: reason))
        }
        nodeStatus = "Node.js \(major) · \(node)"
        return .success(node)
    }

    /// `<executable> --version` output, or nil when it cannot run or does not finish within
    /// `timeout` seconds (it runs on the caller's thread; results are cached per path).
    public nonisolated static func runVersion(_ executable: String, timeout: TimeInterval = 2) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

/// What `BrainService` needs of a running companion to switch its runtime; `AgentSessionClient`
/// provides it.
@MainActor
protocol CompanionRuntimeControl: AnyObject {
    func refreshSnapshot() async throws -> AgentSessionSnapshot
    func setRuntime(_ runtime: AgentRuntime) async throws -> AgentSessionSnapshot
}

extension AgentSessionClient: CompanionRuntimeControl {}
