import Foundation
import UserNotifications
import XCTest
@testable import Omodachi

/// NOTIFY-1: deciding on the alert, quiet at the desk, finished and not seen —
/// the App's half. The ledger is pure, so most of this is its rules; the rest
/// is the wire, the settings and what a decision does with each answer.
private let hostA = String(repeating: "a", count: 32)
private let fingerprint = "0123456789abcdef"

private func posts(_ actions: [AttentionAction]) -> [AttentionAlert] {
    actions.compactMap { if case .post(let alert) = $0 { alert } else { nil } }
}
private func retracts(_ actions: [AttentionAction]) -> [String] {
    actions.compactMap { if case .retract(let id) = $0 { id } else { nil } }
}

/// Answers a decision from a script and remembers what it was asked.
private final class ScriptedDecider: ApprovalDeciding, @unchecked Sendable {
    var paired: Set<String> = [hostA]
    var answer: AttentionDecisionOutcome = .sent
    private(set) var asked: [(String, String, String, String)] = []
    @MainActor func canDecide(hostID: String) -> Bool { paired.contains(hostID) }
    func decide(hostID: String, requestID: String, fingerprint: String, decision: String) async -> AttentionDecisionOutcome {
        asked.append((hostID, requestID, fingerprint, decision))
        return answer
    }
}

@MainActor final class NOTIFY1Tests: XCTestCase {
    // MARK: - The wire

