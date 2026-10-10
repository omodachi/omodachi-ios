// lint:host-words — an agent's words, its checklist and a queue, standing in for the host's.
import Foundation

/// AGENT-QUEUE-1, simulator UI runs only (`--ui-testing --agent-queue-fixture`):
/// codex 0.160 as the real capture has it
/// (`omodachi-core/tests/fixtures/codex-0160-agent-queue1.json`). The thread
/// opens on its newest turns with earlier ones a page away. A message starts a
/// turn that ticks a three-step checklist and asks to run `touch blocked.txt`;
/// while it waits, Send puts words in the queue (Send now steers them in, Edit
/// and Delete change it). Allow runs it; Decline with a reason steers the words
/// into the turn first. When the turn ends the queue drains, a turn each.
/// Stop keeps the queue until Send now.
actor AgentChatQueueFixtureTransport: AgentChatTransport {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--agent-queue-fixture")
        #else
        return false
        #endif
    }

    static let identity = AgentChatIdentity(hostID: "fixture", agentID: "default", // non-copy: ids
                                            provider: "codex", providerSessionID: "fixture-queue")
    /// The thread's older turns, a page away.
    private static let older: [AgentChatRow] = (1...8).flatMap { turn -> [AgentChatRow] in
        [.message(.init(id: "u\(turn)", turnID: "h\(turn)", role: .user, text: "hello \(turn)")),
         .message(.init(id: "a\(turn)", turnID: "h\(turn)", role: .assistant, text: "Got it: hello \(turn)",
                        textTruncated: turn == 3 ? 81_920 : nil))]
    }
    private var sequence = 0
    private var rows: [AgentChatRow] = (9...10).flatMap { turn -> [AgentChatRow] in
        [.message(.init(id: "u\(turn)", turnID: "h\(turn)", role: .user, text: "hello \(turn)")),
         .message(.init(id: "a\(turn)", turnID: "h\(turn)", role: .assistant, text: "Got it: hello \(turn)"))]
    }
    private var earlier = true
    private var activeTurn: String?
    private var pending: [AgentChatApproval] = []
    private var queued: [AgentQueuedMessage] = []
    private var checklist: AgentChecklist?
    private var continuation: AsyncThrowingStream<AgentChatEnvelope, Error>.Continuation?
    private var turns = 0
    private var serial = 0
    private var stopped = false
    /// The question whose first answer "goes down with the connection".
    private var asking: (turn: String, request: String, lost: Bool)?

    private var snapshot: AgentChatSnapshot {
        AgentChatSnapshot(identity: Self.identity, rows: rows, activeTurn: activeTurn, sequence: sequence,
                          pendingApprovals: pending, usage: .empty, earlier: earlier, queue: queued,
                          checklist: checklist)
    }

    /// `--agent-queue-scene`: the panel opens on a turn already waiting on its
    /// command, with its checklist and one message in the queue (for
    /// screenshots that type nothing).
    private var seeded = false
    private func seedScene() {
        guard !seeded, ProcessInfo.processInfo.arguments.contains("--agent-queue-scene") else { return }
        seeded = true
        startTurn("Change the port", asks: true)
        serial += 1
        emit(.queueChanged([AgentQueuedMessage(id: "q-\(serial)", requestID: "scene", text: "And then run the tests on SQLite")]))
    }

    func ensureDefault() async throws -> AgentChatSnapshot {
        seedScene()
        return snapshot
    }
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
        case .tool(let tool): put(.tool(tool))
        case .turnStarted(let id): activeTurn = id
        case .turnFinished: activeTurn = nil
        case .approvalRequested(let approval): pending.append(approval)
        case .approvalResolved(let id, _, _): pending.removeAll { $0.requestID == id }
        case .queueChanged(let value): queued = value ?? []
        case .checklistUpdated(let value): checklist = value
        default: break
        }
        continuation?.yield(AgentChatEnvelope(identity: Self.identity, sequence: sequence, event: event))
    }

    private func put(_ row: AgentChatRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row } else { rows.append(row) }
    }

    private func tick(_ statuses: [AgentChecklist.Status], turn: String) {
        let steps = zip(["Read the config", "Change the port", "Run the tests"], statuses).map {
            AgentChecklist.Step(step: $0.0, status: $0.1)
        }
        emit(.checklistUpdated(AgentChecklist(turnID: turn, explanation: "Three small steps.", steps: steps)))
    }

    /// A turn of the person's words: the checklist, then the command that
    /// waits for an answer.
    private func startTurn(_ text: String, asks: Bool) {
        turns += 1
        let turn = "t\(turns)"
        stopped = false
        emit(.turnStarted(turn))
        emit(.message(.init(id: "you-\(turns)", turnID: turn, role: .user, text: text)))
        guard asks else {
            emit(.message(.init(id: "reply-\(turns)", turnID: turn, role: .assistant, text: "Got it: \(text)")))
            finish(turn)
            return
        }
        tick([.inProgress, .pending, .pending], turn: turn)
        emit(.tool(.init(id: "cmd-\(turns)", turnID: turn, name: "/bin/zsh -lc 'touch blocked.txt'", status: .running,
                         detail: "", command: "touch blocked.txt")))
        emit(.approvalRequested(AgentChatApprovalWire(
            requestID: "r\(turns)", kind: "commandExecution", summary: "touch blocked.txt",
            details: ["item_id": .string("cmd-\(turns)"), "turn_id": .string(turn),
                      "command": .string("touch blocked.txt"), "reason": .string("Write a marker file outside the sandbox.")],
            decisions: ["accept", "acceptForSession", "decline", "cancel"]).value()))
    }

    private func finish(_ turn: String, interrupted: Bool = false) {
        emit(.turnFinished(turnID: turn, interrupted: interrupted))
        stopped = interrupted
        // codex drains its queue after a turn that completed, one turn each;
        // after a Stop it waits.
        guard !interrupted, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        emit(.queueChanged(queued))
        startTurn(next.text, asks: false)
    }

    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {
        _ = try await send(text, requestID: requestID, model: nil, effort: nil, attachments: [], to: identity)
    }

    func send(_ text: String, requestID: UUID, model: String?, effort: String?,
              attachments: [AttachmentRef], to identity: AgentChatIdentity) async throws -> AgentSendReceipt {
        guard identity == Self.identity, activeTurn == nil else { throw AgentChatHostError(code: "agent_busy") }
        if text.hasPrefix("Ask me three") { askThree(text); return AgentSendReceipt() }
        startTurn(text, asks: true)
        return AgentSendReceipt()
    }

    /// Leo's looping card (AGENT-QUEUE-1): three questions; the first answer
    /// never reaches codex, and codex re-sends the identical request when the
    /// thread is resumed (real 0.160 `ask_replay`). The second answer lands.
    static let three: AgentChatApprovalWire = {
        func question(_ id: String, _ header: String, _ text: String, _ options: [(String, String)]) -> AgentChatJSON {
            .object(["id": .string(id), "header": .string(header), "question": .string(text), "secret": .bool(false),
                     "options": .array(options.map { .string($0.0) }),
                     "choices": .array(options.map { .object(["label": .string($0.0), "description": .string($0.1)]) }),
                     "other": .bool(true)])
        }
        return AgentChatApprovalWire(requestID: "a1", kind: "userInput", summary: "Database", details: [
            "item_id": .string("call-a-1"), "blocking": .bool(true), "questions": .array([
                question("db", "Database", "Which database should the tests use?",
                         [("SQLite (Recommended)", "Fast and needs no server."), ("Postgres", "Same as production.")]),
                question("port", "Port", "Which port should it listen on by default?",
                         [("9090 (Recommended)", "Free on the host."), ("8080", "As it is today.")]),
                question("tests", "Tests", "Run the tests after the change?",
                         [("Yes (Recommended)", "Takes a minute."), ("No", "Skip them.")])])],
            decisions: [])
    }()

    private func askThree(_ text: String) {
        turns += 1
        let turn = "t\(turns)"
        emit(.turnStarted(turn))
        emit(.message(.init(id: "you-\(turns)", turnID: turn, role: .user, text: text)))
        asking = (turn, "a1", false)
        emit(.approvalRequested(Self.three.value()))
    }

    func queue(_ text: String, requestID: UUID, in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]? {
        serial += 1
        emit(.queueChanged(queued + [AgentQueuedMessage(id: "q-\(serial)", requestID: requestID.uuidString, text: text)]))
        return queued
    }

    func queueItem(_ id: String, action: AgentQueueAction, text: String?,
                   in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]? {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { throw AgentChatHostError(code: "agent_queue_item_gone") }
        var next = queued
        switch action {
        case .edit:
            next[index].text = text ?? next[index].text
            emit(.queueChanged(next))
        case .delete:
            next.remove(at: index)
            emit(.queueChanged(next))
        case .send:
            let item = next.remove(at: index)
            emit(.queueChanged(next))
            if let turn = activeTurn {
                // Steered into the running turn, as the capture's q2.
                serial += 1
                emit(.message(.init(id: "steered-\(serial)", turnID: turn, role: .user, text: item.text)))
            } else {
                startTurn(item.text, asks: false)
            }
        }
        return queued
    }

    func history(before: String?, limit: Int, in identity: AgentChatIdentity) async throws -> AgentHistoryPage {
        earlier = false
        rows = Self.older + rows
        return AgentHistoryPage(rows: Self.older, earlier: false)
    }

    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        try await resolveApproval(requestID: requestID, decision: decision, input: input, reason: nil, in: identity)
    }

    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?, reason: String?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        if let ask = asking, ask.request == requestID, let input {
            emit(.approvalResolved(requestID: requestID, decision: "input", source: "client"))
            if !ask.lost {
                // Gone with the connection; after the re-attach codex asks again.
                asking = (ask.turn, ask.request, true)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    await self?.askAgain()
                }
            } else {
                asking = nil
                let said = ["db", "port", "tests"].compactMap { input[$0]?.first }.joined(separator: ", ")
                emit(.message(.init(id: "thanks-\(ask.turn)", turnID: ask.turn, role: .assistant, text: "Thanks - \(said).")))
                emit(.turnFinished(turnID: ask.turn, interrupted: false))
            }
            return AgentChatApprovalResolution(requestID: requestID, kind: "userInput", decision: "input", resolved: true)
        }
        guard pending.contains(where: { $0.requestID == requestID }), let turn = activeTurn else {
            throw AgentChatHostError(code: "agent_approval_unknown")
        }
        let number = turn.dropFirst()
        if let reason {
            // Steered in before the decline, as core does it.
            emit(.message(.init(id: "reason-\(number)", turnID: turn, role: .user, text: reason)))
        }
        emit(.approvalResolved(requestID: requestID, decision: decision, source: "client"))
        let ran = decision == "accept" || decision == "acceptForSession"
        emit(.tool(.init(id: "cmd-\(number)", turnID: turn, name: "/bin/zsh -lc 'touch blocked.txt'",
                         status: ran ? .succeeded : .cancelled, detail: "", command: "touch blocked.txt")))
        if decision == "cancel" {
            finish(turn, interrupted: true)
        } else {
            tick([.completed, .inProgress, .pending], turn: turn)
            emit(.message(.init(id: "done-\(number)", turnID: turn, role: .assistant,
                                text: reason.map { "Understood - \($0.prefix(60)) I'll leave that file alone." }
                                    ?? "The marker file is written.")))
            tick([.completed, .completed, .completed], turn: turn)
            finish(turn)
        }
        return AgentChatApprovalResolution(requestID: requestID, kind: "commandExecution",
                                           decision: decision ?? "decline", resolved: true,
                                           delivery: reason == nil ? nil : "steered")
    }

    private func askAgain() { emit(.approvalRequested(Self.three.value())) }

    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {
        guard turnID == activeTurn else { return }
        for approval in pending { emit(.approvalResolved(requestID: approval.requestID, decision: nil, source: "elsewhere")) }
        finish(turnID, interrupted: true)
    }
}
