import Foundation

/// STORE-6 §A3. The Agent panel's demo: a conversation that says it is one.
///
/// There is no agent behind it and it claims none. The provider is `demo`, the
/// two opening messages explain the panel, and anything typed is answered by a
/// sentence saying it went nowhere and what it would do on a paired computer.
/// It goes through the same store and the same view a real agent's chat does,
/// so the panel the reviewer sees is the real panel.
actor AgentChatDemoTransport: AgentChatTransport {
    static let identity = AgentChatIdentity(hostID: "demo", agentID: "default", // non-copy: ids
                                            provider: "demo", providerSessionID: "demo-conversation")
    private var sequence = 0
    private var turns = 0
    private var continuation: AsyncThrowingStream<AgentChatEnvelope, Error>.Continuation?

    func ensureDefault() async throws -> AgentChatSnapshot { snapshot }

    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        guard identity == Self.identity else { throw AgentChatFailure.identityChanged }
        return snapshot
    }

    private var rows: [AgentChatRow] = [
        .message(.init(id: "demo-ask", turnID: "demo-turn-0", role: .user, text: Strings.demoAgentAsk)),
        .message(.init(id: "demo-answer", turnID: "demo-turn-0", role: .assistant, text: Strings.demoAgentAnswer))
    ]

    private var snapshot: AgentChatSnapshot {
        AgentChatSnapshot(identity: Self.identity, rows: rows, activeTurn: nil, sequence: sequence)
    }

    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        guard identity == Self.identity else { throw AgentChatFailure.identityChanged }
        continuation?.finish()
        let (stream, continuation) = AsyncThrowingStream<AgentChatEnvelope, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {
        guard identity == Self.identity else { throw AgentChatFailure.identityChanged }
        turns += 1
        let turn = "demo-turn-\(turns)"
        let events: [AgentChatEvent] = [
            .turnStarted(turn),
            .message(.init(id: "demo-user-\(turns)", turnID: turn, role: .user, text: text)),
            .message(.init(id: "demo-reply-\(turns)", turnID: turn, role: .assistant, text: Strings.demoAgentReply)),
            .turnFinished(turnID: turn, interrupted: false)
        ]
        for event in events {
            sequence += 1
            if case .message(let message) = event { rows.append(.message(message)) }
            continuation?.yield(AgentChatEnvelope(identity: Self.identity, sequence: sequence, event: event))
        }
    }

    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
}
