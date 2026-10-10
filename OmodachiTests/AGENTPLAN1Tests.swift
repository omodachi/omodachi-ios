import XCTest
@testable import Omodachi

/// AGENT-PLAN-1: codex's Plan mode on the phone, on what core makes of real
/// codex 0.160 frames (`CoreFixtures/agent-chat-snapshot-plan.json`,
/// `agent-chat-event-plan.json`, `agent-chat-mode.json`,
/// `agent-chat-command-plan.json`, from core's replay of a private app-server
/// capture): the mode is the thread's, the plan is a card, the chip leaves
/// Plan mode, and "Implement this plan" does what codex's TUI does.
private actor PlanTransport: AgentChatTransport {
    static let identity = AgentChatIdentity(hostID: "host", agentID: "default", provider: "codex", providerSessionID: "t")
    var calls: [String] = []
    var sent: [String] = []
    var refuse: AgentChatHostError?
    var usage: AgentChatUsage
    init(mode: String) { usage = AgentChatUsage(mode: mode) }
    func ensureDefault() async throws -> AgentChatSnapshot {
        AgentChatSnapshot(identity: Self.identity, rows: [
            .message(.init(id: "u1", turnID: "t1", role: .user, text: "plan it")),
            .message(.init(id: "m1", turnID: "t1", role: .assistant, text: "Here is what I would do.")),
            .message(.init(id: "t1-plan", turnID: "t1", role: .assistant, text: "# Steps\n\n1. One.", plan: true)),
        ], activeTurn: nil, sequence: 3, usage: usage)
    }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot { try await ensureDefault() }
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        AsyncThrowingStream { _ in }
    }
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {
        calls.append("send")
        sent.append(text)
    }
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
    func setMode(_ mode: String) async throws -> AgentChatUsage {
        calls.append("mode:" + mode)
        if let refuse { throw refuse }
        usage.mode = mode
        return usage
    }
    func setRefusal(_ error: AgentChatHostError?) { refuse = error }
}

