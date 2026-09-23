import Foundation

/// Provider-backed chat state. PTY text is deliberately not an input format.
struct AgentChatIdentity: Codable, Equatable, Sendable {
    let hostID: String
    let agentID: String
    let provider: String
    let providerSessionID: String
}

enum AgentChatPhase: String, Codable, Sendable {
    case dormant, starting, ready, sending, running, cancelling, reconnecting, failed
}

enum AgentChatRole: String, Codable, Sendable { case user, assistant }
enum AgentChatToolStatus: String, Codable, Sendable {
    case running, succeeded, failed, cancelled, unknown
    /// I18N-1: the wire word is `succeeded`; what the row says is a sentence
    /// fragment in the reader's language. Before this the enum's `rawValue`
    /// was drawn straight onto a Chinese panel.
    var label: String {
        switch self {
        case .running: Strings.toolStatusRunning
        case .succeeded: Strings.toolStatusSucceeded
        case .failed: Strings.toolStatusFailed
        case .cancelled: Strings.toolStatusCancelled
        case .unknown: Strings.toolStatusUnknown
        }
    }
}

struct AgentChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let turnID: String
    let role: AgentChatRole
    var text: String
}

struct AgentChatTool: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let turnID: String
    let name: String
    var status: AgentChatToolStatus
    var detail: String
}

enum AgentChatRow: Identifiable, Equatable, Sendable {
    case message(AgentChatMessage)
    case tool(AgentChatTool)
    var id: String {
        switch self {
        case .message(let value): "message:\(value.id)"
        case .tool(let value): "tool:\(value.id)"
        }
    }
}

enum AgentChatEvent: Sendable {
    case turnStarted(String)
    case message(AgentChatMessage) // Complete current value, not an ANSI fragment.
    case tool(AgentChatTool)
    case turnFinished(turnID: String, interrupted: Bool)
    case turnFailed(turnID: String, message: String)
    /// The provider is waiting for a human. `resolved` also arrives for a
    /// prompt answered on the host, with `source: "elsewhere"`.
    case approvalRequested(AgentChatApproval)
    case approvalResolved(requestID: String, decision: String?, source: String)
    case statusChanged(AgentChatStatus)
    case usageUpdated(AgentChatUsage)
    /// The provider's RPC dropped. Core emits this as a chat event and then
    /// ends the stream (`agent_chat_provider.py` `_disconnected`).
    case connectionLost
    /// An event this client has no surface for — the credential refresh
    /// receipt and the declined-unknown-request receipt. It still advances the
    /// sequence, because skipping it would look like a gap and force a
    /// re-snapshot on every one.
    case ignored(String)
}

struct AgentChatModel: Equatable, Sendable {
    private(set) var phase: AgentChatPhase = .dormant
    private(set) var identity: AgentChatIdentity?
    private(set) var turnID: String?
    private(set) var rows: [AgentChatRow] = []
    /// The message the user has just sent, before the provider has said
    /// anything about it.
    ///
    /// Leo: "发送也很慢". It was not slow — it was silent. `rows` are the
    /// provider's, and the user's own words only appeared once the round trip
    /// to core, then to codex, then back down the event stream had finished,
    /// which on a real network is a second or more of a screen that looks like
    /// the tap missed. So the words go on screen in the same frame as the tap
    /// and the network confirms them afterwards. It is kept *beside* the rows
    /// rather than inside them so it can never be mistaken for something the
    /// provider said, and it is dropped the moment the real row arrives.
    private(set) var localEcho: AgentChatMessage?
    private(set) var lastSequence: Int = 0
    private(set) var ensureRequestID: UUID?
    private(set) var error: String?
    /// Pending prompts first, then the ones already answered, in the order the
    /// provider raised them. They live beside the rows rather than inside them
    /// because their handle is a request id, not an item id.
    private(set) var approvals: [AgentChatApproval] = []
    private(set) var status: AgentChatStatus = .unknown
    private(set) var usage: AgentChatUsage = .empty
    var draft = ""
    var handoff: AgentChatHandoffState = .none
    var slash = AgentSlashState()
    /// The per-turn overrides the next message will carry. codex has no model
    /// setter, so this is a choice waiting for a turn, not a host setting.
    var selectedModel: String?
    var selectedEffort: String?
    var models: AgentModelCatalog?
    var modelsLoading = false
    var modelsNotice: String?

