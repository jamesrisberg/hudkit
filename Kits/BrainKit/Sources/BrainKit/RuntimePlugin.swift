import Foundation

/// A runtime plugin's folder as BrainKit found it: `<runtimesDirectory>/<id>/` with
/// `runtime.json` and an adapter module (the companion README, "Runtime plugins", has the
/// contract). A plugin that breaks the trust rule or whose `runtime.json` is invalid is still
/// reported, with `refusal` saying why and nothing read from its files.
public struct RuntimePlugin: Equatable, Sendable {
    /// The `runtime.json` schema this BrainKit reads.
    public static let schema = 1

    public let runtime: AgentRuntime
    /// `<runtimesDirectory>/<id>`, as passed to the companion.
    public let directory: String
    /// The name to show; the id when the plugin is refused.
    public let title: String
    public let version: String
    /// The adapter module, relative to `directory`.
    public let adapter: String
    /// The tool to find: a name, or an absolute or `~/` path.
    public let executable: String
    /// Folders searched for `executable` after PATH and the common install folders.
    public let searchPaths: [String]
    public let installCommand: String?
    public let loginCommand: String?
    public let loginTitle: String?
    /// Other tools the runtime needs.
    public let requires: [String]
    /// One line a host may show beside the runtime.
    public let note: String?
    /// A sentence describing the runtime, and where its documentation is.
    public let summary: String?
    public let docsURL: URL?
    /// Why the plugin cannot be used; nil when it is trusted and its `runtime.json` is valid.
    public let refusal: String?
    /// When the adapter file last changed; with `version`, what makes `BrainService` restart
    /// the companion after an upgrade.
    public let adapterModified: Date?

    public var id: String { runtime.rawValue }
    public var isTrusted: Bool { refusal == nil }

    /// A refused plugin: only its id is known.
    init(refused runtime: AgentRuntime, directory: String, reason: String) {
        self.runtime = runtime
        self.directory = directory
        title = runtime.rawValue
        version = ""
        adapter = ""
        executable = ""
        searchPaths = []
        installCommand = nil
        loginCommand = nil
        loginTitle = nil
        requires = []
        note = nil
        summary = nil
        docsURL = nil
        refusal = reason
        adapterModified = nil
    }

    init(runtime: AgentRuntime, directory: String, manifest: Manifest, adapterModified: Date) {
        self.runtime = runtime
        self.directory = directory
        title = manifest.title
        version = manifest.version
        adapter = manifest.adapter
        executable = manifest.executable
        searchPaths = manifest.searchPaths
        installCommand = manifest.installCommand
        loginCommand = manifest.loginCommand
        loginTitle = manifest.loginTitle
        requires = manifest.requires
        note = manifest.note
        summary = manifest.summary
        docsURL = manifest.docsURL
        refusal = nil
        self.adapterModified = adapterModified
    }

    /// Reads the plugin in `folder`, named `id`: the same checks, in the same order and with
    /// the same reasons, as the companion makes before importing the adapter (`plugins.mjs`).
    /// Nil when `id` is not a runtime id.
    public static func read(_ id: String, in folder: String) -> RuntimePlugin? {
        guard let runtime = AgentRuntime(rawValue: id) else { return nil }
        let normalized = folder.hasPrefix("/") ? URL(fileURLWithPath: folder).standardized.path : folder
        do {
            let (manifest, modified) = try inspect(runtime, folder: normalized)
            return RuntimePlugin(runtime: runtime, directory: normalized, manifest: manifest, adapterModified: modified)
        } catch let refusal as Refusal {
            return RuntimePlugin(refused: runtime, directory: normalized, reason: refusal.reason)
        } catch {
            return RuntimePlugin(refused: runtime, directory: normalized, reason: error.localizedDescription)
        }
    }

    // MARK: Checks

    struct Refusal: Error { let reason: String }

    struct Manifest {
        var title = "", version = "", adapter = "", executable = ""
        var searchPaths: [String] = [], requires: [String] = []
        var installCommand: String?, loginCommand: String?, loginTitle: String?, note: String?, summary: String?
        var docsURL: URL?
    }

    /// At most this many entries in a plugin folder; a larger tree is refused rather than walked.
    public static let maximumEntries = 4096

    private static func inspect(_ runtime: AgentRuntime, folder: String) throws -> (Manifest, Date) {
        let id = runtime.rawValue
        if runtime.isBuiltIn { throw Refusal(reason: "\(id) is a built-in runtime") }
        guard folder.hasPrefix("/") else { throw Refusal(reason: "The plugin folder \(folder.prefix(256)) is not an absolute path") }
        let name = (folder as NSString).lastPathComponent
        guard name == id else { throw Refusal(reason: "The plugin folder \"\(name.prefix(64))\" is not named \"\(id)\"") }
        let parent = (folder as NSString).deletingLastPathComponent
        _ = try trusted(parent, "The runtimes folder \(parent)", .directory)
        _ = try trusted(folder, "The plugin folder \(folder)", .directory)
        let descriptor = folder + "/runtime.json"
        _ = try trusted(descriptor, "runtime.json", .file)
        guard let data = FileManager.default.contents(atPath: descriptor) else {
            throw Refusal(reason: "runtime.json cannot be read")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            throw Refusal(reason: "runtime.json is not valid JSON")
        }
        let manifest = try readManifest(object, id: id)
        let label = "The adapter \"\(manifest.adapter.prefix(128))\""
        let adapter = URL(fileURLWithPath: folder + "/" + manifest.adapter).standardized.path
        guard !manifest.adapter.hasPrefix("/"), adapter.hasPrefix(folder + "/") else {
            throw Refusal(reason: "\(label) is outside the plugin folder")
        }
        guard adapter.hasSuffix(".mjs") else { throw Refusal(reason: "\(label) is not an .mjs module") }
        let info = try trusted(adapter, label, .file)
        try trustedTree(folder)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (manifest, modified)
    }

