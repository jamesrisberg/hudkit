import XCTest
@testable import BrainKit

/// Runs the companion from the built resource bundle with real Node.js and the Codex
/// stand-in from the companion's own test fixtures (`test/fixtures/fake-codex.mjs`); no
/// real agent CLI is started. Skipped when Node.js 22 or later is not installed.
@MainActor
final class BrainCompanionLiveTests: XCTestCase {
    func testCompanionShipsInTheResourceBundleWithItsTests() throws {
        let directory = try XCTUnwrap(BrainCompanion.directory)
        XCTAssertTrue(directory.path.contains(BrainCompanion.bundleName), directory.path)
        for file in ["server.mjs", "session.mjs", "voice-instructions.mjs", "runtimes/index.mjs", "test/server.test.mjs"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path), file)
        }
        for fixture in ["fake-codex.mjs", "fake-claude.mjs"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(
                atPath: directory.appendingPathComponent("test/fixtures/\(fixture)").path), fixture)
        }
        XCTAssertEqual(BrainCompanion.serverScript, directory.appendingPathComponent("server.mjs"))
    }

    func testMissingCandidatesFindNothing() {
        XCTAssertNil(BrainCompanion.directory(in: [URL(fileURLWithPath: "/nonexistent/Companion")]))
    }

    func testOneTurnThroughTheBundledCompanionAndTheSwiftClient() async throws {
        guard let node = ExecutableLocator.live.locate("node"),
              let major = BrainService.runVersion(node).flatMap(ExecutableLocator.nodeMajorVersion),
              major >= BrainService.minimumNodeMajorVersion
        else { throw XCTSkip("Node.js \(BrainService.minimumNodeMajorVersion) or later is not installed") }
        let companion = try XCTUnwrap(BrainCompanion.directory)
        let root = try temporaryDirectory("live")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let brain = BrainService()
        var configuration = BrainServiceConfiguration(
            runtime: .codex, workingDirectory: workspace.path, stateDirectory: root.appendingPathComponent("state").path,
            port: Int.random(in: 30000...45000), nodePath: node)
        configuration.codexPath = companion.appendingPathComponent("test/fixtures/fake-codex.mjs").path
        // Pinned so no installed agent CLI is ever handed to the companion.
        configuration.claudePath = "/usr/bin/false"
        brain.configure(configuration)
        defer { brain.stop() }
        for _ in 0..<150 where brain.service.state != .running {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(brain.service.state, .running, brain.service.log.joined(separator: "\n"))
        let pid = try XCTUnwrap(brain.service.processIdentifier)

        let client = try XCTUnwrap(brain.makeClient())
        try await client.connect()
        XCTAssertEqual(client.snapshot?.runtime, "codex")
        XCTAssertEqual(client.snapshot?.threadId, "thread-A")
        try await client.submit(text: "What is the capital of France?")
        for _ in 0..<100 where !(client.snapshot?.status == "idle" && client.snapshot?.turnId == "turn-1") {
            try await Task.sleep(for: .milliseconds(100))
        }
        let done = try XCTUnwrap(client.snapshot)
        XCTAssertEqual(done.status, "idle")
        XCTAssertEqual(done.turnId, "turn-1")
        XCTAssertEqual(done.output, "Echo: What is the capital of France?")
        XCTAssertEqual(done.route?.model, "gpt-5.6-luna")
        var transcript = TranscriptModel()
        transcript.userSaid("What is the capital of France?")
        transcript.apply(TranscriptInput(done))
        XCTAssertTrue(transcript.rows.contains { $0.kind == .reply("Echo: What is the capital of France?", streaming: false) })
        client.disconnect()

        brain.stop()
        var alive = true
        for _ in 0..<80 where alive {
            try await Task.sleep(for: .milliseconds(100))
            alive = kill(pid, 0) == 0
        }
        XCTAssertFalse(alive, "the companion outlived stop()")
    }
}
