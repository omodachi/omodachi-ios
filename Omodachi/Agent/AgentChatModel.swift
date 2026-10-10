import Foundation

/// Provider-backed chat state. PTY text is deliberately not an input format.
struct AgentChatIdentity: Codable, Equatable, Sendable {
    let hostID: String
    let agentID: String
    let provider: String
    let providerSessionID: String
}

/// AGENT-PLAN-1: `/diff` - the files this conversation changed, as codex's
/// own fileChange items hold them (never a file viewer), and how many earlier
/// changes core left out.
struct AgentDiffState: Equatable, Sendable {
    var changes: [AgentChatChange]
    var omitted = 0
    /// The change cards' row: not a row of the conversation, so no turn.
    static let itemID = "diff"
    var tool: AgentChatTool {
        AgentChatTool(id: Self.itemID, turnID: "", name: "", status: .succeeded, detail: "", changes: changes)
    }
}

enum AgentChatPhase: String, Codable, Sendable {
    case dormant, starting, ready, sending, running, cancelling, reconnecting, failed
}

enum AgentChatRole: String, Codable, Sendable { case user, assistant }
enum AgentChatToolStatus: String, Codable, Sendable {
    /// AGENT-NEW-1: `interrupted` - core closes a tool whose turn the person
    /// stopped, so no row stays "running" after its turn.
    case running, succeeded, failed, cancelled, interrupted, unknown
    /// I18N-1: the wire word is `succeeded`; what the row says is a sentence
    /// fragment in the reader's language. Before this the enum's `rawValue`
    /// was drawn straight onto a Chinese panel.
    var label: String {
        switch self {
        case .running: Strings.toolStatusRunning
        case .succeeded: Strings.toolStatusSucceeded
        case .failed: Strings.toolStatusFailed
        case .cancelled: Strings.toolStatusCancelled
        case .interrupted: Strings.toolStatusInterrupted
        case .unknown: Strings.toolStatusUnknown
        }
    }
}

struct AgentChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let turnID: String
    let role: AgentChatRole
    var text: String
    /// ATTACH-1: how many pictures rode with the user's words (core's count;
    /// never a path). `nil` for none.
    var images: Int? = nil
    /// AGENT-PLAN-1: this assistant message is the plan codex proposed in Plan
    /// mode (its `plan` item). Drawn as a plan card; `nil` for any other reply.
    var plan: Bool? = nil
    var isPlan: Bool { plan == true && role == .assistant }
    /// AGENT-QUEUE-1: a message longer than core carries (65536 characters)
    /// arrives as its beginning; this many characters are not here.
    var textTruncated: Int? = nil
}

struct AgentChatTool: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let turnID: String
    let name: String
    var status: AgentChatToolStatus
    var detail: String
    /// LINKS-1: the files a `fileChange` changed or an `imageView` looked at,
    /// as core lists them; each opens on the computer.
    var paths: [String]? = nil
    /// AGENT-FIX-2: how many characters of earlier output core no longer
    /// keeps; `detail` is the newest part.
    var detailTruncated: Int? = nil
    /// AGENT-COLLIE-1: a command's words without codex's shell wrapper, its
    /// reading (`actions`), and once finished its exit code and duration.
    var command: String? = nil
    var actions: [AgentChatAction]? = nil
    var exitCode: Int? = nil
    var durationMS: Int? = nil
    /// AGENT-COLLIE-1: a file change, per file, as codex sent it (bounded by
    /// core); `changesOmitted` files past the ones carried.
    var changes: [AgentChatChange]? = nil
    var changesOmitted: Int? = nil

    /// What core keeps of a tool's output, and so what this app keeps:
    /// core's `TOOL_DETAIL_LIMIT`, counted in Unicode scalars as Python
    /// counts characters.
    static let detailLimit = 64 * 1024

    /// `tool.output`: the new words of a running command, appended; only the
    /// newest `detailLimit` characters are kept, as core keeps them.
    mutating func append(output delta: String, truncated: Int?) {
        var scalars = detail.unicodeScalars
        scalars.append(contentsOf: delta.unicodeScalars)
        let excess = scalars.count - Self.detailLimit
        if excess > 0 {
            detail = String(String.UnicodeScalarView(scalars.dropFirst(excess)))
            detailTruncated = truncated ?? ((detailTruncated ?? 0) + excess)
        } else {
            detail = String(scalars)
            if let truncated { detailTruncated = truncated }
        }
    }
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

