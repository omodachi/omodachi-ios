import XCTest
@testable import Omodachi

/// AGENT-NEW-1: "New conversation" in the Agent panel, the conversation the
/// app follows when the default one is replaced, tool rows that end, and slash
/// commands that answer in sentences - never the provider's structure (Leo:
/// `/model` printed raw JSON). Synthetic transports and core's own fixtures.
private actor NewConversationFixture: AgentChatTransport {
    static let old = AgentChatIdentity(hostID: "host", agentID: "default", provider: "codex", providerSessionID: "thread-old")
    static let new = AgentChatIdentity(hostID: "host", agentID: "default", provider: "codex", providerSessionID: "thread-new")
    var current = NewConversationFixture.old
    var activeTurn: String?
    var newCalls: [String] = []
    var answer: Error?
    func ensureDefault() async throws -> AgentChatSnapshot { snapshot() }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        guard identity == current else { throw AgentChatFailure.identityChanged }
        return snapshot()
    }
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        AsyncThrowingStream { _ in }
    }
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {}
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
    func newConversation(expected identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        newCalls.append(identity.providerSessionID)
        if let answer { throw answer }
        current = Self.new
        return AgentChatSnapshot(identity: Self.new, rows: [], activeTurn: nil, sequence: 12)
    }
    func setAnswer(_ error: Error?) { answer = error }
    func replaceElsewhere() { current = Self.new }
    private func snapshot() -> AgentChatSnapshot {
        let rows: [AgentChatRow] = current == Self.old
            ? [.message(.init(id: "m1", turnID: "t0", role: .assistant, text: "From before."))] : []
        return AgentChatSnapshot(identity: current, rows: rows, activeTurn: activeTurn, sequence: 9)
    }
}

