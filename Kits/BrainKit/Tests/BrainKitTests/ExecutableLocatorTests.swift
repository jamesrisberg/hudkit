import XCTest
@testable import BrainKit

final class ExecutableLocatorTests: XCTestCase {
    private func locator(path: String = "/usr/bin:/bin", files: Set<String>, directories: [String: [String]] = [:])
        -> ExecutableLocator {
        ExecutableLocator(path: path, home: "/Users/test", isExecutable: { files.contains($0) },
                          contentsOfDirectory: { directories[$0] ?? [] })
    }

    func testPathEntriesComeBeforeCommonFolders() {
        let locator = locator(path: "/custom/bin:/usr/bin", files: ["/custom/bin/codex", "/opt/homebrew/bin/codex"])
        XCTAssertEqual(locator.locate("codex"), "/custom/bin/codex")
    }

    func testFindsToolsOutsideTheMinimalAppPath() {
        let locator = locator(files: [
            "/opt/homebrew/bin/node", "/Users/test/.local/bin/hermes", "/Users/test/.claude/local/claude",
        ])
        XCTAssertEqual(locator.locate("node"), "/opt/homebrew/bin/node")
        XCTAssertEqual(locator.locate("hermes"), "/Users/test/.local/bin/hermes")
        XCTAssertEqual(locator.locate("claude"), "/Users/test/.claude/local/claude")
        XCTAssertNil(locator.locate("codex"))
    }

    func testHomebrewPrefersAppleSiliconPrefix() {
        let locator = locator(files: ["/usr/local/bin/node", "/opt/homebrew/bin/node"])
        XCTAssertEqual(locator.locate("node"), "/opt/homebrew/bin/node")
    }

    func testNvmUsesNewestVersion() {
        let root = "/Users/test/.nvm/versions/node"
        let locator = locator(
            files: ["\(root)/v20.1.0/bin/node", "\(root)/v22.10.0/bin/node", "\(root)/v22.9.0/bin/node"],
            directories: [root: ["v20.1.0", "v22.9.0", "v22.10.0", ".DS_Store"]])
        XCTAssertEqual(locator.locate("node"), "\(root)/v22.10.0/bin/node")
    }

    func testOverrideWinsAndIsNotSilentlyReplaced() {
        let locator = locator(files: ["/opt/homebrew/bin/node", "/Users/test/tools/node"])
        XCTAssertEqual(locator.locate("node", override: "~/tools/node"), "/Users/test/tools/node")
        XCTAssertNil(locator.locate("node", override: "/missing/node"))
    }

    func testChildPathPutsToolFolderFirstWithoutDuplicates() {
        let locator = locator(path: "/usr/bin:/opt/homebrew/bin", files: [])
        let parts = locator.childPath(prepending: ["/Users/test/.local/bin"]).split(separator: ":")
        XCTAssertEqual(parts.first, "/Users/test/.local/bin")
        XCTAssertTrue(parts.contains("/usr/bin"))
        XCTAssertEqual(Set(parts).count, parts.count)
    }

    func testNodeVersionParsing() {
        XCTAssertEqual(ExecutableLocator.nodeMajorVersion("v22.3.0\n"), 22)
        XCTAssertEqual(ExecutableLocator.nodeMajorVersion("v26.9.0"), 26)
        XCTAssertNil(ExecutableLocator.nodeMajorVersion("22.3.0"))
        XCTAssertNil(ExecutableLocator.nodeMajorVersion(""))
    }

    func testDetectsEachBrain() {
        let locator = locator(files: ["/Users/test/.local/bin/hermes", "/opt/homebrew/bin/codex"])
        let env = "API_SERVER_ENABLED=true\nAPI_SERVER_KEY=secret\n"
        let hermesHome = ProcessInfo.processInfo.environment["HERMES_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/Users/test/.hermes"
        let hermes = BrainCatalog.detect(.hermes, locator: locator, readFile: { $0 == "\(hermesHome)/.env" ? env : nil })
        XCTAssertEqual(hermes.executable, "/Users/test/.local/bin/hermes")
        XCTAssertEqual(hermes.apiServerEnabled, true)
        let claude = BrainCatalog.detect(.claude, locator: locator, readFile: { _ in nil })
        XCTAssertFalse(claude.isInstalled)
        XCTAssertNil(claude.apiServerEnabled)
        let codex = BrainCatalog.detect(.codex, locator: locator, readFile: { _ in nil })
        XCTAssertEqual(codex.executable, "/opt/homebrew/bin/codex")
        let noEnv = BrainCatalog.detect(.hermes, locator: locator, readFile: { _ in nil })
        XCTAssertEqual(noEnv.apiServerEnabled, false)
        XCTAssertFalse(BrainCatalog.detect(.mclaude, locator: locator).isInstalled)
        let withMclaude = self.locator(files: ["/Users/test/.local/bin/mclaude"])
        XCTAssertEqual(BrainCatalog.detect(.mclaude, locator: withMclaude).executable, "/Users/test/.local/bin/mclaude")
        XCTAssertEqual(BrainCatalog.entry(for: .mclaude).executable, "mclaude")
    }

    func testHermesEnvParsing() {
        XCTAssertTrue(BrainCatalog.hermesAPIServerEnabled("API_SERVER_ENABLED=true"))
        XCTAssertTrue(BrainCatalog.hermesAPIServerEnabled("export API_SERVER_ENABLED=\"1\" # on"))
        XCTAssertFalse(BrainCatalog.hermesAPIServerEnabled("# API_SERVER_ENABLED=true"))
        XCTAssertFalse(BrainCatalog.hermesAPIServerEnabled("API_SERVER_ENABLED=false"))
        XCTAssertFalse(BrainCatalog.hermesAPIServerEnabled("API_SERVER_ENABLED_X=true"))
        XCTAssertFalse(BrainCatalog.hermesAPIServerEnabled(""))
    }

    func testEveryRuntimeHasACatalogEntry() {
        for runtime in AgentRuntime.allCases {
            XCTAssertEqual(BrainCatalog.entry(for: runtime).executable, runtime.rawValue)
        }
    }
}
