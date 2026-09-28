import Foundation

/// The part of a companion snapshot the transcript renders.
public struct TranscriptInput: Equatable, Sendable {
    public var turnId: String?
    public var status: String
    public var output: String
    public var progress: String
    public var approvals: [AgentApproval]
    public var error: String?

    public init(turnId: String?, status: String, output: String = "", progress: String = "",
                approvals: [AgentApproval] = [], error: String? = nil) {
        self.turnId = turnId
        self.status = status
        self.output = output
        self.progress = progress
        self.approvals = approvals
        self.error = error
    }

    public init(_ snapshot: AgentSessionSnapshot) {
        self.init(turnId: snapshot.turnId, status: snapshot.status, output: snapshot.output,
                  progress: snapshot.progress, approvals: snapshot.approvals, error: snapshot.error)
    }

    public var isWorking: Bool { status == "running" || status == "approval" }
}

/// One transcript row. Rows are keyed by stable ids so a streaming reply is replaced by
/// its final text in place: nothing ever shows twice.
public struct TranscriptRow: Identifiable, Equatable, Sendable {
    public enum ToolState: String, Equatable, Sendable {
        case running, done, failed, denied
    }

    public enum Resolution: Equatable, Sendable {
        /// A decision was sent through `markDecision` and not yet confirmed.
        case delivering(allow: Bool)
        case allowed
        case denied
        /// Answered elsewhere (another client, voice) or ended with the turn.
        case resolved
        /// The decision could not be delivered; the approval may still be pending.
        case failed(String)
    }

    public struct Approval: Equatable, Sendable {
        public var id: String
        public var kind: String
        public var reason: String
        public var command: String?
        public var cwd: String?
        public var resolution: Resolution?

        public var isPending: Bool {
            switch resolution {
            case nil, .failed: return true
            case .delivering: return true
            default: return false
            }
        }
    }

    public enum Kind: Equatable, Sendable {
        /// `❯` user band.
        case user(String)
        /// `●` assistant prose; `streaming` while the turn is live.
        case reply(String, streaming: Bool)
        /// `⎿` dimmed progress/tool line with a state dot.
        case progress(String, state: ToolState)
        /// Inline approval prompt (Allow Once / Deny).
        case approval(Approval)
        /// Turn-level notice: interruption or failure.
        case notice(String, isError: Bool)
    }

    public var id: String
    public var turnId: String?
    public var kind: Kind
}

/// What a reduction step means for the view around the transcript.
public enum TranscriptEvent: Equatable, Sendable {
    case turnStarted
    /// The first visible output of a live turn (a host may show its transcript).
    case firstOutput
    /// An approval appeared (auto-show, it needs the user).
    case approvalAdded
    case turnEnded
}

/// Reduces a sequence of snapshots (plus what the user said) into transcript rows.
/// Snapshots are complete states, so a repeated or skipped one converges to the same rows.
public struct TranscriptModel: Equatable, Sendable {
    public private(set) var rows: [TranscriptRow] = []
    public private(set) var turnID: String?
    public private(set) var turnActive = false
    public var maxRows = 200

    private var lastInput: TranscriptInput?
    private var sawOutputThisTurn = false
    private var lastProgress = ""
    /// A user row since the last turn began: the next new turn is live, even if its first
    /// snapshot is already complete.
    private var awaitingTurn = false
    private var counter = 0
    /// Decisions sent through `markDecision`, so a vanished approval can be labeled.
    private var decisions: [String: Bool] = [:]

    public init() {}

    public var pendingApprovals: [TranscriptRow.Approval] {
        rows.compactMap {
            if case .approval(let a) = $0.kind, a.isPending { return a }
            return nil
        }
    }

    public mutating func userSaid(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(TranscriptRow(id: nextID("user"), turnId: nil, kind: .user(trimmed)))
        awaitingTurn = true
    }

    /// Clears the transcript (new conversation).
    public mutating func reset() {
        self = TranscriptModel()
    }

