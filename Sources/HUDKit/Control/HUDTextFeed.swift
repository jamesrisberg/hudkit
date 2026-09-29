import Foundation

/// The `text-feed` capability: a panel that keeps a history of finished text (a dictation
/// transcript, an agent reply, ...) and accepts new items without treating them as clipboard
/// events. A panel opts in by listing `HUDTextFeed.capability` in its manifest `capabilities`,
/// then answers on its own socket:
///
/// - `feed {action:"add", text, source, title?, date?}` (`HUDTextFeed.addAction`): store the
///   item, replying `{"ok": true, "id": <string>}` (or `{"ok": false, "error": ...}` if it
///   cannot). `source` is a short label the item is tagged with (e.g. `"Dictation"`, `"Agent"`);
///   the panel must not treat the item as a clipboard write.
///
/// See `docs/CONTRACT.md` § Text feed. A client that wants "whoever keeps a text feed" without
/// naming an app asks MacHUD instead (`feed add text= source= [title=]`), which finds every
/// panel declaring this capability that is already running and forwards to each (never
/// launching one just to feed it).
///
/// ```swift
/// control.register(HUDTextFeed.command) { args, done in
///     guard (args["action"] ?? HUDTextFeed.addAction) == HUDTextFeed.addAction,
///           let text = args["text"], let source = args["source"] else {
///         done(["ok": false, "error": "feed add needs text= and source="]); return
///     }
///     let id = history.add(text: text, source: source, title: args["title"], date: args["date"])
///     done(["ok": true, "id": id])
/// }
/// ```
public enum HUDTextFeed {
    /// The manifest capability a panel lists to accept fed text.
    public static let capability = "text-feed"
    /// The top-level socket command, registered by the provider itself (like `state`), and the
    /// name MacHUD's broker verb reuses.
    public static let command = "feed"
    /// The command's only action so far.
    public static let addAction = "add"

    /// The args for `feed action=add text= source= [title=] [date=]`.
    public static func addArgs(text: String, source: String, title: String? = nil, date: String? = nil) -> [String: String] {
        var args = ["action": addAction, "text": text, "source": source]
        if let title { args["title"] = title }
        if let date { args["date"] = date }
        return args
    }
}