/// AGENT-FIX-2: one line of the drawn conversation.
enum AgentTimelineEntry: Identifiable, Equatable, Sendable {
    case row(AgentChatRow)
    case answered(AgentChatApproval)
    var id: String {
        switch self {
        case .row(let row): row.id
        case .answered(let approval): "approval:\(approval.requestID)"
        }
    }
}

enum AgentChatEvent: Sendable {
    case turnStarted(String)
    case message(AgentChatMessage) // Complete current value, not an ANSI fragment.
    case tool(AgentChatTool)
    /// AGENT-FIX-2: a running command's new output, as an increment.
    case toolOutput(id: String, turnID: String, delta: String, truncated: Int?)
    case turnFinished(turnID: String, interrupted: Bool)
    case turnFailed(turnID: String, message: String)
    /// The provider is waiting for a human. `resolved` also arrives for a
    /// prompt answered on the host, with `source: "elsewhere"`.
    case approvalRequested(AgentChatApproval)
    case approvalResolved(requestID: String, decision: String?, source: String)
    case statusChanged(AgentChatStatus)
    case usageUpdated(AgentChatUsage)
    /// AGENT-QUEUE-1: codex's queue now (nil: this codex has none), and its
    /// plan checklist now.
    case queueChanged([AgentQueuedMessage]?)
    case checklistUpdated(AgentChecklist?)
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
    /// ATTACH-1: the echo's words carried attachments, so the host's copy has
    /// core's paths in it and will not equal the draft; any user row of the
    /// turn is its echo.
    private(set) var echoCarriesAttachments = false
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
    /// One line under the composer: what just happened that the person should
    /// know (a refused step, an unconfirmed answer). AGENT-PLAN-1: this was the
    /// slash list's notice; the list is gone and the line stayed.
    var notice: String?
    /// AGENT-PLAN-1: what `/diff` brought - the conversation's file changes.
    var diff: AgentDiffState?
    /// The per-turn overrides the next message will carry. codex has no model
    /// setter, so this is a choice waiting for a turn, not a host setting.
    var selectedModel: String?
    var selectedEffort: String?
    var models: AgentModelCatalog?
    var modelsLoading = false
    var modelsNotice: String?
    /// AGENT-NEW-1: the New conversation card.
    var fresh: AgentNewConversationState = .none
    /// AGENT-PLAN-1: a mode change on its way to the host.
    var modeBusy = false
    /// AGENT-QUEUE-1: codex's own queue for this thread, as the host says it
    /// (nil: this codex has none, and the composer steers while a turn runs).
    private(set) var queue: [AgentQueuedMessage]?
    /// AGENT-QUEUE-1: codex's plan checklist, the newest it sent.
    private(set) var checklist: AgentChecklist?
    /// AGENT-QUEUE-1: there are rows before the first one here.
    private(set) var earlier = false
    var loadingEarlier = false
    /// AGENT-QUEUE-1: each question card's progress, by request id
    /// (`AgentQuestionDraft`).
    private(set) var questionDrafts: [String: AgentQuestionDraft] = [:]

    /// AGENT-PLAN-1: codex's Plan collaboration mode is on for this thread -
    /// the provider's own state (`usage.mode`), never a flag of this app's.
    var planOn: Bool { usage.mode == "plan" }
    /// Why the mode cannot change now, or nil. codex's TUI refuses `/plan`
    /// while a turn runs, and so does the host.
    var modeRefusal: String? {
        if identity == nil { return Strings.agentNewUnavailable }
        if modeBusy { return Strings.agentPlanSwitching }
        if [.running, .cancelling, .sending, .starting].contains(phase) || turnID != nil || !pendingApprovals.isEmpty {
            return Strings.agentPlanWhileWorking
        }
        return nil
    }
    /// The plan the person can act on: the newest plan, while Plan mode is on
    /// and nothing has been said after it.
    var actionablePlanID: String? {
        guard planOn else { return nil }
        for row in rows.reversed() {
            guard case .message(let message) = row else { continue }
            if message.role == .user { return nil }
            if message.isPlan { return message.id }
        }
        return nil
    }
    /// The host's answer to a mode change: the usage it now reports. A note
    /// about the mode from before is no longer true.
    mutating func modeChanged(_ value: AgentChatUsage) {
        usage = value
        modeBusy = false
        notice = nil
    }