    private enum Kind { case directory, file, entry }

    /// The trust rule for one entry, checked without following links: not a symbolic link,
    /// owned by this user (the effective user id) and writable by no one else.
    private static func trusted(_ path: String, _ label: String, _ kind: Kind) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw Refusal(reason: errno == ENOENT ? "\(label) is missing" : "\(label) cannot be read")
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { throw Refusal(reason: "\(label) is a symbolic link") }
        let fits: Bool
        switch kind {
        case .directory: fits = type == S_IFDIR
        case .file: fits = type == S_IFREG
        case .entry: fits = type == S_IFDIR || type == S_IFREG
        }
        guard fits else {
            let wanted = kind == .directory ? "folder" : kind == .file ? "regular file" : "regular file or folder"
            throw Refusal(reason: "\(label) is not a \(wanted)")
        }
        guard info.st_uid == geteuid() else { throw Refusal(reason: "\(label) is not owned by you") }
        guard info.st_mode & 0o022 == 0 else { throw Refusal(reason: "\(label) is writable by other users") }
        return info
    }

    /// Every entry under the plugin folder, depth first in name order, checked against the
    /// trust rule: a plugin's adapter may import any file beside it.
    private static func trustedTree(_ folder: String) throws {
        var count = 0
        func walk(_ relative: String) throws {
            let path = relative.isEmpty ? folder : folder + "/" + relative
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                throw Refusal(reason: "\"\(relative)\" in the plugin folder cannot be read")
            }
            for name in names.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }) {
                count += 1
                if count > maximumEntries { throw Refusal(reason: "The plugin folder has more than \(maximumEntries) entries") }
                let entry = relative.isEmpty ? name : relative + "/" + name
                let info = try trusted(folder + "/" + entry, "\"\(entry.prefix(256))\" in the plugin folder", .entry)
                if info.st_mode & S_IFMT == S_IFDIR { try walk(entry) }
            }
        }
        try walk("")
    }

    private static func readManifest(_ object: Any, id: String) throws -> Manifest {
        guard let value = object as? [String: Any] else { throw Refusal(reason: "runtime.json must hold an object") }
        let schema = value["schema"]
        guard let number = schema as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(Self.schema)
        else {
            let shown = schema.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
                .map { String(decoding: $0, as: UTF8.self) } ?? "undefined"
            throw Refusal(reason: "runtime.json has schema \(shown.prefix(16)); this BrainKit reads schema \(Self.schema)")
        }
        guard value["id"] as? String == id else {
            let shown = (value["id"].map { "\($0)" } ?? "undefined").prefix(40)
            throw Refusal(reason: "runtime.json's id \"\(shown)\" does not match its folder \"\(id)\"")
        }
        func string(_ key: String) throws -> String {
            guard let text = value[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Refusal(reason: "runtime.json: \"\(key)\" must be a non-empty string")
            }
            return text
        }
        func list(_ key: String) throws -> [String] {
            guard let raw = value[key] else { return [] }
            guard let items = raw as? [Any], let strings = items as? [String], !strings.contains(where: \.isEmpty) else {
                throw Refusal(reason: "runtime.json: \"\(key)\" must be a list of strings")
            }
            return strings
        }
        func optional(_ key: String) throws -> String? {
            guard let raw = value[key] else { return nil }
            guard let text = raw as? String else { throw Refusal(reason: "runtime.json: \"\(key)\" must be a string") }
            return text
        }
        func link(_ key: String) throws -> URL? {
            guard let text = try optional(key) else { return nil }
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw Refusal(reason: "runtime.json: \"\(key)\" must be an http or https URL")
            }
            return url
        }
        var manifest = Manifest()
        manifest.title = try string("title")
        manifest.version = try string("version")
        manifest.adapter = try string("adapter")
        manifest.executable = try string("executable")
        manifest.searchPaths = try list("searchPaths")
        manifest.requires = try list("requires")
        manifest.installCommand = try optional("installCommand")
        manifest.loginCommand = try optional("loginCommand")
        manifest.loginTitle = try optional("loginTitle")
        manifest.note = try optional("note")
        manifest.summary = try optional("summary")
        manifest.docsURL = try link("docsURL")
        return manifest
    }
}

extension ExecutableLocator {
    /// The plugins in `runtimesDirectory`, by id: every folder whose name is a runtime id
    /// (hidden entries, files and other names are skipped), refused ones included.
    /// None when `runtimesDirectory` is not absolute (`runtimesDirectoryProblem` says why).
    public func runtimePlugins() -> [RuntimePlugin] {
        guard runtimesDirectoryProblem == nil else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: runtimesDirectory)) ?? []
        return names.sorted().compactMap { name in
            let folder = "\(runtimesDirectory)/\(name)"
            var isDirectory: ObjCBool = false
            guard AgentRuntime.isValidID(name),
                  FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            return RuntimePlugin.read(name, in: folder)
        }
    }
}
