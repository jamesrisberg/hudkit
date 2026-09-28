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
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(companionDirectory: URL? = nil) -> BrainService {
        let directory = companionDirectory ?? companion
        return BrainService(
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

    func testRuntimeOnlyChangeKeepsTheProcessAndOtherChangesRestart() {
        let service = make()
        service.configure(configuration(.codex))
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