    private func event(_ type: String, _ payload: String) throws -> SanitizedHostEvent {
        try CompanionHostClient.decodeEvent(Data(#"{"event":{"seq":3,"event_id":"e3","type":"\#(type)","device_id":null,"payload":\#(payload),"ts":1},"instance_id":"n2","after_cursor":2}"#.utf8))
    }

    func testTheEventsCarryIdsAndReadingsOnly() throws {
        let asked = try event("agent.changed", #"{"agent":{"status":"waiting_on_approval","chat":{"pending_approvals":1,"approval":{"request_id":"41","kind":"commandExecution","fingerprint":"\#(fingerprint)","decidable":true}}},"revision":4}"#)
        XCTAssertEqual(asked.agentStatus, "waiting_on_approval")
        XCTAssertEqual(asked.notify?.approval, .some(AttentionApproval(requestID: "41", kind: "commandExecution",
                                                                       fingerprint: fingerprint, decidable: true)))
        // `null`: nothing pending any more. Absent: the event said nothing about it.
        XCTAssertEqual(try event("agent.changed", #"{"agent":{"chat":{"approval":null}},"revision":5}"#).notify?.approval, .some(nil))
        XCTAssertNil(try event("agent.changed", #"{"agent":{"status":"working"},"revision":6}"#).notify)
        // A malformed one is no approval at all; a question is never decidable.
        XCTAssertEqual(try event("agent.changed", #"{"agent":{"chat":{"approval":{"request_id":"../x","fingerprint":"zz"}}},"revision":7}"#).notify?.approval, .some(nil))
        let question = try event("agent.changed", #"{"agent":{"chat":{"approval":{"request_id":"9","kind":"userInput","fingerprint":"\#(fingerprint)","decidable":true}}},"revision":8}"#)
        XCTAssertEqual(question.notify?.approval??.decidable, false)
        XCTAssertEqual(try event("desk.changed", #"{"desk":{"present":true,"state":"using","source":"wayland"},"revision":9}"#).notify?.desk,
                       DeskReading(present: true, state: "using"))
        XCTAssertEqual(try event("desk.changed", #"{"desk":{"present":false,"state":"<b>","source":"x"},"revision":10}"#).notify?.desk?.state,
                       "unknown")
        let seen = try event("unseen.changed", #"{"unseen":{"agent":true,"herdr":[{"session":"work","pane_id":"w1:p2","name":"codex\nx"},{"session":"--bad","pane_id":"w1:p1","name":null}]},"revision":11}"#)
        XCTAssertEqual(seen.notify?.unseen, UnseenReading(agent: true, herdr: [.init(session: "work", paneID: "w1:p2", name: "codexx")]))
    }

    func testTheStateCarriesTheThreeAndAnOlderCoreNoneOfThem() throws {
        // The shape of core's `contracts/fixtures/state-notify1.json`.
        let json = #"""
        {"revision":3,"agent":{"status":"waiting_on_approval","chat":{"status":{"waiting":"approval"},"pending_approvals":1,
          "approval":{"request_id":"approval-fixture-01","kind":"commandExecution","fingerprint":"cabe476767cbe468","decidable":true}}},
         "desk":{"present":true,"state":"using","source":"wayland"},
         "unseen":{"agent":false,"herdr":[{"session":"omodachi","pane_id":"w1:p2","name":"codex"}]}}
        """#
        let state = try JSONDecoder().decode(HostStateDTO.self, from: Data(json.utf8))
        XCTAssertEqual(state.agent?.approval?.requestID, "approval-fixture-01")
        XCTAssertEqual(state.agent?.chat?.pendingApprovals, 1)
        XCTAssertEqual(state.desk, DeskReading(present: true, state: "using"))
        XCTAssertEqual(state.unseen?.herdr.map(\.paneID), ["w1:p2"])
        let old = try JSONDecoder().decode(HostStateDTO.self, from: Data(#"{"revision":1,"agent":{"status":"working"}}"#.utf8))
        XCTAssertNil(old.agent?.approval)
        XCTAssertNil(old.desk)
        XCTAssertNil(old.unseen)
    }

    func testAnApprovalAlertCarriesTheRequestAndOnlyAnApprovalDoes() {
        let target = AttentionTarget(hostID: hostA, kind: .agentApproval, requestID: "41", fingerprint: fingerprint)
        XCTAssertTrue(target.decidable)
        XCTAssertEqual(target.userInfo["request_id"], "41")
        XCTAssertEqual(AttentionTarget(userInfo: target.userInfo), target)
        var info = target.userInfo
        info["kind"] = "agent_needs_input"
        XCTAssertNil(AttentionTarget(userInfo: info)?.requestID, "only an approval names a request")
        info = target.userInfo
        info["fingerprint"] = "nope"
        XCTAssertFalse(AttentionTarget(userInfo: info)?.decidable ?? true, "a bad fingerprint is no decision")
        XCTAssertEqual(AttentionTarget(hostID: hostA, kind: .herdrFinished, session: "w", pane: "w1:p1").link,
                       AppLink(target: .herdr, hostID: hostA, session: "w", pane: "w1:p1"))
        XCTAssertEqual(AttentionTarget(hostID: hostA, kind: .agentFinished).link, AppLink(target: .agent, hostID: hostA))
    }

    // MARK: - Act on the alert: the ledger

    private func connected() -> AttentionLedger {
        var ledger = AttentionLedger()
        ledger.connected(hostID: hostA, hostName: "omarchy")
        _ = ledger.agent(status: "working", now: 0)
        return ledger
    }

    func testTheApprovalAlertNamesThePendingRequestAndFollowsIt() {
        var ledger = connected()
        let first = AttentionApproval(requestID: "41", kind: "commandExecution", fingerprint: fingerprint, decidable: true)
        let alert = posts(ledger.agent(status: "waiting_on_approval", approval: .some(first), now: 1)).first
        XCTAssertEqual(alert?.target.requestID, "41")
        XCTAssertEqual(alert?.target.fingerprint, fingerprint)
        // Answered at the computer and a second one asked, all while waiting:
        // the alert is replaced so its buttons decide the one pending now.
        let second = AttentionApproval(requestID: "42", kind: "fileChange", fingerprint: "fedcba9876543210", decidable: true)
        XCTAssertEqual(posts(ledger.agent(status: "waiting_on_approval", approval: .some(second), now: 40)).first?.target.requestID, "42")
        XCTAssertEqual(ledger.agent(status: "waiting_on_approval", approval: .some(second), now: 41), [], "the same one: no news")
        // A question is answered in the app: no request on the alert.
        _ = ledger.agent(status: "working", approval: .some(nil), now: 80)
        let question = AttentionApproval(requestID: "9", kind: "userInput", fingerprint: fingerprint, decidable: false)
        XCTAssertNil(posts(ledger.agent(status: "waiting_on_approval", approval: .some(question), now: 120)).first?.target.requestID)
    }

    func testAnOlderCoreGetsAnAlertThatOpensTheApp() {
        var ledger = connected()
        let alert = posts(ledger.agent(status: "waiting_on_approval", now: 1)).first
        XCTAssertNotNil(alert)
        XCTAssertFalse(alert?.target.decidable ?? true)
    }

    // MARK: - Act on the alert: the notifier

    private func notifier(_ decider: ScriptedDecider, suite: String = UUID().uuidString) throws -> AttentionNotifier {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "notify1-\(suite)"))
        addTeardownBlock { defaults.removePersistentDomain(forName: "notify1-\(suite)") }
        return AttentionNotifier(system: false, defaults: defaults, decider: decider)
    }

    func testAllowAndDenyOnlyWhenEveryPieceIsThere() throws {
        let decider = ScriptedDecider()
        let attention = try notifier(decider)
        let decidable = AttentionTarget(hostID: hostA, kind: .agentApproval, requestID: "41", fingerprint: fingerprint)
        XCTAssertEqual(attention.category(for: decidable), AttentionNotifier.CategoryID.decide)
        XCTAssertEqual(attention.category(for: AttentionTarget(hostID: hostA, kind: .agentApproval)),
                       AttentionNotifier.CategoryID.answer, "no request id: Answer… only")
        decider.paired = []
        XCTAssertEqual(attention.category(for: decidable), AttentionNotifier.CategoryID.answer,
                       "no pairing with that computer here: never a dead button")
        XCTAssertEqual(attention.category(for: AttentionTarget(hostID: hostA, kind: .herdrBlocked, session: "w", pane: "w1:p1")),
                       AttentionNotifier.CategoryID.answer, "core does not know a pane's choices")
        XCTAssertNil(attention.category(for: AttentionTarget(hostID: hostA, kind: .herdrFinished)))
    }

    func testTheCategoriesAskForTheUnlockAndNeverOfferDontAskAgain() throws {
        let categories = AttentionNotifier.categories()
        let decide = try XCTUnwrap(categories.first { $0.identifier == AttentionNotifier.CategoryID.decide })
        XCTAssertEqual(decide.actions.map(\.identifier),
                       [AttentionNotifier.ActionID.allow, AttentionNotifier.ActionID.deny, AttentionNotifier.ActionID.answer])
        XCTAssertTrue(decide.actions[0].options.contains(.authenticationRequired))
        XCTAssertTrue(decide.actions[1].options.contains(.authenticationRequired))
        XCTAssertFalse(decide.actions[0].options.contains(.foreground), "Allow runs without opening the app")
        XCTAssertTrue(decide.actions[2].options.contains(.foreground), "Answer… opens it")
        XCTAssertEqual(decide.actions.map(\.title), [Strings.attentionActionAllow, Strings.attentionActionDeny,
                                                     Strings.attentionActionAnswer])
        let answer = try XCTUnwrap(categories.first { $0.identifier == AttentionNotifier.CategoryID.answer })
        XCTAssertEqual(answer.actions.map(\.identifier), [AttentionNotifier.ActionID.answer])
    }

    func testADecisionSendsAcceptOrDeclineForThatRequestAndSaysWhenNothingWasSent() async throws {
        let decider = ScriptedDecider()
        let attention = try notifier(decider)
        var opened: [AttentionTarget] = []
        attention.onOpen = { opened.append($0) }
        let info = AttentionTarget(hostID: hostA, kind: .agentApproval, requestID: "41", fingerprint: fingerprint).userInfo
        await attention.decide(info, allow: true)
        await attention.decide(info, allow: false)
        XCTAssertEqual(decider.asked.map(\.3), ["accept", "decline"], "never acceptForSession")
        XCTAssertEqual(decider.asked.first?.1, "41")
        XCTAssertEqual(decider.asked.first?.2, fingerprint)
        XCTAssertNil(attention.notice)
        XCTAssertEqual(opened, [], "sent: the app stays where it is")
        // Answered at the computer meanwhile, with the app in front: nothing
        // sent, and the app lands on the Agent and says why.
        decider.answer = .gone
        await attention.decide(info, allow: true, appActive: true)
        XCTAssertEqual(attention.notice, Strings.attentionNoticeGone)
        XCTAssertEqual(opened.map(\.kind), [.agentApproval])
        XCTAssertNil(opened.first?.requestID)
        // From the lock screen the replacement alert carries the reason, and a
        // tap on it says the sentence where it lands.
        attention.notice = nil
        decider.answer = .changed
        await attention.decide(info, allow: true, appActive: false)
        XCTAssertNil(attention.notice)
        var followUp = AttentionTarget(hostID: hostA, kind: .agentApproval).userInfo
        followUp["notice"] = "\(AttentionDecisionOutcome.changed)"
        attention.opened(followUp)
        XCTAssertEqual(attention.notice, Strings.attentionNoticeChanged)
        XCTAssertEqual(AttentionNotifier.sentence(for: .unreachable, hostName: "omarchy"),
                       Strings.attentionNotSentUnreachable("omarchy"))
        // An alert without a request is not decided: it opens the app.
        let before = decider.asked.count
        await attention.decide(AttentionTarget(hostID: hostA, kind: .agentApproval).userInfo, allow: true)
        XCTAssertEqual(decider.asked.count, before)
        XCTAssertEqual(opened.count, 3)
    }

    func testTheClientSendsTheFingerprintWithTheDecision() async throws {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        let client = CompanionHostClient(configuration: try CompanionHostConfiguration(endpoint: URL(string: "https://fixture.invalid:8443")!),
                                         credentials: FixtureCredential(), pinnedFingerprint: nil,
                                         session: URLSession(configuration: options))
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/agent/default/chat/approvals/41",
                                         body: #"{"request_id":"41","kind":"commandExecution","decision":"accept","resolved":true}"#)
        let result = try await client.chatResolveApproval(requestID: "41", decision: "accept", input: nil, fingerprint: fingerprint)
        XCTAssertTrue(result.resolved)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.body(XCTUnwrap(CompanionURLProtocol.storage.requests.last)))
                                 as? [String: String])
        XCTAssertEqual(body, ["decision": "accept", "fingerprint": fingerprint])
        // The Agent panel's own taps send no fingerprint, as before.
        _ = try await client.chatResolveApproval(requestID: "41", decision: "decline", input: nil)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.body(XCTUnwrap(CompanionURLProtocol.storage.requests.last)))
                                  as? [String: String])
        XCTAssertEqual(plain, ["decision": "decline"])
        for code in ["agent_approval_changed", "agent_approval_unknown"] {
            CompanionURLProtocol.storage.set("/v1/agent/default/chat/approvals/41", status: 409,
                                             body: #"{"error":{"code":"\#(code)","message":"x"}}"#)
            do {
                _ = try await client.chatResolveApproval(requestID: "41", decision: "accept", input: nil, fingerprint: fingerprint)
                XCTFail("refused")
            } catch let error as AgentChatHostError {
                XCTAssertEqual(error.code, code)
                XCTAssertFalse(ReasonText.message(code, domain: .agent).isEmpty)
            }
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

    // MARK: - Quiet at the desk

    func testAtTheDeskAlertsWaitAndLeavingSaysOnlyWhatIsStillWaiting() {
        var ledger = connected()
        _ = ledger.desk(present: true, now: 0)
        XCTAssertEqual(ledger.agent(status: "waiting_on_approval", now: 1), [], "held")
        XCTAssertEqual(ledger.held.count, 1)
        XCTAssertEqual(posts(ledger.desk(present: false, now: 60)).map(\.target.kind), [.agentApproval],
                       "still pending when the desk was left: it rings")
        // Answered at the computer while held: dropped.
        _ = ledger.agent(status: "working", now: 61)
        _ = ledger.desk(present: true, now: 62)
        _ = ledger.agent(status: "waiting_on_user_input", now: 100)
        _ = ledger.agent(status: "working", now: 101)
        XCTAssertEqual(ledger.held, [:], "the withdrawal took it out")
        _ = ledger.agent(status: "waiting_on_approval", now: 140)
        _ = ledger.agent(status: "working", now: 141)
        XCTAssertEqual(posts(ledger.desk(present: false, now: 200)), [])
    }

    func testTheSettingTurnsHoldingOffAndLetsWhatWasHeldGo() {
        var ledger = connected()
        _ = ledger.desk(present: true, now: 0)
        _ = ledger.agent(status: "waiting_on_approval", now: 1)
        XCTAssertEqual(posts(ledger.setHoldAtDesk(false)).count, 1)
        _ = ledger.agent(status: "working", now: 40)
        XCTAssertEqual(posts(ledger.agent(status: "waiting_on_user_input", now: 80)).count, 1, "not held any more")
    }

    func testHerdrWaitsThirtySecondsAndIsOneAlertAnsweredAtTheDeskMeansNothing() {
        var ledger = connected()
        let pane = { (id: String) in HerdrAttentionEvent.Pane(paneID: id, name: "codex") }
        _ = ledger.herdr(.init(session: "work", blocked: []), now: 0)
        _ = ledger.herdr(.init(session: "work", blocked: [pane("w1:p1")]), now: 1)
        XCTAssertEqual(ledger.herdr(.init(session: "work", blocked: []), now: 10), [], "answered within 30 s")
        XCTAssertNil(ledger.nextDue)
        XCTAssertEqual(ledger.due(now: 31), [])
        // Two sessions waiting: one alert for the computer.
        _ = ledger.herdr(.init(session: "play", blocked: []), now: 40)
        _ = ledger.herdr(.init(session: "work", blocked: [pane("w1:p1")]), now: 41)
        _ = ledger.herdr(.init(session: "play", blocked: [pane("w3:p1")]), now: 45)
        let digest = posts(ledger.due(now: 71))
        XCTAssertEqual(digest.map(\.id), [AttentionLedger.herdrDigestID(hostA)])
        XCTAssertEqual(digest.first?.title, Strings.attentionHerdrManyTitle(Format.count(2)))
        // At the desk the Herdr alert waits too, and says what waits on release.
        _ = ledger.herdr(.init(session: "work", blocked: []), now: 80)
        _ = ledger.desk(present: true, now: 81)
        _ = ledger.herdr(.init(session: "work", blocked: [pane("w1:p7")]), now: 82)
        XCTAssertEqual(ledger.due(now: 112), [])
        let released = posts(ledger.desk(present: false, now: 200))
        XCTAssertEqual(released.first?.title, Strings.attentionHerdrManyTitle(Format.count(2)))
        XCTAssertEqual(retracts(ledger.herdr(.init(session: "play", blocked: [], stopped: true), now: 201)), [])
        XCTAssertEqual(retracts(ledger.herdr(.init(session: "work", blocked: []), now: 202)),
                       [AttentionLedger.herdrDigestID(hostA)], "all answered: withdrawn")
    }

    func testTheSettingsAreRememberedAndChangeWhatTheAppTellsCore() throws {
        let suite = UUID().uuidString
        let first = try notifier(ScriptedDecider(), suite: suite)
        XCTAssertFalse(first.alertAtDesk, "default: quiet at the desk")
        XCTAssertFalse(first.finishedAlerts, "default: no finished alerts")
        first.alertAtDesk = true
        first.finishedAlerts = true
        let again = try XCTUnwrap(UserDefaults(suiteName: "notify1-\(suite)"))
        XCTAssertTrue(again.bool(forKey: AttentionNotifier.atDeskKey))
        XCTAssertTrue(again.bool(forKey: AttentionNotifier.finishedKey))
        let second = AttentionNotifier(system: false, defaults: again, decider: ScriptedDecider())
        XCTAssertTrue(second.alertAtDesk)
        XCTAssertEqual(AttentionNotifier.alertKinds(for: .authorized, finished: true).suffix(2), ["agent_done", "herdr_done"])
        XCTAssertEqual(AttentionNotifier.alertKinds(for: .provisional, finished: true), ["host_notification"])
    }

    // MARK: - Done, not yet seen

    func testFinishedAlertsAreOptInAndWithdrawnOnceSeen() {
        var ledger = connected()
        let pane = UnseenReading.Pane(session: "work", paneID: "w1:p2", name: "codex")
        XCTAssertEqual(ledger.unseen(.init(agent: false, herdr: []), now: 0), [], "the first reading is a baseline")
        XCTAssertEqual(ledger.unseen(.init(agent: true, herdr: [pane]), now: 1), [], "off by default")
        ledger.finishedAlerts = true
        _ = ledger.unseen(.init(agent: false, herdr: []), now: 2)
        let rang = posts(ledger.unseen(.init(agent: true, herdr: [pane]), now: 3))
        XCTAssertEqual(rang.map(\.target.kind), [.herdrFinished, .agentFinished])
        XCTAssertEqual(rang.first?.title, Strings.attentionFinishedTitle("codex"))
        XCTAssertEqual(rang.first?.target.pane, "w1:p2")
        XCTAssertEqual(retracts(ledger.unseen(.init(agent: false, herdr: []), now: 4)),
                       [AttentionLedger.finishedID(hostA, .init(session: "work", pane: "w1:p2")),
                        AttentionLedger.agentFinishedID(hostA)])
        // Held at the desk, and dropped when it was looked at meanwhile.
        _ = ledger.desk(present: true, now: 40)
        XCTAssertEqual(ledger.unseen(.init(agent: false, herdr: [pane]), now: 41), [])
        _ = ledger.unseen(.init(agent: false, herdr: []), now: 42)
        XCTAssertEqual(posts(ledger.desk(present: false, now: 100)), [])
    }

    func testTheBarsQuietDotFollowsUnseen() throws {
        let attention = try notifier(ScriptedDecider())
        attention.connected(hostID: hostA, hostName: "omarchy")
        attention.stateApplied(agentStatus: "idle", defaultPane: nil, hostName: "omarchy",
                               unseen: .init(agent: false, herdr: [.init(session: "w", paneID: "w1:p1", name: nil)]))
        XCTAssertEqual(attention.unseen?.herdr.count, 1)
        attention.handle(try event("unseen.changed", #"{"unseen":{"agent":false,"herdr":[]},"revision":12}"#))
        XCTAssertEqual(attention.unseen?.herdr, [])
        attention.handle(try event("desk.changed", #"{"desk":{"present":true,"state":"using","source":"wayland"},"revision":13}"#))
        XCTAssertEqual(attention.desk?.present, true)
    }
}
