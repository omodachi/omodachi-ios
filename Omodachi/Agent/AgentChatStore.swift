import Foundation
import Combine

struct AgentChatSnapshot: Sendable {
    let identity: AgentChatIdentity
    let rows: [AgentChatRow]
    let activeTurn: String?
    let sequence: Int
    var acceptedRequestIDs: [String] = []
    var pendingApprovals: [AgentChatApproval] = []
    var status: AgentChatStatus = .unknown
    var usage: AgentChatUsage = .empty
    /// AGENT-QUEUE-1: rows before the first one here; codex's queue (nil: none);
    /// its plan checklist.
    var earlier = false
    var queue: [AgentQueuedMessage]? = nil
    var checklist: AgentChecklist? = nil
}
struct AgentChatEnvelope: Sendable {
    let identity: AgentChatIdentity
    let sequence: Int
    var event: AgentChatEvent? = nil
    var snapshot: AgentChatSnapshot? = nil
    /// The host's own "my queue overflowed, re-read me" frame. It carries no
    /// sequence of its own, so it is a flag rather than an event.
    var resyncRequired = false
}

/// Host adapter boundary. No endpoints or provider command lines are invented
/// here; B maps existing ensure + the official provider protocol to this shape.
protocol AgentChatTransport: Sendable {
    func ensureDefault() async throws -> AgentChatSnapshot
    func prepareHandoff() async throws -> AgentChatHandoffPlan
    func confirmHandoff(planID: String) async throws -> AgentChatHandoffResult
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error>
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws
    /// A per-turn model/effort override, which is the only way codex takes one.
    func send(_ text: String, requestID: UUID, model: String?, effort: String?,
              to identity: AgentChatIdentity) async throws
    func steer(_ text: String, requestID: UUID, in identity: AgentChatIdentity) async throws
    /// ATTACH-1: the chips' ids and markers ride with the words.
    func send(_ text: String, requestID: UUID, model: String?, effort: String?,
              attachments: [AttachmentRef], to identity: AgentChatIdentity) async throws -> AgentSendReceipt
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution
    func models() async throws -> AgentModelCatalog
    /// AGENT-NEW-1: `POST /v1/agent/default/chat:new` for the conversation on
    /// screen; the answer is the new, empty conversation.
    func newConversation(expected identity: AgentChatIdentity) async throws -> AgentChatSnapshot
    /// AGENT-PLAN-1: `POST /v1/agent/default/chat/mode` - codex's collaboration
    /// mode for the turns that follow. The answer is the usage, mode included.
    func setMode(_ mode: String) async throws -> AgentChatUsage
    /// AGENT-QUEUE-1: `POST …/chat/queue` - words for when the running turn
    /// ends, kept in codex's own queue; the answer is the queue now.
    func queue(_ text: String, requestID: UUID, in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]?
    /// `POST …/chat/queue/{id}:send | :edit | :delete`; the answer is the queue now.
    func queueItem(_ id: String, action: AgentQueueAction, text: String?,
                   in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]?
    /// `GET …/chat/history?before=` - the rows before `before`.
    func history(before: String?, limit: Int, in identity: AgentChatIdentity) async throws -> AgentHistoryPage
    /// A decline with one line of why (`reason`); the answer says where the
    /// words went (`delivery`).
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?, reason: String?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution
}

