import Foundation

/// Finds command-line tools the way a login shell would, without running one. Apps
/// launched from Finder get a minimal PATH, so common install folders are searched too.
/// Every input is injectable for tests; runtime plugins are read from `runtimesDirectory`
/// on disk (`runtimePlugins()`).
public struct ExecutableLocator {
    public var path: String
    public var home: String
    public var isExecutable: (String) -> Bool
    public var contentsOfDirectory: (String) -> [String]
    /// The folder holding runtime plugins, one folder per plugin named by its id.
    public var runtimesDirectory: String

    /// `runtimesDirectory` nil is `<home>/Library/Application Support/BrainKit/Runtimes`.
    public init(path: String, home: String, isExecutable: @escaping (String) -> Bool,
                contentsOfDirectory: @escaping (String) -> [String], runtimesDirectory: String? = nil) {
        self.path = path
        self.home = home
        self.isExecutable = isExecutable
        self.contentsOfDirectory = contentsOfDirectory
        self.runtimesDirectory = runtimesDirectory ?? Self.defaultRuntimesDirectory(home: home, environment: [:])
    }

    /// The environment's PATH, home and `BRAINKIT_RUNTIMES_DIR`, and the real file system.
    public static var live: ExecutableLocator {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ExecutableLocator(
            path: environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            home: home,
            isExecutable: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
            },
            contentsOfDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            runtimesDirectory: defaultRuntimesDirectory(home: home, environment: environment))
    }

    /// `BRAINKIT_RUNTIMES_DIR` when set (tests and isolated runs), otherwise
    /// `<home>/Library/Application Support/BrainKit/Runtimes`.
    public static func defaultRuntimesDirectory(home: String, environment: [String: String]) -> String {
        if let directory = environment["BRAINKIT_RUNTIMES_DIR"], !directory.isEmpty { return directory }
        return "\(home)/Library/Application Support/BrainKit/Runtimes"
    }

    /// Install folders used by Homebrew, the official installers and common version managers.
    public var commonDirectories: [String] {
        [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/.claude/local", "\(home)/bin",
        ] + nvmDirectories
    }

    /// `~/.nvm/versions/node/v*/bin`, newest version first.
    private var nvmDirectories: [String] {
        let root = "\(home)/.nvm/versions/node"
        return contentsOfDirectory(root)
            .filter { $0.hasPrefix("v") }
            .sorted { Self.versionComponents($0).lexicographicallyPrecedes(Self.versionComponents($1)) }
            .reversed()
            .map { "\(root)/\($0)/bin" }
    }

    /// Directories searched in order: PATH first, then the common folders, without repeats.
    public var searchDirectories: [String] {
        var seen = Set<String>()
        return (path.split(separator: ":").map(String.init) + commonDirectories)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// An explicit override wins when it is executable; an unusable override is not
    /// silently replaced, so the caller can report it. `additionalDirectories` (`~/` allowed)
    /// are searched after the usual ones.
    public func locate(_ name: String, override: String = "", additionalDirectories: [String] = []) -> String? {
        let explicit = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            let expanded = expandingHome(explicit)
            return isExecutable(expanded) ? expanded : nil
        }
        for directory in searchDirectories + additionalDirectories.map(expandingHome) {
            let candidate = "\(directory)/\(name)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// `~/x` as a path in `home`; any other path unchanged.
    public func expandingHome(_ path: String) -> String {
        path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    /// PATH for child processes: the tool's own folder first so shebangs such as
    /// `#!/usr/bin/env node` resolve, then the common folders, then the inherited PATH.
    public func childPath(prepending directories: [String] = []) -> String {
        var seen = Set<String>()
        return (directories + commonDirectories + path.split(separator: ":").map(String.init))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    public static func versionComponents(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "v \n"))
            .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// Major version from `node --version` output such as `v22.3.0`.
    public static func nodeMajorVersion(_ output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("v"), let major = versionComponents(trimmed).first, major > 0 else {
            return nil
        }
        return major
    }
}

/// What BrainKit knows about each installable brain: how to find, install and sign in to it.
/// The built-in runtimes have entries here; a runtime plugin describes itself in its
/// `runtime.json` (`RuntimePlugin`).
public enum BrainCatalog {
    public struct Entry: Sendable {
        public let runtime: AgentRuntime
        public let executable: String
        public let summary: String
        public let installCommand: String
        /// Command that signs in or finishes setup; nil when the install covers it.
        public let loginCommand: String?
        public let loginTitle: String
        public let docsURL: URL
    }

    public static let entries: [Entry] = [
        Entry(
            runtime: .hermes, executable: "hermes",
            summary: "Nous Research's open agent. Brings its own models, tools and memory.",
            installCommand: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash",
            loginCommand: "hermes setup", loginTitle: "Set Up",
            docsURL: URL(string: "https://github.com/NousResearch/hermes-agent")!),
        Entry(
            runtime: .claude, executable: "claude",
            summary: "Anthropic's Claude Code. Uses your Claude subscription or API key.",
            installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
            loginCommand: "claude", loginTitle: "Log In",
            docsURL: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!),
        Entry(
            runtime: .codex, executable: "codex",
            summary: "OpenAI's Codex CLI. Uses your ChatGPT account or API key.",
            installCommand: "brew install --cask codex || npm install -g @openai/codex",
            loginCommand: "codex login", loginTitle: "Log In",
            docsURL: URL(string: "https://developers.openai.com/codex/cli")!),
    ]

    /// The built-in runtime's entry; nil for a plugin.
    public static func entry(for runtime: AgentRuntime) -> Entry? {
        entries.first { $0.runtime == runtime }
    }

    /// One runtime as this Mac has it, built-in or plugin.
    public struct Detection: Equatable, Sendable {
        public let runtime: AgentRuntime
        /// The name to show: the built-in's name or the plugin's title.
        public let title: String
        /// The executable found (or the override given); nil when none is.
        public let executable: String?
        /// Hermes only: whether `~/.hermes/.env` enables the API server the companion talks to.
        public let apiServerEnabled: Bool?
        public let installCommand: String?
        public let loginCommand: String?
        public let loginTitle: String?
        /// A plugin's one-line note.
        public let note: String?
        /// A sentence describing the runtime, and its documentation.
        public let summary: String?
        public let docsURL: URL?
        /// The plugin's `requires` that were not found; the plugin is unavailable until they are.
        public let missingRequirements: [String]
        /// Why a plugin cannot be used even if its executable is found (the trust rule or an
        /// invalid `runtime.json`), or why no plugin of this id exists.
        public let refusal: String?
        /// The plugin; nil for a built-in runtime.
        public let plugin: RuntimePlugin?

        public var isInstalled: Bool { executable != nil }
        /// Installed, not refused and with everything it requires: `BrainService` gives the
        /// companion only these plugins.
        public var isAvailable: Bool { unavailableReason == nil }

        /// Why the runtime cannot be used, or nil when it can.
        public var unavailableReason: String? {
            if let refusal { return refusal }
            guard executable != nil else { return "\(title) is not installed." }
            guard missingRequirements.isEmpty else {
                return "\(title) needs \(missingRequirements.joined(separator: ", ")), which \(missingRequirements.count == 1 ? "is" : "are") not installed."
            }
            return nil
        }
    }

    /// Detects one runtime: a built-in from its catalog entry, anything else from its plugin
    /// folder in `locator.runtimesDirectory`.
    public static func detect(
        _ runtime: AgentRuntime, locator: ExecutableLocator, override: String = "",
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> Detection {
        guard let entry = entry(for: runtime) else {
            let folder = "\(locator.runtimesDirectory)/\(runtime.rawValue)"
            let plugin = RuntimePlugin.read(runtime.rawValue, in: folder)
                ?? RuntimePlugin(refused: runtime, directory: folder, reason: "No runtime plugin \(runtime.rawValue) is installed")
            return detect(plugin: plugin, locator: locator, override: override)
        }
        let executable = locator.locate(entry.executable, override: override)
        var apiServer: Bool?
        if runtime == .hermes {
            let hermesHome = ProcessInfo.processInfo.environment["HERMES_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(locator.home)/.hermes"
            apiServer = readFile("\(hermesHome)/.env").map(hermesAPIServerEnabled) ?? false
        }
        return Detection(
            runtime: runtime, title: runtime.displayName, executable: executable, apiServerEnabled: apiServer,
            installCommand: entry.installCommand, loginCommand: entry.loginCommand, loginTitle: entry.loginTitle,
            note: nil, summary: entry.summary, docsURL: entry.docsURL, missingRequirements: [], refusal: nil, plugin: nil)
    }

    /// Detects a plugin: its executable (`override` wins, then its `runtime.json` path or name,
    /// searched like the built-ins' tools and then in its `searchPaths`) and its `requires`
    /// (searched like the built-ins' tools).
    /// A refused plugin is reported with its reason and nothing located.
    public static func detect(plugin: RuntimePlugin, locator: ExecutableLocator, override: String = "") -> Detection {
        var executable: String?
        var missing: [String] = []
        if plugin.isTrusted {
            let explicit = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if explicit.isEmpty, plugin.executable.hasPrefix("/") || plugin.executable.hasPrefix("~/") {
                executable = locator.locate(plugin.executable, override: plugin.executable)
            } else {
                executable = locator.locate(plugin.executable, override: override,
                                            additionalDirectories: plugin.searchPaths)
            }
            missing = plugin.requires.filter { locator.locate($0) == nil }
        }
        return Detection(
            runtime: plugin.runtime, title: plugin.title, executable: executable, apiServerEnabled: nil,
            installCommand: plugin.installCommand, loginCommand: plugin.loginCommand,
            loginTitle: plugin.isTrusted ? plugin.loginTitle ?? "Log In" : nil, note: plugin.note,
            summary: plugin.summary, docsURL: plugin.docsURL,
            missingRequirements: missing, refusal: plugin.refusal, plugin: plugin)
    }

    /// The built-in runtimes, then every plugin in `locator.runtimesDirectory` by id (a folder
    /// named like a built-in is left out). `overrides` are executable paths by runtime.
    public static func detectAll(
        locator: ExecutableLocator, overrides: [AgentRuntime: String] = [:],
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> [Detection] {
        AgentRuntime.builtIns.map { detect($0, locator: locator, override: overrides[$0] ?? "", readFile: readFile) }
            + locator.runtimePlugins().filter { !$0.runtime.isBuiltIn }
            .map { detect(plugin: $0, locator: locator, override: overrides[$0.runtime] ?? "") }
    }

    /// Reads `API_SERVER_ENABLED` from a Hermes `.env` file (read only; never modified).
    public static func hermesAPIServerEnabled(_ contents: String) -> Bool {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "API_SERVER_ENABLED" else {
                continue
            }
            let value = line[line.index(after: equals)...]
                .split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased()
            return ["true", "1", "yes", "on"].contains(cleaned)
        }
        return false
    }
}