    @discardableResult
    public mutating func apply(_ input: TranscriptInput) -> [TranscriptEvent] {
        guard input != lastInput else { return [] }
        lastInput = input
        var events: [TranscriptEvent] = []
        guard let turn = input.turnId else {
            // A runtime failure can drop the turn identity: end whatever was live.
            if turnActive, input.status == "failed" {
                finishTurn(turnID, input: input)
                events.append(.turnEnded)
            }
            return events
        }

        let isNewTurn = turn != turnID
        if isNewTurn {
            if turnActive { finishTurn(turnID, input: nil) }
            let live = input.isWorking || awaitingTurn
            turnID = turn
            turnActive = live
            sawOutputThisTurn = false
            lastProgress = ""
            awaitingTurn = false
            // Attach the waiting user rows to this turn.
            for i in rows.indices.reversed() {
                guard case .user = rows[i].kind, rows[i].turnId == nil else { break }
                rows[i].turnId = turn
            }
            if live {
                events.append(.turnStarted)
            } else {
                // Historical completion seen on connect: show it, never announce it.
                if !input.output.isEmpty {
                    upsertReply(turn: turn, text: input.output, streaming: false)
                }
                return events
            }
        } else if !turnActive {
            if input.isWorking {
                // The same turn resumed (e.g. a reconnect adopting live work).
                turnActive = true
                events.append(.turnStarted)
            } else {
                return events
            }
        }

        // Progress: each new line settles the previous running one.
        let progress = input.progress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !progress.isEmpty, progress != lastProgress {
            settleRunningProgress(turn: turn, to: .done)
            append(TranscriptRow(id: nextID("progress"), turnId: turn, kind: .progress(progress, state: input.isWorking ? .running : .done)))
            lastProgress = progress
        }

        // Approvals: add new ones, resolve vanished ones.
        let live = Set(input.approvals.map(\.id))
        for i in rows.indices {
            guard rows[i].turnId == turn, case .approval(var a) = rows[i].kind, a.isPending,
                !live.contains(a.id)
            else { continue }
            a.resolution = decisions[a.id].map { $0 ? .allowed : .denied } ?? .resolved
            rows[i].kind = .approval(a)
            if a.resolution == .denied { settleRunningProgress(turn: turn, to: .denied) }
        }
        for approval in input.approvals where !rows.contains(where: { $0.id == "approval-\(approval.id)" }) {
            append(TranscriptRow(
                id: "approval-\(approval.id)", turnId: turn,
                kind: .approval(.init(id: approval.id, kind: approval.kind, reason: approval.reason,
                                      command: approval.command, cwd: approval.cwd))))
            events.append(.approvalAdded)
        }

        if input.isWorking {
            if !input.output.isEmpty {
                upsertReply(turn: turn, text: input.output, streaming: true)
                if !sawOutputThisTurn {
                    sawOutputThisTurn = true
                    events.append(.firstOutput)
                }
            }
        } else {
            if !input.output.isEmpty, !sawOutputThisTurn {
                sawOutputThisTurn = true
                events.append(.firstOutput)
            }
            finishTurn(turn, input: input)
            events.append(.turnEnded)
        }
        return events
    }

    /// The host sent a decision; shown as delivering until the snapshot drops the approval.
    public mutating func markDecision(approvalID: String, allow: Bool) {
        decisions[approvalID] = allow
        updateApproval(approvalID) { $0.resolution = .delivering(allow: allow) }
    }

    /// The decision could not be confirmed; the approval stays answerable.
    public mutating func decisionFailed(approvalID: String, message: String) {
        decisions[approvalID] = nil
        updateApproval(approvalID) { $0.resolution = .failed(message) }
    }

    // MARK: - Steps

    private mutating func finishTurn(_ turn: String?, input: TranscriptInput?) {
        guard let turn else { turnActive = false; return }
        let status = input?.status ?? "idle"
        // Streaming text is swapped for the final message in the same step.
        if let input, !input.output.isEmpty {
            upsertReply(turn: turn, text: input.output, streaming: false)
        } else if let i = rows.firstIndex(where: { $0.id == "reply-\(turn)" }),
            case .reply(let text, _) = rows[i].kind
        {
            rows[i].kind = .reply(text, streaming: false)
        }
        settleRunningProgress(turn: turn, to: status == "failed" ? .failed : .done)
        for i in rows.indices {
            guard rows[i].turnId == turn, case .approval(var a) = rows[i].kind, a.isPending else { continue }
            a.resolution = decisions[a.id].map { $0 ? .allowed : .denied } ?? .resolved
            rows[i].kind = .approval(a)
        }
        switch status {
        case "failed":
            append(TranscriptRow(id: nextID("notice"), turnId: turn,
                                 kind: .notice(input?.error ?? "Agent work failed.", isError: true)))
        case "interrupted":
            append(TranscriptRow(id: nextID("notice"), turnId: turn,
                                 kind: .notice("Interrupted. Completed changes may remain.", isError: false)))
        default: break
        }
        turnActive = false
    }

    private mutating func upsertReply(turn: String, text: String, streaming: Bool) {
        let id = "reply-\(turn)"
        if let i = rows.firstIndex(where: { $0.id == id }) {
            rows[i].kind = .reply(text, streaming: streaming)
        } else {
            append(TranscriptRow(id: id, turnId: turn, kind: .reply(text, streaming: streaming)))
        }
    }

    private mutating func settleRunningProgress(turn: String, to state: TranscriptRow.ToolState) {
        for i in rows.indices {
            guard rows[i].turnId == turn, case .progress(let text, .running) = rows[i].kind else { continue }
            rows[i].kind = .progress(text, state: state)
        }
    }

    private mutating func updateApproval(_ id: String, _ change: (inout TranscriptRow.Approval) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == "approval-\(id)" }),
            case .approval(var a) = rows[i].kind
        else { return }
        change(&a)
        rows[i].kind = .approval(a)
    }

    private mutating func append(_ row: TranscriptRow) {
        rows.append(row)
        if rows.count > maxRows { rows.removeFirst(rows.count - maxRows) }
    }

    private mutating func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }
}
