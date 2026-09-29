import XCTest
@testable import BrainKit

final class BrainSettingsTests: XCTestCase {
    func testRoundTrips() throws {
        let settings = BrainSettings(
            runtime: .hermes, workspacePath: "/Users/test/Assistant", assistantName: "Jarvis",
            nodePath: "/opt/homebrew/bin/node", codex: .init(executablePath: "/opt/homebrew/bin/codex"),
            claude: .init(executablePath: "~/.local/bin/claude"), hermes: .init(url: "http://127.0.0.1:8642"),
            mclaude: .init(executablePath: "~/.local/bin/mclaude"))
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(BrainSettings.self, from: data), settings)
    }

    func testMissingOrUnknownValuesFallBackToDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(BrainSettings.self, from: Data("{}".utf8)), BrainSettings())
        let partial = """
        {"runtime":"gemini","workspacePath":"/w","codex":{},"hermes":{"url":"http://127.0.0.1:1"},"later":true}
        """
        let decoded = try JSONDecoder().decode(BrainSettings.self, from: Data(partial.utf8))
        XCTAssertEqual(decoded.runtime, .codex)
        XCTAssertEqual(decoded.workspacePath, "/w")
        XCTAssertEqual(decoded.codex, .init())
        XCTAssertEqual(decoded.hermes.url, "http://127.0.0.1:1")
        XCTAssertEqual(decoded.claude, .init())
        XCTAssertEqual(decoded.mclaude, .init())
        let mclaude = try JSONDecoder().decode(BrainSettings.self, from: Data(#"{"runtime":"mclaude","mclaude":{"executablePath":"/m"}}"#.utf8))
        XCTAssertEqual(mclaude.runtime, .mclaude)
        XCTAssertEqual(mclaude.mclaude.executablePath, "/m")
    }

    func testServiceConfigurationCarriesEveryOption() {
        let settings = BrainSettings(
            runtime: .claude, workspacePath: "/w", assistantName: "Jarvis", nodePath: "/n",
            codex: .init(executablePath: "/c"), claude: .init(executablePath: "/cl"), hermes: .init(url: "http://h"),
            mclaude: .init(executablePath: "/m"))
        XCTAssertEqual(
            settings.serviceConfiguration(stateDirectory: "/state", port: 8791),
            BrainServiceConfiguration(runtime: .claude, workingDirectory: "/w", stateDirectory: "/state", port: 8791,
                                      nodePath: "/n", codexPath: "/c", claudePath: "/cl", mclaudePath: "/m",
                                      hermesURL: "http://h", assistantName: "Jarvis"))
    }
}
