import Combine
import CryptoKit
import Foundation

/// How to run the brain companion. A plain value: the host fills it from its own settings
/// (`BrainSettings.serviceConfiguration`) and chooses where state lives and which port to use.
public struct BrainServiceConfiguration: Equatable, Sendable {
    /// The runtime the companion starts with; later switches go over HTTP (`AgentSessionClient.setRuntime`).
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
    /// `codex` and `claude` overrides; empty finds them the same way.
    public var codexPath: String
    public var claudePath: String
    /// Hermes API server (`--runtime-url`); empty lets the companion read `~/.hermes/.env`.
    public var hermesURL: String
    /// Name the voice instructions give the assistant (`--assistant-name`); empty names none.
    public var assistantName: String

    public init(runtime: AgentRuntime, workingDirectory: String, stateDirectory: String, port: Int,
                nodePath: String = "", codexPath: String = "", claudePath: String = "",
                hermesURL: String = "", assistantName: String = "") {
        self.runtime = runtime
        self.workingDirectory = workingDirectory
        self.stateDirectory = stateDirectory
        self.port = port
        self.nodePath = nodePath
        self.codexPath = codexPath
        self.claudePath = claudePath
        self.hermesURL = hermesURL
        self.assistantName = assistantName
    }

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
/// exits with the host. A configuration that differs only in `runtime` keeps the running
/// process (the host switches with `AgentSessionClient.setRuntime`; the new flag applies at
/// the next start); any other change restarts it.
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
    public private(set) var configuration: BrainServiceConfiguration?

    private let locatorProvider: () -> ExecutableLocator
    private let nodeVersion: (String) -> String?
    private let companionDirectory: () -> URL?
    private let baseEnvironment: [String: String]
    private let fileManager = FileManager.default
    private var nodeVersions: [String: Int?] = [:]
    private var lastKey: [String]?
    private var cancellables = Set<AnyCancellable>()

    /// Every dependency is injectable for tests: the launcher and scheduler behind the
    /// supervisor, tool lookup, `node --version`, the companion folder and the environment
    /// the child inherits.
    public init(
        launcher: ProcessLaunching = FoundationProcessLauncher(),
        scheduler: ServiceScheduling = DispatchServiceScheduler(),
        policy: ManagedService.Policy = ManagedService.Policy(),
        locator: @escaping () -> ExecutableLocator = { .live },
        nodeVersion: @escaping (String) -> String? = BrainService.runVersion,
        companionDirectory: @escaping () -> URL? = { BrainCompanion.directory },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        service = ManagedService(
            id: "brain", displayName: "Brain companion", readinessMarker: Self.readinessMarker,
            launcher: launcher, scheduler: scheduler, policy: policy)
        locatorProvider = locator
        self.nodeVersion = nodeVersion
        self.companionDirectory = companionDirectory
        baseEnvironment = environment
        service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Run the companion as configured, or stop it (`nil`).
    public func configure(_ configuration: BrainServiceConfiguration?) {
        self.configuration = configuration
        guard let configuration else {
            service.stop()
            lastKey = nil
            return
        }
        refreshDetections()
        switch processSpec(for: configuration) {
        case .success(let built):
            if built.key == lastKey, service.spec != nil {
                service.replaceSpecWithoutRestart(built.spec)
            } else {
                service.configure(.success(built.spec))
            }
            lastKey = built.key
        case .failure(let reason):
            service.configure(.failure(reason))
            lastKey = nil
        }
    }

    /// Restart the process now, clearing the failure count.
    public func restart() { service.restart() }

    public func stop() { configure(nil) }

    /// Look the brains up again (after an install, or a changed override).
    public func refreshDetections() {
        let locator = locatorProvider()
        var result: [AgentRuntime: BrainCatalog.Detection] = [:]
        for runtime in AgentRuntime.allCases {
            result[runtime] = BrainCatalog.detect(runtime, locator: locator, override: override(for: runtime))
        }
        detections = result
        nodeVersions.removeAll()
    }

    /// The companion's address and token, once it has written its token file.
    public func endpoint() -> ServiceEndpoint? {
        guard let configuration,
              let text = try? String(
                contentsOf: URL(fileURLWithPath: configuration.stateDirectory).appendingPathComponent("token"),
                encoding: .utf8),
              let url = URL(string: "http://127.0.0.1:\(configuration.port)")
        else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("\n") else { return nil }
        return ServiceEndpoint(url: url, token: token)
    }

    /// A client for the running companion; nil until its token exists.
    public func makeClient() -> AgentSessionClient? {
        endpoint().map { AgentSessionClient(endpoint: $0.url, token: $0.token) }
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
        try? fileManager.createDirectory(
            atPath: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var arguments = [
            server.path, "--cwd", workspace, "--state-dir", stateDirectory, "--port", String(configuration.port),
        ]
        if let codex = detections[.codex]?.executable { arguments += ["--codex", codex] }
        if let claude = detections[.claude]?.executable { arguments += ["--claude", claude] }
        let hermesURL = configuration.hermesURL.trimmingCharacters(in: .whitespaces)
        if !hermesURL.isEmpty { arguments += ["--runtime-url", hermesURL] }
        let name = configuration.assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { arguments += ["--assistant-name", name] }
        let key = [node] + arguments
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

    private func override(for runtime: AgentRuntime) -> String {
        switch runtime {
        case .codex: return configuration?.codexPath ?? ""
        case .claude: return configuration?.claudePath ?? ""
        case .hermes: return ""
        }
    }

    /// `<executable> --version` output, or nil when it cannot run.
    public nonisolated static func runVersion(_ executable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
