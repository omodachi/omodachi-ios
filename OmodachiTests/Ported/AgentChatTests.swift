import XCTest
@testable import Omodachi

/// Synthetic-only adapter for local tests. No sockets, subprocesses, provider
/// APIs, credentials, transcript reads, or actual agent operations.
actor AgentChatFixtureTransport: AgentChatTransport {
    let identity = AgentChatIdentity(hostID: "MOCK-host", agentID: "default", provider: "fixture", providerSessionID: "MOCK-existing-thread")
    private var rows: [AgentChatRow] = []
    private var activeTurn: String?
    private var sequence = 0
    private var listeners: [UUID: AsyncThrowingStream<AgentChatEnvelope, Error>.Continuation] = [:]
    private var requests: [UUID] = []
    private(set) var ensureCount = 0
    private(set) var snapshotCount = 0
    private(set) var interruptionCount = 0

    func ensureDefault() async throws -> AgentChatSnapshot {
        ensureCount += 1
        return value()
    }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        snapshotCount += 1
        return value()
    }
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {
        guard !requests.contains(requestID) else { return }
        requests.append(requestID)
        let turn = "MOCK-turn-\(requests.count)"
        activeTurn = turn
        emit(.turnStarted(turn))
        emit(.message(.init(id: "user-\(turn)", turnID: turn, role: .user, text: text)))
        emit(.message(.init(id: "assistant-\(turn)", turnID: turn, role: .assistant, text: "This is a local fixture response, not your agent. Inspecting the example…")))
        emit(.tool(.init(id: "tool-\(turn)", turnID: turn, name: "Example tool", status: .running, detail: "Synthetic progress. No command was run.")))
    }
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {
        interruptionCount += 1
        guard activeTurn == turnID else { return }
        emit(.tool(.init(id: "tool-\(turnID)", turnID: turnID, name: "Example tool", status: .cancelled, detail: "Fixture interruption acknowledged.")))
        emit(.turnFinished(turnID: turnID, interrupted: true))
    }
    func hasObserver() -> Bool { !listeners.isEmpty }
    private func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func value() -> AgentChatSnapshot {
        AgentChatSnapshot(identity: identity, rows: rows, activeTurn: activeTurn, sequence: sequence, acceptedRequestIDs: requests.map(\.uuidString))
    }
    private func emit(_ event: AgentChatEvent) {
        sequence += 1
        switch event {
        case .message(let item): upsert(.message(item))
        case .tool(let item): upsert(.tool(item))
        case .turnFinished, .turnFailed: activeTurn = nil
        case .turnStarted(let id): activeTurn = id
        // This fixture only produces the turn/message/tool events above; the
        // approval, status and usage events are exercised directly against the
        // model in `AgentApprovalTests`.
        default: break
        }
        for observer in listeners.values { observer.yield(.init(identity: identity, sequence: sequence, event: event)) }
    }
    private func upsert(_ row: AgentChatRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row }
        else { rows.append(row) }
    }
}

private actor HandoffFixture: AgentChatTransport {
    var confirms = 0
    var prepared = 0
    var migrated = false
    func ensureDefault() async throws -> AgentChatSnapshot {
        if !migrated { throw AgentChatHostError(code: "existing_thread_handoff_required") }
        return AgentChatSnapshot(identity: .init(hostID: "host", agentID: "default", provider: "codex", providerSessionID: "same-thread"), rows: [], activeTurn: nil, sequence: 0)
    }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot { try await ensureDefault() }
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> { AsyncThrowingStream { _ in } }
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {}
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
    func prepareHandoff() async throws -> AgentChatHandoffPlan {
        prepared += 1
        return .init(planID: "handoff_fixture", status: "prepared", requiresConfirmation: true,
            agentID: "default", provider: "codex", providerSessionID: "same-thread", paneID: "same-pane",
            impact: "Existing idle terminal reopens in the same pane and thread.", rollback: "Restore the original TUI on failure.")
    }
    func confirmHandoff(planID: String) async throws -> AgentChatHandoffResult {
        confirms += 1; migrated = true
        return .init(status: "completed", providerSessionID: "same-thread", paneID: "same-pane", sameThread: true, herdrPaneRegistered: true)
    }
}

