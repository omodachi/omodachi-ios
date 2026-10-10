// lint:host-words — an agent's words and commands, standing in for the host's.
import Foundation

/// AGENT-FIX-2, simulator UI runs only (`--ui-testing --agent-tool-fixture`):
/// a scripted agent that runs three commands in one turn, each needing an
/// approval, streams their output, and breaks the event stream once in the
/// middle (the host's "re-read me"). It is what a UI test needs to show that
/// the history stays, the panel reconnects by itself and answered prompts
/// stay where they happened (Leo: "agent 在工具调用的时候，聊天记录会消失",
/// "通过的 permission 会在底部堆积").
actor AgentChatToolFixtureTransport: AgentChatTransport {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--agent-tool-fixture")
        #else
        return false
        #endif
    }

    static let identity = AgentChatIdentity(hostID: "fixture", agentID: "default", // non-copy: ids
                                            provider: "codex", providerSessionID: "fixture-thread")
    private var sequence = 0
    private var rows: [AgentChatRow] = [
        .message(.init(id: "h-ask", turnID: "t0", role: .user, text: "What is in this folder?")),
        .message(.init(id: "h-answer", turnID: "t0", role: .assistant, text: "A Makefile and a src directory.")),
    ]
    private var activeTurn: String?
    private var pending: [AgentChatApproval] = []
    private var continuation: AsyncThrowingStream<AgentChatEnvelope, Error>.Continuation?
    private var step = 0
    private var brokeOnce = false
    private(set) var snapshots = 0

    private var snapshot: AgentChatSnapshot {
        AgentChatSnapshot(identity: Self.identity, rows: rows, activeTurn: activeTurn, sequence: sequence,
                          pendingApprovals: pending)
    }

    func ensureDefault() async throws -> AgentChatSnapshot { snapshots += 1; return snapshot }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        guard identity == Self.identity else { throw AgentChatFailure.identityChanged }
        snapshots += 1
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
        case .toolOutput(let id, _, let delta, let truncated):
            if let index = rows.firstIndex(where: { $0.id == "tool:\(id)" }), case .tool(var tool) = rows[index] {
                tool.append(output: delta, truncated: truncated)
                rows[index] = .tool(tool)
            }
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

    private static let commands = ["make clean", "make all", "make install"]

    private func startCommand(_ index: Int) {
        let id = "cmd\(index)"
        emit(.tool(.init(id: id, turnID: "t1", name: Self.commands[index], status: .running, detail: "")))
        for line in 0..<40 {
            emit(.toolOutput(id: id, turnID: "t1", delta: "\(Self.commands[index]): step \(line)\n", truncated: nil))
        }
        emit(.approvalRequested(AgentChatApprovalWire(requestID: String(index), kind: "commandExecution",
            summary: Self.commands[index], details: ["item_id": .string(id), "command": .string(Self.commands[index])],
            decisions: ["accept", "acceptForSession", "decline", "cancel"]).value()))
    }

    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {
        guard identity == Self.identity, activeTurn == nil else { throw AgentChatHostError(code: "agent_busy") }
        emit(.turnStarted("t1"))
        emit(.message(.init(id: "u1", turnID: "t1", role: .user, text: text)))
        emit(.message(.init(id: "a1", turnID: "t1", role: .assistant, text: "Building in three steps.")))
        step = 0
        startCommand(0)
    }

    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        guard let index = Int(requestID), index == step, pending.contains(where: { $0.requestID == requestID }) else {
            throw AgentChatHostError(code: "agent_approval_unknown")
        }
        emit(.approvalResolved(requestID: requestID, decision: decision, source: "client"))
        let id = "cmd\(index)"
        emit(.tool(.init(id: id, turnID: "t1", name: Self.commands[index], status: .succeeded,
                         detail: (0..<40).map { "\(Self.commands[index]): step \($0)\n" }.joined())))
        if index == 0 && !brokeOnce {
            // The host dropped its backlog: the stream says "re-read me" and ends.
            brokeOnce = true
            continuation?.yield(AgentChatEnvelope(identity: Self.identity, sequence: 0, resyncRequired: true))
            continuation?.finish()
            continuation = nil
        }
        step = index + 1
        if step < Self.commands.count {
            startCommand(step)
        } else {
            emit(.message(.init(id: "a2", turnID: "t1", role: .assistant, text: "All three steps ran.")))
            emit(.turnFinished(turnID: "t1", interrupted: false))
        }
        return AgentChatApprovalResolution(requestID: requestID, kind: "commandExecution",
                                           decision: decision ?? "accept", resolved: true)
    }

    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
}
