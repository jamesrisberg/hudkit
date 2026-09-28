import Combine
import Foundation

/// The companion's folder scope: which folders the agent may write without asking.
public struct AgentPermissions: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case approvedFolders, fullAccess
        public var id: String { rawValue }
        public var displayName: String {
            self == .fullAccess ? "Full access" : "Ask outside approved folders"
        }
    }

    public var mode: Mode
    public var approvedFolders: [String]

    public init(mode: Mode, approvedFolders: [String]) {
        self.mode = mode
        self.approvedFolders = approvedFolders
    }
}

/// Agent runtimes the companion can run. Raw values match the companion's `--runtime`.
public enum AgentRuntime: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, hermes, claude
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .hermes: return "Hermes"
        case .claude: return "Claude"
        }
    }
}

/// What the running runtime can honour (see `Companion/runtimes/Runtime.mjs`).
public struct AgentCapabilities: Codable, Equatable, Sendable {
    public let approvals: Bool
    public let folderScope: Bool
    public let modelRouting: Bool
    public let cancel: Bool

    public init(approvals: Bool, folderScope: Bool, modelRouting: Bool, cancel: Bool) {
        self.approvals = approvals
        self.folderScope = folderScope
        self.modelRouting = modelRouting
        self.cancel = cancel
    }
}

public struct AgentApproval: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let reason: String
    public let command: String?
    public let cwd: String?

    public init(id: String, kind: String, reason: String, command: String? = nil, cwd: String? = nil) {
        self.id = id
        self.kind = kind
        self.reason = reason
        self.command = command
        self.cwd = cwd
    }
}

public struct AgentRoute: Codable, Equatable, Sendable {
    public let tier: String
    public let model: String?
    public let effort: String?
    public let reason: String
}

public struct AgentTiming: Codable, Equatable, Sendable {
    public let startedAt: Double
    public let firstResponseMs: Double?
    public let completedMs: Double?
}

/// One complete companion state (`GET /v1/session`); see the companion README's HTTP contract.
public struct AgentSessionSnapshot: Codable, Equatable, Sendable {
    public let threadId: String?
    public let turnId: String?
    public let status: String
    public let output: String
    public let progress: String
    public let approvals: [AgentApproval]
    public let error: String?
    public let revision: Int
    public let instanceId: String?
    public let requestId: String?
    public var permissions: AgentPermissions?
    public var route: AgentRoute?
    public var timing: AgentTiming?
    /// Absent from companions that predate pluggable runtimes, which always run Codex.
    public var runtime: String?
    public var capabilities: AgentCapabilities?

    public var runtimeName: String {
        AgentRuntime(rawValue: runtime ?? AgentRuntime.codex.rawValue)?.displayName ?? (runtime ?? "Agent")
    }

    public var isWorking: Bool { status == "running" || status == "approval" }
}

public enum AgentSessionError: LocalizedError, Equatable {
    case invalidEndpoint
    case missingToken
    case responseTooLarge
    case server(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The companion address must use http://127.0.0.1 with a port and no path."
        case .missingToken: return "The companion token is missing or malformed."
        case .responseTooLarge: return "The companion response exceeded its size limit."
        case .server(let code, let message): return "Companion (\(code)): \(message)"
        }
    }
}

private final class CompanionSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward the local credential to a redirect destination.
        completionHandler(nil)
    }
}

/// Talks to the companion over loopback HTTP. Polls complete snapshots, so a brief
/// disconnect cannot lose approvals or replay work.
@MainActor
public final class AgentSessionClient: ObservableObject {
    @Published public private(set) var snapshot: AgentSessionSnapshot?
    @Published public private(set) var isConnected = false
    @Published public private(set) var errorMessage: String?

    private let endpoint: URL
    private let token: String
    private let session: URLSession
    private var pollTask: Task<Void, Never>?
    private var generation = UUID()
    private var mutationsInFlight = 0
    private var mutationRevision = 0

    /// `session` replaces the ephemeral, proxy-free URL session (tests).
    public init(endpoint: URL, token: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        // Ignore system proxies for the explicitly local service.
        configuration.connectionProxyDictionary = [:]
        self.session = session
            ?? URLSession(configuration: configuration, delegate: CompanionSessionDelegate(), delegateQueue: nil)
    }

    deinit {
        pollTask?.cancel()
        session.invalidateAndCancel()
    }