/// AGENT-PLAN-1 (Leo: what is typed goes through): records what reached the
/// chat route, words and all.
private actor PassthroughFixture: AgentChatTransport {
    var sent: [String] = []
    let identity = AgentChatIdentity(hostID: "host", agentID: "default", provider: "codex", providerSessionID: "original-thread")
    func ensureDefault() async throws -> AgentChatSnapshot { .init(identity: identity, rows: [], activeTurn: nil, sequence: 0) }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot { try await ensureDefault() }
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> { AsyncThrowingStream { _ in } }
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws { sent.append(text) }
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
}

/// Typed chat state machine. Synthetic; no provider/host IO.
final class AgentChatModelTests: XCTestCase {
    func testTypedChatStateTransitions() {
        let identity = AgentChatIdentity(hostID: "fixture-host", agentID: "default", provider: "codex", providerSessionID: "fixture-existing-thread")
        var model = AgentChatModel()
        XCTAssertNotNil(model.beginEnsure(), "explicit open starts one ensure")
        XCTAssertNil(model.beginEnsure(), "repeated tap does not duplicate start")
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: nil, sequence: 0), "attach existing provider identity")
        model.draft = "Show the current change"
        XCTAssertNotNil(model.beginSend())
        XCTAssertFalse(model.canSend, "send cannot be tapped twice")
        model.sendAcknowledged(text: "Show the current change")
        XCTAssertEqual(model.phase, .sending)
        XCTAssertTrue(model.rows.isEmpty, "ACK cannot manufacture answer or completion")
        XCTAssertTrue(model.apply(.turnStarted("turn-1"), identity: identity, sequence: 1), "provider starts turn")
        let message = AgentChatMessage(id: "answer-1", turnID: "turn-1", role: .assistant, text: "I will inspect it.")
        XCTAssertTrue(model.apply(.message(message), identity: identity, sequence: 2), "real structured message")
        XCTAssertFalse(model.apply(.message(message), identity: identity, sequence: 2), "duplicate event ignored")
        let tool = AgentChatTool(id: "tool-1", turnID: "turn-1", name: "Inspect changes", status: .running, detail: "Working")
        XCTAssertTrue(model.apply(.tool(tool), identity: identity, sequence: 3), "structured tool progress")
        XCTAssertEqual(model.requestCancel(), "turn-1")
        XCTAssertEqual(model.phase, .cancelling, "stop remains pending")
        XCTAssertTrue(model.apply(.turnFinished(turnID: "turn-1", interrupted: true), identity: identity, sequence: 4), "provider interruption completes stop")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.rows.count, 2, "return to ready keeps conversation")
        let foreign = AgentChatIdentity(hostID: "fixture-host", agentID: "default", provider: "codex", providerSessionID: "different-thread")
        XCTAssertFalse(model.restore(identity: foreign, rows: [], activeTurn: nil, sequence: 5), "cannot replace original provider thread silently")
        XCTAssertFalse(model.apply(.turnStarted("turn-2"), identity: identity, sequence: 6))
        XCTAssertEqual(model.phase, .reconnecting, "event gap requires snapshot")
        XCTAssertTrue(model.restore(identity: identity, rows: model.rows, activeTurn: "turn-2", sequence: 6), "reconnect same active turn")
        XCTAssertFalse(model.restore(identity: identity, rows: [], activeTurn: nil, sequence: 1), "stale snapshot cannot erase current history")
        var startup = AgentChatModel(); _ = startup.beginEnsure(); startup.connectionLost()
        XCTAssertNotNil(startup.beginEnsure(), "interrupted first attach can retry")
    }
}

