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
    }

    init(runtime: AgentRuntime, directory: String, manifest: Manifest) {
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
    }

    /// Reads the plugin in `folder`, named `id`: the same checks, in the same order and with
    /// the same reasons, as the companion makes before importing the adapter (`plugins.mjs`).
    public static func read(_ id: String, in folder: String) -> RuntimePlugin? {
        guard let runtime = AgentRuntime(rawValue: id) else { return nil }
        do {
            return RuntimePlugin(runtime: runtime, directory: folder, manifest: try inspect(runtime, folder: folder))
        } catch let refusal as Refusal {
            return RuntimePlugin(refused: runtime, directory: folder, reason: refusal.reason)
        } catch {
            return RuntimePlugin(refused: runtime, directory: folder, reason: error.localizedDescription)
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

    private static func inspect(_ runtime: AgentRuntime, folder directory: String) throws -> Manifest {
        let id = runtime.rawValue
        if runtime.isBuiltIn { throw Refusal(reason: "\(id) is a built-in runtime") }
        let folder = URL(fileURLWithPath: directory).standardized.path
        try trusted(folder, "The plugin folder \(directory)", directory: true)
        let descriptor = folder + "/runtime.json"
        try trusted(descriptor, "runtime.json", directory: false)
        guard let data = FileManager.default.contents(atPath: descriptor),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else { throw Refusal(reason: "runtime.json is not valid JSON") }
        let manifest = try readManifest(object, id: id)
        let label = "The adapter \"\(manifest.adapter.prefix(128))\""
        let adapter = URL(fileURLWithPath: folder + "/" + manifest.adapter).standardized.path
        guard !manifest.adapter.hasPrefix("/"), adapter.hasPrefix(folder + "/") else {
            throw Refusal(reason: "\(label) is outside the plugin folder")
        }
        try trusted(adapter, label, directory: false)
        // A link in a folder between the plugin folder and the adapter.
        guard let real = resolved(adapter), let realFolder = resolved(folder), real.hasPrefix(realFolder + "/") else {
            throw Refusal(reason: "\(label) is outside the plugin folder")
        }
        return manifest
    }

    /// The path with every link resolved, or nil when it does not exist.
    private static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// The trust rule, checked without following links: not a symbolic link, owned by this
    /// user (the effective user id) and writable by no one else.
    private static func trusted(_ path: String, _ label: String, directory: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Refusal(reason: "\(label) is missing") }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { throw Refusal(reason: "\(label) is a symbolic link") }
        guard directory ? type == S_IFDIR : type == S_IFREG else {
            throw Refusal(reason: "\(label) is not a \(directory ? "folder" : "regular file")")
        }
        guard info.st_uid == geteuid() else { throw Refusal(reason: "\(label) is not owned by you") }
        guard info.st_mode & 0o022 == 0 else { throw Refusal(reason: "\(label) is writable by other users") }
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
    public func runtimePlugins() -> [RuntimePlugin] {
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