    public func connect() async throws {
        disconnect()
        let currentGeneration = generation
        do {
            let value = try await request(path: "/v1/session")
            guard generation == currentGeneration else { throw CancellationError() }
            // Companion restarts reset the revision counter.
            snapshot = value
            isConnected = true
            errorMessage = nil
            beginPolling(generation: currentGeneration)
        } catch {
            if generation == currentGeneration {
                isConnected = false
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// A fresh read after a failed mutation can settle whether its opaque action
    /// is still pending. A cached or overlapping poll cannot authorize a retry.
    public func refreshSnapshot() async throws -> AgentSessionSnapshot {
        let expectedGeneration = generation
        let expectedRevision = mutationRevision
        let value = try await request(path: "/v1/session")
        guard generation == expectedGeneration, mutationRevision == expectedRevision, mutationsInFlight == 0
        else { throw CancellationError() }
        apply(value)
        return value
    }

    public func disconnect() {
        generation = UUID()
        pollTask?.cancel()
        pollTask = nil
        isConnected = false
    }

    @discardableResult
    public func submit(text: String, requestId: String = UUID().uuidString) async throws -> AgentSessionSnapshot {
        // No automatic submission retry. The server also deduplicates this request ID.
        try await mutate(path: "/v1/turn", body: ["text": text, "requestId": requestId])
    }

    public func approve(id: String, allow: Bool) async throws {
        try await mutate(path: "/v1/approval", body: ["id": id, "decision": allow ? "accept" : "decline"])
    }

    public func cancel() async throws { try await mutate(path: "/v1/cancel", body: [String: String]()) }

    public func resetSession() async throws {
        try await mutate(path: "/v1/session/reset", body: [String: String]())
    }

    /// Switch (or restart a failed) runtime while idle. The companion keeps each
    /// runtime's conversation, so switching back resumes it.
    @discardableResult
    public func setRuntime(_ runtime: AgentRuntime) async throws -> AgentSessionSnapshot {
        try await mutate(path: "/v1/runtime", body: ["runtime": runtime.rawValue])
    }

    @discardableResult
    public func setPermissions(_ permissions: AgentPermissions) async throws -> AgentSessionSnapshot {
        try await mutate(path: "/v1/permissions", body: permissions)
    }

    @discardableResult
    private func mutate<Body: Encodable>(path: String, body: Body) async throws -> AgentSessionSnapshot {
        mutationRevision += 1
        mutationsInFlight += 1
        defer { mutationsInFlight -= 1 }
        let currentGeneration = generation
        do {
            let value = try await request(path: path, body: JSONEncoder().encode(body))
            guard currentGeneration == generation else { throw CancellationError() }
            apply(value)
            return value
        } catch {
            if currentGeneration == generation { errorMessage = error.localizedDescription }
            throw error
        }
    }

    private func beginPolling(generation currentGeneration: UUID) {
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(failures == 0 ? 500 : 2000)) } catch { return }
                guard let self, self.generation == currentGeneration else { return }
                do {
                    let expectedMutationRevision = self.mutationRevision
                    let value = try await self.request(path: "/v1/session")
                    guard self.generation == currentGeneration, !Task.isCancelled else { return }
                    // A successful poll after transport failure can be a restarted companion.
                    if self.mutationsInFlight == 0 && self.mutationRevision == expectedMutationRevision {
                        if failures > 0 { self.snapshot = value } else { self.apply(value) }
                    }
                    failures = 0
                    self.isConnected = true
                    self.errorMessage = nil
                } catch {
                    guard self.generation == currentGeneration, !Task.isCancelled else { return }
                    failures += 1
                    self.isConnected = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func apply(_ value: AgentSessionSnapshot) {
        // A lower revision from the same companion process is stale; a new instance restarts the count.
        if snapshot == nil || value.instanceId != snapshot!.instanceId || value.revision >= snapshot!.revision {
            snapshot = value
        }
        isConnected = true
        errorMessage = nil
    }

    private func request(path: String, body: Data? = nil) async throws -> AgentSessionSnapshot {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port,
              (1024...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/"
        else { throw AgentSessionError.invalidEndpoint }
        guard token.count == 64, token.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw AgentSessionError.missingToken
        }
        var url = parts
        url.path = path
        guard let requestURL = url.url else { throw AgentSessionError.invalidEndpoint }
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1024 * 1024 else { throw AgentSessionError.responseTooLarge }
            data.append(byte)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            struct ServerError: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "Unexpected response"
            throw AgentSessionError.server(code, message)
        }
        return try JSONDecoder().decode(AgentSessionSnapshot.self, from: data)
    }
}
