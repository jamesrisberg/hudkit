import Foundation

/// The brain a host app lets the user choose, with each runtime's options: the value a
/// Brain settings tab binds to. Decoding fills anything missing or unknown with its
/// default, so a stored value survives fields being added.
///
/// Secrets stay out of it: the companion reads the Hermes API key from Hermes' own
/// `~/.hermes/.env`, and the companion token lives in the state directory.
public struct BrainSettings: Codable, Equatable, Sendable {
    public struct CodexOptions: Codable, Equatable, Sendable {
        /// Path to the `codex` executable; empty finds it on PATH and the common install folders.
        public var executablePath: String

        public init(executablePath: String = "") { self.executablePath = executablePath }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            executablePath = try values.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        }
    }

    public struct ClaudeOptions: Codable, Equatable, Sendable {
        /// Path to the `claude` executable; empty finds it on PATH and the common install folders.
        public var executablePath: String

        public init(executablePath: String = "") { self.executablePath = executablePath }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            executablePath = try values.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        }
    }

    public struct HermesOptions: Codable, Equatable, Sendable {
        /// The `hermes gateway` API server; empty uses the port in `~/.hermes/.env`.
        public var url: String

        public init(url: String = "") { self.url = url }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
        }
    }

    /// The brain turns go to.
    public var runtime: AgentRuntime
    /// The agent's workspace folder; empty until the user picks one.
    public var workspacePath: String
    /// The name the voice instructions give the assistant; empty names none.
    public var assistantName: String
    /// Path to `node` (22 or later); empty finds it on PATH and the common install folders.
    public var nodePath: String
    public var codex: CodexOptions
    public var claude: ClaudeOptions
    public var hermes: HermesOptions

    public init(runtime: AgentRuntime = .codex, workspacePath: String = "", assistantName: String = "",
                nodePath: String = "", codex: CodexOptions = CodexOptions(),
                claude: ClaudeOptions = ClaudeOptions(), hermes: HermesOptions = HermesOptions()) {
        self.runtime = runtime
        self.workspacePath = workspacePath
        self.assistantName = assistantName
        self.nodePath = nodePath
        self.codex = codex
        self.claude = claude
        self.hermes = hermes
    }

    private enum CodingKeys: String, CodingKey {
        case runtime, workspacePath, assistantName, nodePath, codex, claude, hermes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let runtime = try values.decodeIfPresent(String.self, forKey: .runtime)
        self.runtime = runtime.flatMap(AgentRuntime.init(rawValue:)) ?? .codex
        workspacePath = try values.decodeIfPresent(String.self, forKey: .workspacePath) ?? ""
        assistantName = try values.decodeIfPresent(String.self, forKey: .assistantName) ?? ""
        nodePath = try values.decodeIfPresent(String.self, forKey: .nodePath) ?? ""
        codex = try values.decodeIfPresent(CodexOptions.self, forKey: .codex) ?? CodexOptions()
        claude = try values.decodeIfPresent(ClaudeOptions.self, forKey: .claude) ?? ClaudeOptions()
        hermes = try values.decodeIfPresent(HermesOptions.self, forKey: .hermes) ?? HermesOptions()
    }

    /// The launch configuration for these settings. The host chooses where the companion
    /// keeps its state and which loopback port it listens on.
    public func serviceConfiguration(stateDirectory: String, port: Int) -> BrainServiceConfiguration {
        BrainServiceConfiguration(
            runtime: runtime, workingDirectory: workspacePath, stateDirectory: stateDirectory, port: port,
            nodePath: nodePath, codexPath: codex.executablePath, claudePath: claude.executablePath,
            hermesURL: hermes.url, assistantName: assistantName)
    }
}
