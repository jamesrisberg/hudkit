import XCTest
@testable import BrainKit

final class BrainSettingsTests: XCTestCase {
    func testRoundTrips() throws {
        let settings = BrainSettings(
            runtime: .hermes, workspacePath: "/Users/test/Assistant", assistantName: "Jarvis",
            nodePath: "/opt/homebrew/bin/node", codex: .init(executablePath: "/opt/homebrew/bin/codex"),
            claude: .init(executablePath: "~/.local/bin/claude"), hermes: .init(url: "http://127.0.0.1:8642"),
            plugins: ["example-agent": .init(executablePath: "~/.example/bin/example")])
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(BrainSettings.self, from: data), settings)
    }

    func testMissingOrUnknownValuesFallBackToDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(BrainSettings.self, from: Data("{}".utf8)), BrainSettings())
        let partial = """
        {"runtime":"Not A Runtime","workspacePath":"/w","codex":{},"hermes":{"url":"http://127.0.0.1:1"},"later":true}
        """
        let decoded = try JSONDecoder().decode(BrainSettings.self, from: Data(partial.utf8))
        XCTAssertEqual(decoded.runtime, .codex)
        XCTAssertEqual(decoded.workspacePath, "/w")
        XCTAssertEqual(decoded.codex, .init())
        XCTAssertEqual(decoded.hermes.url, "http://127.0.0.1:1")
        XCTAssertEqual(decoded.claude, .init())
        XCTAssertEqual(decoded.plugins, [:])
    }

    func testAPluginRuntimeAndItsOptionsDecode() throws {
        let json = #"{"runtime":"example-agent","plugins":{"example-agent":{"executablePath":"/x","later":1},"other-agent":{}}}"#
        let decoded = try JSONDecoder().decode(BrainSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.runtime, AgentRuntime(rawValue: "example-agent"))
        XCTAssertEqual(decoded.plugins, ["example-agent": .init(executablePath: "/x"), "other-agent": .init()])
        // A plugin's options are never read from another key, and a plugin that is not installed stays chosen.
        let older = try JSONDecoder().decode(BrainSettings.self, from: Data(#"{"runtime":"absent-agent","absent-agent":{"executablePath":"/m"}}"#.utf8))
        XCTAssertEqual(older.runtime, AgentRuntime(rawValue: "absent-agent"))
        XCTAssertEqual(older.plugins, [:])
    }

    func testServiceConfigurationCarriesEveryOption() {
        let settings = BrainSettings(
            runtime: .claude, workspacePath: "/w", assistantName: "Jarvis", nodePath: "/n",
            codex: .init(executablePath: "/c"), claude: .init(executablePath: "/cl"), hermes: .init(url: "http://h"),
            plugins: ["example-agent": .init(executablePath: "/x")])
        XCTAssertEqual(
            settings.serviceConfiguration(stateDirectory: "/state", port: 8791),
            BrainServiceConfiguration(runtime: .claude, workingDirectory: "/w", stateDirectory: "/state", port: 8791,
                                      nodePath: "/n", codexPath: "/c", claudePath: "/cl",
                                      pluginExecutablePaths: ["example-agent": "/x"],
                                      hermesURL: "http://h", assistantName: "Jarvis"))
    }
}
