import XCTest
@testable import Omodachi

/// AGENT-FIX-2. Leo: "agent 在工具调用的时候，聊天记录会消失" and "通过的
/// permission 会在底部堆积". A command's output arrives as increments and is
/// kept to its newest part; a broken stream reconnects by itself and keeps
/// what is on screen; an answered approval is one line under its own command.
@MainActor final class AGENTFIX2Tests: XCTestCase {
    private let identity = AgentChatIdentity(hostID: "fixture-host", agentID: "default",
                                             provider: "codex", providerSessionID: "fixture-thread")

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }

    private func approval(_ id: String, item: String?) -> AgentChatApproval {
        var details: [String: AgentChatJSON] = ["command": .string("make")]
        if let item { details["item_id"] = .string(item) }
        return AgentChatApprovalWire(requestID: id, kind: "commandExecution", summary: "make \(id)", details: details,
                                     decisions: ["accept", "acceptForSession", "decline", "cancel"]).value()
    }

    private func tool(_ id: String, _ status: AgentChatToolStatus = .running) -> AgentChatEvent {
        .tool(.init(id: id, turnID: "t1", name: "make \(id)", status: status, detail: ""))
    }

    // MARK: - Output

    func testOutputIsAppendedAndKeptToItsNewestPartAsCoreKeepsIt() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: "t1", sequence: 0))
        XCTAssertTrue(model.apply(tool("c1"), identity: identity, sequence: 1))
        XCTAssertTrue(model.apply(.toolOutput(id: "c1", turnID: "t1", delta: "one\n", truncated: nil), identity: identity, sequence: 2))
        XCTAssertTrue(model.apply(.toolOutput(id: "c1", turnID: "t1", delta: "two\n", truncated: nil), identity: identity, sequence: 3))
        guard case .tool(let first) = model.rows[0] else { return XCTFail() }
        XCTAssertEqual(first.detail, "one\ntwo\n")
        XCTAssertNil(first.detailTruncated)
        let big = String(repeating: "é", count: AgentChatTool.detailLimit)
        XCTAssertTrue(model.apply(.toolOutput(id: "c1", turnID: "t1", delta: big, truncated: 8), identity: identity, sequence: 4))
        guard case .tool(let clipped) = model.rows[0] else { return XCTFail() }
        XCTAssertEqual(clipped.detail.unicodeScalars.count, AgentChatTool.detailLimit)
        XCTAssertTrue(clipped.detail.allSatisfy { $0 == "é" }, "the newest part is the part kept")
        XCTAssertEqual(clipped.detailTruncated, 8, "core's count")
        // Output for a row this client does not hold changes nothing and
        // still advances the sequence: no gap, no reconnect.
        XCTAssertTrue(model.apply(.toolOutput(id: "nope", turnID: "t1", delta: "x", truncated: nil), identity: identity, sequence: 5))
        XCTAssertEqual(model.lastSequence, 5)
        XCTAssertEqual(model.phase, .running)
    }

    func testCoreFixturesForOutputAndAClippedRowDecode() throws {
        let envelope = try JSONDecoder().decode(AgentChatEventWire.self, from: fixtureData("agent-chat-event-tool-output")).value()
        guard case .toolOutput(let id, let turn, let delta, let truncated) = try XCTUnwrap(envelope.event) else {
            return XCTFail("tool.output must decode")
        }
        XCTAssertEqual(id, "item-fixture-build")
        XCTAssertEqual(turn, "turn-fixture-01")
        XCTAssertEqual(delta, "cc -c main.c\ncc -o app main.o\n")
        XCTAssertNil(truncated)
        let snapshot = try JSONDecoder().decode(AgentChatSnapshotWire.self, from: fixtureData("agent-chat-snapshot-tool-output")).value()
        guard case .tool(let row) = try XCTUnwrap(snapshot.rows.first) else { return XCTFail() }
        XCTAssertGreaterThan(try XCTUnwrap(row.detailTruncated), 0)
    }

    /// The App before this fix read every event's `value` as a row
    /// (`AgentChatSnapshotWire.Row`); a `tool.output` value must still decode
    /// that way, or the first command output after a core upgrade ends that
    /// App's stream (seen on omarchy before core 2d81c0d).
    func testAnOlderAppStillDecodesTheOutputEventsValue() throws {
        struct Legacy: Decodable { struct Event: Decodable { let type: String; let value: AgentChatSnapshotWire.Row? }; let event: Event }
        let legacy = try JSONDecoder().decode(Legacy.self, from: fixtureData("agent-chat-event-tool-output"))
        XCTAssertEqual(legacy.event.type, "tool.output")
        XCTAssertEqual(legacy.event.value?.id, "item-fixture-build")
    }

    func testAnEventOfAnUnfamiliarShapeNeverBreaksTheStream() throws {
        let data = Data(#"{"identity": {"hostID": "h", "agentID": "default", "provider": "codex", "providerSessionID": "t"}, "sequence": 9, "event": {"type": "tool.future", "value": {"id": 3, "weird": [1]}}}"#.utf8)
        guard case .ignored = try XCTUnwrap(try JSONDecoder().decode(AgentChatEventWire.self, from: data).value().event) else {
            return XCTFail()
        }
    }

    // MARK: - Approvals

    func testThreeApprovalsInARowEachStayUnderTheirOwnCommand() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: nil, sequence: 0))
        var sequence = 0
        func apply(_ event: AgentChatEvent) { sequence += 1; XCTAssertTrue(model.apply(event, identity: identity, sequence: sequence)) }
        apply(.turnStarted("t1"))
        apply(.message(.init(id: "u1", turnID: "t1", role: .user, text: "build it")))
        for index in 0..<3 {
            apply(tool("c\(index)"))
            apply(.approvalRequested(approval("\(index)", item: "c\(index)")))
            XCTAssertEqual(model.waitingApprovals.map(\.requestID), ["\(index)"], "the waiting card is at the end")
            apply(.approvalResolved(requestID: "\(index)", decision: "accept", source: "client"))
            apply(tool("c\(index)", .succeeded))
        }
        apply(.message(.init(id: "a1", turnID: "t1", role: .assistant, text: "done")))
        XCTAssertTrue(model.waitingApprovals.isEmpty, "nothing piles up at the bottom")
        XCTAssertEqual(model.timeline.map(\.id), ["message:u1", "tool:c0", "approval:0", "tool:c1", "approval:1",
                                                  "tool:c2", "approval:2", "message:a1"])
    }

    func testAPromptWithNoItemSitsAfterTheRowThatWasLastAndASnapshotKeepsThePlace() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [.message(.init(id: "u1", turnID: "t1", role: .user, text: "hi"))],
                                    activeTurn: "t1", sequence: 0))
        XCTAssertTrue(model.apply(.approvalRequested(approval("5", item: nil)), identity: identity, sequence: 1))
        XCTAssertTrue(model.apply(.message(.init(id: "a1", turnID: "t1", role: .assistant, text: "later")), identity: identity, sequence: 2))
        // The stream broke and the host was read again while it waited.
        let snapshot = AgentChatSnapshot(identity: identity, rows: model.rows, activeTurn: "t1", sequence: 2,
                                         pendingApprovals: [approval("5", item: nil)])
        XCTAssertTrue(model.restore(snapshot))
        XCTAssertTrue(model.apply(.approvalResolved(requestID: "5", decision: "accept", source: "client"), identity: identity, sequence: 3))
        XCTAssertEqual(model.timeline.map(\.id), ["message:u1", "approval:5", "message:a1"])
    }

    func testAnIdTheProviderReusesAfterAReconnectIsANewPromptAndTheOldLineStays() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: "t1", sequence: 0))
        XCTAssertTrue(model.apply(tool("c0"), identity: identity, sequence: 1))
        XCTAssertTrue(model.apply(.approvalRequested(approval("0", item: "c0")), identity: identity, sequence: 2))
        XCTAssertTrue(model.apply(.approvalResolved(requestID: "0", decision: "accept", source: "client"), identity: identity, sequence: 3))
        XCTAssertTrue(model.apply(tool("c1"), identity: identity, sequence: 4))
        XCTAssertTrue(model.apply(.approvalRequested(approval("0", item: "c1")), identity: identity, sequence: 5))
        XCTAssertEqual(model.waitingApprovals.count, 1)
        XCTAssertTrue(model.apply(.approvalResolved(requestID: "0", decision: "decline", source: "client"), identity: identity, sequence: 6))
        XCTAssertTrue(model.waitingApprovals.isEmpty)
        let entries = model.timeline
        XCTAssertEqual(entries.count, 4)
        guard case .answered(let first) = entries[1], case .answered(let second) = entries[3] else { return XCTFail() }
        XCTAssertEqual(first.state, .resolved(decision: "accept", source: "client"))
        XCTAssertEqual(second.state, .resolved(decision: "decline", source: "client"))
    }

    // MARK: - Reconnect

    func testABrokenStreamReconnectsByItselfAndTheHistoryNeverLeaves() async throws {
        let transport = AgentChatToolFixtureTransport()
        let store = AgentChatStore(transport: transport)
        store.recoveryScale = 0.01
        await store.open()
        XCTAssertEqual(store.model.rows.count, 2)
        store.model.draft = "build it"
        await store.send()
        try await waitUntil { store.model.waitingApprovals.count == 1 }
        await store.decide(requestID: "0", decision: "accept")
        // The fixture drops the stream here ("re-read me").
        for index in 1..<3 {
            try await waitUntil { store.model.waitingApprovals.first?.requestID == "\(index)" }
            XCTAssertTrue(store.model.rows.contains { $0.id == "message:h-answer" }, "history left during command \(index)")
            await store.decide(requestID: "\(index)", decision: "accept")
        }
        try await waitUntil { store.model.phase == .ready }
        XCTAssertEqual(store.model.timeline.map(\.id), [
            "message:h-ask", "message:h-answer", "message:u1", "message:a1",
            "tool:cmd0", "approval:0", "tool:cmd1", "approval:1", "tool:cmd2", "approval:2", "message:a2"])
        let reads = await transport.snapshots
        XCTAssertGreaterThanOrEqual(reads, 2, "the panel read the host again by itself")
        store.leave()
    }

    func testAFailedReadKeepsWhatIsOnScreen() async {
        let transport = FailingSnapshot()
        let store = AgentChatStore(transport: transport)
        await store.open()
        XCTAssertEqual(store.model.rows.count, 1)
        store.leave()
        await store.open()
        XCTAssertEqual(store.model.rows.count, 1, "an answer too large to read is not an empty conversation")
        XCTAssertNotNil(store.model.error)
        store.leave()
    }

    /// Core restarted (or lost its app-server) mid-turn: the snapshot says the
    /// chat is not ready, and only an ensure attaches it again. Seen on
    /// omarchy: the panel asked for the snapshot over and over and said "This
    /// host offers no agent conversation".
    func testAHostThatLostItsAgentIsEnsuredAgainNotAskedForever() async throws {
        let transport = NotReadyThenEnsured()
        let store = AgentChatStore(transport: transport)
        await store.open()
        store.leave()
        await transport.restart()
        await store.open()
        XCTAssertNil(store.model.error)
        XCTAssertEqual(store.model.rows.count, 1, "the same conversation, with its history")
        let ensures = await transport.ensures
        XCTAssertEqual(ensures, 2)
        store.leave()
    }

    func testTheRecoveryPauseGrowsAndStops() {
        XCTAssertEqual(AgentChatStore.recoveryDelay(attempt: 0), 0.5)
        XCTAssertEqual(AgentChatStore.recoveryDelay(attempt: 1), 1)
        XCTAssertEqual(AgentChatStore.recoveryDelay(attempt: 4), 8)
        XCTAssertEqual(AgentChatStore.recoveryDelay(attempt: 40), 8)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("condition never held"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private actor NotReadyThenEnsured: AgentChatTransport {
    static let identity = AgentChatIdentity(hostID: "h", agentID: "default", provider: "codex", providerSessionID: "t")
    private var attached = true
    private(set) var ensures = 0
    func restart() { attached = false }
    private var snapshot: AgentChatSnapshot {
        AgentChatSnapshot(identity: Self.identity, rows: [.message(.init(id: "m", turnID: "t0", role: .user, text: "kept"))],
                          activeTurn: nil, sequence: 1)
    }
    func ensureDefault() async throws -> AgentChatSnapshot { ensures += 1; attached = true; return snapshot }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        guard attached else { throw AgentChatHostError(code: AgentChatHostError.safeCode("agent_chat_not_ready")) }
        return snapshot
    }
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        AsyncThrowingStream { _ in }
    }
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {}
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
}

private actor FailingSnapshot: AgentChatTransport {
    static let identity = AgentChatIdentity(hostID: "h", agentID: "default", provider: "codex", providerSessionID: "t")
    func ensureDefault() async throws -> AgentChatSnapshot {
        AgentChatSnapshot(identity: Self.identity, rows: [.message(.init(id: "m", turnID: "t0", role: .user, text: "kept"))],
                          activeTurn: nil, sequence: 1)
    }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        throw CompanionHostError.protocolError(message: Strings.hostErrorTooLarge)
    }
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        AsyncThrowingStream { _ in }
    }
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {}
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
}