extension AgentChatTransport {
    func prepareHandoff() async throws -> AgentChatHandoffPlan { throw AgentChatHostError(code: "handoff_transport_unavailable") }
    func confirmHandoff(planID: String) async throws -> AgentChatHandoffResult { throw AgentChatHostError(code: "handoff_transport_unavailable") }
    /// A transport that has no override route still delivers the message; it
    /// does not silently drop the words because it cannot carry the choice.
    func send(_ text: String, requestID: UUID, model: String?, effort: String?,
              to identity: AgentChatIdentity) async throws {
        guard model == nil, effort == nil else { throw AgentChatHostError(code: "agent_chat_unavailable") }
        try await send(text, requestID: requestID, to: identity)
    }
    func steer(_ text: String, requestID: UUID, in identity: AgentChatIdentity) async throws {
        throw AgentChatHostError(code: "agent_chat_unavailable")
    }
    /// A transport with no attachment route still sends words alone; with
    /// chips it refuses rather than dropping the files.
    func send(_ text: String, requestID: UUID, model: String?, effort: String?,
              attachments: [AttachmentRef], to identity: AgentChatIdentity) async throws -> AgentSendReceipt {
        guard attachments.isEmpty else { throw AgentChatHostError(code: "agent_chat_unavailable") }
        try await send(text, requestID: requestID, model: model, effort: effort, to: identity)
        return AgentSendReceipt()
    }
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        throw AgentChatHostError(code: "agent_chat_unavailable")
    }
    func models() async throws -> AgentModelCatalog { throw AgentChatHostError(code: "agent_chat_unavailable") }
    func newConversation(expected identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        throw AgentChatHostError(code: "agent_chat_unavailable")
    }
    func setMode(_ mode: String) async throws -> AgentChatUsage {
        throw AgentChatHostError(code: "agent_mode_unavailable")
    }
    /// AGENT-QUEUE-1: a transport without the queue has none; the composer
    /// steers instead (its snapshots say `queue: nil`).
    func queue(_ text: String, requestID: UUID, in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]? {
        throw AgentChatHostError(code: "agent_queue_unavailable")
    }
    func queueItem(_ id: String, action: AgentQueueAction, text: String?,
                   in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]? {
        throw AgentChatHostError(code: "agent_queue_unavailable")
    }
    func history(before: String?, limit: Int, in identity: AgentChatIdentity) async throws -> AgentHistoryPage {
        AgentHistoryPage(rows: [], earlier: false)
    }
    /// A transport that cannot carry a reason still declines; the words come
    /// back as unsent (the person keeps them), never silently dropped.
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?, reason: String?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        var result = try await resolveApproval(requestID: requestID, decision: decision, input: input, in: identity)
        if reason != nil { result.delivery = "unsent" }
        return result
    }
}

enum AgentChatFailure: LocalizedError {
    case identityChanged
    var errorDescription: String? { Strings.agentIdentityChanged }
}

