import XCTest
@testable import BrainKit

final class RuntimePluginTests: XCTestCase {
    private var root: URL!
    private var runtimes: URL!

    override func setUpWithError() throws {
        root = try temporaryDirectory("plugins")
        runtimes = root.appendingPathComponent("Runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func locator(files: Set<String> = []) -> ExecutableLocator {
        ExecutableLocator(path: "/usr/bin:/bin", home: "/Users/test", isExecutable: { files.contains($0) },
                          contentsOfDirectory: { _ in [] }, runtimesDirectory: runtimes.path)
    }

    private func plugin(_ id: String) -> RuntimePlugin? {
        locator().runtimePlugins().first { $0.id == id }
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: AgentRuntime

    func testRuntimesAreStringsWithBuiltIns() throws {
        XCTAssertEqual(AgentRuntime.builtIns, [.codex, .hermes, .claude])
        XCTAssertEqual(AgentRuntime(rawValue: "claude"), .claude)
        XCTAssertTrue(AgentRuntime.claude.isBuiltIn)
        let plugin = try XCTUnwrap(AgentRuntime(rawValue: "example-agent"))
        XCTAssertFalse(plugin.isBuiltIn)
        XCTAssertEqual(plugin.displayName, "example-agent")
        XCTAssertEqual(AgentRuntime.codex.displayName, "Codex")
        for invalid in ["", "Example", "1agent", "-agent", "agent_x", String(repeating: "a", count: 33)] {
            XCTAssertNil(AgentRuntime(rawValue: invalid), invalid)
        }
        XCTAssertNotNil(AgentRuntime(rawValue: String(repeating: "a", count: 32)))
        let data = try JSONEncoder().encode([plugin, .hermes])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["example-agent","hermes"]"#)
        XCTAssertEqual(try JSONDecoder().decode([AgentRuntime].self, from: data), [plugin, .hermes])
        XCTAssertThrowsError(try JSONDecoder().decode([AgentRuntime].self, from: Data(#"["Not One"]"#.utf8)))
    }

    // MARK: Descriptors

    func testRuntimesDirectoryDefaultsUnderApplicationSupport() {
        let plain = ExecutableLocator(path: "", home: "/Users/test", isExecutable: { _ in false }, contentsOfDirectory: { _ in [] })
        XCTAssertEqual(plain.runtimesDirectory, "/Users/test/Library/Application Support/BrainKit/Runtimes")
        XCTAssertEqual(ExecutableLocator.defaultRuntimesDirectory(home: "/h", environment: [:]),
                       "/h/Library/Application Support/BrainKit/Runtimes")
        XCTAssertEqual(ExecutableLocator.defaultRuntimesDirectory(home: "/h", environment: ["BRAINKIT_RUNTIMES_DIR": ""]),
                       "/h/Library/Application Support/BrainKit/Runtimes")
        XCTAssertEqual(ExecutableLocator.defaultRuntimesDirectory(home: "/h", environment: ["BRAINKIT_RUNTIMES_DIR": "/tmp/r"]),
                       "/tmp/r")
    }

    func testTheLiveLocatorReadsPluginsFromTheEnvironmentsFolder() throws {
        try writePlugin("example-agent", in: runtimes)
        let previous = ProcessInfo.processInfo.environment["BRAINKIT_RUNTIMES_DIR"]
        setenv("BRAINKIT_RUNTIMES_DIR", runtimes.path, 1)
        defer {
            if let previous { setenv("BRAINKIT_RUNTIMES_DIR", previous, 1) } else { unsetenv("BRAINKIT_RUNTIMES_DIR") }
        }
        XCTAssertEqual(ExecutableLocator.live.runtimesDirectory, runtimes.path)
        XCTAssertEqual(ExecutableLocator.live.runtimePlugins().map(\.id), ["example-agent"])
    }

    func testReadsATrustedPluginsDescriptor() throws {
        let folder = try writePlugin("example-agent", in: runtimes, manifest: [
            "title": "Example Agent", "version": "1.2.0", "executable": "example", "searchPaths": ["~/.example/bin"],
            "installCommand": "brew install example", "loginCommand": "example login", "loginTitle": "Sign In",
            "requires": ["git"], "note": "Needs git.", "summary": "An example agent.",
            "docsURL": "https://example.com/agent", "later": ["unknown keys are ignored"],
        ])
        // Hidden entries, files and folders that cannot be runtime ids are not plugins.
        try FileManager.default.createDirectory(at: runtimes.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimes.appendingPathComponent("Not A Plugin"), withIntermediateDirectories: true)
        try Data().write(to: runtimes.appendingPathComponent("notes.txt"))
        let plugins = locator().runtimePlugins()
        XCTAssertEqual(plugins.map(\.id), ["example-agent"])
        let plugin = try XCTUnwrap(plugins.first)
        XCTAssertNil(plugin.refusal)
        XCTAssertEqual(plugin.runtime, AgentRuntime(rawValue: "example-agent"))
        XCTAssertEqual(plugin.directory, folder.path)
        XCTAssertEqual(plugin.title, "Example Agent")
        XCTAssertEqual(plugin.version, "1.2.0")
        XCTAssertEqual(plugin.adapter, "adapter.mjs")
        XCTAssertEqual(plugin.executable, "example")
        XCTAssertEqual(plugin.searchPaths, ["~/.example/bin"])
        XCTAssertEqual(plugin.installCommand, "brew install example")
        XCTAssertEqual(plugin.loginCommand, "example login")
        XCTAssertEqual(plugin.loginTitle, "Sign In")
        XCTAssertEqual(plugin.requires, ["git"])
        XCTAssertEqual(plugin.note, "Needs git.")
        XCTAssertEqual(plugin.summary, "An example agent.")
        XCTAssertEqual(plugin.docsURL, URL(string: "https://example.com/agent"))
    }

    func testRefusesAPluginUnlessItsWholeFolderAndItsParentArePrivate() throws {
        // The same steps and reasons as the companion's test/plugins.test.mjs.
        let folder = try writePlugin("example-agent", in: runtimes)
        let manager = FileManager.default
        func at(_ path: String) -> URL { folder.appendingPathComponent(path) }
        func refusal() -> String { plugin("example-agent")?.refusal ?? "" }
        try chmod(runtimes, 0o775)
        XCTAssertEqual(refusal(), "The runtimes folder \(runtimes.path) is writable by other users")
        try chmod(runtimes, 0o755)
        try chmod(folder, 0o775)
        XCTAssertEqual(refusal(), "The plugin folder \(folder.path) is writable by other users")
        let refused = try XCTUnwrap(plugin("example-agent"))
        XCTAssertEqual(refused.title, "example-agent", "nothing from an untrusted folder is shown")
        XCTAssertNil(refused.installCommand)
        try chmod(folder, 0o755)
        try chmod(at("runtime.json"), 0o646)
        XCTAssertEqual(refusal(), "runtime.json is writable by other users")
        try chmod(at("runtime.json"), 0o644)
        try chmod(at("adapter.mjs"), 0o664)
        XCTAssertEqual(refusal(), #"The adapter "adapter.mjs" is writable by other users"#)
        try chmod(at("adapter.mjs"), 0o644)
        // Everything else in the folder: a module the adapter imports, and the folders on the way.
        try manager.createDirectory(at: at("lib"), withIntermediateDirectories: true)
        try Data("export const x = 1;".utf8).write(to: at("lib/helper.mjs"))
        try chmod(at("lib/helper.mjs"), 0o644)
        try chmod(at("lib"), 0o775)
        XCTAssertEqual(refusal(), #""lib" in the plugin folder is writable by other users"#)
        try chmod(at("lib"), 0o755)
        try chmod(at("lib/helper.mjs"), 0o666)
        XCTAssertEqual(refusal(), #""lib/helper.mjs" in the plugin folder is writable by other users"#)
        try chmod(at("lib/helper.mjs"), 0o644)
        XCTAssertNil(plugin("example-agent")?.refusal)
        try manager.removeItem(at: at("lib"))
        // Adapter paths and links.
        let outside = runtimes.appendingPathComponent("outside.mjs")
        try Data().write(to: outside)
        try chmod(outside, 0o644)
        try writePlugin("example-agent", in: runtimes, manifest: ["adapter": "../outside.mjs"])
        XCTAssertEqual(refusal(), #"The adapter "../outside.mjs" is outside the plugin folder"#)
        try writePlugin("example-agent", in: runtimes, manifest: ["adapter": outside.path])
        XCTAssertEqual(refusal(), "The adapter \"\(outside.path)\" is outside the plugin folder")
        try writePlugin("example-agent", in: runtimes, manifest: ["adapter": "adapter.js"])
        XCTAssertEqual(refusal(), #"The adapter "adapter.js" is not an .mjs module"#)
        try manager.createSymbolicLink(at: at("linked.mjs"), withDestinationURL: outside)
        try writePlugin("example-agent", in: runtimes, manifest: ["adapter": "linked.mjs"])
        XCTAssertEqual(refusal(), #"The adapter "linked.mjs" is a symbolic link"#)
        try writePlugin("example-agent", in: runtimes)
        XCTAssertEqual(refusal(), #""linked.mjs" in the plugin folder is a symbolic link"#)
        try manager.removeItem(at: at("linked.mjs"))
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data().write(to: elsewhere.appendingPathComponent("adapter.mjs"))
        try chmod(elsewhere.appendingPathComponent("adapter.mjs"), 0o644)
        try manager.createSymbolicLink(at: at("lib"), withDestinationURL: elsewhere)
        try writePlugin("example-agent", in: runtimes, manifest: ["adapter": "lib/adapter.mjs"])
        XCTAssertEqual(refusal(), #""lib" in the plugin folder is a symbolic link"#)
        try manager.removeItem(at: at("lib"))
        try writePlugin("example-agent", in: runtimes, manifest: ["adapter": "missing.mjs"])
        XCTAssertEqual(refusal(), #"The adapter "missing.mjs" is missing"#)
        // An unreadable, a missing and a linked runtime.json.
        try writePlugin("example-agent", in: runtimes)
        try chmod(at("runtime.json"), 0o000)
        XCTAssertEqual(refusal(), "runtime.json cannot be read")
        try manager.removeItem(at: at("runtime.json"))
        XCTAssertEqual(refusal(), "runtime.json is missing")
        try Data("{}".utf8).write(to: elsewhere.appendingPathComponent("runtime.json"))
        try manager.createSymbolicLink(at: at("runtime.json"), withDestinationURL: elsewhere.appendingPathComponent("runtime.json"))
        XCTAssertEqual(refusal(), "runtime.json is a symbolic link")
        // A plugin folder that is itself a link, and one read under another name.
        let real = try writePlugin("linked-agent", in: root)
        try manager.createSymbolicLink(at: runtimes.appendingPathComponent("linked-agent"), withDestinationURL: real)
        XCTAssertEqual(plugin("linked-agent")?.refusal,
                       "The plugin folder \(runtimes.appendingPathComponent("linked-agent").path) is a symbolic link")
        XCTAssertEqual(RuntimePlugin.read("other-agent", in: real.path)?.refusal,
                       #"The plugin folder "linked-agent" is not named "other-agent""#)
        XCTAssertNil(RuntimePlugin.read("Echo", in: real.path))
    }

    func testRefusesAnInvalidDescriptor() throws {
        func refusal(_ manifest: [String: Any], id: String = "example-agent") throws -> String {
            try writePlugin(id, in: runtimes, manifest: manifest)
            return plugin(id)?.refusal ?? ""
        }
        XCTAssertEqual(try refusal(["id": "other-agent"]), #"runtime.json's id "other-agent" does not match its folder "example-agent""#)
        XCTAssertEqual(try refusal(["schema": 2]), "runtime.json has schema 2; this BrainKit reads schema 1")
        XCTAssertEqual(try refusal(["title": ""]), #"runtime.json: "title" must be a non-empty string"#)
        XCTAssertEqual(try refusal(["requires": "git"]), #"runtime.json: "requires" must be a list of strings"#)
        XCTAssertEqual(try refusal(["note": 3]), #"runtime.json: "note" must be a string"#)
        XCTAssertEqual(try refusal(["docsURL": "file:///etc"]), #"runtime.json: "docsURL" must be an http or https URL"#)
        XCTAssertEqual(try refusal([:], id: "codex"), "codex is a built-in runtime")
        let file = runtimes.appendingPathComponent("example-agent/runtime.json")
        try Data("{ not json".utf8).write(to: file)
        XCTAssertEqual(plugin("example-agent")?.refusal, "runtime.json is not valid JSON")
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(plugin("example-agent")?.refusal, "runtime.json is missing")
    }

    // MARK: Detections

    func testDetectsPluginsBesideTheBuiltIns() throws {
        try writePlugin("example-agent", in: runtimes, manifest: [
            "executable": "example", "searchPaths": ["~/.example/bin"], "installCommand": "brew install example",
            "loginCommand": "example login", "requires": ["git", "~/tools/example-helper"], "note": "Needs git.",
            "docsURL": "https://example.com/agent",
        ])
        let refused = try writePlugin("other-agent", in: runtimes, manifest: ["title": "Other"])
        try chmod(refused, 0o777)
        let locator = locator(files: ["/opt/homebrew/bin/codex", "/Users/test/.example/bin/example", "/usr/bin/git",
                                      "/Users/test/.local/bin/other-agent"])
        let found = BrainCatalog.detectAll(locator: locator, readFile: { _ in nil })
        XCTAssertEqual(found.map(\.runtime.rawValue), ["codex", "hermes", "claude", "example-agent", "other-agent"])
        let codex = try XCTUnwrap(found.first)
        XCTAssertEqual(codex.title, "Codex")
        XCTAssertEqual(codex.executable, "/opt/homebrew/bin/codex")
        XCTAssertEqual(codex.loginCommand, "codex login")
        XCTAssertEqual(codex.docsURL, URL(string: "https://developers.openai.com/codex/cli"))
        XCTAssertTrue(codex.isAvailable)
        XCTAssertNil(codex.plugin)
        let example = found[3]
        XCTAssertEqual(example.title, "Example Agent")
        XCTAssertEqual(example.executable, "/Users/test/.example/bin/example")
        XCTAssertEqual(example.installCommand, "brew install example")
        XCTAssertEqual(example.loginCommand, "example login")
        XCTAssertEqual(example.loginTitle, "Log In")
        XCTAssertEqual(example.note, "Needs git.")
        XCTAssertEqual(example.docsURL, URL(string: "https://example.com/agent"))
        XCTAssertEqual(example.missingRequirements, ["~/tools/example-helper"])
        XCTAssertNil(example.refusal)
        XCTAssertTrue(example.isInstalled)
        XCTAssertFalse(example.isAvailable)
        XCTAssertEqual(example.unavailableReason, "Example Agent needs ~/tools/example-helper, which is not installed.")
        let withHelper = BrainCatalog.detectAll(locator: self.locator(files: [
            "/Users/test/.example/bin/example", "/usr/bin/git", "/Users/test/tools/example-helper"]), readFile: { _ in nil })
        XCTAssertTrue(withHelper[3].isAvailable)
        XCTAssertEqual(example.plugin?.directory, runtimes.appendingPathComponent("example-agent").path)
        let other = found[4]
        XCTAssertEqual(other.title, "other-agent")
        XCTAssertNil(other.executable)
        XCTAssertFalse(other.isAvailable)
        XCTAssertTrue(other.refusal?.hasSuffix("other-agent is writable by other users") == true, other.refusal ?? "")
        // An override, and a plugin whose tool is missing.
        let overridden = BrainCatalog.detectAll(
            locator: self.locator(files: ["/custom/example"]),
            overrides: [AgentRuntime(rawValue: "example-agent")!: "/custom/example"], readFile: { _ in nil })
        XCTAssertEqual(overridden[3].executable, "/custom/example")
        XCTAssertFalse(BrainCatalog.detect(AgentRuntime(rawValue: "example-agent")!, locator: self.locator()).isInstalled)
        XCTAssertFalse(BrainCatalog.detect(AgentRuntime(rawValue: "absent-agent")!, locator: self.locator()).isAvailable)
    }

    func testAPluginMayNameAnAbsoluteExecutable() throws {
        try writePlugin("example-agent", in: runtimes, manifest: ["executable": "~/tools/example"])
        let detection = BrainCatalog.detect(AgentRuntime(rawValue: "example-agent")!,
                                            locator: locator(files: ["/Users/test/tools/example"]))
        XCTAssertEqual(detection.executable, "/Users/test/tools/example")
        XCTAssertNil(detection.loginCommand)
        XCTAssertNil(detection.loginTitle, "no login button without a login command")
    }

    func testTheEnvironmentsFolderIsExpandedAndMustBeAbsolute() throws {
        XCTAssertEqual(ExecutableLocator.defaultRuntimesDirectory(home: "/h", environment: ["BRAINKIT_RUNTIMES_DIR": "~/r/../x/"]),
                       "/h/x")
        XCTAssertEqual(ExecutableLocator.defaultRuntimesDirectory(home: "/h", environment: ["BRAINKIT_RUNTIMES_DIR": "relative/r"]),
                       "relative/r")
        try writePlugin("example-agent", in: runtimes)
        var relative = locator()
        XCTAssertNil(relative.runtimesDirectoryProblem)
        relative.runtimesDirectory = "relative/r"
        XCTAssertEqual(relative.runtimesDirectoryProblem,
                       "The runtime plugins folder relative/r (BRAINKIT_RUNTIMES_DIR) is not an absolute path.")
        XCTAssertEqual(relative.runtimePlugins(), [])
        XCTAssertEqual(BrainCatalog.detectAll(locator: relative, readFile: { _ in nil }).count, 3)
    }
}
