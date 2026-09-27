import Foundation

/// Files dropped on a panel's MacHUD dock button, delivered as `action drop paths=<p1|p2>`.
///
/// Each path is percent-encoded (everything except ASCII letters, digits and `/-._~`), then
/// the paths are joined with `|`. So `|`, `%`, `=`, spaces, newlines and non-ASCII names all
/// survive the socket and the CLI's `k=v` parsing. Only panels whose manifest `capabilities`
/// include `acceptsFileDrop` receive drops.
///
/// ```swift
/// func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
///     guard name == HUDDrop.action else { ... }
///     importFiles(HUDDrop.urls(from: args))
///     done(["ok": true])
/// }
/// ```
public enum HUDDrop {
    /// The action verb: `action drop ...`.
    public static let action = "drop"
    /// The argument holding the encoded paths.
    public static let pathsKey = "paths"
    /// The manifest capability that opts a panel into drops.
    public static let capability = "acceptsFileDrop"

    private static let unreserved = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._~")

    /// `[/a/b c, /x|y]` → `"/a/b%20c|/x%7Cy"`. File URLs contribute their path.
    public static func encode(_ urls: [URL]) -> String {
        urls.map { url in
            let path = url.isFileURL ? url.path : url.absoluteString
            return path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
        }.joined(separator: "|")
    }

    /// The inverse of `encode`: file URLs, empty segments dropped. A segment that is not valid
    /// percent-encoding is taken literally, and `file://` URLs are accepted as-is.
    public static func decode(_ string: String) -> [URL] {
        string.split(separator: "|", omittingEmptySubsequences: true).compactMap { raw in
            let segment = String(raw)
            if segment.hasPrefix("file://"), let url = URL(string: segment) { return url }
            let path = segment.removingPercentEncoding ?? segment
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
    }

    /// The args for `action drop` (MacHUD's side), plus `id=` when a panel is named.
    public static func args(for urls: [URL], panel: String? = nil) -> [String: String] {
        var a = [pathsKey: encode(urls)]
        if let panel { a["id"] = panel }
        return a
    }

    /// The dropped files in an `action drop` payload (empty if there are none).
    public static func urls(from args: [String: String]) -> [URL] {
        args[pathsKey].map(decode) ?? []
    }
}
