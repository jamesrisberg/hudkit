import Foundation

/// Client for a `HUDSocketServer` (or any server speaking the same JSON-lines shape).
///
/// Each `request` opens a connection, sends one line, reads one line and closes.
/// `subscribe` keeps a connection open and delivers pushed lines on a background thread.
public struct HUDSocketClient: Sendable {
    public let path: String
    /// Receive timeout for `request`, in seconds (0 = wait forever).
    public var timeout: TimeInterval

    public init(path: String, timeout: TimeInterval = 95) {
        self.path = path
        self.timeout = timeout
    }

    /// Convenience for the MacHUD convention: `HUDSocketClient(name: "wormhole")`.
    public init(name: String, timeout: TimeInterval = 95) {
        self.init(path: HUDSocket.path(for: name), timeout: timeout)
    }

    /// True when something accepts connections at `path`.
    public var isServerRunning: Bool {
        guard let fd = try? HUDSocket.connect(to: path) else { return false }
        close(fd)
        return true
    }

    /// Sends `{"command": command, "args": args}` and returns the raw response line.
    public func requestLine(_ command: String, args: [String: Any] = [:]) throws -> String {
        let fd = try HUDSocket.connect(to: path)
        defer { close(fd) }
        if timeout > 0 { Self.setReceiveTimeout(fd, timeout) }
        guard HUDSocket.writeAll(fd, HUDSocket.line(["command": command, "args": args])) else {
            throw HUDSocketError.system("write", errno)
        }
        guard let line = HUDLineReader(fd: fd).next() else {
            throw (errno == EAGAIN || errno == EWOULDBLOCK) ? HUDSocketError.timeout : HUDSocketError.noResponse
        }
        return line
    }

    /// Sends a command and decodes the JSON object response.
    public func request(_ command: String, args: [String: Any] = [:]) throws -> [String: Any] {
        let line = try requestLine(command, args: args)
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HUDSocketError.malformedResponse(line)
        }
        return obj
    }

    /// Opens a `subscribe` stream. `onEvent` is called on a background thread for every
    /// pushed object; `onClose` once when the stream ends (server gone or `cancel()`).
    /// Throws if the server does not acknowledge the subscription.
    public func subscribe(events: [String]? = nil,
                          onEvent: @escaping @Sendable ([String: Any]) -> Void,
                          onClose: (@Sendable () -> Void)? = nil) throws -> HUDSubscription {
        let fd = try HUDSocket.connect(to: path)
        var args: [String: Any] = [:]
        if let events { args["events"] = events.joined(separator: ",") }
        guard HUDSocket.writeAll(fd, HUDSocket.line(["command": "subscribe", "args": args])) else {
            close(fd); throw HUDSocketError.system("write", errno)
        }
        if timeout > 0 { Self.setReceiveTimeout(fd, timeout) }
        let reader = HUDLineReader(fd: fd)
        guard let ack = reader.next(),
              let data = ack.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true else {
            close(fd); throw HUDSocketError.malformedResponse("subscribe was not acknowledged")
        }
        Self.setReceiveTimeout(fd, 0)
        let subscription = HUDSubscription(fd: fd)
        let thread = Thread {
            while let line = reader.next() {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                onEvent(obj)
            }
            subscription.finish()
            onClose?()
        }
        thread.name = "HUDSocketClient.subscribe"
        thread.start()
        return subscription
    }

    private static func setReceiveTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Command-line front end

    /// The body of an app CLI (`<repo> <command> [key=value ...]`, see docs/CLI.md) and of
    /// MacHUD's `MacHUD ctl <command> ...`: `arguments` start at the command. Sends it,
    /// pretty-prints the JSON response (sorted keys) to stdout and returns an exit status (0 ok,
    /// 1 `ok: false`/not running/error, 2 no command). Arguments are parsed by `parseArguments`.
    public static func runCLI(path: String, arguments: [String], appName: String) -> Int32 {
        guard let command = arguments.first else {
            FileHandle.standardError.write(Data("usage: \(appName) ctl <command> [key=value ...]\n".utf8))
            return 2
        }
        let args = parseArguments(Array(arguments.dropFirst()))
        let line: String
        do {
            line = try HUDSocketClient(path: path, timeout: 0).requestLine(command, args: args)
        } catch {
            FileHandle.standardError.write(Data((failureMessage(for: error, path: path, appName: appName) + "\n").utf8))
            return 1
        }
        if let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: pretty, as: UTF8.self))
            if let dict = obj as? [String: Any], dict["ok"] as? Bool == false { return 1 }
            return 0
        }
        print(line)
        return 1
    }

    /// The line `runCLI` prints when the request fails: "not running" only when nothing listens
    /// at `path`; a path over `HUDSocket.maxPathLength` names the real problem (no server can
    /// bind it, so "not running" would send the reader looking in the wrong place).
    public static func failureMessage(for error: Error, path: String, appName: String) -> String {
        switch error {
        case HUDSocketError.notRunning:
            return "\(appName) is not running (no socket at \(path))"
        case HUDSocketError.pathTooLong:
            return "\(appName): socket path too long (\(path.utf8.count) bytes, the limit is \(HUDSocket.maxPathLength)): \(path)"
                + "; use a shorter socket name"
        default:
            return "\(appName): \(error)"
        }
    }

    /// `["a=1", "flag", "b=x=y"]` -> `["a": "1", "flag": "1", "b": "x=y", "_": "flag"]`.
    /// The first bare word is also recorded under `_` so verbs such as
    /// `action select-set name=x` keep their sub-verb even when a `name=` payload is present.
    public static func parseArguments(_ arguments: [String]) -> [String: String] {
        var args: [String: String] = [:]
        for kv in arguments {
            if let eq = kv.firstIndex(of: "=") {
                args[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            } else {
                args[kv] = "1"
                if args["_"] == nil { args["_"] = kv }
            }
        }
        return args
    }
}

/// A live `subscribe` stream. Cancel it to disconnect.
public final class HUDSubscription: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var open = true

    init(fd: Int32) { self.fd = fd }

    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return open }

    /// Disconnects; the reader thread then ends and `onClose` fires.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard open else { return }
        shutdown(fd, SHUT_RDWR)
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard open else { return }
        open = false
        close(fd)
    }

    deinit { cancel() }
}