@MainActor final class AGENTPLAN1Tests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }
    private func model(_ snapshot: AgentChatSnapshot) -> AgentChatModel {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(snapshot))
        return model
    }

    func testTheRealPlanTurnDecodesWithTheThreadsModeAndThePlanAsItsOwnRow() throws {
        let snapshot = try JSONDecoder().decode(AgentChatSnapshotWire.self, from: fixtureData("agent-chat-snapshot-plan")).value()
        XCTAssertEqual(snapshot.usage.mode, "plan")
        let model = model(snapshot)
        XCTAssertTrue(model.planOn)
        let messages = snapshot.rows.compactMap { if case .message(let m) = $0 { m } else { nil } }
        let plan = try XCTUnwrap(messages.first(where: \.isPlan))
        XCTAssertTrue(plan.text.hasPrefix("# Read the port from the environment\n\n1. Add a `PORT` setting"))
        XCTAssertFalse(plan.text.contains("proposed_plan"))
        // After the words that introduce it, as it streamed.
        let turn = messages.filter { $0.turnID == plan.turnID }.map { $0.isPlan ? "plan" : $0.role.rawValue }
        XCTAssertEqual(turn, ["user", "assistant", "plan"])
        XCTAssertEqual(model.actionablePlanID, plan.id)
        // Not a plan for any other message, nor for a user row that says plan: true.
        XCTAssertFalse(messages.filter { !$0.isPlan }.contains { $0.plan == true })
        let forged = #"{"identity":{"hostID":"h","agentID":"default","provider":"codex","providerSessionID":"t"},"rows":[{"kind":"message","id":"x","turnID":"t","role":"user","text":"hi","plan":true}],"activeTurn":null,"sequence":0}"#
        let decoded = try JSONDecoder().decode(AgentChatSnapshotWire.self, from: Data(forged.utf8)).value()
        if case .message(let user) = decoded.rows[0] { XCTAssertFalse(user.isPlan) } else { XCTFail("a message") }
    }

    func testThePlanStreamsInAsAMessageEvent() throws {
        let envelope = try JSONDecoder().decode(AgentChatEventWire.self, from: fixtureData("agent-chat-event-plan")).value()
        guard case .message(let plan)? = envelope.event else { return XCTFail("a message event") }
        XCTAssertTrue(plan.isPlan)
        XCTAssertTrue(plan.text.contains("Run the tests on SQLite."))
    }

    func testTheModeIsReadLenientlyAndAnOlderCoreHasNone() throws {
        func usage(_ json: String) throws -> AgentChatUsage {
            try JSONDecoder().decode(AgentChatUsageWire.self, from: Data(json.utf8)).value()
        }
        XCTAssertEqual(try usage(#"{"tokens":null,"rate_limits":null,"model":"m","effort":"high","mode":"plan"}"#).mode, "plan")
        XCTAssertEqual(try usage(#"{"tokens":null,"rate_limits":null,"model":"m","effort":"high","mode":"default"}"#).mode, "default")
        XCTAssertNil(try usage(#"{"tokens":null,"rate_limits":null,"model":"m","effort":"high"}"#).mode)
        XCTAssertNil(try usage(#"{"tokens":null,"rate_limits":null,"model":"m","effort":"high","mode":"auto"}"#).mode)
        XCTAssertNil(try usage(#"{"tokens":null,"rate_limits":null,"model":"m","effort":"high","mode":7}"#).mode)
        XCTAssertNil(try usage(#"{"tokens":null,"rate_limits":null,"model":"m","effort":"high","mode":null}"#).mode)
    }

    func testTheModeChangesBetweenTurnsOnlyAndSaysWhy() throws {
        var model = model(try JSONDecoder().decode(AgentChatSnapshotWire.self, from: fixtureData("agent-chat-snapshot-plan")).value())
        XCTAssertNil(model.modeRefusal)
        model.modeBusy = true
        XCTAssertEqual(model.modeRefusal, Strings.agentPlanSwitching)
        model.modeBusy = false
        let identity = try XCTUnwrap(model.identity)
        XCTAssertTrue(model.apply(.turnStarted("t9"), identity: identity, sequence: model.lastSequence + 1))
        XCTAssertEqual(model.modeRefusal, Strings.agentPlanWhileWorking)
        // A new turn's user words: the old plan is no longer the one to act on.
        XCTAssertTrue(model.apply(.message(.init(id: "u9", turnID: "t9", role: .user, text: "more")), identity: identity,
                                  sequence: model.lastSequence + 1))
        XCTAssertNil(model.actionablePlanID)
        // The mode follows codex's own word, here `agent.usage.updated`.
        XCTAssertTrue(model.apply(.usageUpdated(AgentChatUsage(mode: "default")), identity: identity,
                                  sequence: model.lastSequence + 1))
        XCTAssertFalse(model.planOn)
    }

    func testTheChipLeavesPlanModeOnTheHostAndATurnInFlightSaysWhyInstead() async {
        let transport = PlanTransport(mode: "plan")
        let store = AgentChatStore(transport: transport)
        await store.open()
        XCTAssertTrue(store.model.planOn)
        let left = await store.setMode("default")
        XCTAssertTrue(left)
        XCTAssertFalse(store.model.planOn)
        XCTAssertFalse(store.model.modeBusy)
        let calls = await transport.calls
        XCTAssertEqual(calls, ["mode:default"])
        // While a turn runs nothing is asked; the reason is said.
        let identity = store.model.identity!
        _ = store.model.apply(.turnStarted("t2"), identity: identity, sequence: store.model.lastSequence + 1)
        let refused = await store.setMode("plan")
        XCTAssertFalse(refused)
        XCTAssertEqual(store.model.notice, Strings.agentPlanWhileWorking)
        let after = await transport.calls
        XCTAssertEqual(after, ["mode:default"])
    }

    func testARefusalIsSaidInWords() async {
        let transport = PlanTransport(mode: "plan")
        await transport.setRefusal(AgentChatHostError(code: "agent_mode_unavailable"))
        let store = AgentChatStore(transport: transport)
        await store.open()
        let changed = await store.setMode("default")
        XCTAssertFalse(changed)
        XCTAssertEqual(store.model.notice, Strings.reasonAgentModeUnavailable)
        XCTAssertTrue(store.model.planOn)
        XCTAssertFalse(store.model.modeBusy)
        XCTAssertEqual(AgentChatHostError(code: "invalid_agent_mode").localizedDescription, Strings.reasonAgentModeInvalid)
    }

    func testImplementThisPlanLeavesPlanModeThenSendsTheWordsAndKeepsTheDraft() async {
        let transport = PlanTransport(mode: "plan")
        let store = AgentChatStore(transport: transport)
        await store.open()
        XCTAssertEqual(store.model.actionablePlanID, "t1-plan")
        store.model.draft = "half a thought"
        await store.implementPlan()
        let calls = await transport.calls
        XCTAssertEqual(calls, ["mode:default", "send"])
        let sent = await transport.sent
        XCTAssertEqual(sent, [Strings.agentPlanImplementMessage])
        XCTAssertEqual(store.model.draft, "half a thought")
        XCTAssertFalse(store.model.planOn)
        XCTAssertEqual(store.model.localEcho?.text, Strings.agentPlanImplementMessage)
        // Plan mode off: there is nothing left to implement from here.
        XCTAssertNil(store.model.actionablePlanID)
    }

    func testTheClientAsksForTheModeAndDecodesCoresAnswer() async throws {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        let client = CompanionHostClient(configuration: try CompanionHostConfiguration(endpoint: URL(string: "https://fixture.invalid:8443")!),
                                         credentials: FixtureCredential(), pinnedFingerprint: nil,
                                         session: URLSession(configuration: options))
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/mode",
                                         body: String(decoding: try fixtureData("agent-chat-mode"), as: UTF8.self))
        let usage = try await client.chatMode("plan")
        XCTAssertEqual(usage.mode, "plan")
        let request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/agent/default/chat/mode")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.body(request)) as? [String: Any])
        XCTAssertEqual(body as NSDictionary, ["mode": "plan"] as NSDictionary)
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/mode", status: 409,
                                         body: #"{"error":{"code":"agent_busy","message":"x"}}"#)
        do {
            _ = try await client.chatMode("default")
            XCTFail("refused")
        } catch let error as AgentChatHostError {
            XCTAssertEqual(error.code, "agent_busy")
        }
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

    func testWhatIsTypedGoesThroughAndTheHostsAnswerSettlesIt() async throws {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        let client = CompanionHostClient(configuration: try CompanionHostConfiguration(endpoint: URL(string: "https://fixture.invalid:8443")!),
                                         credentials: FixtureCredential(), pinnedFingerprint: nil,
                                         session: URLSession(configuration: options))
        try await client.connect()
        // `/plan` alone: the host switched the mode, no turn starts.
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/messages",
            body: #"{"contract_revision":"omodachi.v1","accepted":true,"delivery":"command","command":"plan","mode":"plan"}"#)
        let plan = try await client.chatSend("/plan", id: UUID(), model: nil, effort: nil, attachments: [])
        XCTAssertEqual(plan, AgentSendReceipt(command: "plan", startsNoTurn: true))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Self.body(try XCTUnwrap(CompanionURLProtocol.storage.requests.last))) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "/plan", "sent as typed")
        // `/diff`: the conversation's change cards come with the answer.
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/messages",
            body: #"{"accepted":true,"delivery":"command","command":"diff","changes_omitted":2,"changes":[{"path":"/w/app.py","kind":"update","added":1,"removed":1,"diff":"@@ -1 +1 @@\n-a\n+b","turnID":"t1"},{"path":"","kind":"update","added":0,"removed":0,"diff":""}]}"#)
        let diff = try await client.chatSend("/diff", id: UUID(), model: nil, effort: nil, attachments: [])
        XCTAssertTrue(diff.startsNoTurn)
        XCTAssertEqual(diff.changes.map(\.path), ["/w/app.py"], "a change of a shape this build does not read is left out")
        XCTAssertEqual(diff.changesOmitted, 2)
        // an ordinary message (an older core too) is an ordinary receipt
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/messages",
            body: #"{"accepted":true,"turnID":"t2","delivery":"accepted"}"#)
        let words = try await client.chatSend("/vim", id: UUID(), model: nil, effort: nil, attachments: [])
        XCTAssertEqual(words, AgentSendReceipt())
    }

    func testTheAnswerSettlesTheEchoAndTheDiffCard() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(AgentChatSnapshot(identity: PlanTransport.identity, rows: [], activeTurn: nil, sequence: 0)))
        model.draft = "/plan"
        let text = model.beginSend()!
        XCTAssertEqual(model.phase, .sending)
        model.sendAnswered(text: text, receipt: AgentSendReceipt(command: "plan", startsNoTurn: true))
        XCTAssertEqual(model.phase, .ready, "nothing waits for a turn that is not coming")
        XCTAssertNil(model.localEcho)
        // `/plan <words>`: codex records only the words; any user row of the turn is the echo.
        model.draft = "/plan read the port"
        let words = model.beginSend()!
        model.sendAnswered(text: words, receipt: AgentSendReceipt(command: "plan"))
        XCTAssertEqual(model.phase, .sending)
        XCTAssertTrue(model.apply(.turnStarted("t1"), identity: PlanTransport.identity, sequence: 1))
        XCTAssertTrue(model.apply(.message(.init(id: "u1", turnID: "t1", role: .user, text: "read the port")),
                                  identity: PlanTransport.identity, sequence: 2))
        XCTAssertNil(model.localEcho, "no second copy of the words")
        XCTAssertTrue(model.apply(.turnFinished(turnID: "t1", interrupted: false), identity: PlanTransport.identity, sequence: 3))
        // `/diff`
        model.draft = "/diff"
        let diff = model.beginSend()!
        let change = AgentChatChange(path: "/w/app.py", kind: .update, added: 1, removed: 1, diff: ["-a", "+b"])
        model.sendAnswered(text: diff, receipt: AgentSendReceipt(command: "diff", startsNoTurn: true, changes: [change],
                                                                 changesOmitted: 1))
        XCTAssertEqual(model.diff, AgentDiffState(changes: [change], omitted: 1))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(AgentChatHostError(code: "agent_command_while_working").localizedDescription,
                       Strings.reasonAgentCommandWhileWorking)
    }
}
