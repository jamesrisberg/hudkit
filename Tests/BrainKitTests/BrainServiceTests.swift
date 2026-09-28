import XCTest
@testable import BrainKit

@MainActor
final class BrainServiceTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var companion: URL!
    private var launcher: FakeLauncher!
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
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(companionDirectory: URL? = nil) -> BrainService {
        let directory = companionDirectory ?? companion
        return BrainService(
            launcher: launcher, scheduler: FakeScheduler(),
            locator: { [unowned self] in
                ExecutableLocator(path: "/usr/bin:/bin", home: "/Users/test",
                                  isExecutable: { [files] in files.contains($0) }, contentsOfDirectory: { _ in [] })
            },
            nodeVersion: { [unowned self] _ in nodeOutput },
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
        XCTAssertEqual(launcher.launched.count, 1)
        XCTAssertEqual(service.service.state, .running)
        // The next start uses the new runtime.
        XCTAssertEqual(service.service.spec?.arguments.suffix(2), ["--runtime", "claude"])
        var moved = configuration(.claude)
        moved.port = 8792
        service.configure(moved)
        XCTAssertTrue(launcher.launched[0].terminated)
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
        try (token + "\n").write(to: root.appendingPathComponent("state/token"), atomically: true, encoding: .utf8)
        XCTAssertEqual(service.endpoint(), ServiceEndpoint(url: URL(string: "http://127.0.0.1:8791")!, token: token))
        XCTAssertNotNil(service.makeClient())
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
}