@MainActor final class AGENTNEW1Tests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: - New conversation

    func testNewConversationIsRefusedWithAReasonWhileATurnRunsOrAQuestionWaits() {
        var model = AgentChatModel()
        XCTAssertEqual(model.newConversationRefusal, Strings.agentNewUnavailable)
        XCTAssertTrue(model.restore(identity: NewConversationFixture.old, rows: [], activeTurn: nil, sequence: 0))
        XCTAssertNil(model.newConversationRefusal)
        XCTAssertTrue(model.apply(.turnStarted("t1"), identity: NewConversationFixture.old, sequence: 1))
        XCTAssertEqual(model.newConversationRefusal, Strings.agentNewWhileWorking)
        XCTAssertTrue(model.apply(.approvalRequested(AgentChatApprovalWire(requestID: "7", kind: "commandExecution",
            summary: "pwd", details: nil, decisions: ["accept", "decline"]).value()), identity: NewConversationFixture.old, sequence: 2))
        XCTAssertEqual(model.newConversationRefusal, Strings.agentNewWhileWaiting)
    }

    func testStartingANewConversationEmptiesThePanelAndFollowsIt() async throws {
        let transport = NewConversationFixture()
        let store = AgentChatStore(transport: transport)
        await store.open()
        XCTAssertEqual(store.model.identity, NewConversationFixture.old)
        XCTAssertEqual(store.model.rows.count, 1)
        store.model.draft = "keep me"
        store.askNewConversation()
        XCTAssertEqual(store.model.fresh, .confirming)
        await store.confirmNewConversation()
        let asked = await transport.newCalls
        XCTAssertEqual(asked, ["thread-old"], "for the conversation on screen")
        XCTAssertEqual(store.model.identity, NewConversationFixture.new)
        XCTAssertTrue(store.model.rows.isEmpty)
        XCTAssertEqual(store.model.phase, .ready)
        XCTAssertEqual(store.model.fresh, .none)
        XCTAssertEqual(store.model.draft, "keep me", "the words being typed survive")
        XCTAssertNil(store.model.error)
        store.leave()
    }

    func testTheCardNeverStartsOneWithoutItsButtonOrWhileATurnRuns() async {
        let transport = NewConversationFixture()
        let store = AgentChatStore(transport: transport)
        await store.open()
        await store.confirmNewConversation()
        var asked = await transport.newCalls
        XCTAssertEqual(asked, [], "no card, no request")
        store.askNewConversation()
        XCTAssertTrue(store.model.apply(.turnStarted("t1"), identity: NewConversationFixture.old, sequence: 10))
        await store.confirmNewConversation()
        asked = await transport.newCalls
        XCTAssertEqual(asked, [], "a running turn keeps the button off")
        store.leave()
    }

    func testARefusalIsSaidInWordsAndAnotherDeviceWinningIsFollowed() async {
        let transport = NewConversationFixture()
        let store = AgentChatStore(transport: transport)
        await store.open()
        await transport.setAnswer(AgentChatHostError(code: "agent_turn_active"))
        store.askNewConversation()
        await store.confirmNewConversation()
        XCTAssertEqual(store.model.fresh, .problem(Strings.agentNewWhileWorking))
        // Another phone made the new conversation first.
        await transport.replaceElsewhere()
        await transport.setAnswer(AgentChatHostError(code: "agent_identity_changed"))
        store.askNewConversation()
        await store.confirmNewConversation()
        XCTAssertEqual(store.model.identity, NewConversationFixture.new)
        XCTAssertTrue(store.model.rows.isEmpty)
        XCTAssertEqual(store.model.fresh, .none)
        store.leave()
    }

    func testAReplacedConversationIsFollowedOnReopenNotAnError() async {
        let transport = NewConversationFixture()
        let store = AgentChatStore(transport: transport)
        await store.open()
        store.leave()
        await transport.replaceElsewhere()
        await store.open()
        XCTAssertEqual(store.model.identity, NewConversationFixture.new)
        XCTAssertNil(store.model.error)
        XCTAssertEqual(store.model.phase, .ready)
        store.leave()
    }

    func testTheClientAsksForTheConversationOnScreenAndDecodesCoresAnswer() async throws {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        let client = CompanionHostClient(configuration: try CompanionHostConfiguration(endpoint: URL(string: "https://fixture.invalid:8443")!),
                                         credentials: FixtureCredential(), pinnedFingerprint: nil,
                                         session: URLSession(configuration: options))
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/agent/default/chat:new",
                                         body: String(decoding: try fixtureData("agent-chat-new"), as: UTF8.self))
        let snapshot = try await client.chatNew(expected: "thread-fixture-01")
        XCTAssertEqual(snapshot.identity.providerSessionID, "thread-fixture-02")
        XCTAssertTrue(snapshot.rows.isEmpty)
        let request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.body(request)) as? [String: Any])
        XCTAssertEqual(body["confirmed"] as? Bool, true)
        XCTAssertEqual(body["expected_provider_session_id"] as? String, "thread-fixture-01")
        CompanionURLProtocol.storage.set("/v1/agent/default/chat:new", status: 409,
                                         body: #"{"error":{"code":"agent_approval_pending","message":"x"}}"#)
        do {
            _ = try await client.chatNew(expected: "thread-fixture-01")
            XCTFail("refused")
        } catch let error as AgentChatHostError {
            XCTAssertEqual(error.code, "agent_approval_pending")
            XCTAssertEqual(error.localizedDescription, Strings.agentNewWhileWaiting)
        }
    }

    // AGENT-PLAN-1 (Leo: "甚至是 / 的优化整个都可以砍掉 只透传"): the slash list and
    // its answers are gone - what is typed is a message. AGENTPLAN1Tests
    // covers what replaced them.

    private func usage(_ model: String, _ effort: String) -> AgentChatUsage {
        var value = AgentChatUsage.empty
        value.model = model
        value.effort = effort
        return value
    }

    func testAPickedModelShowsAtOnceEvenWhenTheThreadsOwnIsKnown() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(AgentChatSnapshot(identity: NewConversationFixture.old, rows: [], activeTurn: nil,
                                                      sequence: 0, usage: usage("gpt-6.1-sol", "medium"))))
        XCTAssertEqual(model.effectiveEffort, "medium")
        model.selectedModel = "gpt-6.1-sol"
        model.selectedEffort = "low"
        XCTAssertEqual(model.effectiveEffort, "low", "the picker's tap shows, marked pending")
        XCTAssertTrue(model.apply(.usageUpdated(usage("gpt-6.1-sol", "low")),
                                  identity: NewConversationFixture.old, sequence: 1))
        XCTAssertNil(model.selectedEffort, "confirmed by the provider")
        XCTAssertEqual(model.effectiveEffort, "low")
    }

    func testAToolThePersonStoppedDecodesAndIsSaid() throws {
        let row = try JSONDecoder().decode(AgentChatSnapshotWire.Row.self, from: Data(
            #"{"kind":"tool","id":"c","turnID":"t","name":"sleep 8","status":"interrupted","detail":""}"#.utf8))
        guard case .tool(let tool) = try row.value() else { return XCTFail("a tool") }
        XCTAssertEqual(tool.status, .interrupted)
        XCTAssertEqual(tool.status.label, Strings.toolStatusInterrupted)
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 2048)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
