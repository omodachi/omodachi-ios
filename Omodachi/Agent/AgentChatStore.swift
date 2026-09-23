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
    func slashCommands() async throws -> AgentSlashCatalog
    func executeSlash(commandID: String, revision: String, arguments: String, requestID: UUID) async throws -> AgentSlashResult
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
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution
    func models() async throws -> AgentModelCatalog
}

extension AgentChatTransport {
    func slashCommands() async throws -> AgentSlashCatalog { throw AgentChatHostError(code: "slash_commands_unavailable") }
    func executeSlash(commandID: String, revision: String, arguments: String, requestID: UUID) async throws -> AgentSlashResult { throw AgentChatHostError(code: "slash_commands_unavailable") }
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
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        throw AgentChatHostError(code: "agent_chat_unavailable")
    }
    func models() async throws -> AgentModelCatalog { throw AgentChatHostError(code: "agent_chat_unavailable") }
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
    var onNativeCommand: ((AgentSlashNativeRequest) -> Void)?
    /// The surface posts a local notification when the agent starts waiting and
    /// this app is not the thing the user is looking at. It never fires in the
    /// foreground: the card is already on screen.
    var onApprovalRequested: ((AgentChatApproval) -> Void)?
    private var pendingSend: (id: UUID, text: String)?

    init(transport: any AgentChatTransport) { self.transport = transport }

    /// Called only by explicit navigation into the Agent surface. The root must
    /// keep this store for the same host/default agent when switching surfaces.
    func open() async {
        guard !opening, observation == nil else { return }
        opening = true
        visibility &+= 1
        let generation = visibility
        defer { opening = false }
        do {
            let snapshot: AgentChatSnapshot
            if let identity = model.identity {
                snapshot = try await transport.snapshot(for: identity)
            } else {
                guard model.beginEnsure() != nil else { return }
                snapshot = try await transport.ensureDefault()
            }
            guard generation == visibility else { return }
            guard model.restore(snapshot) else { throw AgentChatFailure.identityChanged }
            if let pending = pendingSend, snapshot.acceptedRequestIDs.contains(pending.id.uuidString) {
                model.sendAcknowledged(text: pending.text)
                pendingSend = nil
            }
            model.handoff = .none
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
                    if envelope.resyncRequired { self.model.connectionLost(); return }
                    if let snapshot = envelope.snapshot {
                        guard snapshot.identity == identity, self.model.restore(snapshot) else { continue }
                    } else if let event = envelope.event {
                        let applied = self.model.apply(event, identity: envelope.identity, sequence: envelope.sequence)
                        if applied { AgentChatTrace.trace(event, sequence: envelope.sequence) }
                        if applied, case .approvalRequested(let approval) = event { self.onApprovalRequested?(approval) }
                    }
                    if self.model.phase == .reconnecting { return }
                }
                if !Task.isCancelled && self.visibility == generation { self.model.connectionLost() }
            } catch {
                if !Task.isCancelled && self.visibility == generation { self.model.connectionLost() }
            }
        }
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

    func send() async {
        if AgentSlashInvocation.parse(model.draft) != nil && !model.slash.literalText {
            await executeSlash()
            return
        }
        guard let identity = model.identity, let text = model.beginSend() else { return }
        if let pending = pendingSend, pending.text != text {
            model.fail(Strings.agentPreviousSendUnconfirmed)
            return
        }
        let request = pendingSend?.id ?? UUID()
        pendingSend = (request, text)
        // The words are already on screen at this point — `beginSend` put them
        // there and emptied the composer — so everything after this line is
        // confirmation, not reveal.
        AgentChatTrace.send("echoed", request: request.uuidString, bytes: text.utf8.count)
        do {
            AgentChatTrace.send("request-out", request: request.uuidString)
            try await transport.send(text, requestID: request, model: model.selectedModel,
                                     effort: model.selectedEffort, to: identity)
            AgentChatTrace.send("core-accepted", request: request.uuidString)
            model.sendAcknowledged(text: text)
            model.slash.literalText = false
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
            model.slash.notice = Strings.agentSteerTooLate
        } catch {
            model.slash.notice = Strings.agentSteerUnconfirmed
        }
    }

    /// One decision per prompt. The card locks while the answer is in flight,
    /// and only the host's own reply — or the resolved event — settles it.
    func decide(requestID: String, decision: String) async {
        guard let identity = model.identity, model.beginDecision(requestID: requestID, decision: decision) else { return }
        await resolve(requestID: requestID, decision: decision, input: nil, identity: identity)
    }

    func answer(requestID: String, input: [String: [String]]) async {
        guard let identity = model.identity, !input.isEmpty,
              model.beginDecision(requestID: requestID, decision: "input") else { return }
        await resolve(requestID: requestID, decision: nil, input: input, identity: identity)
    }

    private func resolve(requestID: String, decision: String?, input: [String: [String]]?,
                         identity: AgentChatIdentity) async {
        do {
            let result = try await transport.resolveApproval(requestID: requestID, decision: decision,
                                                             input: input, in: identity)
            guard result.resolved else {
                model.failDecision(requestID: requestID)
                model.slash.notice = Strings.agentAnswerUnconfirmed
                return
            }
            model.settleDecision(requestID: requestID, decision: result.decision, source: "client")
        } catch let error as AgentChatHostError where error.code == "agent_approval_unknown" {
            // Answered somewhere else between the tap and the request.
            model.settleDecision(requestID: requestID, decision: nil, source: "elsewhere")
        } catch {
            model.failDecision(requestID: requestID)
            model.slash.notice = Strings.agentAnswerUnconfirmed
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

    func loadSlashCommands() async {
        guard !model.slash.loading, model.identity != nil else { return }
        model.slash.loading = true
        defer { model.slash.loading = false }
        do { model.slash.catalog = try await transport.slashCommands(); model.slash.notice = nil }
        catch { model.slash.notice = Strings.agentCommandsUnreadable }
    }

    func selectSlash(_ command: AgentSlashDescriptor) {
        let args = AgentSlashInvocation.parse(model.draft)?.arguments ?? ""
        model.draft = "/" + command.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (args.isEmpty ? " " : args)
        model.slash.literalText = false
    }

    func executeSlash() async {
        guard !model.slash.executing, let parsed = AgentSlashInvocation.parse(model.draft) else { return }
        if model.slash.catalog == nil { await loadSlashCommands() }
        guard let command = model.slash.exact(model.draft), let catalog = model.slash.catalog else {
            model.slash.notice = Strings.agentUnknownCommand
            return
        }
        guard command.available, command.execution != "unsupported" else {
            model.slash.notice = command.reason ?? Strings.agentCommandUnsupported
            return
        }
        guard model.phase == .ready || (model.phase == .running && command.turnPolicy == "allowed") else {
            model.slash.notice = Strings.agentWaitForTurn
            return
        }
        let draft = model.draft
        model.slash.executing = true
        defer { model.slash.executing = false }
        do {
            let result = try await transport.executeSlash(commandID: command.id, revision: catalog.revision,
                arguments: parsed.arguments, requestID: UUID())
            guard result.commandID == command.id else { model.slash.notice = Strings.agentCommandUnconfirmed; return }
            model.slash.notice = result.message ?? result.status
            if let request = result.nativeRequest {
                if let onNativeCommand { onNativeCommand(request) }
                else { model.slash.notice = Strings.agentCommandNeedsNative }
            }
            if ["completed", "applied"].contains(result.status), model.draft == draft { model.draft = "" }
        } catch { model.slash.notice = Strings.agentCommandUnconfirmed }
    }

    func cancel() async {
        guard let identity = model.identity, let turn = model.requestCancel() else { return }
        do { try await transport.interrupt(turnID: turn, in: identity) }
        catch { model.fail(Strings.agentStopUnconfirmed) }
    }
}
