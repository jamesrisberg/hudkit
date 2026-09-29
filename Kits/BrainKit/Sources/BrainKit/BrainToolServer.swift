import Foundation

/// A stdio MCP server the host gives its brain: the agent can call its tools. The companion
/// passes it to Codex (`-c mcp_servers.<name>.…`), Claude Code and mclaude (`--mcp-config`);
/// Hermes cannot use it and says so in the snapshot (`AgentSessionSnapshot.toolServers`).
public struct BrainToolServer: Codable, Equatable, Sendable {
    /// Letters, digits, `_` and `-`, at most 64; the agent sees its tools as
    /// `mcp__<name>__<tool>` (Claude) or under this server name (Codex).
    public var name: String
    /// The executable: an absolute path, or a name the agent finds on its PATH.
    public var command: String
    public var arguments: [String]
    /// Set in the server's environment on top of what the agent passes on.
    public var environment: [String: String]
    /// Ask the user before each tool call. When false the tools run without asking, while
    /// the agent's other actions keep their approval policy.
    public var requireApproval: Bool

    public init(name: String, command: String, arguments: [String] = [], environment: [String: String] = [:],
                requireApproval: Bool = false) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.requireApproval = requireApproval
    }

    /// The companion's naming rule (`tool-servers.mjs`).
    public static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count)
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
            && name != "brainkit_permissions"
    }
}

/// The host's tool servers as the companion reports them for the running runtime.
public struct AgentToolServerStatus: Codable, Equatable, Sendable {
    /// The configured server names.
    public let names: [String]
    /// Whether the running runtime gives them to the agent.
    public let active: Bool
    /// Why they are not available (Hermes), as a sentence to show; nil otherwise.
    public let note: String?

    public init(names: [String], active: Bool, note: String?) {
        self.names = names
        self.active = active
        self.note = note
    }
}
