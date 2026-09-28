import Foundation

/// Finds command-line tools the way a login shell would, without running one. Apps
/// launched from Finder get a minimal PATH, so common install folders are searched too.
/// Every input is injectable for tests.
public struct ExecutableLocator {
    public var path: String
    public var home: String
    public var isExecutable: (String) -> Bool
    public var contentsOfDirectory: (String) -> [String]

    public init(path: String, home: String, isExecutable: @escaping (String) -> Bool,
                contentsOfDirectory: @escaping (String) -> [String]) {
        self.path = path
        self.home = home
        self.isExecutable = isExecutable
        self.contentsOfDirectory = contentsOfDirectory
    }

    public static var live: ExecutableLocator {
        ExecutableLocator(
            path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
            },
            contentsOfDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] })
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
    /// silently replaced, so the caller can report it.
    public func locate(_ name: String, override: String = "") -> String? {
        let explicit = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            let expanded = explicit.hasPrefix("~/") ? home + explicit.dropFirst() : explicit
            return isExecutable(expanded) ? expanded : nil
        }
        for directory in searchDirectories {
            let candidate = "\(directory)/\(name)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
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

    public static func entry(for runtime: AgentRuntime) -> Entry {
        entries.first { $0.runtime == runtime }!
    }

    public struct Detection: Equatable, Sendable {
        public let runtime: AgentRuntime
        public let executable: String?
        /// Hermes only: whether `~/.hermes/.env` enables the API server the companion talks to.
        public let apiServerEnabled: Bool?
        public var isInstalled: Bool { executable != nil }
    }

    public static func detect(
        _ runtime: AgentRuntime, locator: ExecutableLocator, override: String = "",
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> Detection {
        let executable = locator.locate(entry(for: runtime).executable, override: override)
        var apiServer: Bool?
        if runtime == .hermes {
            let hermesHome = ProcessInfo.processInfo.environment["HERMES_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(locator.home)/.hermes"
            apiServer = readFile("\(hermesHome)/.env").map(hermesAPIServerEnabled) ?? false
        }
        return Detection(runtime: runtime, executable: executable, apiServerEnabled: apiServer)
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
