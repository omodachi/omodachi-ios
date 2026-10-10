// lint:host-words — an agent's words and its plan, standing in for the host's.
import Foundation

/// AGENT-PLAN-1, simulator UI runs only (`--ui-testing --agent-plan-fixture`):
/// codex's Plan mode as the real 0.160 capture has it
/// (`omodachi-core/tests/fixtures/codex-0160-agent-plan1.json`). The thread
/// starts in the default mode. `/plan` typed as a message turns Plan mode on
/// (or off again), `/plan <words>` turns it on and sends them, as core does;
/// a Plan turn asks one question
/// (`request_user_input`), then streams a short reply and the proposed plan
/// (codex's `plan` item). The chip, `POST …/chat/mode`, leaves it. A turn in
/// the default mode answers in one line.
actor AgentChatPlanFixtureTransport: AgentChatTransport {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--agent-plan-fixture")
        #else
        return false
        #endif
    }

    static let identity = AgentChatIdentity(hostID: "fixture", agentID: "default", // non-copy: ids
                                            provider: "codex", providerSessionID: "fixture-plan")
    private var sequence = 0
    private var rows: [AgentChatRow] = [
        .message(.init(id: "u0", turnID: "t0", role: .user, text: "What does app.py do?")),
        .message(.init(id: "m0", turnID: "t0", role: .assistant,
                       text: "It starts a small web server on port 8080 and prints a greeting.")),
    ]
    private var activeTurn: String?
    private var pending: [AgentChatApproval] = []
    private var mode = "default"
    private var continuation: AsyncThrowingStream<AgentChatEnvelope, Error>.Continuation?
    private var turns = 0
    /// The Plan turn waiting on its question.
    private var asking: String?

    static let plan = "# Read the port from the environment\n\n1. Add a `PORT` setting with 9090 as the default.\n"
        + "2. Use it in `main()` instead of 8080.\n3. Run the tests on SQLite.\n"

    /// AGENT-UI-2 (`--agent-models-fixture` as well): the header as a real
    /// codex thread fills it - a long model id, `xhigh`, the context and both
    /// quota meters - and a `model/list` with long names and five efforts, so
    /// a phone shows whether the model control and the picker still read.
    static var models: Bool {
        requested && ProcessInfo.processInfo.arguments.contains("--agent-models-fixture")
    }

    private var usage: AgentChatUsage {
        guard Self.models else { return AgentChatUsage(mode: mode) }
        var last = AgentChatUsage.Tokens()
        last.totalTokens = 61_000
        return AgentChatUsage(last: last, modelContextWindow: 258_000,
                              primary: .init(usedPercent: 37, windowDurationMins: 300),
                              secondary: .init(usedPercent: 12, windowDurationMins: 10080),
                              model: "gpt-6.1-sol", effort: "xhigh", mode: mode)
    }

    static let catalog = """
        {"models": [
          {"id": "gpt-6.1-sol", "model": "gpt-6.1-sol", "display_name": "GPT-6.1 Sol", "is_default": true,
           "description": "Latest frontier agentic coding model.", "default_effort": "medium",
           "efforts": ["minimal", "low", "medium", "high", "xhigh"]},
          {"id": "gpt-6.1-sol-mini", "model": "gpt-6.1-sol-mini", "display_name": "GPT-6.1 Sol Mini",
           "description": "Smaller, faster and cheaper.", "default_effort": "medium",
           "efforts": ["low", "medium", "high"]},
          {"id": "gpt-5.6-sol-codex-max", "model": "gpt-5.6-sol-codex-max", "display_name": "GPT-5.6 Sol Codex Max",
           "description": "The previous generation, for long-running work.", "default_effort": "high",
           "efforts": ["minimal", "low", "medium", "high", "xhigh"]}
        ], "default": "gpt-6.1-sol"}
        """

    func models() async throws -> AgentModelCatalog {
        guard Self.models else { throw AgentChatHostError(code: "agent_chat_unavailable") }
        return try JSONDecoder().decode(AgentModelCatalog.self, from: Data(Self.catalog.utf8))
    }
    private var snapshot: AgentChatSnapshot {
        AgentChatSnapshot(identity: Self.identity, rows: rows, activeTurn: activeTurn, sequence: sequence,
                          pendingApprovals: pending, usage: usage)
    }

    func ensureDefault() async throws -> AgentChatSnapshot { snapshot }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        guard identity == Self.identity else { throw AgentChatFailure.identityChanged }
        return snapshot
    }

    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        guard identity == Self.identity else { throw AgentChatFailure.identityChanged }
        continuation?.finish()
        let (stream, continuation) = AsyncThrowingStream<AgentChatEnvelope, Error>.makeStream()
        self.continuation = continuation
        continuation.yield(AgentChatEnvelope(identity: Self.identity, sequence: self.sequence, snapshot: snapshot))
        return stream
    }

    private func emit(_ event: AgentChatEvent) {
        sequence += 1
        switch event {
        case .message(let message): put(.message(message))
        case .turnStarted(let id): activeTurn = id
        case .turnFinished: activeTurn = nil
        case .approvalRequested(let approval): pending.append(approval)
        case .approvalResolved(let id, _, _): pending.removeAll { $0.requestID == id }
        default: break
        }
        continuation?.yield(AgentChatEnvelope(identity: Self.identity, sequence: sequence, event: event))
    }

    private func put(_ row: AgentChatRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row } else { rows.append(row) }
    }

    private func changeMode(_ value: String) {
        mode = value
        emit(.usageUpdated(usage))
    }

    func setMode(_ value: String) async throws -> AgentChatUsage {
        guard ["plan", "default"].contains(value) else { throw AgentChatHostError(code: "invalid_agent_mode") }
        guard activeTurn == nil else { throw AgentChatHostError(code: "agent_busy") }
        changeMode(value)
        return usage
    }

    private func startTurn(_ text: String) {
        turns += 1
        let turn = "t\(turns)"
        emit(.turnStarted(turn))
        emit(.message(.init(id: "you-\(turns)", turnID: turn, role: .user, text: text)))
        if mode == "plan" {
            asking = turn
            emit(.approvalRequested(AgentChatApprovalWire(
                requestID: "q\(turns)", kind: "userInput", summary: "Database",
                details: ["item_id": .string("call-q-\(turns)"), "turn_id": .string(turn), "questions": .array([
                    .object(["id": .string("db"), "header": .string("Database"),
                             "question": .string("Which database should the tests use?"), "secret": .bool(false),
                             "options": .array([.string("SQLite (Recommended)"), .string("Postgres")]),
                             "choices": .array([
                                .object(["label": .string("SQLite (Recommended)"),
                                         "description": .string("Fast and needs no server.")]),
                                .object(["label": .string("Postgres"), "description": .string("Same as production.")])]),
                             "other": .bool(true)])])],
                decisions: []).value()))
        } else {
            emit(.message(.init(id: "reply-\(turns)", turnID: turn, role: .assistant,
                                text: "Done. The port now comes from the environment.")))
            emit(.turnFinished(turnID: turn, interrupted: false))
        }
    }

    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {
        _ = try await send(text, requestID: requestID, model: nil, effort: nil, attachments: [], to: identity)
    }

    /// The words as core takes them (AGENT-PLAN-1): `/plan` and `/plan
    /// <words>` the host handles itself; anything else is a message.
    func send(_ text: String, requestID: UUID, model: String?, effort: String?,
              attachments: [AttachmentRef], to identity: AgentChatIdentity) async throws -> AgentSendReceipt {
        guard identity == Self.identity, activeTurn == nil else { throw AgentChatHostError(code: "agent_busy") }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed == "/plan" {
            changeMode(mode == "plan" ? "default" : "plan")
            return AgentSendReceipt(command: "plan", startsNoTurn: true)
        }
        if typed.hasPrefix("/plan ") {
            changeMode("plan")
            startTurn(String(typed.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            return AgentSendReceipt(command: "plan")
        }
        startTurn(text)
        return AgentSendReceipt()
    }

    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        guard pending.contains(where: { $0.requestID == requestID }) else {
            throw AgentChatHostError(code: "agent_approval_unknown")
        }
        emit(.approvalResolved(requestID: requestID, decision: "input", source: "client"))
        if let turn = asking {
            asking = nil
            emit(.message(.init(id: "intro-\(turn)", turnID: turn, role: .assistant, text: "Here is what I would do.")))
            // The plan as codex streams it (`item/plan/delta`), then whole.
            var text = ""
            for line in Self.plan.split(separator: "\n", omittingEmptySubsequences: false) {
                text += line + "\n"
                emit(.message(.init(id: "\(turn)-plan", turnID: turn, role: .assistant, text: text, plan: true)))
            }
            emit(.message(.init(id: "\(turn)-plan", turnID: turn, role: .assistant, text: Self.plan, plan: true)))
            emit(.turnFinished(turnID: turn, interrupted: false))
        }
        return AgentChatApprovalResolution(requestID: requestID, kind: "userInput", decision: "input", resolved: true)
    }

    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
}