/// Fixture-backed store journey; no real backend.
@MainActor
final class AgentChatStoreTests: XCTestCase {
    private func waitUntil(_ description: String, _ condition: () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("fixture event did not arrive: \(description)")
    }

    func testEnsureSendStreamNavigationReattachAndCancel() async {
        let fixture = AgentChatFixtureTransport()
        let store = AgentChatStore(transport: fixture)
        await store.open()
        await waitUntil("observer") { await fixture.hasObserver() }
        await store.open()
        let ensures = await fixture.ensureCount
        XCTAssertEqual(ensures, 1, "open twice must not launch twice")
        store.model.draft = "Synthetic request"
        await store.send()
        await waitUntil("three rows") { store.model.phase == .running && store.model.rows.count == 3 }
        XCTAssertEqual(store.model.rows.count, 3, "message/tool rows are structured")
        XCTAssertTrue(store.model.draft.isEmpty, "accepted input clears submitted draft")
        store.model.draft = "Keep this unsent draft"
        store.leave()
        await store.open()
        await waitUntil("observer after reattach") { await fixture.hasObserver() }
        XCTAssertEqual(store.model.phase, .running)
        XCTAssertEqual(store.model.rows.count, 3, "same active turn snapshot restored")
        XCTAssertEqual(store.model.draft, "Keep this unsent draft", "navigation preserves composer")
        let afterResume = await fixture.ensureCount
        XCTAssertEqual(afterResume, 1, "reattach uses snapshot, never new default agent")
        await store.cancel()
        await waitUntil("ready after cancel") { store.model.phase == .ready }
        let interrupts = await fixture.interruptionCount
        XCTAssertEqual(interrupts, 1, "cancel targets one running turn")
        XCTAssertEqual(store.model.identity?.providerSessionID, "MOCK-existing-thread")
        store.leave()
    }

    func testExistingSessionHandoffRequiresExplicitReviewAndConfirmation() async {
        let handoff = HandoffFixture()
        let migrationStore = AgentChatStore(transport: handoff)
        await migrationStore.open()
        XCTAssertEqual(migrationStore.model.handoff, .required)
        await migrationStore.confirmPreparedHandoff()
        let beforeReview = await handoff.confirms
        XCTAssertEqual(beforeReview, 0, "no confirmation possible before review")
        await migrationStore.prepareHandoff()
        let afterReview = await handoff.confirms
        XCTAssertEqual(afterReview, 0, "prepare never confirms")
        migrationStore.deferHandoff()
        await migrationStore.confirmPreparedHandoff()
        let afterDefer = await handoff.confirms
        XCTAssertEqual(afterDefer, 0, "Not now cannot execute stale plan")
        await migrationStore.prepareHandoff()
        await migrationStore.confirmPreparedHandoff()
        let afterExplicit = await handoff.confirms
        XCTAssertEqual(afterExplicit, 1)
        XCTAssertEqual(migrationStore.model.identity?.providerSessionID, "same-thread")
        XCTAssertEqual(migrationStore.model.handoff, AgentChatHandoffState.none, "same-thread snapshot follows confirmed handoff")
        migrationStore.leave()
    }

    func testASlashCommandIsSentAsTypedLikeAnyOtherWords() async {
        let fixture = PassthroughFixture()
        let store = AgentChatStore(transport: fixture)
        await store.open()
        for words in ["/rename  exact  arguments", "/unknown keep this", "/model gpt-6-sol high"] {
            store.model.draft = words
            await store.send()
            XCTAssertTrue(store.model.draft.isEmpty, words)
            // No turn comes from this fixture; let the next send through.
            _ = store.model.restore(identity: store.model.identity!, rows: [], activeTurn: nil,
                                    sequence: store.model.lastSequence)
        }
        let sent = await fixture.sent
        XCTAssertEqual(sent, ["/rename  exact  arguments", "/unknown keep this", "/model gpt-6-sol high"],
                       "exactly what was typed, arguments and spaces included")
        store.leave()
    }
}
