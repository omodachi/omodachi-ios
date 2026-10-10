import XCTest
@testable import Omodachi

/// AGENT-QUEUE-1: the queue, codex's checklist, a decline's reason and earlier
/// messages, on what core makes of real codex 0.160 frames
/// (`CoreFixtures/agent-chat-snapshot-queue.json`, `agent-chat-event-queue.json`,
/// `agent-chat-event-checklist.json`, `agent-chat-history.json`,
/// `agent-chat-queue.json`, from core's replay of a private app-server capture).
private actor QueueTransport: AgentChatTransport {
    static let identity = AgentChatIdentity(hostID: "host", agentID: "default", provider: "codex", providerSessionID: "t")
    var calls: [String] = []
    var queued: [AgentQueuedMessage] = []
    var refuse: [String: AgentChatHostError] = [:]
    var delivery: String?
    var reasons: [String?] = []
    var page = AgentHistoryPage(rows: [], earlier: false)

    func ensureDefault() async throws -> AgentChatSnapshot {
        AgentChatSnapshot(identity: Self.identity, rows: [
            .message(.init(id: "u1", turnID: "t1", role: .user, text: "hello 9")),
            .message(.init(id: "m1", turnID: "t1", role: .assistant, text: "Got it: hello 9")),
        ], activeTurn: "t1", sequence: 3, earlier: true, queue: queued)
    }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot { try await ensureDefault() }
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        AsyncThrowingStream { _ in }
    }
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws { calls.append("send") }
    func steer(_ text: String, requestID: UUID, in identity: AgentChatIdentity) async throws { calls.append("steer:" + text) }
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
    func queue(_ text: String, requestID: UUID, in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]? {
        calls.append("queue:" + text)
        if let refused = refuse["queue"] { throw refused }
        queued.append(AgentQueuedMessage(id: "q-\(queued.count + 1)", requestID: requestID.uuidString, text: text))
        return queued
    }
    func queueItem(_ id: String, action: AgentQueueAction, text: String?,
                   in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]? {
        calls.append("\(action.rawValue):\(id)")
        if let refused = refuse[action.rawValue] { throw refused }
        if action == .delete || action == .send { queued.removeAll { $0.id == id } }
        if action == .edit, let index = queued.firstIndex(where: { $0.id == id }) { queued[index].text = text ?? "" }
        return queued
    }
    func history(before: String?, limit: Int, in identity: AgentChatIdentity) async throws -> AgentHistoryPage {
        calls.append("history:\(before ?? "-")")
        return page
    }
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        try await resolveApproval(requestID: requestID, decision: decision, input: input, reason: nil, in: identity)
    }
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?, reason: String?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        calls.append("resolve:\(decision ?? "-")")
        reasons.append(reason)
        return AgentChatApprovalResolution(requestID: requestID, kind: "commandExecution", decision: decision ?? "",
                                           resolved: true, delivery: reason == nil ? nil : delivery)
    }
    func set(refusal: AgentChatHostError?, for key: String) { refuse[key] = refusal }
    func set(delivery: String?) { self.delivery = delivery }
    func set(page: AgentHistoryPage) { self.page = page }
    func set(queued: [AgentQueuedMessage]) { self.queued = queued }
}

