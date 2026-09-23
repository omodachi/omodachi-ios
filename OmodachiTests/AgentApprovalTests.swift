import XCTest
@testable import Omodachi

/// SPEC-G2 §1. The approval state machine and the steer/interrupt decision,
/// against the contract documents core generates (`contracts/fixtures/`).
/// Synthetic only: no sockets, no provider, no host.
final class AgentApprovalWireTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json",
                                                           subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }

    func testRequestedEventDecodesIntoOneRenderableCard() throws {
        let envelope = try JSONDecoder().decode(AgentChatEventWire.self, from: fixture("agent-chat-event-requested")).value()
        guard case .approvalRequested(let approval) = try XCTUnwrap(envelope.event) else {
            return XCTFail("the requested fixture is an approval")
        }
        XCTAssertEqual(approval.requestID, "7")
        XCTAssertEqual(approval.kind, "commandExecution")
        XCTAssertEqual(approval.summary, "ls -la")
        XCTAssertEqual(approval.decisions, ["accept", "acceptForSession", "decline", "cancel"])
        // `item_id`/`turn_id` identify the row for the provider, not the reader.
        XCTAssertEqual(approval.details.map(\.key), ["command", "command_kind", "cwd"])
        XCTAssertEqual(approval.details.first { $0.key == "cwd" }?.value, "/home/fixture/workspace")
        XCTAssertTrue(approval.questions.isEmpty, "a command approval asks no questions")
    }

    func testResolvedEventNamesWhoAnsweredIt() throws {
        let envelope = try JSONDecoder().decode(AgentChatEventWire.self, from: fixture("agent-chat-event-resolved")).value()
        guard case .approvalResolved(let requestID, let decision, let source) = try XCTUnwrap(envelope.event) else {
            return XCTFail("the resolved fixture is a resolution")
        }
        XCTAssertEqual(requestID, "7")
        XCTAssertEqual(decision, "accept")
        XCTAssertEqual(source, "client")
    }

    func testSnapshotCarriesPendingApprovalsStatusAndUsage() throws {
        let snapshot = try JSONDecoder().decode(AgentChatSnapshotWire.self, from: fixture("agent-chat-snapshot")).value()
        XCTAssertEqual(snapshot.status.waiting, "approval")
        XCTAssertEqual(snapshot.status.label, "Waiting for you")
        XCTAssertEqual(snapshot.usage.last?.totalTokens, 1440)
        XCTAssertEqual(snapshot.usage.modelContextWindow, 400_000)
        XCTAssertEqual(snapshot.usage.model, "gpt-6-astra")
        XCTAssertEqual(snapshot.usage.effort, "high")
        XCTAssertEqual(snapshot.usage.primary?.label, "5h")
        XCTAssertEqual(snapshot.usage.secondary?.label, "weekly")
        XCTAssertEqual(snapshot.usage.contextFraction.map { ($0 * 10_000).rounded() }, 36)
    }

    /// The host found this one. A request id is whatever the client that sent
    /// the message chose — core checks its shape and nothing more — so the
    /// journal can hold ids this app did not write. Reading them as UUIDs made
    /// one foreign id undecode the entire snapshot, and the Agent surface then
    /// said "the host response does not match the supported contract" about a
    /// conversation that was perfectly fine.
    func testAForeignRequestIDDoesNotMakeTheSnapshotUnreadable() throws {
        let data = Data(#"""
        {"identity": {"hostID": "omarchy", "agentID": "default", "provider": "codex", "providerSessionID": "thread-1"},
         "rows": [], "activeTurn": null, "sequence": 14,
         "acceptedRequestIDs": ["spec-g1-b66e8151b72e", "8B9E6A1C-2E5D-4A3F-9E7B-1C0D2E3F4A5B"],
         "pendingApprovals": [], "status": {"type": "idle", "activeFlags": [], "waiting": null},
         "usage": {"tokens": null, "rate_limits": null, "model": null, "effort": null}}
        """#.utf8)
        let snapshot = try JSONDecoder().decode(AgentChatSnapshotWire.self, from: data).value()
        XCTAssertEqual(snapshot.acceptedRequestIDs,
                       ["spec-g1-b66e8151b72e", "8B9E6A1C-2E5D-4A3F-9E7B-1C0D2E3F4A5B"])
        XCTAssertEqual(snapshot.sequence, 14)
    }

    func testApprovalsUsageAndModelsDocumentsDecode() throws {
        struct Approvals: Decodable { let requests: [AgentChatApprovalWire] }
        let approvals = try JSONDecoder().decode(Approvals.self, from: fixture("agent-chat-approvals")).requests.map { $0.value() }
        XCTAssertEqual(approvals.map(\.requestID), ["8"])
        XCTAssertEqual(approvals.first?.summary, "rm -rf build")

        struct Usage: Decodable { let usage: AgentChatUsageWire }
        let usage = try JSONDecoder().decode(Usage.self, from: fixture("agent-chat-usage")).usage.value()
        XCTAssertEqual(usage.primary?.usedPercent, 12)
        XCTAssertEqual(usage.total?.totalTokens, 27_100)

        let models = try JSONDecoder().decode(AgentModelCatalog.self, from: fixture("agent-chat-models"))
        XCTAssertEqual(models.defaultID, "gpt-6-astra")
        XCTAssertEqual(models.offered.first?.name, "GPT-6-Astra")
        XCTAssertEqual(models.offered.first?.efforts, ["low", "medium", "high"])
    }

    /// A host on an API key never receives `account/rateLimits/updated`, so the
    /// quota half of the usage bar has nothing to draw. That is a host state,
    /// not a value to invent (`SPEC-G1-report.md` §5.1).
    func testEmptyRateLimitsAreAbsentRatherThanZero() throws {
        let data = Data(#"{"usage": {"tokens": {"last": {"totalTokens": 8}, "modelContextWindow": 100}, "rate_limits": {}, "model": null, "effort": null}}"#.utf8)
        struct Usage: Decodable { let usage: AgentChatUsageWire }
        let usage = try JSONDecoder().decode(Usage.self, from: data).usage.value()
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertNil(usage.model)
        XCTAssertEqual(usage.contextFraction, 0.08)
    }

    /// An event type this build does not know still holds a sequence. Dropping
    /// it would read as a gap and force a re-snapshot on every one.
    func testUnknownAndReceiptEventsAdvanceTheSequenceWithoutChangingState() throws {
        for type in ["agent.auth.refreshed", "agent.request.declined", "agent.something.future"] {
            let data = Data(#"{"identity": {"hostID": "h", "agentID": "default", "provider": "codex", "providerSessionID": "t"}, "sequence": 9, "event": {"type": "\#(type)"}}"#.utf8)
            let envelope = try JSONDecoder().decode(AgentChatEventWire.self, from: data).value()
            guard case .ignored(let name) = try XCTUnwrap(envelope.event) else {
                return XCTFail("\(type) has no surface and must not end the stream")
            }
            XCTAssertEqual(name, type)
        }
    }
}

final class AgentApprovalStateMachineTests: XCTestCase {
    private let identity = AgentChatIdentity(hostID: "fixture-host", agentID: "default",
                                             provider: "codex", providerSessionID: "fixture-thread")
    private func approval(_ id: String, kind: String = "commandExecution") -> AgentChatApproval {
        AgentChatApproval(requestID: id, kind: kind, summary: "touch /tmp/probe", details: [],
                          questions: [], decisions: ["accept", "acceptForSession", "decline", "cancel"])
    }

    func testOnePromptTakesExactlyOneAnswer() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: "turn-1", sequence: 0))
        XCTAssertTrue(model.apply(.approvalRequested(approval("7")), identity: identity, sequence: 1))
        XCTAssertEqual(model.pendingApprovals.map(\.requestID), ["7"])

        XCTAssertTrue(model.beginDecision(requestID: "7", decision: "accept"))
        XCTAssertFalse(model.beginDecision(requestID: "7", decision: "decline"),
                       "a second tap cannot send a second answer to the same request")
        XCTAssertTrue(model.approvals[0].isDeciding)
        XCTAssertTrue(model.approvals[0].isPending, "in flight is still waiting on the host")

        model.settleDecision(requestID: "7", decision: "accept", source: "client")
        XCTAssertEqual(model.approvals[0].state, .resolved(decision: "accept", source: "client"))
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertEqual(model.approvals.count, 1, "an answered prompt stays as a result row")
    }

    func testRefusedAnswerReturnsTheCardToWaiting() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: "turn-1", sequence: 0))
        XCTAssertTrue(model.apply(.approvalRequested(approval("7")), identity: identity, sequence: 1))
        XCTAssertTrue(model.beginDecision(requestID: "7", decision: "accept"))
        model.failDecision(requestID: "7")
        XCTAssertEqual(model.approvals[0].state, .pending, "an unconfirmed answer leaves the agent waiting")
        XCTAssertTrue(model.beginDecision(requestID: "7", decision: "decline"), "and it can be answered again")
    }

    func testAnswerSomewhereElseResolvesTheSameRow() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: "turn-1", sequence: 0))
        XCTAssertTrue(model.apply(.approvalRequested(approval("7")), identity: identity, sequence: 1))
        XCTAssertTrue(model.apply(.approvalResolved(requestID: "7", decision: nil, source: "elsewhere"),
                                  identity: identity, sequence: 2))
        XCTAssertEqual(model.approvals[0].state, .resolved(decision: nil, source: "elsewhere"))
        XCTAssertFalse(model.beginDecision(requestID: "7", decision: "accept"),
                       "a stale card cannot be answered after the host answered it")
    }

    func testRepeatedRequestIDIsTheSamePromptNotASecondOne() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: "turn-1", sequence: 0))
        XCTAssertTrue(model.apply(.approvalRequested(approval("7")), identity: identity, sequence: 1))
        XCTAssertTrue(model.apply(.approvalRequested(approval("7")), identity: identity, sequence: 2))
        XCTAssertEqual(model.approvals.count, 1)
    }

    /// The host is the authority on what is still waiting. A snapshot that no
    /// longer lists a prompt means it was answered while this client was away.
    func testSnapshotIsTheAuthorityOnWhatIsStillWaiting() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: "turn-1", sequence: 0))
        XCTAssertTrue(model.apply(.approvalRequested(approval("7")), identity: identity, sequence: 1))
        XCTAssertTrue(model.apply(.approvalRequested(approval("8")), identity: identity, sequence: 2))
        XCTAssertTrue(model.beginDecision(requestID: "8", decision: "accept"))

        let snapshot = AgentChatSnapshot(identity: identity, rows: [], activeTurn: "turn-1", sequence: 5,
                                         acceptedRequestIDs: [], pendingApprovals: [approval("8")],
                                         status: .init(type: "active", activeFlags: ["waitingOnApproval"], waiting: "approval"),
                                         usage: .empty)
        XCTAssertTrue(model.restore(snapshot))
        XCTAssertEqual(model.pendingApprovals.map(\.requestID), ["8"], "the host still waits on 8")
        XCTAssertEqual(model.approvals.map(\.requestID), ["8", "7"])
        XCTAssertEqual(model.approvals.last?.state, .resolved(decision: nil, source: "elsewhere"),
                       "7 stopped waiting while this client was away")
        XCTAssertEqual(model.status.waiting, "approval")
    }

    func testProviderConfirmationClearsAPendingModelOverride() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: nil, sequence: 0))
        model.selectedModel = "gpt-6-astra"
        model.selectedEffort = "xhigh"
        XCTAssertEqual(model.effectiveModel, "gpt-6-astra", "a choice shows before the turn carries it")
        var usage = AgentChatUsage.empty
        usage.model = "gpt-6-astra"
        XCTAssertTrue(model.apply(.usageUpdated(usage), identity: identity, sequence: 1))
        XCTAssertNil(model.selectedModel, "the provider confirmed the model")
        XCTAssertEqual(model.selectedEffort, "xhigh", "it said nothing about effort, so that is still pending")
        XCTAssertEqual(model.effectiveModel, "gpt-6-astra")
    }
}

/// §1: sending, steering and interrupting are three different decisions, and
/// which one is offered is decided by the turn, not by the button's label.
final class AgentSteerInterruptTests: XCTestCase {
    private let identity = AgentChatIdentity(hostID: "h", agentID: "default", provider: "codex", providerSessionID: "t")

    func testSteeringIsOfferedExactlyWhenSendingIsNot() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: nil, sequence: 0))
        model.draft = "add the tests too"
        XCTAssertTrue(model.canSend)
        XCTAssertFalse(model.canSteer, "there is no turn to steer")
        XCTAssertFalse(model.canCancel)

        XCTAssertTrue(model.apply(.turnStarted("turn-1"), identity: identity, sequence: 1))
        XCTAssertFalse(model.canSend, "a running turn does not take a new message")
        XCTAssertTrue(model.canSteer)
        XCTAssertTrue(model.canCancel)

        XCTAssertEqual(model.beginSteer(), "add the tests too")
        XCTAssertEqual(model.phase, .running, "steering does not take the turn away from the provider")
        model.steerAcknowledged(text: "add the tests too")
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertFalse(model.canSteer, "an empty composer has nothing to add")
    }

    func testInterruptStaysPendingUntilTheProviderCompletesTheTurn() {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: identity, rows: [], activeTurn: "turn-1", sequence: 0))
        XCTAssertEqual(model.requestCancel(), "turn-1")
        XCTAssertEqual(model.phase, .cancelling)
        model.draft = "actually, also check the logs"
        XCTAssertTrue(model.canSteer, "a turn that has not stopped yet can still be steered")
        XCTAssertNil(model.requestCancel(), "one interrupt per turn")
        XCTAssertTrue(model.apply(.turnFinished(turnID: "turn-1", interrupted: true), identity: identity, sequence: 1))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.canSteer)
    }

    /// The provider's RPC dropping is an event on the stream, not a decode
    /// failure: it moves the surface to reconnecting and keeps the transcript.
    func testProviderDisconnectBecomesReconnectingRatherThanLostHistory() {
        var model = AgentChatModel()
        let row = AgentChatMessage(id: "m1", turnID: "turn-1", role: .assistant, text: "working")
        XCTAssertTrue(model.restore(identity: identity, rows: [.message(row)], activeTurn: "turn-1", sequence: 3))
        XCTAssertTrue(model.apply(.connectionLost, identity: identity, sequence: 4))
        XCTAssertEqual(model.phase, .reconnecting)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.lastSequence, 4)
    }
}
