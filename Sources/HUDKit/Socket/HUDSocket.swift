import Foundation

/// Socket-path conventions and low-level helpers shared by the server and client.
public enum HUDSocket {
    /// `~/Library/Application Support/MacHUD/sockets`, created with mode 0700 on first use.
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacHUD/sockets", isDirectory: true)
    }

    /// The contract socket path for an app: `~/Library/Application Support/MacHUD/sockets/<name>.sock`.
    /// Creates the directory (0700) if needed.
    public static func path(for name: String) -> String {
        path(for: name, in: directory)
    }

    /// Same as `path(for:)` but rooted in `directory` (for tests and isolated instances).
    public static func path(for name: String, in directory: URL) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        chmod(directory.path, 0o700)
        return directory.appendingPathComponent("\(name).sock").path
    }

    /// Longest socket path the kernel accepts (`sun_path` minus the terminator).
    public static var maxPathLength: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 }

    /// Builds a `sockaddr_un`, or nil when the path does not fit.
    static func address(for path: String) -> sockaddr_un? {
        guard path.utf8.count <= maxPathLength else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                    _ = strlcpy(dst, cstr, capacity)
                }
            }
        }
        return addr
    }

    /// Connects a new stream socket to `path`. Returns the fd or throws.
    static func connect(to path: String) throws -> Int32 {
        guard var addr = address(for: path) else { throw HUDSocketError.pathTooLong(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HUDSocketError.system("socket", errno) }
        noSigPipe(fd)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) } }
        guard ok == 0 else {
            let err = errno
            close(fd)
            throw HUDSocketError.notRunning(path, err)
        }
        return fd
    }

    /// Writing to a peer that went away must return EPIPE, not kill the process.
    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`, retrying short writes. Returns false on failure.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buf -> Bool in
            guard var p = buf.baseAddress else { return true }
            var remaining = buf.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { return false }
                p += n
                remaining -= n
            }
            return true
        }
    }

    /// Writes `data` only if the peer's buffer takes all of it at once (`MSG_DONTWAIT`); never
    /// waits. For a last message from a process that is exiting.
    @discardableResult
    static func writeNow(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buf -> Bool in
            guard let p = buf.baseAddress else { return true }
            return send(fd, p, buf.count, MSG_DONTWAIT) == buf.count
        }
    }

    /// Encodes a JSON object as one line (with trailing newline).
    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: sanitize(object) as Any)) ?? Data("{\"ok\":false,\"error\":\"unencodable response\"}".utf8)
        data.append(10)
        return data
    }

    /// Replaces values JSONSerialization cannot encode (e.g. CGFloat.nan, custom types) so a
    /// bad handler response degrades to a string instead of an ObjC exception.
    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]: return d.mapValues { sanitize($0) }
        case let a as [Any]: return a.map { sanitize($0) }
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n }
            return n.doubleValue.isFinite ? n : NSNull()
        case is NSNull: return value
        default: return "\(value)"
        }
    }
}

/// Buffered line reader over a file descriptor.
final class HUDLineReader {
    private let fd: Int32
    private var buffer = Data()
    private let maxLine: Int

    init(fd: Int32, maxLine: Int = 4_000_000) {
        self.fd = fd
        self.maxLine = maxLine
    }

    /// Next line without the newline, or nil at EOF/error. A final unterminated line is returned.
    func next() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(decoding: line, as: UTF8.self)
            }
            if buffer.count > maxLine {
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

public enum HUDSocketError: Error, CustomStringConvertible, Equatable {
    case pathTooLong(String)
    case notRunning(String, Int32)
    case system(String, Int32)
    case noResponse
    case malformedResponse(String)
    case timeout

    public var description: String {
        switch self {
        case .pathTooLong(let p): return "socket path too long (\(p.utf8.count) > \(HUDSocket.maxPathLength)): \(p)"
        case .notRunning(let p, let e): return "no server at \(p) (\(String(cString: strerror(e))))"
        case .system(let call, let e): return "\(call) failed: \(String(cString: strerror(e)))"
        case .noResponse: return "no response"
        case .malformedResponse(let s): return "malformed response: \(s.prefix(200))"
        case .timeout: return "timeout"
        }
    }
}