    var canSend: Bool { phase == .ready && identity != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canCancel: Bool { phase == .running && turnID != nil }
    /// Steering adds to the turn in flight (`turn/steer`). It needs a running
    /// turn, which is exactly when sending is refused.
    var canSteer: Bool {
        (phase == .running || phase == .cancelling) && turnID != nil && identity != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var pendingApprovals: [AgentChatApproval] { approvals.filter(\.isPending) }
    /// D-15 / A-63: a turn is in flight and nothing has come back from it. This
    /// is the only thing between "send" and the first token, and it goes away
    /// on that token rather than on the turn finishing.
    var awaitingFirstToken: Bool {
        switch phase {
        case .sending: return true
        case .running:
            guard let turnID else { return true }
            return !rows.contains { row in
                switch row {
                case .message(let message):
                    return message.role == .assistant && message.turnID == turnID && !message.text.isEmpty
                case .tool(let tool):
                    return tool.turnID == turnID
                }
            }
        default: return false
        }
    }
    /// What the header shows. The provider's confirmed value wins over the
    /// pending choice, so the strip never claims a model the turn did not use.
    var effectiveModel: String? { usage.model ?? selectedModel }
    var effectiveEffort: String? { usage.effort ?? selectedEffort }

    /// Called on explicit Agent navigation only. Repeated taps share one request.
    mutating func beginEnsure() -> UUID? {
        guard phase == .dormant || phase == .failed || (phase == .reconnecting && identity == nil) else { return nil }
        let request = UUID()
        ensureRequestID = request
        error = nil
        phase = .starting
        return request
    }

    /// A provider snapshot is authoritative after reconnect; sequence is Host
    /// adapter replay state, not a field claimed to exist on raw Codex events.
    mutating func restore(identity next: AgentChatIdentity, rows: [AgentChatRow],
                          activeTurn: String?, sequence: Int) -> Bool {
        guard next.agentID == "default", !next.providerSessionID.isEmpty, sequence >= 0,
              identity == nil || identity == next,
              identity == nil || sequence >= lastSequence else { return false }
        identity = next
        self.rows = rows
        // A snapshot is the host's whole answer; anything this client was
        // holding on the user's behalf is either in it or was never sent.
        localEcho = nil
        turnID = activeTurn
        lastSequence = sequence
        phase = activeTurn == nil ? .ready : .running
        ensureRequestID = nil
        error = nil
        return true
    }

    /// Ordering and identity checks prevent stale/foreign sessions contaminating
    /// this chat. A gap requires a snapshot instead of inventing missing output.
    mutating func apply(_ event: AgentChatEvent, identity: AgentChatIdentity, sequence: Int) -> Bool {
        guard self.identity == identity, sequence > lastSequence else { return false }
        guard phase != .reconnecting, sequence == lastSequence + 1 else {
            phase = .reconnecting
            return false
        }
        switch event {
        case .turnStarted(let id): turnID = id; phase = .running
        case .message(let message):
            guard message.turnID == turnID else { return false }
            // The provider has echoed the words back: the local copy has done
            // its job and must not become a second copy of the same sentence.
            if message.role == .user, message.text == localEcho?.text { localEcho = nil }
            upsert(.message(message))
        case .tool(let tool):
            guard tool.turnID == turnID else { return false }
            upsert(.tool(tool))
        case .turnFinished(let id, _):
            guard id == turnID else { return false }
            turnID = nil; phase = .ready; localEcho = nil
        case .turnFailed(let id, let message):
            guard id == turnID else { return false }
            turnID = nil; error = message; phase = .failed; localEcho = nil
        case .approvalRequested(let approval):
            // The provider re-raising the same id is the same prompt, not a
            // second one; the card is replaced in place.
            if let index = approvals.firstIndex(where: { $0.requestID == approval.requestID }) {
                approvals[index] = approval
            } else {
                approvals.append(approval)
            }
        case .approvalResolved(let requestID, let decision, let source):
            guard let index = approvals.firstIndex(where: { $0.requestID == requestID }) else { break }
            approvals[index].state = .resolved(decision: decision, source: source)
        case .statusChanged(let value): status = value
        case .usageUpdated(let value):
            usage = value
            // `thread/settings/updated` is the provider confirming what the
            // turn actually used; a pending override that landed is no longer
            // pending, and one that did not is left alone.
            if let model = value.model, model == selectedModel { selectedModel = nil }
            if let effort = value.effort, effort == selectedEffort { selectedEffort = nil }
        case .connectionLost:
            lastSequence = sequence
            phase = .reconnecting
            return true
        case .ignored: break
        }
        lastSequence = sequence
        return true
    }

    /// Everything the snapshot carries beyond the rows. Approvals the snapshot
    /// no longer lists were answered while this client was away: they are kept
    /// as result rows rather than deleted, and a card the snapshot still lists
    /// goes back to pending even if a decision was in flight when the stream
    /// broke — the host is the authority on what is still waiting.
    mutating func restore(_ snapshot: AgentChatSnapshot) -> Bool {
        guard restore(identity: snapshot.identity, rows: snapshot.rows,
                      activeTurn: snapshot.activeTurn, sequence: snapshot.sequence) else { return false }
        let waiting = Set(snapshot.pendingApprovals.map(\.requestID))
        var merged = snapshot.pendingApprovals
        for previous in approvals where !waiting.contains(previous.requestID) {
            var row = previous
            if row.isPending { row.state = .resolved(decision: nil, source: "elsewhere") }
            merged.append(row)
        }
        approvals = merged
        status = snapshot.status
        usage = snapshot.usage
        return true
    }

    /// A decision is optimistic only in the sense that the card is locked while
    /// the request is in flight; the result row still waits for the host.
    mutating func beginDecision(requestID: String, decision: String) -> Bool {
        guard let index = approvals.firstIndex(where: { $0.requestID == requestID }),
              case .pending = approvals[index].state else { return false }
        approvals[index].state = .deciding(decision)
        return true
    }
    mutating func settleDecision(requestID: String, decision: String?, source: String) {
        guard let index = approvals.firstIndex(where: { $0.requestID == requestID }) else { return }
        approvals[index].state = .resolved(decision: decision, source: source)
    }
    mutating func failDecision(requestID: String) {
        guard let index = approvals.firstIndex(where: { $0.requestID == requestID }),
              approvals[index].isDeciding else { return }
        approvals[index].state = .pending
    }

    mutating func beginSend() -> String? {
        guard canSend else { return nil }
        let text = draft
        phase = .sending
        error = nil
        // The composer empties and the words appear in the list in this frame,
        // before anything is on the wire. `localEcho` is not a row: it claims
        // only that the user typed this, which is the one thing that is already
        // true.
        localEcho = AgentChatMessage(id: Self.localEchoID, turnID: "", role: .user, text: text)
        draft = ""
        return text
    }
    /// The id the optimistic copy carries. It is not an item id the provider
    /// could ever mint, so a real row can never collide with it.
    static let localEchoID = "local-echo"
    mutating func sendAcknowledged(text: String) {
        // An ACK only permits clearing the submitted draft; it never invents
        // an assistant answer, tool result, or turn completion.
        if draft == text { draft = "" }
    }
    /// The request did not land. The words go back into the composer, because
    /// the user still has them and retyping them is the worst possible outcome
    /// of a failed send.
    mutating func sendFailed(text: String, message: String) {
        localEcho = nil
        if draft.isEmpty { draft = text }
        fail(message)
    }
    /// Steering does not change the phase: the turn is still the provider's,
    /// and the composer clears only once the host has taken the words.
    mutating func beginSteer() -> String? {
        guard canSteer else { return nil }
        error = nil
        return draft
    }
    mutating func steerAcknowledged(text: String) {
        if draft == text { draft = "" }
    }
    mutating func requestCancel() -> String? {
        guard canCancel else { return nil }
        phase = .cancelling
        return turnID // Remains cancelling until a real provider completion.
    }
    mutating func connectionLost() { phase = .reconnecting }
    mutating func fail(_ message: String) { error = message; phase = .failed; ensureRequestID = nil }
    private mutating func upsert(_ value: AgentChatRow) {
        if let index = rows.firstIndex(where: { $0.id == value.id }) { rows[index] = value }
        else { rows.append(value) }
    }
}
