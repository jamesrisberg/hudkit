import Foundation

/// JSON-lines control server on a Unix socket.
///
/// Wire format, one JSON object per line:
/// - request: `{"command": "...", "args": {...}}` (arg values are delivered to handlers as strings)
/// - response: `{"ok": true, ...}` or `{"ok": false, "error": "..."}`
///
/// Each connection carries one request and one response, then the server closes it, so
/// `echo '{"command":"ping"}' | nc -U <path>` works. The exception is `subscribe`: the
/// server acknowledges with `{"ok": true, "subscribed": true}` and keeps the connection
/// open, pushing every `publish(_:payload:)` as a line until the client disconnects.
/// `subscribe events=a,b` limits the push to those event names.
///
/// `help` is built in and lists the registered commands.
///
/// Starting the first server in an app bundle announces the app to a running MacHUD
/// (`HUDAnnounce`), so a freshly built app appears in its dock.
open class HUDSocketServer {
    public typealias Args = [String: String]
    public typealias Response = [String: Any]
    /// Handlers run on the main thread and must call `done` exactly once.
    public typealias Handler = @MainActor (Args, @escaping (Response) -> Void) -> Void

    /// The primary socket path (first of `paths`).
    public var path: String { paths[0] }
    /// Every path the server listens on. Extra paths let an app keep a legacy location
    /// alongside the MacHUD one.
    public let paths: [String]
    /// How long a request may wait for its handler before `{"ok":false,"error":"timeout"}`.
    public var handlerTimeout: TimeInterval = 90
    /// An event pushed once to every subscriber, whatever its `events` filter, when the server
    /// stops with the app (`stop()`, which the server also calls itself when the app
    /// terminates). `HUDControlRouter.install()` sets it to `quitting`. The write never blocks:
    /// a subscriber that is not reading is skipped, so stopping is never held up.
    public var farewellEvent: String? {
        get { subscribersLock.lock(); defer { subscribersLock.unlock() }; return farewell }
        set { subscribersLock.lock(); farewell = newValue; subscribersLock.unlock() }
    }
    private var farewell: String?

    private var handlers: [String: Handler] = [:]
    private let handlersLock = NSLock()
    private var listeners: [(fd: Int32, path: String, source: DispatchSourceRead)] = []
    private let ioQueue: DispatchQueue
    private let logName: String
    private var terminateObserver: NSObjectProtocol?

    private struct Subscriber {
        let fd: Int32
        let events: Set<String>?
        let source: DispatchSourceRead
    }
    private var subscribers: [Int32: Subscriber] = [:]
    private let subscribersLock = NSLock()

    /// - Parameters:
    ///   - path: socket path; use `HUDSocket.path(for:)` for the MacHUD convention.
    ///   - additionalPaths: more paths served by the same handlers.
    ///   - label: dispatch queue label and log prefix.
    public init(path: String, additionalPaths: [String] = [], label: String = "hudkit.socket") {
        self.paths = [path] + additionalPaths.filter { $0 != path }
        self.ioQueue = DispatchQueue(label: label, attributes: .concurrent)
        self.logName = label
    }

    deinit { stop() }

    /// Register (or replace) a command.
    public func register(_ command: String, _ handler: @escaping Handler) {
        handlersLock.lock(); defer { handlersLock.unlock() }
        handlers[command] = handler
    }

    public func unregister(_ command: String) {
        handlersLock.lock(); defer { handlersLock.unlock() }
        handlers[command] = nil
    }

    /// Registered command names, sorted: what `help` lists. The built-in `help` and
    /// `subscribe` are not included.
    public var commands: [String] {
        handlersLock.lock(); defer { handlersLock.unlock() }
        return handlers.keys.sorted()
    }

    public var isRunning: Bool { !listeners.isEmpty }

