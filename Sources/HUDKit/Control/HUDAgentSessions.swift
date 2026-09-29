import Foundation

/// The `agent-sessions` capability: a panel that shows agent sessions (mechaclaude, Codex, ...)
/// and can be told to show and focus one. A panel opts in by listing `HUDAgentSessions.capability`
/// in its manifest `capabilities`, then answers two things on its own socket:
///
/// - `action name=open-session id=<sessionKey>` (`HUDAgentSessions.openSessionAction`): show and
///   focus that session, replying `{"ok": true}` (or `{"ok": false, "error": ...}` if it cannot).
/// - `sessions` (`HUDAgentSessions.sessionsCommand`, a top-level command like `state`): the
///   sessions it currently shows, `{"ok": true, "sessions": [{"id", "title", "cwd", "state"}, ...]}`.
///
/// See `docs/CONTRACT.md` § Agent sessions. A client that wants "whoever shows agent sessions"
/// without naming an app asks MacHUD instead (`sessions providers`, `sessions open id=`), which
/// finds the panel(s) declaring this capability and forwards to one.
///
/// ```swift
/// func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
///     guard name == HUDAgentSessions.openSessionAction, let id = args["id"] else { ... }
///     dashboard.focus(sessionKey: id)
///     done(["ok": true])
/// }
/// control.register(HUDAgentSessions.sessionsCommand) { _, done in
///     done(["ok": true, "sessions": sessions.map(\.json)])
/// }
/// ```
public enum HUDAgentSessions {
    /// The manifest capability a panel lists to offer agent sessions.
    public static let capability = "agent-sessions"
    /// The `action` verb that shows and focuses a session.
    public static let openSessionAction = "open-session"
    /// The top-level socket command that lists current sessions.
    public static let sessionsCommand = "sessions"

    /// The args for `action name=open-session id=<sessionKey>`.
    public static func openSessionArgs(id sessionKey: String) -> [String: String] {
        ["name": openSessionAction, "id": sessionKey]
    }
}

/// One entry of a provider's `sessions` reply.
public struct HUDAgentSession: Equatable, Sendable {
    /// The session's key (e.g. mechaclaude's `claude:<sessionId>`), as passed to `open-session`.
    public var id: String
    public var title: String
    public var cwd: String?
    /// Free-form, provider-defined (e.g. `idle`, `running`, `requires_action`).
    public var state: String

    public init(id: String, title: String, cwd: String? = nil, state: String) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.state = state
    }

    /// Parses one entry of a `sessions` reply's `sessions` array; nil if `id` or `state` is
    /// missing. `title` falls back to `id`.
    public static func parse(_ json: [String: Any]) -> HUDAgentSession? {
        guard let id = json["id"] as? String, let state = json["state"] as? String else { return nil }
        return HUDAgentSession(id: id, title: json["title"] as? String ?? id, cwd: json["cwd"] as? String, state: state)
    }

    /// Parses a whole `{"ok": true, "sessions": [...]}` reply; entries that do not parse (or are
    /// not even an object) are skipped, not fatal for the rest.
    public static func parseAll(_ reply: [String: Any]) -> [HUDAgentSession] {
        (reply[sessionsKey] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(parse) }
    }

    static let sessionsKey = "sessions"

    public var json: [String: Any] {
        var d: [String: Any] = ["id": id, "title": title, "state": state]
        if let cwd { d["cwd"] = cwd }
        return d
    }
}