@MainActor final class AGENTQUEUE1Tests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }
    private func snapshot(_ name: String) throws -> AgentChatSnapshot {
        try JSONDecoder().decode(AgentChatSnapshotWire.self, from: fixtureData(name)).value()
    }

    func testTheRealSnapshotCarriesTheQueueTheChecklistAndThatThereIsMoreBefore() throws {
        let value = try snapshot("agent-chat-snapshot-queue")
        XCTAssertEqual(value.queue?.map(\.text), ["And then run the tests on SQLite.", "Keep the old port as a fallback."])
        XCTAssertEqual(value.queue?.first?.requestID, "request-fixture-q1")
        XCTAssertEqual(value.checklist?.steps.map(\.step), ["Read the config", "Change the port", "Run the tests"])
        XCTAssertTrue(value.earlier)
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(value))
        XCTAssertEqual(model.queue?.count, 2)
        XCTAssertTrue(model.earlier)
        // An older core says none of it: no queue (the composer steers), no
        // checklist, nothing before.
        let older = try snapshot("agent-chat-snapshot-plan")
        XCTAssertNil(older.queue)
        XCTAssertNil(older.checklist)
        XCTAssertFalse(older.earlier)
    }

    func testTheQueueAndTheChecklistArriveAsEvents() throws {
        let queued = try JSONDecoder().decode(AgentChatEventWire.self, from: fixtureData("agent-chat-event-queue")).value()
        let ticked = try JSONDecoder().decode(AgentChatEventWire.self, from: fixtureData("agent-chat-event-checklist")).value()
        guard case .queueChanged(let queue)? = queued.event, case .checklistUpdated(let list)? = ticked.event else {
            return XCTFail("queue and checklist events")
        }
        XCTAssertEqual(queue?.count, 2)
        let checklist = try XCTUnwrap(list)
        XCTAssertEqual(checklist.explanation, nil)
        XCTAssertEqual(checklist.line.done, 1)
        XCTAssertEqual(checklist.line.total, 3)
        XCTAssertEqual(checklist.line.current, "Change the port")
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(AgentChatSnapshot(identity: queued.identity, rows: [], activeTurn: checklist.turnID,
                                                      sequence: 0, queue: [])))
        XCTAssertTrue(model.apply(queued.event!, identity: queued.identity, sequence: 1))
        XCTAssertTrue(model.apply(ticked.event!, identity: queued.identity, sequence: 2))
        XCTAssertEqual(model.queue?.count, 2)
        XCTAssertEqual(model.checklistShown, checklist)
        // A shape this build does not read is no checklist, and the stream goes on.
        let odd = #"{"identity":{"hostID":"h","agentID":"default","provider":"codex","providerSessionID":"t"},"sequence":3,"event":{"type":"agent.checklist.updated","checklist":{"steps":"no"}}}"#
        let decoded = try JSONDecoder().decode(AgentChatEventWire.self, from: Data(odd.utf8)).value()
        guard case .checklistUpdated(nil)? = decoded.event else { return XCTFail("no checklist") }
    }

    func testTheChecklistShowsWhileItsPlanIsActive() {
        let steps = ["a", "b"].map { AgentChecklist.Step(step: $0, status: .completed) }
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(AgentChatSnapshot(identity: QueueTransport.identity,
                                                      rows: [.message(.init(id: "u1", turnID: "t1", role: .user, text: "go"))],
                                                      activeTurn: "t1", sequence: 0,
                                                      checklist: AgentChecklist(turnID: "t1", steps: steps))))
        XCTAssertNotNil(model.checklistShown, "its turn still runs")
        XCTAssertTrue(model.apply(.turnFinished(turnID: "t1", interrupted: false), identity: QueueTransport.identity, sequence: 1))
        XCTAssertNil(model.checklistShown, "all done and the turn over: history")
        let open = [AgentChecklist.Step(step: "a", status: .completed), AgentChecklist.Step(step: "b", status: .pending)]
        XCTAssertTrue(model.apply(.checklistUpdated(AgentChecklist(turnID: "t1", steps: open)),
                                  identity: QueueTransport.identity, sequence: 2))
        XCTAssertEqual(model.checklistShown?.line.current, "b", "a step open and no later turn")
        // A later turn: the plan was left behind.
        XCTAssertTrue(model.apply(.turnStarted("t2"), identity: QueueTransport.identity, sequence: 3))
        XCTAssertTrue(model.apply(.message(.init(id: "u2", turnID: "t2", role: .user, text: "next")),
                                  identity: QueueTransport.identity, sequence: 4))
        XCTAssertTrue(model.apply(.turnFinished(turnID: "t2", interrupted: false), identity: QueueTransport.identity, sequence: 5))
        XCTAssertNil(model.checklistShown)
    }

    func testWhileATurnRunsSendQueuesOnlyWhenCodexHasAQueue() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(AgentChatSnapshot(identity: QueueTransport.identity, rows: [], activeTurn: "t1",
                                                      sequence: 0, queue: [])))
        model.draft = "next"
        XCTAssertTrue(model.queues)
        XCTAssertTrue(model.canQueue)
        model.queueReplaced(nil)
        XCTAssertFalse(model.canQueue)
        XCTAssertTrue(model.canSteer, "a codex without the queue is steered into, as before")
    }

    func testEarlierRowsGoInFrontAndALaterSnapshotKeepsThem() throws {
        let value = try snapshot("agent-chat-snapshot-queue")
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(value))
        let wire = try JSONSerialization.jsonObject(with: fixtureData("agent-chat-history")) as? [String: Any]
        let rowsData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(wire?["rows"]))
        let rows = try JSONDecoder().decode([AgentChatSnapshotWire.Row].self, from: rowsData).map { try $0.value() }
        let count = model.rows.count
        model.prependEarlier(AgentHistoryPage(rows: rows, earlier: wire?["earlier"] as? Bool ?? false))
        XCTAssertEqual(model.rows.count, count + rows.count)
        guard case .message(let first) = model.rows[0] else { return XCTFail("a message") }
        XCTAssertEqual(first.text, "hello 5")
        XCTAssertTrue(model.earlier)
        model.prependEarlier(AgentHistoryPage(rows: rows, earlier: true))
        XCTAssertEqual(model.rows.count, count + rows.count, "a row already here is not added twice")
        // The stream reconnects: the snapshot starts at the same row, the older ones stay.
        var again = value
        again = AgentChatSnapshot(identity: again.identity, rows: again.rows, activeTurn: again.activeTurn,
                                  sequence: again.sequence + 1, earlier: true, queue: again.queue)
        XCTAssertTrue(model.restore(again))
        XCTAssertEqual(model.rows.count, count + rows.count)
    }

    func testAGiantMessageIsMarkedAsCutAndAnOddMarkIsIgnored() throws {
        let json = #"{"identity":{"hostID":"h","agentID":"default","provider":"codex","providerSessionID":"t"},"rows":[{"kind":"message","id":"a","turnID":"t","role":"assistant","text":"xx","text_truncated":123},{"kind":"message","id":"b","turnID":"t","role":"assistant","text":"y","text_truncated":"lots"}],"activeTurn":null,"sequence":0}"#
        let value = try JSONDecoder().decode(AgentChatSnapshotWire.self, from: Data(json.utf8)).value()
        guard case .message(let cut) = value.rows[0], case .message(let odd) = value.rows[1] else { return XCTFail("messages") }
        XCTAssertEqual(cut.textTruncated, 123)
        XCTAssertNil(odd.textTruncated)
    }

    func testSendWhileWorkingQueuesAndEmptiesTheComposerOnceTheHostHasIt() async {
        let transport = QueueTransport()
        let store = AgentChatStore(transport: transport)
        await transport.set(queued: [])
        await store.open()
        store.model.draft = "and then run the tests"
        await store.queueDraft()
        let calls = await transport.calls
        XCTAssertEqual(calls, ["queue:and then run the tests"])
        XCTAssertEqual(store.model.draft, "")
        XCTAssertEqual(store.model.queue?.map(\.text), ["and then run the tests"])
        // Send now, Edit, Delete.
        let edited = await store.queueItem("q-1", .edit, text: "and the lint")
        XCTAssertTrue(edited)
        XCTAssertEqual(store.model.queue?.first?.text, "and the lint")
        let sent = await store.queueItem("q-1", .send)
        XCTAssertTrue(sent)
        XCTAssertEqual(store.model.queue, [])
        store.leave()
    }

    func testACodexWithoutTheQueueIsSteeredIntoAsBefore() async {
        let transport = QueueTransport()
        let store = AgentChatStore(transport: transport)
        await transport.set(queued: [])
        await transport.set(refusal: AgentChatHostError(code: "agent_queue_unavailable"), for: "queue")
        await store.open()
        store.model.draft = "words"
        await store.queueDraft()
        let calls = await transport.calls
        XCTAssertEqual(calls, ["queue:words", "steer:words"])
        XCTAssertNil(store.model.queue)
        store.leave()
    }

    func testAnEditThatFindsItGoneIsNotLost() async {
        let transport = QueueTransport()
        let store = AgentChatStore(transport: transport)
        await transport.set(queued: [AgentQueuedMessage(id: "q-1", requestID: "r", text: "old")])
        await transport.set(refusal: AgentChatHostError(code: "agent_queue_item_gone"), for: "edit")
        await store.open()
        let edited = await store.queueItem("q-1", .edit, text: "new words")
        XCTAssertFalse(edited)
        XCTAssertEqual(store.model.draft, "new words")
        XCTAssertEqual(store.model.notice, Strings.agentQueueEditGone)
        XCTAssertEqual(store.model.queue, [])
        store.leave()
    }

    func testADeclineCarriesItsReasonAndWordsNobodyTookComeBack() async {
        let transport = QueueTransport()
        let store = AgentChatStore(transport: transport)
        await store.open()
        let approval = AgentChatApprovalWire(requestID: "7", kind: "commandExecution", summary: "touch blocked.txt",
                                             details: [:], decisions: ["accept", "decline"]).value()
        XCTAssertTrue(store.model.apply(.approvalRequested(approval), identity: QueueTransport.identity, sequence: 4))
        await transport.set(delivery: "unsent")
        await store.declineWithReason(requestID: "7", reason: "  Use /tmp instead.  ")
        let reasons = await transport.reasons
        XCTAssertEqual(reasons, ["Use /tmp instead."])
        XCTAssertEqual(store.model.draft, "Use /tmp instead.", "neither the turn nor the queue took it")
        XCTAssertFalse(store.model.approvals[0].isPending)
        // No words: today's decline, without a reason.
        let second = AgentChatApprovalWire(requestID: "8", kind: "commandExecution", summary: "x", details: [:],
                                           decisions: ["decline"]).value()
        XCTAssertTrue(store.model.apply(.approvalRequested(second), identity: QueueTransport.identity, sequence: 5))
        await store.declineWithReason(requestID: "8", reason: "   ")
        let after = await transport.reasons
        XCTAssertEqual(after, ["Use /tmp instead.", nil])
        store.leave()
    }

    func testEarlierMessagesLoadBeforeTheFirstRow() async {
        let transport = QueueTransport()
        let store = AgentChatStore(transport: transport)
        await transport.set(page: AgentHistoryPage(rows: [.message(.init(id: "u0", turnID: "t0", role: .user, text: "hello 8"))],
                                                   earlier: false))
        await store.open()
        XCTAssertTrue(store.model.earlier)
        await store.loadEarlier()
        let calls = await transport.calls
        XCTAssertEqual(calls, ["history:u1"])
        XCTAssertEqual(store.model.rows.first?.id, "message:u0")
        XCTAssertFalse(store.model.earlier)
        XCTAssertFalse(store.model.loadingEarlier)
        store.leave()
    }

    /// Leo (2026-10-07): "askuserquestion 的卡片 会循环". codex re-sends a request
    /// it is still waiting on, identical, when the thread is resumed; if the
    /// answer this phone sent never reached it, the same id came back and the
    /// card started again at question 1 with nothing chosen.
    func testTheSameQuestionsComingBackResumeAtTheReviewWithTheAnswers() {
        let id = AgentChatIdentity(hostID: "h", agentID: "default", provider: "codex", providerSessionID: "t")
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(AgentChatSnapshot(identity: id, rows: [], activeTurn: "t1", sequence: 0)))
        let ask = AgentChatQueueFixtureTransport.three.value()
        XCTAssertTrue(model.apply(.approvalRequested(ask), identity: id, sequence: 1))
        XCTAssertNil(model.draft(for: ask))
        // The card reports its progress as the person goes.
        model.keep(AgentQuestionDraft(fingerprint: ask.questionsFingerprint, chosen: ["db": "Postgres", "port": "8080"],
                                      typed: ["tests": "only the fast ones"], page: 2), for: "a1")
        XCTAssertEqual(model.draft(for: ask)?.page, 2)
        XCTAssertTrue(model.beginAnswer(requestID: "a1", input: ["db": ["Postgres"], "port": ["8080"],
                                                                 "tests": ["only the fast ones"]]))
        XCTAssertTrue(model.apply(.approvalResolved(requestID: "a1", decision: "input", source: "client"),
                                  identity: id, sequence: 2))
        // The same request again.
        XCTAssertTrue(model.apply(.approvalRequested(ask), identity: id, sequence: 3))
        let again = try! XCTUnwrap(model.waitingApprovals.first)
        XCTAssertEqual(again.requestID, "a1")
        let draft = try! XCTUnwrap(model.draft(for: again))
        XCTAssertEqual(draft.page, 3, "back at Check your answers, not at question 1")
        XCTAssertEqual(draft.chosen["db"], "Postgres")
        XCTAssertEqual(draft.typed["tests"], "only the fast ones")
        XCTAssertTrue(draft.others.contains("tests"))
        // A different request under the same id starts clean.
        var other = AgentChatQueueFixtureTransport.three
        other = AgentChatApprovalWire(requestID: "a1", kind: "userInput", summary: "x",
                                      details: ["questions": .array([.object(["id": .string("db"), "question": .string("Another?"),
                                                                              "options": .array([])])])], decisions: [])
        XCTAssertNil(model.draft(for: other.value()))
    }

    func testASecretAnswerIsNotKeptForWhenTheCardComesBack() {
        let id = AgentChatIdentity(hostID: "h", agentID: "default", provider: "codex", providerSessionID: "t")
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(AgentChatSnapshot(identity: id, rows: [], activeTurn: "t1", sequence: 0)))
        let ask = AgentChatApprovalWire(requestID: "s1", kind: "userInput", summary: "Token", details: ["questions": .array([
            .object(["id": .string("token"), "question": .string("Token?"), "secret": .bool(true), "options": .array([])]),
            .object(["id": .string("env"), "question": .string("Where?"), "options": .array([.string("prod"), .string("dev")])])])],
                                        decisions: []).value()
        XCTAssertTrue(model.apply(.approvalRequested(ask), identity: id, sequence: 1))
        model.keep(AgentQuestionDraft(fingerprint: ask.questionsFingerprint, chosen: ["env": "dev"],
                                      typed: ["token": "s3cret"], page: 2), for: "s1")
        XCTAssertTrue(model.beginAnswer(requestID: "s1", input: ["token": ["s3cret"], "env": ["dev"]]))
        let draft = try! XCTUnwrap(model.draft(for: ask))
        XCTAssertNil(draft.typed["token"])
        XCTAssertEqual(draft.chosen["env"], "dev")
    }

    func testTheClientSpeaksTheNewRoutes() async throws {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        let client = CompanionHostClient(configuration: try CompanionHostConfiguration(endpoint: URL(string: "https://fixture.invalid:8443")!),
                                         credentials: FixtureCredential(), pinnedFingerprint: nil,
                                         session: URLSession(configuration: options))
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/queue",
                                         body: String(decoding: try fixtureData("agent-chat-queue"), as: UTF8.self))
        let queue = try await client.chatQueue("later", id: UUID())
        XCTAssertEqual(queue?.map(\.text), ["And then run the tests on SQLite."])
        var request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.body(request)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "later")
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/queue/q-01:edit", body: #"{"agent_id":"default","edited":true,"queue":[]}"#)
        let emptied = try await client.chatQueueItem("q-01", action: .edit, text: "new")
        XCTAssertEqual(emptied, [])
        request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        body = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.body(request)) as? [String: Any])
        XCTAssertEqual(body as NSDictionary, ["text": "new"] as NSDictionary)
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/history",
                                         body: String(decoding: try fixtureData("agent-chat-history"), as: UTF8.self))
        let page = try await client.chatHistory(before: "row-1", limit: 4)
        XCTAssertEqual(page.rows.count, 4)
        XCTAssertTrue(page.earlier)
        request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        XCTAssertEqual(request.url?.query, "before=row-1&limit=4")
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/approvals/7",
                                         body: #"{"request_id":"7","kind":"commandExecution","decision":"decline","resolved":true,"delivery":"steered"}"#)
        let result = try await client.chatResolveApproval(requestID: "7", decision: "decline", input: nil, reason: "Use /tmp.")
        XCTAssertEqual(result.delivery, "steered")
        request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        body = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.body(request)) as? [String: Any])
        XCTAssertEqual(body as NSDictionary, ["decision": "decline", "reason": "Use /tmp."] as NSDictionary)
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