    /// AGENT-NEW-1: why "New conversation" cannot start now, or nil. A turn in
    /// flight or a question waiting would be left hanging.
    var newConversationRefusal: String? {
        if identity == nil { return Strings.agentNewUnavailable }
        if !pendingApprovals.isEmpty { return Strings.agentNewWhileWaiting }
        if [.running, .cancelling, .sending, .starting].contains(phase) || turnID != nil { return Strings.agentNewWhileWorking }
        return nil
    }

    /// AGENT-NEW-1: the conversation was replaced (here or on another device).
    /// Everything that belonged to it goes; the words being typed stay.
    mutating func startOver() {
        let keep = draft
        let catalog = models
        self = AgentChatModel()
        draft = keep
        models = catalog
    }

    var canSend: Bool { phase == .ready && identity != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// ATTACH-1: a message of only attachments has something to say too.
    func canSend(attached: Bool) -> Bool { canSend || (attached && phase == .ready && identity != nil) }
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
    ///
    /// AGENT-NEW-1: a pending choice wins - it is what the next turn carries,
    /// and the header marks it (↑) until the provider confirms it. Now that core
    /// tells the thread's model from the start, letting the confirmed value win
    /// made a tap in the picker look as if it did nothing.
    var effectiveModel: String? { selectedModel ?? usage.model }
    var effectiveEffort: String? { selectedEffort ?? usage.effort }

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
            if message.role == .user, message.text == localEcho?.text || (localEcho != nil && echoCarriesAttachments) {
                localEcho = nil
                echoCarriesAttachments = false
            }
            upsert(.message(message))
        case .tool(let tool):
            guard tool.turnID == turnID else { return false }
            upsert(.tool(tool))
        case .toolOutput(let id, let turn, let delta, let truncated):
            // Output of a row this client does not hold (a snapshot older
            // than the command) changes nothing; the completion brings it.
            if turn == turnID, let index = rows.firstIndex(where: { $0.id == "tool:\(id)" }),
               case .tool(var tool) = rows[index] {
                tool.append(output: delta, truncated: truncated)
                rows[index] = .tool(tool)
            }
        case .turnFinished(let id, _):
            guard id == turnID else { return false }
            turnID = nil; phase = .ready; localEcho = nil
        case .turnFailed(let id, let message):
            guard id == turnID else { return false }
            turnID = nil; error = message; phase = .failed; localEcho = nil
        case .approvalRequested(let approval):
            receive(approval)
        case .approvalResolved(let requestID, let decision, let source):
            guard let index = approvals.firstIndex(where: { $0.requestID == requestID }) else { break }
            approvals[index].state = .resolved(decision: decision, source: source)
            if source != "client" { approvals[index].answered = nil }
        case .statusChanged(let value): status = value
        case .queueChanged(let value): queue = value
        case .checklistUpdated(let value): checklist = value
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
        // AGENT-QUEUE-1: earlier rows this client already read stay in front
        // while the snapshot still starts where they end.
        var rows = snapshot.rows
        var before = snapshot.earlier
        if before, identity == snapshot.identity, let first = rows.first?.id,
           let at = self.rows.firstIndex(where: { $0.id == first }), at > 0 {
            let fresh = Set(rows.map(\.id))
            rows = self.rows[..<at].filter { !fresh.contains($0.id) } + rows
            before = earlier
        }
        guard restore(identity: snapshot.identity, rows: rows,
                      activeTurn: snapshot.activeTurn, sequence: snapshot.sequence) else { return false }
        earlier = before && !rows.isEmpty
        loadingEarlier = false
        queue = snapshot.queue
        checklist = snapshot.checklist
        let waiting = Set(snapshot.pendingApprovals.map(\.requestID))
        var merged = snapshot.pendingApprovals.map { incoming in
            var approval = incoming
            // A prompt this client already placed keeps its place.
            let known = approvals.first { $0.requestID == incoming.requestID }
            approval.afterRowID = known?.afterRowID ?? rows.last?.id
            return approval
        }
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

    /// AGENT-FIX-2. A prompt arriving. The provider re-raising the same id
    /// while it waits is the same prompt, replaced in place. The same id on an
    /// answered prompt is a new one (codex numbers requests per connection and
    /// starts again after a reconnect): the old line stays where it was.
    mutating func receive(_ incoming: AgentChatApproval) {
        var approval = incoming
        approval.afterRowID = rows.last?.id
        if let index = approvals.firstIndex(where: { $0.requestID == approval.requestID }) {
            if approvals[index].isPending {
                approval.afterRowID = approvals[index].afterRowID ?? approval.afterRowID
                approvals[index] = approval
                return
            }
            approvals[index].retire()
        }
        approvals.append(approval)
    }

    /// The conversation as it is drawn: the rows, each followed by the
    /// answered prompts that belong to it. An answered prompt whose rows are
    /// all gone is not drawn; a prompt still waiting is never here - it stays
    /// at the end (`waitingApprovals`), where the person has to act on it.
    var timeline: [AgentTimelineEntry] {
        let present = Set(rows.map(\.id))
        var placed: [String: [AgentChatApproval]] = [:]
        for approval in approvals where !approval.isPending {
            let anchor = approval.itemID.map { "tool:\($0)" }.flatMap { present.contains($0) ? $0 : nil }
                ?? approval.afterRowID.flatMap { present.contains($0) ? $0 : nil }
            if let anchor { placed[anchor, default: []].append(approval) }
        }
        var entries: [AgentTimelineEntry] = []
        for row in rows {
            entries.append(.row(row))
            for approval in placed[row.id] ?? [] { entries.append(.answered(approval)) }
        }
        return entries
    }
    var waitingApprovals: [AgentChatApproval] { approvals.filter(\.isPending) }

    /// A decision is optimistic only in the sense that the card is locked while
    /// the request is in flight; the result row still waits for the host.
    mutating func beginDecision(requestID: String, decision: String) -> Bool {
        guard let index = approvals.firstIndex(where: { $0.requestID == requestID }),
              case .pending = approvals[index].state else { return false }
        approvals[index].state = .deciding(decision)
        return true
    }
    /// AGENT-COLLIE-1: a `userInput` answer going out. The card locks like a
    /// decision, and the answered line will say what was chosen - every
    /// answer except a secret one, which is never kept.
    mutating func beginAnswer(requestID: String, input: [String: [String]]) -> Bool {
        guard let index = approvals.firstIndex(where: { $0.requestID == requestID }),
              case .pending = approvals[index].state else { return false }
        approvals[index].state = .deciding("input")
        // AGENT-QUEUE-1: should the same request come back, it comes back at
        // "Check your answers" with these answers - except a secret one, which
        // is never kept once it has been sent.
        let approval = approvals[index]
        var draft = questionDrafts[requestID].flatMap { $0.fingerprint == approval.questionsFingerprint ? $0 : nil }
            ?? AgentQuestionDraft(fingerprint: approval.questionsFingerprint)
        for question in approval.questions {
            if question.secret { draft.typed[question.id] = nil; draft.chosen[question.id] = nil; draft.others.remove(question.id) }
            else if let words = input[question.id]?.first, !question.choices.contains(where: { $0.label == words }) {
                draft.others.insert(question.id); draft.typed[question.id] = words
            } else if let words = input[question.id]?.first { draft.chosen[question.id] = words }
        }
        draft.page = approval.questions.count > 1 ? approval.questions.count : 0
        keep(draft, for: requestID)
        let shown = approvals[index].questions.filter { !$0.secret }
            .compactMap { input[$0.id].map { $0.joined(separator: ", ") } } // non-copy: the person's own words
            .filter { !$0.isEmpty }
        approvals[index].answered = shown.isEmpty ? nil : shown
        return true
    }
    mutating func settleDecision(requestID: String, decision: String?, source: String) {
        guard let index = approvals.firstIndex(where: { $0.requestID == requestID }) else { return }
        approvals[index].state = .resolved(decision: decision, source: source)
        if source != "client" { approvals[index].answered = nil }
    }
    mutating func failDecision(requestID: String) {
        guard let index = approvals.firstIndex(where: { $0.requestID == requestID }),
              approvals[index].isDeciding else { return }
        approvals[index].state = .pending
        approvals[index].answered = nil
    }

    /// `attachments`: how many chips ride with the words, and how many of them
    /// are pictures (ATTACH-1).
    mutating func beginSend(attachments: Int = 0, images: Int = 0) -> String? {
        guard canSend(attached: attachments > 0) else { return nil }
        let text = draft
        phase = .sending
        error = nil
        // The composer empties and the words appear in the list in this frame,
        // before anything is on the wire. `localEcho` is not a row: it claims
        // only that the user typed this, which is the one thing that is already
        // true.
        localEcho = AgentChatMessage(id: Self.localEchoID, turnID: "", role: .user, text: text,
                                     images: images > 0 ? images : nil)
        echoCarriesAttachments = attachments > 0
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
    /// AGENT-PLAN-1 (Leo: no slash list - what is typed goes through). What
    /// the host did with the words. `/plan`, `/compact` and `/diff` start no
    /// turn of their own, so nothing waits for one and the words do not stay
    /// on screen as if sent; `/diff` brings the conversation's file changes.
    /// `/plan <words>` and `/review` are turns whose user row codex words
    /// differently from what was typed, so any user row of the turn is the echo.
    mutating func sendAnswered(text: String, receipt: AgentSendReceipt) {
        sendAcknowledged(text: text)
        if receipt.startsNoTurn {
            localEcho = nil
            echoCarriesAttachments = false
            if phase == .sending { phase = turnID == nil ? .ready : .running }
            if receipt.command == "diff" {
                diff = AgentDiffState(changes: receipt.changes, omitted: receipt.changesOmitted)
            }
        } else if receipt.command != nil, localEcho != nil {
            echoCarriesAttachments = true
        }
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
    /// AGENT-QUEUE-1: a page of earlier rows, in front of what is here (a
    /// row already here is not added twice).
    mutating func prependEarlier(_ page: AgentHistoryPage) {
        let have = Set(rows.map(\.id))
        rows = page.rows.filter { !have.contains($0.id) } + rows
        earlier = page.earlier
        loadingEarlier = false
    }
    /// AGENT-QUEUE-1: a question card's progress, kept for when it is drawn again.
    mutating func keep(_ draft: AgentQuestionDraft, for requestID: String) {
        questionDrafts[requestID] = draft
        if questionDrafts.count > 16, let oldest = questionDrafts.keys.first(where: { key in
            !approvals.contains { $0.requestID == key && $0.isPending }
        }) {
            questionDrafts[oldest] = nil
        }
    }
    /// A card's saved progress, when it is for these very questions.
    func draft(for approval: AgentChatApproval) -> AgentQuestionDraft? {
        questionDrafts[approval.requestID].flatMap { $0.fingerprint == approval.questionsFingerprint ? $0 : nil }
    }
    /// AGENT-QUEUE-1: the host's answer to a queue route is the queue now.
    mutating func queueReplaced(_ value: [AgentQueuedMessage]?) { queue = value }
    mutating func connectionLost() { phase = .reconnecting }
    mutating func fail(_ message: String) { error = message; phase = .failed; ensureRequestID = nil }
    private mutating func upsert(_ value: AgentChatRow) {
        if let index = rows.firstIndex(where: { $0.id == value.id }) { rows[index] = value }
        else { rows.append(value) }
    }
}