    /// Binds and listens on every path. Any stale socket file at a path is replaced.
    /// Returns false if the primary path failed (extra paths are best effort).
    @discardableResult
    public func start() -> Bool {
        guard listeners.isEmpty else { return true }
        for (i, p) in paths.enumerated() {
            if !listen(on: p) && i == 0 { return false }
        }
        // Remove the socket files on a normal app exit so clients see "not running"
        // instead of a stale path.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil
        ) { [weak self] _ in self?.stop() }
        // The app is up: let a running MacHUD know it exists (no-op outside an app bundle
        // with a machud.json, or with HUD_NO_ANNOUNCE=1).
        HUDAnnounce.announceOnLaunch(excluding: paths)
        return true
    }

    /// True when a process is currently accepting connections at `path`, so a
    /// second instance does not silently unlink and take over a live socket.
    static func isLive(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path), var addr = HUDSocket.address(for: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
        return rc == 0
    }

    private func listen(on path: String) -> Bool {
        guard var addr = HUDSocket.address(for: path) else {
            NSLog("%@: socket path too long: %@", logName, path)
            return false
        }
        if Self.isLive(path: path) {
            NSLog("%@: another server is already listening at %@; not taking it over", logName, path)
            return false
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("%@: socket() failed", logName); return false }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            NSLog("%@: bind/listen on %@ failed: %s", logName, path, strerror(errno))
            close(fd)
            return false
        }
        chmod(path, 0o600)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.acceptOne(fd) }
        src.setCancelHandler { close(fd) }
        src.resume()
        listeners.append((fd, path, src))
        return true
    }

    public func stop() {
        guard !listeners.isEmpty else { return }
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        sendFarewell()
        for l in listeners {
            l.source.cancel()
            unlink(l.path)
        }
        listeners.removeAll()
        subscribersLock.lock()
        let subs = subscribers.values
        subscribers.removeAll()
        subscribersLock.unlock()
        for s in subs { s.source.cancel() }
    }

    /// Pushes `{"event": event, ...payload}` to every subscriber interested in `event`.
    /// Safe to call from any thread.
    public func publish(_ event: String, payload: [String: Any] = [:]) {
        var object = payload
        object["event"] = event
        let data = HUDSocket.line(object)
        subscribersLock.lock()
        let targets = subscribers.values.filter { $0.events?.contains(event) ?? true }
        subscribersLock.unlock()
        for sub in targets where !HUDSocket.writeAll(sub.fd, data) {
            dropSubscriber(sub.fd)
        }
    }

    /// Pushes the farewell event, once, without blocking.
    private func sendFarewell() {
        subscribersLock.lock()
        let event = farewell
        farewell = nil
        let targets = Array(subscribers.values)
        subscribersLock.unlock()
        guard let event else { return }
        let data = HUDSocket.line(["event": event])
        for sub in targets { _ = HUDSocket.writeNow(sub.fd, data) }
    }

    public var subscriberCount: Int {
        subscribersLock.lock(); defer { subscribersLock.unlock() }
        return subscribers.count
    }

    // MARK: - Connections

    private func acceptOne(_ listenFD: Int32) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        HUDSocket.noSigPipe(client)
        ioQueue.async { [weak self] in
            guard let self else { close(client); return }
            guard let line = HUDLineReader(fd: client, maxLine: 1_000_000).next(), !line.isEmpty else {
                // Peer connected and hung up without a request (e.g. a liveness probe).
                close(client)
                return
            }
            let request = Self.parse(line)
            if let request, request.command == "subscribe" {
                self.addSubscriber(client, args: request.args)
                return
            }
            defer { close(client) }
            let response = request.map { self.dispatch($0.command, args: $0.args) }
                ?? ["ok": false, "error": "malformed request"]
            HUDSocket.writeAll(client, HUDSocket.line(response))
        }
    }

    private static func parse(_ line: String) -> (command: String, args: Args)? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String else { return nil }
        let args = (obj["args"] as? [String: Any] ?? [:]).reduce(into: Args()) { $0[$1.key] = stringify($1.value) }
        return (command, args)
    }

    /// A handler's `Args` are always strings; a scalar (string, number, bool) renders as today
    /// (`"\(value)"`), and an object or array value round-trips as compact JSON text instead of
    /// Swift's `description`, so a client can send `settings={...}` and the handler decodes the
    /// same JSON a hand-typed `settings set settings='{"a":1}'` would produce.
    private static func stringify(_ value: Any) -> String {
        guard value is [String: Any] || value is [Any],
              let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return "\(value)" }
        return json
    }

    /// Runs a command's handler on the main thread and waits for its response.
    /// Must not be called on the main thread.
    func dispatch(_ command: String, args: Args) -> Response {
        if command == "help" { return ["ok": true, "commands": commands] }
        handlersLock.lock()
        let handler = handlers[command]
        handlersLock.unlock()
        guard let handler else {
            return ["ok": false, "error": "unknown command \(command)", "commands": commands]
        }
        let box = ResponseBox()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler(args) { box.fulfil($0) }
            }
        }
        return box.wait(timeout: handlerTimeout) ?? ["ok": false, "error": "timeout"]
    }

    private func addSubscriber(_ fd: Int32, args: Args) {
        let events = args["events"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in
            // Subscribers are write-only after the request; any read is EOF or noise.
            var byte = [UInt8](repeating: 0, count: 256)
            if read(fd, &byte, byte.count) <= 0 { self?.dropSubscriber(fd) }
        }
        src.setCancelHandler { close(fd) }
        subscribersLock.lock()
        subscribers[fd] = Subscriber(fd: fd, events: events, source: src)
        subscribersLock.unlock()
        HUDSocket.writeAll(fd, HUDSocket.line(["ok": true, "subscribed": true]))
        src.resume()
    }

    private func dropSubscriber(_ fd: Int32) {
        subscribersLock.lock()
        let sub = subscribers.removeValue(forKey: fd)
        subscribersLock.unlock()
        sub?.source.cancel()
    }
}

/// One-shot, thread-safe response slot. Later calls to `fulfil` are ignored, so a
/// handler that answers twice (or after a timeout) cannot race the reader.
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private let sema = DispatchSemaphore(value: 0)
    private var value: [String: Any]?
    private var done = false

    func fulfil(_ response: [String: Any]) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        value = response
        lock.unlock()
        sema.signal()
    }

    func wait(timeout: TimeInterval) -> [String: Any]? {
        if sema.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); done = true; lock.unlock()
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
