import XCTest
@testable import BrainKit

@MainActor
final class BrainServiceTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var companion: URL!
    private var launcher: FakeLauncher!
    private var scheduler: FakeScheduler!
    private var versionCalls: [String] = []
    private var nodeOutput = "v22.3.0\n"
    private var files: Set<String> = ["/opt/homebrew/bin/node", "/opt/homebrew/bin/codex", "/Users/test/.local/bin/claude"]
    private var control: FakeRuntimeControl!

    override func setUpWithError() throws {
        root = try temporaryDirectory("service")
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        companion = root.appendingPathComponent("Companion", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: true)
        try Data().write(to: companion.appendingPathComponent("server.mjs"))
        launcher = FakeLauncher()
        scheduler = FakeScheduler()
        versionCalls = []
        control = FakeRuntimeControl()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(companionDirectory: URL? = nil) -> BrainService {
        let directory = companionDirectory ?? companion
        let service = BrainService(
            launcher: launcher, scheduler: scheduler,
            locator: { [unowned self] in
                ExecutableLocator(path: "/usr/bin:/bin", home: "/Users/test",
                                  isExecutable: { [files] in files.contains($0) }, contentsOfDirectory: { _ in [] })
            },
            nodeVersion: { [unowned self] node in
                versionCalls.append(node)
                return nodeOutput
            },
            companionDirectory: { directory },
            environment: ["PATH": "/usr/bin", "LANG": "en_US.UTF-8"])
        service.makeRuntimeControl = { [unowned self] endpoint in
            control.endpoints.append(endpoint)
            return control
        }
        return service
    }

    private func configuration(_ runtime: AgentRuntime = .codex) -> BrainServiceConfiguration {
        BrainServiceConfiguration(runtime: runtime, workingDirectory: workspace.path,
                                  stateDirectory: root.appendingPathComponent("state").path, port: 8791)
    }

    func testRunsTheBundledServerWithNodeAndTheParentPipe() throws {
        let service = make()
        service.configure(configuration())
        XCTAssertEqual(service.service.state, .starting)
        let spec = try XCTUnwrap(launcher.specs.last)
        let state = root.appendingPathComponent("state").path
        XCTAssertEqual(spec.executable, "/opt/homebrew/bin/node")
        XCTAssertEqual(spec.arguments, [
            companion.appendingPathComponent("server.mjs").path, "--cwd", workspace.path, "--state-dir", state,
            "--port", "8791", "--codex", "/opt/homebrew/bin/codex", "--claude", "/Users/test/.local/bin/claude",
            "--runtime", "codex",
        ])
        XCTAssertEqual(spec.currentDirectory, workspace.path)
        XCTAssertEqual(spec.environment["BRAINKIT_PARENT_PIPE"], "1")
        XCTAssertEqual(spec.environment["HOME"], "/Users/test")
        XCTAssertEqual(spec.environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(spec.environment["PATH"]?.split(separator: ":").first, "/opt/homebrew/bin")
        XCTAssertTrue(spec.environment["PATH"]?.contains("/Users/test/.local/bin") == true)
        XCTAssertEqual(service.nodeStatus, "Node.js 22 · /opt/homebrew/bin/node")
        let mode = try FileManager.default.attributesOfItem(atPath: state)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testReadinessUsesTheCompanionsReadyLine() {
        let service = make()
        service.configure(configuration())
        launcher.last.say("Brain companion ready at http://127.0.0.1:8791")
        XCTAssertEqual(service.service.state, .running)
    }

    func testOptionsBecomeFlags() throws {
        var config = configuration(.hermes)
        config.hermesURL = " http://127.0.0.1:8642 "
        config.assistantName = "Jarvis"
        config.claudePath = "/custom/claude"
        files.insert("/custom/claude")
        let service = make()
        service.configure(config)
        let arguments = try XCTUnwrap(launcher.specs.last?.arguments)
        XCTAssertEqual(Array(arguments.suffix(10)), [
            "--codex", "/opt/homebrew/bin/codex", "--claude", "/custom/claude",
            "--runtime-url", "http://127.0.0.1:8642", "--assistant-name", "Jarvis", "--runtime", "hermes",
        ])
    }

    func testMclaudeIsPassedWhenFoundOrOverridden() throws {
        files.insert("/Users/test/.local/bin/mclaude")
        let service = make()
        service.configure(configuration(.mclaude))
        let arguments = try XCTUnwrap(launcher.specs.last?.arguments)
        XCTAssertEqual(Array(arguments.suffix(4)), ["--mclaude", "/Users/test/.local/bin/mclaude", "--runtime", "mclaude"])
        XCTAssertEqual(service.detections[.mclaude]?.executable, "/Users/test/.local/bin/mclaude")
        var custom = configuration(.mclaude)
        custom.mclaudePath = "/custom/mclaude"
        files.insert("/custom/mclaude")
        let other = make()
        other.configure(custom)
        XCTAssertEqual(Array(try XCTUnwrap(launcher.specs.last?.arguments).suffix(4)),
                       ["--mclaude", "/custom/mclaude", "--runtime", "mclaude"])
    }

    func testRuntimeOnlyChangeKeepsTheProcessAndOtherChangesRestart() throws {
        let service = make()
        service.configure(configuration(.codex))
        try writeToken(String(repeating: "f", count: 64), to: root.appendingPathComponent("state/token"))
        launcher.last.say("Brain companion ready at")
        service.configure(configuration(.claude))
        scheduler.advance(0.4)
        XCTAssertEqual(launcher.launched.count, 1)
        XCTAssertEqual(service.service.state, .running)
        // The next start uses the new runtime.
        XCTAssertEqual(service.service.spec?.arguments.suffix(2), ["--runtime", "claude"])
        var moved = configuration(.claude)
        moved.port = 8792
        service.configure(moved)
        scheduler.advance(0.4)
        XCTAssertTrue(launcher.launched[0].terminated)
        launcher.launched[0].exit(0)
        XCTAssertEqual(launcher.launched.count, 2)
    }

    // MARK: Runtime switches

    /// A service whose companion (runtime `running`) is up with a token, so it can be reached.
    private func runningCompanion(_ runtime: AgentRuntime = .codex) async throws -> BrainService {
        let service = make()
        service.configure(configuration(runtime))
        try writeToken(String(repeating: "f", count: 64), to: root.appendingPathComponent("state/token"))
        control.runtime = runtime.rawValue
        launcher.last.say("Brain companion ready at")
        await drainTasks()
        return service
    }

    func testARuntimeOnlyChangeReachesTheRunningCompanion() async throws {
        let service = try await runningCompanion(.codex)
        // Ready: the companion already runs the configured runtime, so nothing is switched.
        XCTAssertEqual(control.reads, 1)
        XCTAssertEqual(control.switches, [])
        XCTAssertEqual(control.endpoints.last, ServiceEndpoint(url: URL(string: "http://127.0.0.1:8791")!,
                                                               token: String(repeating: "f", count: 64)))
        service.configure(configuration(.mclaude))
        await drainTasks()
        XCTAssertEqual(control.switches, [], "not before the debounce")
        scheduler.advance(0.4)
        await drainTasks()
        XCTAssertEqual(control.switches, [.mclaude])
        XCTAssertEqual(launcher.launched.count, 1)
        XCTAssertFalse(launcher.last.terminated)
        // Nothing more is asked once it runs the configured runtime.
        scheduler.advance(10)
        await drainTasks()
        XCTAssertEqual(control.switches, [.mclaude])
    }

    func testTheSwitchWaitsForTheTurnToEnd() async throws {
        let service = try await runningCompanion(.codex)
        control.status = "running"
        service.configure(configuration(.claude))
        scheduler.advance(0.4)
        await drainTasks()
        XCTAssertEqual(control.switches, [])
        control.status = "approval"
        scheduler.advance(BrainService.runtimeRetryInterval)
        await drainTasks()
        XCTAssertEqual(control.switches, [])
        control.status = "idle"
        scheduler.advance(BrainService.runtimeRetryInterval)
        await drainTasks()
        XCTAssertEqual(control.switches, [.claude])
    }

    func testARefusedSwitchIsAskedAgainAndAFailedStartIsNot() async throws {
        let service = try await runningCompanion(.codex)
        // A turn began between the read and the switch.
        control.switchError = AgentSessionError.server(409, "Finish or interrupt the active turn before switching runtime")
        service.configure(configuration(.claude))
        scheduler.advance(0.4)
        await drainTasks()
        XCTAssertEqual(control.switches, [.claude])
        scheduler.advance(BrainService.runtimeRetryInterval)
        await drainTasks()
        XCTAssertEqual(control.switches, [.claude, .claude])
        XCTAssertEqual(control.runtime, "claude")

        // The runtime does not start: the companion reports that itself; the switch is not repeated.
        control.switchError = AgentSessionError.server(503, "Claude Code is not installed")
        control.runtime = "claude"
        service.configure(configuration(.hermes))
        scheduler.advance(0.4)
        await drainTasks()
        scheduler.advance(10)
        await drainTasks()
        XCTAssertEqual(control.switches, [.claude, .claude, .hermes])
    }

    func testAChangeDuringStartIsAppliedOnceReady() async throws {
        let service = make()
        service.configure(configuration(.codex))
        try writeToken(String(repeating: "f", count: 64), to: root.appendingPathComponent("state/token"))
        // Still starting with --runtime codex when the change lands.
        service.configure(configuration(.claude))
        scheduler.advance(0.4)
        await drainTasks()
        XCTAssertEqual(launcher.launched.count, 1)
        XCTAssertEqual(control.reads, 0)
        launcher.last.say("Brain companion ready at")
        await drainTasks()
        XCTAssertEqual(control.switches, [.claude])
    }

    func testARestartOrStopDropsAPendingSwitch() async throws {
        let service = try await runningCompanion(.codex)
        control.status = "running"
        service.configure(configuration(.claude))
        scheduler.advance(0.4)
        await drainTasks()
        // Another change restarts the companion, which starts on the new runtime itself.
        var moved = configuration(.claude)
        moved.port = 8792
        service.configure(moved)
        scheduler.advance(0.4)
        control.status = "idle"
        scheduler.advance(10)
        await drainTasks()
        XCTAssertEqual(control.switches, [])
        XCTAssertEqual(Array(try XCTUnwrap(launcher.specs.last?.arguments).suffix(2)), ["--runtime", "claude"])

        let stopped = try await runningCompanion(.codex)
        control.status = "running"
        stopped.configure(configuration(.claude))
        scheduler.advance(0.4)
        await drainTasks()
        stopped.stop()
        control.status = "idle"
        scheduler.advance(10)
        await drainTasks()
        XCTAssertEqual(control.switches, [])
    }

    func testACompanionSwitchedElsewhereIsBroughtBackToTheConfiguredRuntime() async throws {
        let service = try await runningCompanion(.claude)
        // Another client of the companion switched it; the next configuration puts it back.
        control.runtime = "codex"
        service.configure(configuration(.claude))
        scheduler.advance(0.4)
        await drainTasks()
        XCTAssertEqual(control.switches, [.claude])
    }

    func testToolServersAndHostContextArePrivateFilesAndFlags() throws {
        var config = configuration(.claude)
        config.toolServers = [
            BrainToolServer(name: "machud", command: "/Apps/MacHUD.app/Contents/Helpers/machud-mcp",
                            environment: ["MACHUD_SOCKET": "/tmp/machud.sock"]),
            BrainToolServer(name: "notes", command: "notes", arguments: ["mcp"], requireApproval: true),
        ]
        config.hostContext = "\n# MacHUD\nYou drive MacHUD.\n"
        let service = make()
        service.configure(config)
        let state = root.appendingPathComponent("state")
        let servers = state.appendingPathComponent("tool-servers.json")
        let context = state.appendingPathComponent("host-context.md")
        XCTAssertEqual(Array(try XCTUnwrap(launcher.specs.last?.arguments).suffix(6)), [
            "--tool-servers", servers.path, "--host-context", context.path, "--runtime", "claude",
        ])
        for file in [servers, context] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, file.lastPathComponent)
        }
        XCTAssertEqual(try String(contentsOf: context, encoding: .utf8), "# MacHUD\nYou drive MacHUD.")
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: servers)) as? [[String: Any]]
        XCTAssertEqual(written?.count, 2)
        XCTAssertEqual(written?[0]["name"] as? String, "machud")
        XCTAssertEqual(written?[0]["command"] as? String, "/Apps/MacHUD.app/Contents/Helpers/machud-mcp")
        XCTAssertEqual(written?[0]["arguments"] as? [String], [])
        XCTAssertEqual(written?[0]["environment"] as? [String: String], ["MACHUD_SOCKET": "/tmp/machud.sock"])
        XCTAssertEqual(written?[0]["requireApproval"] as? Bool, false)
        XCTAssertEqual(written?[1]["requireApproval"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode([BrainToolServer].self, from: Data(contentsOf: servers)), config.toolServers)

        // A changed file restarts the companion (debounced), which reads it again.
        launcher.last.say("Brain companion ready at")
        config.hostContext = "# MacHUD\nTwo apps installed."
        service.configure(config)
        scheduler.advance(0.4)
        XCTAssertTrue(launcher.launched[0].terminated)
        launcher.launched[0].exit(0)
        XCTAssertEqual(launcher.launched.count, 2)
        XCTAssertEqual(try String(contentsOf: context, encoding: .utf8), "# MacHUD\nTwo apps installed.")

        // Removing them removes the files and the flags.
        launcher.last.say("Brain companion ready at")
        config.toolServers = []
        config.hostContext = "  "
        service.configure(config)
        scheduler.advance(0.4)
        launcher.launched[1].exit(0)
        XCTAssertEqual(launcher.launched.count, 3)
        XCTAssertEqual(Array(try XCTUnwrap(launcher.specs.last?.arguments).suffix(2)), ["--runtime", "claude"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: servers.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.path))
    }

    func testSameToolServersAndRuntimeOnlyChangeKeepTheProcess() {
        var config = configuration(.codex)
        config.toolServers = [BrainToolServer(name: "machud", command: "/bin/machud-mcp")]
        config.hostContext = "# MacHUD"
        let service = make()
        service.configure(config)
        launcher.last.say("Brain companion ready at")
        config.runtime = .claude
        service.configure(config)
        scheduler.advance(0.4)
        XCTAssertEqual(launcher.launched.count, 1)
        XCTAssertFalse(launcher.launched[0].terminated)
    }

    func testInvalidToolServersExplainThemselves() {
        func reason(_ servers: [BrainToolServer], context: String = "") -> String {
            var config = configuration()
            config.toolServers = servers
            config.hostContext = context
            let service = make()
            service.configure(config)
            guard case .unavailable(let reason) = service.service.state else { return "\(service.service.state)" }
            return reason
        }
        XCTAssertEqual(reason([BrainToolServer(name: "mac hud", command: "/x")]),
                       "The tool server name \"mac hud\" must be letters, digits, _ or - (at most 64).")
        XCTAssertEqual(reason([BrainToolServer(name: "brainkit_permissions", command: "/x")]),
                       "The tool server name \"brainkit_permissions\" must be letters, digits, _ or - (at most 64).")
        XCTAssertEqual(reason([BrainToolServer(name: "machud", command: "")]), "The tool server machud needs a command.")
        XCTAssertEqual(reason([BrainToolServer(name: "a", command: "/x"), BrainToolServer(name: "a", command: "/y")]),
                       "Each tool server needs its own name.")
        XCTAssertEqual(reason([], context: String(repeating: "x", count: 65537)), "The brain's host context is too long.")
        XCTAssertTrue(launcher.launched.isEmpty)
    }

    func testUnavailableConfigurationsExplainThemselves() {
        func reason(_ config: BrainServiceConfiguration, companion: URL? = nil) -> String {
            let service = make(companionDirectory: companion)
            service.configure(config)
            guard case .unavailable(let reason) = service.service.state else { return "\(service.service.state)" }
            return reason
        }
        var config = configuration()
        config.workingDirectory = root.appendingPathComponent("missing").path
        XCTAssertEqual(reason(config), "Choose a workspace folder for the agent.")
        config = configuration()
        config.stateDirectory = "state"
        XCTAssertEqual(reason(config), "The brain's state directory must be an absolute path.")
        config = configuration()
        config.port = 80
        XCTAssertEqual(reason(config), "The brain's port must be between 1024 and 65535.")
        XCTAssertEqual(reason(configuration(), companion: root.appendingPathComponent("nowhere")),
                       "The brain companion is missing from this build.")
        nodeOutput = "v20.1.0"
        XCTAssertEqual(reason(configuration()),
                       "/opt/homebrew/bin/node is Node.js 20; version 22 or later is needed.")
        files.remove("/opt/homebrew/bin/node")
        XCTAssertTrue(reason(configuration()).hasPrefix("Node.js 22 or later is needed."))
        config = configuration()
        config.nodePath = "/missing/node"
        XCTAssertEqual(reason(config), "The Node.js path /missing/node is not an executable.")
        XCTAssertTrue(launcher.launched.isEmpty)
    }

    func testEndpointAndClientFollowTheTokenFile() throws {
        let service = make()
        XCTAssertNil(service.endpoint())
        service.configure(configuration())
        XCTAssertNil(service.endpoint())
        XCTAssertNil(service.makeClient())
        let token = String(repeating: "f", count: 64)
        let file = root.appendingPathComponent("state/token")
        try writeToken(token + "\n", to: file)
        // A token from an earlier run is not an endpoint until this process is ready.
        XCTAssertNil(service.endpoint())
        launcher.last.say("Brain companion ready at")
        XCTAssertEqual(service.endpoint(), ServiceEndpoint(url: URL(string: "http://127.0.0.1:8791")!, token: token))
        XCTAssertNotNil(service.makeClient())
        launcher.last.exit(1)
        XCTAssertNil(service.endpoint())
    }

    func testStopEndsTheProcess() {
        let service = make()
        service.configure(configuration())
        service.stop()
        XCTAssertTrue(launcher.last.terminated)
        XCTAssertEqual(service.service.state, .stopped)
        XCTAssertNil(service.configuration)
    }

    func testStateDirectoryIsOnePerWorkspace() throws {
        let base = URL(fileURLWithPath: "/state")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace)
        let first = BrainServiceConfiguration.stateDirectory(forWorkspace: workspace.path, under: base)
        XCTAssertEqual(first.deletingLastPathComponent().path, "/state")
        XCTAssertEqual(first.lastPathComponent.count, 16)
        XCTAssertEqual(BrainServiceConfiguration.stateDirectory(forWorkspace: link.path, under: base), first)
        XCTAssertNotEqual(BrainServiceConfiguration.stateDirectory(forWorkspace: root.path, under: base), first)
    }

    private func writeToken(_ text: String, to file: URL, mode: Int = 0o600) throws {
        try? FileManager.default.removeItem(at: file)
        try text.write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    private func ready(_ service: BrainService) {
        service.configure(configuration())
        launcher.last.say("Brain companion ready at")
    }

    func testTokenFileMustBePrivateRegularAndWellFormed() throws {
        let service = make()
        ready(service)
        let file = root.appendingPathComponent("state/token")
        let token = String(repeating: "a", count: 64)
        try writeToken(token, to: file, mode: 0o644)
        XCTAssertNil(service.endpoint(), "a token others can read is refused")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try writeToken(token, to: elsewhere)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        XCTAssertNil(service.endpoint(), "a symlinked token is refused")
        try FileManager.default.removeItem(at: file)
        try writeToken("not a token", to: file)
        XCTAssertNil(service.endpoint())
        try writeToken(token, to: file)
        XCTAssertEqual(service.endpoint()?.token, token)
    }

    func testAnExistingStateDirectoryIsMadePrivate() throws {
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        make().configure(configuration())
        let mode = try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testAssistantNameIsOneLineOfAtMost64UTF16Units() {
        func state(_ name: String) -> ManagedService.State {
            let service = make()
            var config = configuration()
            config.assistantName = name
            service.configure(config)
            return service.service.state
        }
        let refused = ManagedService.State.unavailable("The assistant name must be one line of at most 64 characters.")
        XCTAssertEqual(state("Two\nlines"), refused)
        XCTAssertEqual(state("Carriage\rreturn"), refused)
        XCTAssertEqual(state(String(repeating: "x", count: 65)), refused)
        XCTAssertEqual(state(String(repeating: "\u{1F600}", count: 33)), refused)
        XCTAssertEqual(state(String(repeating: "\u{1F600}", count: 32)), .starting)
        XCTAssertEqual(state("  Jarvis \n"), .starting)
        XCTAssertEqual(launcher.specs.last?.arguments.suffix(4), ["--assistant-name", "Jarvis", "--runtime", "codex"])
    }

    func testChangesAreDebouncedAndTheLastOneWins() {
        let service = make()
        service.configure(configuration())
        XCTAssertEqual(launcher.launched.count, 1, "the first configuration applies at once")
        for port in [8792, 8793] {
            var config = configuration()
            config.port = port
            service.configure(config)
            scheduler.advance(0.2)
        }
        XCTAssertFalse(launcher.launched[0].terminated)
        scheduler.advance(0.2)
        XCTAssertTrue(launcher.launched[0].terminated)
        launcher.launched[0].exit(0)
        XCTAssertEqual(launcher.launched.count, 2)
        XCTAssertEqual(launcher.last.processIdentifier, 101)
        XCTAssertTrue(launcher.specs.last?.arguments.contains("8793") == true)
        // Stopping is immediate and drops a pending change.
        var config = configuration()
        config.port = 8794
        service.configure(config)
        service.stop()
        scheduler.advance(1)
        XCTAssertEqual(service.service.state, .stopped)
        XCTAssertEqual(launcher.launched.count, 2)
    }

    func testNodeVersionIsCheckedOncePerPath() {
        files.insert("/custom/node")
        let service = make()
        service.configure(configuration())
        var config = configuration()
        config.port = 8792
        service.configure(config)
        scheduler.advance(0.4)
        XCTAssertEqual(versionCalls, ["/opt/homebrew/bin/node"])
        config.nodePath = "/custom/node"
        service.configure(config)
        scheduler.advance(0.4)
        XCTAssertEqual(versionCalls, ["/opt/homebrew/bin/node", "/custom/node"])
        // An explicit refresh (after an install or upgrade) checks again.
        service.refreshDetections()
        config.port = 8793
        service.configure(config)
        scheduler.advance(0.4)
        XCTAssertEqual(versionCalls.count, 3)
    }

    func testVersionProbeGivesUpOnAHungExecutable() throws {
        let script = root.appendingPathComponent("hang")
        try "#!/bin/sh\nsleep 10\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let started = Date()
        XCTAssertNil(BrainService.runVersion(script.path, timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(BrainService.runVersion("/bin/echo")?.trimmingCharacters(in: .whitespacesAndNewlines), "--version")
    }
}