@MainActor final class AgentChatStore: ObservableObject {
    @Published var model = AgentChatModel()
    private let transport: any AgentChatTransport
    private var observation: Task<Void, Never>?
    private var opening = false
    private var visibility: UInt = 0
    private var pendingSend: (id: UUID, text: String)?
    /// AGENT-QUEUE-1: the words on their way to codex's queue; a second tap
    /// on the same words asks with the same id, so they are queued once.
    private var pendingQueue: (id: UUID, text: String)?
    /// AGENT-FIX-2: how many times in a row the panel has reconnected itself.
    private var recoveryAttempt = 0
    /// The pause before reconnecting itself, by attempt: 0.5 s doubling to 8 s.
    nonisolated static func recoveryDelay(attempt: Int) -> Double { min(8, 0.5 * pow(2, Double(min(attempt, 4)))) }
    /// AGENT-FIX-2: tests shorten the pause.
    var recoveryScale = 1.0
    /// AGENT-QUEUE-1 (the iPad flake in AGENTPLAN1UITests): one settling
    /// publish after a burst of events. On an iPad simulator, SwiftUI now and
    /// then never drew the *last* change of a quick burst - the store held
    /// codex's question (or the turn's end), `objectWillChange` had fired, and
    /// no view body ran again, so the card never appeared until something
    /// else changed (traced: it lands while the keyboard re-syncs the
    /// just-cleared composer). A real codex usually sends another event soon
    /// after; a burst that ends on a question must not depend on that.
    private var settling = false
    private func settle() {
        guard !settling else { return }
        settling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.settling = false
            self.objectWillChange.send()
        }
    }

    /// ATTACH-1: the chips above the composer. They read and write this
    /// store's own draft.
    private(set) var attachments: AttachmentTray!

    init(transport: any AgentChatTransport,
         uploader: (@MainActor () throws -> any AttachmentUploading)? = nil) {
        self.transport = transport
        let upload = uploader ?? { DemoAttachmentUploader() }
        attachments = AttachmentTray(uploader: upload, target: { .agent },
                                     readDraft: { [weak self] in self?.model.draft ?? "" },
                                     writeDraft: { [weak self] in self?.model.draft = $0 })
    }

    /// NOTIFY-2: whether `model.approvals` is being kept current right now. Off
    /// the Agent panel it is not, and the bar's badge must not read a frozen list.
    var isObserving: Bool { observation != nil }

    /// Called only by explicit navigation into the Agent surface. The root must
    /// keep this store for the same host/default agent when switching surfaces.
    func open() async {
        guard !opening, observation == nil else { return }
        opening = true
        visibility &+= 1
        let generation = visibility
        defer { opening = false }
        do {
            var snapshot: AgentChatSnapshot
            if let identity = model.identity {
                do {
                    snapshot = try await transport.snapshot(for: identity)
                } catch AgentChatFailure.identityChanged {
                    // AGENT-NEW-1: the default conversation was replaced -
                    // here or on another device. Not an error: follow it,
                    // keeping only the words being typed.
                    guard generation == visibility else { return }
                    model.startOver()
                    pendingSend = nil
                    guard model.beginEnsure() != nil else { return }
                    snapshot = try await transport.ensureDefault()
                } catch let error as AgentChatHostError where error.code == "agent_chat_unavailable" {
                    // AGENT-FIX-2: core is up but not attached to the agent
                    // (it restarted, or its app-server connection dropped) and
                    // answers `agent_chat_not_ready`. Reading the snapshot
                    // again can never fix that; the ensure entering the panel
                    // does (A-63) - same thread, history kept.
                    guard generation == visibility else { return }
                    snapshot = try await transport.ensureDefault()
                }
            } else {
                guard model.beginEnsure() != nil else { return }
                snapshot = try await transport.ensureDefault()
            }
            guard generation == visibility else { return }
            if let current = model.identity, current != snapshot.identity {
                model.startOver()
                pendingSend = nil
            }
            guard model.restore(snapshot) else { throw AgentChatFailure.identityChanged }
            if let pending = pendingSend, snapshot.acceptedRequestIDs.contains(pending.id.uuidString) {
                model.sendAcknowledged(text: pending.text)
                pendingSend = nil
            }
            model.handoff = .none
            recoveryAttempt = 0
            observe(generation: generation)
        } catch {
            guard generation == visibility else { return }
            if let hostError = error as? AgentChatHostError, hostError.code == "existing_thread_handoff_required" {
                model.handoff = .required
            }
            model.fail(error.localizedDescription)
        }
    }

    func prepareHandoff() async {
        guard !opening else { return }
        switch model.handoff {
        case .required, .problem: break
        default: return
        }
        let generation = visibility
        model.handoff = .preparing
        do {
            let plan = try await transport.prepareHandoff()
            guard generation == visibility else { return }
            guard plan.status == "prepared", plan.requiresConfirmation,
                  plan.agentID == "default", !plan.providerSessionID.isEmpty else {
                throw AgentChatHostError(code: "handoff_target_changed")
            }
            model.handoff = .prepared(plan)
        } catch {
            guard generation == visibility else { return }
            model.handoff = .problem(error.localizedDescription)
        }
    }

    /// This method is wired ONLY to the explicit confirmation button after the
    /// actual plan is visible. Entry, prepare and retry never call it.
    func confirmPreparedHandoff() async {
        guard case .prepared(let plan) = model.handoff else { return }
        let generation = visibility
        model.handoff = .confirming(plan)
        do {
            let result = try await transport.confirmHandoff(planID: plan.planID)
            guard generation == visibility else { return }
            guard result.status == "completed", result.sameThread, result.herdrPaneRegistered,
                  result.providerSessionID == plan.providerSessionID, result.paneID == plan.paneID else {
                throw AgentChatHostError(code: "handoff_thread_unconfirmed")
            }
            model.handoff = .none
            await retry() // Same default ensure now returns its real snapshot.
        } catch {
            guard generation == visibility else { return }
            model.handoff = .problem(error.localizedDescription)
        }
    }

    // MARK: - AGENT-NEW-1: New conversation

    /// The header control: the card appears; nothing starts until its button.
    func askNewConversation() {
        if case .starting = model.fresh { return }
        model.fresh = .confirming
    }
    func cancelNewConversation() {
        if case .starting = model.fresh { return }
        model.fresh = .none
    }
    /// Wired ONLY to the card's own button. A running turn or a waiting
    /// question keeps it off (the card says which).
    func confirmNewConversation() async {
        guard model.fresh == .confirming, model.newConversationRefusal == nil, let identity = model.identity else { return }
        model.fresh = .starting
        do {
            let snapshot = try await transport.newConversation(expected: identity)
            // Stop following the old conversation, then follow the new one.
            visibility &+= 1
            observation?.cancel()
            observation = nil
            model.startOver()
            pendingSend = nil
            guard model.restore(snapshot) else { throw AgentChatFailure.identityChanged }
            observe(generation: visibility)
        } catch let error as AgentChatHostError where error.code == "agent_identity_changed" {
            // Another device was first: show the conversation that is the
            // default now.
            model.fresh = .none
            await retry()
        } catch {
            model.fresh = .problem(error.localizedDescription)
        }
    }

    // MARK: - AGENT-PLAN-1: Plan mode

    /// The header's Plan chip: back to the default mode. While a turn runs the
    /// chip says why it cannot instead (`modeRefusal`).
    @discardableResult
    func setMode(_ mode: String) async -> Bool {
        if let refusal = model.modeRefusal {
            model.notice = refusal
            return false
        }
        model.modeBusy = true
        do {
            model.modeChanged(try await transport.setMode(mode))
            return true
        } catch let error as AgentChatHostError where error.code != "agent_chat_unavailable" {
            model.modeBusy = false
            model.notice = error.localizedDescription
        } catch {
            model.modeBusy = false
            model.notice = Strings.agentPlanFailed
        }
        return false
    }

    /// The chip's tap.
    func leavePlan() async { await setMode("default") }

    /// After a plan: what codex's TUI offers as "Yes, implement this plan" -
    /// back to the default mode, then the words that ask for it, sent as the
    /// person's own message. Whatever they were typing stays in the composer.
    func implementPlan() async {
        guard model.actionablePlanID != nil, model.modeRefusal == nil, let identity = model.identity else { return }
        guard await setMode("default") else { return }
        let kept = model.draft
        model.draft = Strings.agentPlanImplementMessage
        guard let text = model.beginSend() else { model.draft = kept; return }
        model.draft = kept
        let request = UUID()
        do {
            try await transport.send(text, requestID: request, model: model.selectedModel,
                                     effort: model.selectedEffort, to: identity)
        } catch {
            model.sendFailed(text: text, message: Strings.agentSendUnconfirmed)
            model.draft = kept
        }
    }

    func deferHandoff() {
        if case .confirming = model.handoff { return }
        model.handoff = .required
    }

    private func observe(generation: UInt) {
        guard let identity = model.identity else { return }
        let cursor = model.lastSequence
        observation = Task { [weak self] in
            guard let self else { return }
            defer { if self.visibility == generation { self.observation = nil } }
            do {
                let stream = try await self.transport.events(for: identity, after: cursor)
                for try await envelope in stream {
                    guard !Task.isCancelled, self.visibility == generation else { return }
                    // The host's queue overflowed: its own events are gone, so
                    // the only honest recovery is to read the snapshot again.
                    if envelope.resyncRequired { self.model.connectionLost(); self.recover(after: generation); return }
                    if let snapshot = envelope.snapshot {
                        guard snapshot.identity == identity, self.model.restore(snapshot) else { continue }
                    } else if let event = envelope.event {
                        let applied = self.model.apply(event, identity: envelope.identity, sequence: envelope.sequence)
                        if applied { AgentChatTrace.trace(event, sequence: envelope.sequence) }
                    }
                    self.settle()
                    if self.model.phase == .reconnecting { self.recover(after: generation); return }
                }
                if !Task.isCancelled && self.visibility == generation { self.model.connectionLost(); self.recover(after: generation) }
            } catch {
                if !Task.isCancelled && self.visibility == generation { self.model.connectionLost(); self.recover(after: generation) }
            }
        }
    }

    /// AGENT-FIX-2. The stream broke - the host dropped its backlog, a
    /// sequence gap, the provider connection - while the panel is on screen.
    /// It used to stop at "Reconnecting…" with a Reconnect control drawn below
    /// the visible end of the list, so nothing reconnected until the person
    /// left the panel and came back. Now the panel reads the host again by
    /// itself: after 0.5 s, then 1, 2, 4, 8 s while it keeps failing, for as
    /// long as the panel stays open. What is on screen stays on screen.
    private func recover(after generation: UInt) {
        guard visibility == generation else { return }
        let delay = Self.recoveryDelay(attempt: recoveryAttempt) * recoveryScale
        recoveryAttempt += 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.visibility == generation, self.observation == nil,
                  self.model.handoff == .none,
                  self.model.phase == .reconnecting || self.model.phase == .failed else { return }
            await self.retry()
            if self.model.phase == .failed, self.model.handoff == .none, self.recoveryAttempt < 6 {
                self.recover(after: self.visibility)
            }
        }
    }

    /// REL2-POLISH-1: how many Agent panels are on screen. Turning the phone
    /// draws the panel again, and SwiftUI starts the new one (its `.task`,
    /// `open()`) before it tells the old one it went away (`onDisappear`).
    /// `open()` found the old panel's observation still running and did
    /// nothing; the old panel's `leave()` then stopped it, and the panel on
    /// screen followed nothing - `/plan` turned Plan mode on at the host and
    /// no chip came, a reply never arrived - until the person left the panel
    /// and came back. The panel says when it appears and disappears; only the
    /// last one going away leaves.
    private var shown = 0
    func panelAppeared() { shown += 1 }
    func panelDisappeared() {
        shown = max(0, shown - 1)
        if shown == 0 { leave() }
    }

    /// Leaving this surface stops UI observation only. Never stop/kill/recreate
    /// the provider session or release the independent Remote session here.
    func leave() {
        visibility &+= 1
        observation?.cancel()
        observation = nil
        if model.handoff != .none { model.handoff = .required }
        if model.phase == .starting || model.phase == .sending { model.connectionLost() }
    }

    func retry() async {
        leave()
        await open()
    }

    /// AGENT-PLAN-1 (Leo: "甚至是 / 的优化整个都可以砍掉 只透传"): what is typed
    /// goes to codex as typed - a slash command too. The host handles the few
    /// basics it must (`AgentChatModel.sendAnswered`).
    func send() async {
        // ATTACH-1: an upload still going holds Send until it is done.
        if attachments.isUploading { attachments.say(Strings.attachWait); return }
        let refs = attachments.refs
        guard let identity = model.identity,
              let text = model.beginSend(attachments: refs.count, images: attachments.readyImageCount) else { return }
        let key = text + "\u{0}" + refs.map(\.id).joined(separator: ",")
        if let pending = pendingSend, pending.text != key {
            model.fail(Strings.agentPreviousSendUnconfirmed)
            return
        }
        let request = pendingSend?.id ?? UUID()
        pendingSend = (request, key)
        // The words are already on screen at this point — `beginSend` put them
        // there and emptied the composer — so everything after this line is
        // confirmation, not reveal.
        AgentChatTrace.send("echoed", request: request.uuidString, bytes: text.utf8.count)
        do {
            AgentChatTrace.send("request-out", request: request.uuidString)
            // The receipt says what the host did with the words, even with no
            // chips (AGENT-PLAN-1: `/plan`, `/compact`, `/review`, `/diff`).
            let receipt = try await transport.send(text, requestID: request, model: model.selectedModel,
                                                   effort: model.selectedEffort, attachments: refs, to: identity)
            if !refs.isEmpty { attachments.clear() }
            AgentChatTrace.send("core-accepted", request: request.uuidString)
            model.sendAnswered(text: text, receipt: receipt)
            if receipt.imagesAsPaths { model.notice = Strings.attachPathOnly }
            pendingSend = nil
        } catch let error as AgentChatHostError where error.code == "attachment_gone" {
            model.sendFailed(text: text, message: Strings.attachGone)
            pendingSend = nil
        } catch let error as AgentChatHostError where ["agent_mode_unavailable", "agent_busy"].contains(error.code) {
            // A refusal the host names in words (Plan mode on a codex that
            // cannot, or a turn already running) is said; the words come back.
            model.sendFailed(text: text, message: error.localizedDescription)
            pendingSend = nil
        } catch {
            // The optimistic copy comes back off the screen and the words go
            // back into the composer: the send is unconfirmed, so the list must
            // not keep showing a message that may never have been said.
            model.sendFailed(text: text,
                             message: Strings.agentSendUnconfirmed)
            // No automatic retry: the provider may already have accepted it.
        }
    }

    /// Interjecting into the running turn. `turn/steer` has no delivery
    /// journal, so a failure is reported and the words stay in the composer
    /// rather than being sent a second time.
    func steer() async {
        guard let identity = model.identity, let text = model.beginSteer() else { return }
        do {
            try await transport.steer(text, requestID: UUID(), in: identity)
            model.steerAcknowledged(text: text)
        } catch let error as AgentChatHostError where error.code == "agent_not_working" {
            model.notice = Strings.agentSteerTooLate
        } catch let error as AgentChatHostError where error.code == "agent_command_while_working" {
            // AGENT-PLAN-1: `/plan`, `/compact`, `/review`, `/diff` wait for the
            // turn to end; the words stay in the composer for then.
            model.notice = error.localizedDescription
        } catch {
            model.notice = Strings.agentSteerUnconfirmed
        }
    }

    /// One decision per prompt. The card locks while the answer is in flight,
    /// and only the host's own reply — or the resolved event — settles it.
    func decide(requestID: String, decision: String) async {
        guard let identity = model.identity, model.beginDecision(requestID: requestID, decision: decision) else { return }
        await resolve(requestID: requestID, decision: decision, input: nil, identity: identity)
    }

    /// AGENT-QUEUE-1: "No, and here's why" - a decline with one optional line.
    /// The host steers the words into the turn before it declines (or queues
    /// them as the next message); words it could not place come back into the
    /// composer, never lost.
    func declineWithReason(requestID: String, reason: String) async {
        let words = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity = model.identity, model.beginDecision(requestID: requestID, decision: "decline") else { return }
        await resolve(requestID: requestID, decision: "decline", input: nil, identity: identity,
                      reason: words.isEmpty ? nil : words)
    }

    func answer(requestID: String, input: [String: [String]]) async {
        guard let identity = model.identity, !input.isEmpty,
              model.beginAnswer(requestID: requestID, input: input) else { return }
        await resolve(requestID: requestID, decision: nil, input: input, identity: identity)
    }

    private func resolve(requestID: String, decision: String?, input: [String: [String]]?,
                         identity: AgentChatIdentity, reason: String? = nil) async {
        do {
            let result = reason == nil
                ? try await transport.resolveApproval(requestID: requestID, decision: decision, input: input, in: identity)
                : try await transport.resolveApproval(requestID: requestID, decision: decision, input: input,
                                                      reason: reason, in: identity)
            guard result.resolved else {
                model.failDecision(requestID: requestID)
                model.notice = Strings.agentAnswerUnconfirmed
                return
            }
            model.settleDecision(requestID: requestID, decision: result.decision, source: "client")
            if let reason, result.delivery == "unsent",
               model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.draft = reason
            }
        } catch let error as AgentChatHostError where error.code == "agent_approval_unknown" {
            // Answered somewhere else between the tap and the request.
            model.settleDecision(requestID: requestID, decision: nil, source: "elsewhere")
        } catch {
            model.failDecision(requestID: requestID)
            model.notice = Strings.agentAnswerUnconfirmed
        }
    }

    func loadModels() async {
        guard !model.modelsLoading, model.identity != nil else { return }
        model.modelsLoading = true
        defer { model.modelsLoading = false }
        do { model.models = try await transport.models(); model.modelsNotice = nil }
        catch { model.modelsNotice = Strings.agentModelsUnreadable }
    }

    /// A choice, not a host setting: it rides the next turn and the provider
    /// confirms what landed (`thread/settings/updated`).
    func choose(model id: String?, effort: String?) {
        model.selectedModel = id
        model.selectedEffort = effort
    }

    // MARK: - AGENT-QUEUE-1: the queue, earlier messages

    /// Send while a turn runs: codex keeps the words in its own queue and
    /// starts them when the turn ends. The composer empties once the host has
    /// them; the queue above it shows them meanwhile. A codex without the
    /// queue is steered into, as before.
    func queueDraft() async {
        guard model.canQueue, let identity = model.identity else { return }
        let text = model.draft
        let request = pendingQueue?.text == text ? pendingQueue!.id : UUID()
        pendingQueue = (request, text)
        do {
            model.queueReplaced(try await transport.queue(text, requestID: request, in: identity))
            pendingQueue = nil
            if model.draft == text { model.draft = "" }
        } catch let error as AgentChatHostError where error.code == "agent_queue_unavailable" {
            pendingQueue = nil
            model.queueReplaced(nil)
            await steer()
        } catch let error as AgentChatHostError where error.code == "agent_command_while_working" {
            pendingQueue = nil
            model.notice = error.localizedDescription
        } catch {
            model.notice = Strings.agentQueueUnconfirmed
        }
    }

    /// A waiting message's Send now, Edit or Delete. An edit that finds it
    /// gone (it started meanwhile) is not lost: the words go back into the
    /// composer.
    @discardableResult
    func queueItem(_ id: String, _ action: AgentQueueAction, text: String? = nil) async -> Bool {
        guard let identity = model.identity else { return false }
        do {
            model.queueReplaced(try await transport.queueItem(id, action: action, text: text, in: identity))
            return true
        } catch let error as AgentChatHostError where error.code == "agent_queue_item_gone" {
            model.queueReplaced(model.queue?.filter { $0.id != id })
            if action == .edit, let text, model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.draft = text
                model.notice = Strings.agentQueueEditGone
            }
            return action != .edit
        } catch {
            model.notice = Strings.agentQueueUnconfirmed
            return false
        }
    }

    /// "Earlier messages": the rows before the first one here. A page that
    /// does not come leaves the button for another try.
    func loadEarlier() async {
        guard model.earlier, !model.loadingEarlier, let identity = model.identity, let first = model.rows.first else { return }
        model.loadingEarlier = true
        let before: String
        switch first {
        case .message(let message): before = message.id
        case .tool(let tool): before = tool.id
        }
        do {
            let page = try await transport.history(before: before, limit: 100, in: identity)
            guard model.rows.first?.id == first.id else { model.loadingEarlier = false; return }
            model.prependEarlier(page)
        } catch {
            model.loadingEarlier = false
        }
    }

    /// AGENT-PLAN-1: the `/diff` card's own close.
    func closeDiff() { model.diff = nil }

    func cancel() async {
        guard let identity = model.identity, let turn = model.requestCancel() else { return }
        do { try await transport.interrupt(turnID: turn, in: identity) }
        catch { model.fail(Strings.agentStopUnconfirmed) }
    }
}
