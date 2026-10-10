import Foundation
import XCTest
@testable import Omodachi

/// NOTIFY-2: the app's own alerts, where a tap or a link lands, and what the
/// app tells core about itself.
private let hostA = String(repeating: "0", count: 32)
private let hostB = String(repeating: "1", count: 32)

private func coreFixture(_ name: String) throws -> Data {
    try Data(contentsOf: XCTUnwrap(Bundle(for: NOTIFY2Tests.self)
        .url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures")))
}

private final class PresenceKeychain: KeychainRecordStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    func save(_ value: Data, service: String, account: String) throws { lock.withLock { values["\(service)|\(account)"] = value } }
    func insertIfAbsent(_ value: Data, service: String, account: String) throws -> Bool {
        lock.withLock {
            if values["\(service)|\(account)"] != nil { return false }
            values["\(service)|\(account)"] = value
            return true
        }
    }
    func load(service: String, account: String) throws -> Data? { lock.withLock { values["\(service)|\(account)"] } }
    func remove(service: String, account: String) throws { lock.withLock { _ = values.removeValue(forKey: "\(service)|\(account)") } }
}

/// A host with one event stream per connection and the presence route.
private actor PresenceHost: CompanionServing, PresenceReporting {
    private(set) var presence: [PresenceBody] = []
    private var continuation: AsyncThrowingStream<SanitizedHostEvent, Error>.Continuation?
    func reportPresence(_ body: PresenceBody) async -> PresenceDTO? {
        presence.append(body)
        return PresenceDTO(foreground: body.foreground, alerts: body.alerts, quiets: body.foreground ? body.alerts : [])
    }
    func connect() async throws {}
    func disconnect() async { continuation?.finish(); continuation = nil }
    static func state(_ status: String) throws -> HostStateDTO {
        try JSONDecoder().decode(HostStateDTO.self, from: Data(#"""
        {"revision":1,"event_cursor":1,"instance_id":"n2","host":{"name":"omarchy-fixture","connected":true},
         "agent":{"status":"\#(status)","default_agent":{"pane_id":"w1:p2"}}}
        """#.utf8))
    }
    func fetchState() async throws -> HostStateDTO { try Self.state("working") }
    func fetchSnapshot() async throws -> CompanionSnapshot {
        let decoder = JSONDecoder()
        return try CompanionSnapshot(state: Self.state("waiting_on_approval"),
            capabilities: decoder.decode(HostCapabilitiesDTO.self, from: Data(#"{"terminal":true,"desktop":false}"#.utf8)),
            catalog: decoder.decode(HostCatalogDTO.self, from: Data(#"{"revision":"n2","entries":[]}"#.utf8)),
            herdr: decoder.decode(HostHerdrDTO.self, from: Data(#"{"available":true}"#.utf8)))
    }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter], targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse { throw CompanionHostError.notConnected }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse { throw CompanionHostError.notConnected }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        AsyncThrowingStream { continuation = $0 }
    }
    var isListening: Bool { continuation != nil }
    func send(_ event: SanitizedHostEvent) { continuation?.yield(event) }
}

@MainActor final class NOTIFY2Tests: XCTestCase {
    // MARK: - Links

    func testAgentAndHerdrLinksCarryTheHostAndForHerdrTheSessionAndPane() throws {
        let agent = try XCTUnwrap(AppLink.parse(URL(string: "https://omodachi.app/open/agent?host=\(hostA)")!))
        XCTAssertEqual(agent, AppLink(target: .agent, hostID: hostA))
        XCTAssertEqual(AppLink.parse(URL(string: "omodachi://open/agent?host=\(hostA)")!), agent)
        let herdr = try XCTUnwrap(AppLink.parse(URL(string:
            "https://omodachi.app/open/herdr?host=\(hostA)&session=work&pane=w2%3Ap3")!))
        XCTAssertEqual(herdr, AppLink(target: .herdr, hostID: hostA, session: "work", pane: "w2:p3"))
        XCTAssertEqual(AppLink.parse(URL(string: "omodachi://open/herdr?host=\(hostA)&session=work&pane=w2:p3")!), herdr)
        // Ids in Herdr's own alphabets only; a pane needs its session; only Herdr has a place.
        for (query, session, pane) in [("session=--takeover&pane=w1:p1", nil, nil), ("session=a/b", nil, nil),
                                       ("session=work&pane=x;y", "work", nil), ("pane=w1:p1", nil, nil)] as [(String, String?, String?)] {
            let link = try XCTUnwrap(AppLink.parse(URL(string: "omodachi://open/herdr?host=\(hostA)&\(query)")!), query)
            XCTAssertEqual(link.session, session, query)
            XCTAssertEqual(link.pane, pane, query)
        }
        XCTAssertNil(AppLink.parse(URL(string: "omodachi://open/agent?host=\(hostA)&session=work&pane=w1:p1")!)?.session)
        // An unknown host is still the plain sentence, never a pairing.
        XCTAssertEqual(AppLink(target: .agent, hostID: hostB).resolve(records: [], current: nil), .unknownHost)
    }

    func testANotificationCarriesIdsOnlyAndOnlyOursAreRead() throws {
        let target = AttentionTarget(hostID: hostA, kind: .herdrBlocked, session: "work", pane: "w2:p3")
        XCTAssertEqual(target.userInfo, ["omodachi": "attention", "host_id": hostA, "kind": "herdr_blocked",
                                         "session": "work", "pane": "w2:p3"])
        XCTAssertEqual(AttentionTarget(userInfo: target.userInfo), target)
        XCTAssertEqual(target.link, AppLink(target: .herdr, hostID: hostA, session: "work", pane: "w2:p3"))
        XCTAssertEqual(AttentionTarget(hostID: hostA, kind: .agentApproval).link, AppLink(target: .agent, hostID: hostA))
        XCTAssertNil(AttentionTarget(userInfo: ["host_id": hostA, "kind": "agent_approval"]), "not ours")
        XCTAssertNil(AttentionTarget(userInfo: ["omodachi": "attention", "host_id": "192.168.1.10", "kind": "agent_approval"]))
        // NOTIFY-1: a finished turn is one of ours now (opt-in); an unknown kind is not.
        XCTAssertEqual(AttentionTarget(userInfo: ["omodachi": "attention", "host_id": hostA, "kind": "agent_done"])?.kind,
                       .agentFinished)
        XCTAssertNil(AttentionTarget(userInfo: ["omodachi": "attention", "host_id": hostA, "kind": "agent_bored"]))
        let odd = AttentionTarget(userInfo: ["omodachi": "attention", "host_id": hostA, "kind": "agent_approval",
                                             "session": "work", "pane": "w1:p1"])
        XCTAssertNil(odd?.session, "only a Herdr alert names a place in Herdr")
    }

    // MARK: - The ledger

    private func posts(_ actions: [AttentionAction]) -> [AttentionAlert] {
        actions.compactMap { if case .post(let alert) = $0 { alert } else { nil } }
    }
    private func retracts(_ actions: [AttentionAction]) -> [String] {
        actions.compactMap { if case .retract(let id) = $0 { id } else { nil } }
    }

    func testTheAgentRingsForAnApprovalAndAQuestionAndIsWithdrawnWhenAnswered() {
        var ledger = AttentionLedger()
        ledger.connected(hostID: hostA, hostName: "omarchy")
        XCTAssertEqual(ledger.agent(status: "working", now: 0), [], "the first look is a baseline")
        let asked = posts(ledger.agent(status: "waiting_on_approval", now: 1))
        XCTAssertEqual(asked.map(\.target.kind), [.agentApproval])
        XCTAssertEqual(asked.first?.title, Strings.attentionApprovalTitle)
        XCTAssertEqual(asked.first?.body, Strings.attentionApprovalBody("omarchy"))
        XCTAssertEqual(retracts(ledger.agent(status: "working", now: 2)), [AttentionLedger.agentID(hostA)])
        XCTAssertEqual(ledger.agent(status: "working", now: 3), [], "no change, no news")
        XCTAssertEqual(ledger.agent(status: "done", now: 4), [], "a finished turn is Odomo's to say, not the app's")
        // A question 30 s later rings at once; leaving it withdraws it.
        XCTAssertEqual(posts(ledger.agent(status: "waiting_on_user_input", now: 40)).map(\.target.kind), [.agentNeedsInput])
        XCTAssertEqual(ledger.agent(status: "blocked", now: 41), [], "still waiting for input")
        XCTAssertEqual(retracts(ledger.agent(status: "done", now: 42)), [AttentionLedger.agentID(hostA)])
    }

    func testOneSourceSpeaksOnceAWindowAndSaysTheRestAtItsEnd() {
        var ledger = AttentionLedger()
        ledger.connected(hostID: hostA, hostName: "omarchy")
        _ = ledger.agent(status: "working", now: 0)
        XCTAssertEqual(posts(ledger.agent(status: "waiting_on_approval", now: 1)).count, 1)
        _ = ledger.agent(status: "working", now: 2)
        XCTAssertEqual(posts(ledger.agent(status: "waiting_on_approval", now: 3)), [], "held for the window")
        _ = ledger.agent(status: "working", now: 4)
        XCTAssertEqual(posts(ledger.agent(status: "waiting_on_approval", now: 5)), [])
        XCTAssertEqual(ledger.nextDue, 31)
        XCTAssertEqual(ledger.due(now: 20), [])
        let flushed = posts(ledger.due(now: 31))
        XCTAssertEqual(flushed.map(\.more), [0], "the one still waiting, said once (each answer cancelled the one before)")
        XCTAssertNil(ledger.nextDue)
        // A withdrawal cancels what was waiting in the window.
        _ = ledger.agent(status: "working", now: 32)
        _ = ledger.agent(status: "waiting_on_approval", now: 33)
        _ = ledger.agent(status: "working", now: 34)
        XCTAssertEqual(posts(ledger.due(now: 61)), [])
    }

    func testAHerdrPaneRingsWhenItTurnsBlockedNotWhenFirstSeen() {
        // NOTIFY-1: Herdr rings 30 s later, once for the computer, and only
        // for what is still waiting then.
        var ledger = AttentionLedger()
        ledger.connected(hostID: hostA, hostName: "omarchy")
        ledger.defaultPane = "w1:p2"
        let pane = { (id: String) in HerdrAttentionEvent.Pane(paneID: id, name: "claude") }
        let digest = AttentionLedger.herdrDigestID(hostA)
        XCTAssertEqual(ledger.herdr(.init(session: "work", blocked: [pane("w1:p1")]), now: 0), [],
                       "already blocked when first seen: a baseline")
        XCTAssertEqual(ledger.herdr(.init(session: "work", blocked: [pane("w1:p1"), pane("w2:p3")]), now: 1), [],
                       "nothing for 30 s")
        XCTAssertEqual(ledger.nextDue, 31)
        let rang = posts(ledger.due(now: 31))
        XCTAssertEqual(rang.map(\.id), [digest])
        XCTAssertEqual(rang.first?.target, AttentionTarget(hostID: hostA, kind: .herdrBlocked, session: "work", pane: "w2:p3"))
        XCTAssertEqual(rang.first?.title, Strings.attentionHerdrManyTitle(Format.count(2)))
        XCTAssertEqual(rang.first?.body, Strings.attentionHerdrManyBody("omarchy"))
        XCTAssertEqual(ledger.herdr(.init(session: "work", blocked: [pane("w1:p1")]), now: 32), [], "one still waits")
        // The default agent's own pane is the agent asking, which agent.changed says.
        _ = ledger.herdr(.init(session: "omodachi", blocked: []), now: 33)
        XCTAssertEqual(ledger.herdr(.init(session: "omodachi", blocked: [pane("w1:p2")]), now: 34), [])
        XCTAssertNil(ledger.nextDue)
        // A session that stops, with nothing else waiting, withdraws the alert.
        XCTAssertEqual(retracts(ledger.herdr(.init(session: "work", blocked: [], stopped: true), now: 35)), [digest])
        XCTAssertEqual(ledger.herdr(.init(session: "work", blocked: [pane("w9:p9")]), now: 36), [], "a new first look")
        // An agent with no name is still somebody.
        _ = ledger.herdr(.init(session: "work", blocked: [], stopped: true), now: 36.5)
        _ = ledger.herdr(.init(session: "x", blocked: []), now: 37)
        _ = ledger.herdr(.init(session: "x", blocked: [.init(paneID: "w1:p1", name: nil)]), now: 38)
        XCTAssertEqual(posts(ledger.due(now: 68)).first?.title, Strings.attentionHerdrTitle(Strings.attentionHerdrSomeone))
    }

    func testAReconnectWithdrawsWhatStoppedWaitingAndRingsForNothingOld() {
        var ledger = AttentionLedger()
        ledger.connected(hostID: hostA, hostName: "omarchy")
        let pane = HerdrAttentionEvent.Pane(paneID: "w1:p1", name: "codex")
        _ = ledger.herdr(.init(session: "work", blocked: []), now: 0)
        _ = ledger.herdr(.init(session: "work", blocked: [pane]), now: 1)
        XCTAssertEqual(posts(ledger.due(now: 31)).count, 1)
        _ = ledger.agent(status: "working", now: 31)
        _ = ledger.agent(status: "waiting_on_approval", now: 32)
        // Away; meanwhile the pane was answered and the approval too.
        ledger.connected(hostID: hostA, hostName: "omarchy")
        XCTAssertEqual(retracts(ledger.herdr(.init(session: "work", blocked: []), now: 100)),
                       [AttentionLedger.herdrDigestID(hostA)])
        XCTAssertEqual(retracts(ledger.agent(status: "working", now: 100)), [AttentionLedger.agentID(hostA)])
        // Away again; this time something new was waiting when we came back: a baseline.
        ledger.connected(hostID: hostA, hostName: "omarchy")
        XCTAssertEqual(ledger.herdr(.init(session: "work", blocked: [pane]), now: 200), [])
        XCTAssertNil(ledger.nextDue)
        XCTAssertEqual(posts(ledger.agent(status: "waiting_on_approval", now: 200)), [])
        // Another computer starts clean.
        ledger.connected(hostID: hostB, hostName: "other")
        XCTAssertEqual(ledger.herdr(.init(session: "work", blocked: []), now: 300), [])
        XCTAssertNil(ledger.agentStatus)
    }

    func testTheHostsOwnReadingIsTheFirstLookSoTheNextChangeIsNews() throws {
        var ledger = AttentionLedger()
        ledger.connected(hostID: hostA, hostName: "omarchy")
        let p1 = HerdrAttentionEvent.Pane(paneID: "w1:p1", name: "claude")
        let p2 = HerdrAttentionEvent.Pane(paneID: "w1:p2", name: "codex")
        XCTAssertEqual(ledger.seed(["work": [p1], "quiet": []]), [], "a first look is never news")
        // A session nobody opened: its first change after connecting rings (after the delay).
        XCTAssertEqual(ledger.herdr(.init(session: "quiet", blocked: [p2]), now: 1), [])
        XCTAssertEqual(posts(ledger.due(now: 31)).map(\.target.pane), ["w1:p2"],
                       "one alert for the computer, pointing at the pane that just started waiting")
        // A later state read does not overrule the events.
        XCTAssertEqual(ledger.seed(["work": []]), [])
        // After a reconnect the reading withdraws what stopped waiting meanwhile.
        ledger.connected(hostID: hostA, hostName: "omarchy")
        XCTAssertEqual(retracts(ledger.seed(["work": [], "quiet": []])), [AttentionLedger.herdrDigestID(hostA)])
        let json = #"{"revision":1,"herdr":{"available":true,"agent_count":0,"blocked":{"work":[{"pane_id":"w1:p1","name":"claude"},{"pane_id":"x","name":null}],"--bad":[]}}}"#
        let state = try JSONDecoder().decode(HostStateDTO.self, from: Data(json.utf8))
        XCTAssertEqual(state.herdr?.blocked, ["work": [p1]])
    }

    // MARK: - The wire

    func testTheTwoEventsAreReadIdsOnly() throws {
        let stopped = try JSONSerialization.jsonObject(with: coreFixture("event-herdr-layout-stopped")) as? [String: Any]
        var event = try XCTUnwrap(stopped)
        event.removeValue(forKey: "contract_revision")
        let frame = try JSONSerialization.data(withJSONObject: ["event": event, "instance_id": "n2", "after_cursor": 0])
        let decoded = try CompanionHostClient.decodeEvent(frame)
        XCTAssertEqual(decoded.herdrAttention, HerdrAttentionEvent(session: "probe", blocked: [], stopped: true))
        func wire(_ type: String, _ payload: String) throws -> SanitizedHostEvent {
            try CompanionHostClient.decodeEvent(Data(#"{"event":{"seq":3,"event_id":"e3","type":"\#(type)","device_id":null,"payload":\#(payload),"ts":1},"instance_id":"n2","after_cursor":2}"#.utf8))
        }
        XCTAssertEqual(try wire("agent.changed", #"{"agent":{"status":"waiting_on_approval","kind":"codex"},"revision":4}"#).agentStatus,
                       "waiting_on_approval")
        XCTAssertNil(try wire("agent.changed", #"{"agent":{"chat":{}},"revision":5}"#).agentStatus, "a patch without a status")
        XCTAssertNil(try wire("agent.changed", #"{"agent":{"status":"<b>x</b>"},"revision":6}"#).agentStatus)
        let layout = try wire("herdr.layout.changed", #"{"revision":7,"session":"work","blocked":[{"pane_id":"w2:p3","name":"claude\ncode"},{"pane_id":"../x","name":"no"}]}"#)
        XCTAssertEqual(layout.herdrAttention, HerdrAttentionEvent(session: "work", blocked: [.init(paneID: "w2:p3", name: "claudecode")]))
        XCTAssertNil(try wire("herdr.layout.changed", #"{"revision":8,"session":"--x","blocked":[]}"#).herdrAttention)
    }

    func testPresenceIsTheContractsAndSaysOnlyWhatTheAppAlerts() throws {
        let fixture = try JSONDecoder().decode(PresenceDTO.self, from: coreFixture("presence"))
        XCTAssertEqual(fixture.alerts, AttentionNotifier.alertKinds(for: .authorized).sorted())
        XCTAssertEqual(AttentionNotifier.alertKinds(for: .provisional), ["host_notification"],
                       "quiet delivery is not an alert: Odomo is not muted for it")
        XCTAssertEqual(AttentionNotifier.alertKinds(for: .denied), ["host_notification"])
        XCTAssertFalse(AttentionNotifier.alertKinds(for: .authorized).contains("agent_done"))
        let body = try JSONEncoder().encode(PresenceBody(foreground: true, alerts: ["herdr_blocked"]))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? NSDictionary,
                       ["foreground": true, "alerts": ["herdr_blocked"]] as NSDictionary)
    }

    func testTheAppTellsCoreItIsInFrontOnEveryConnectionAndTheAlertsHearTheStream() async throws {
        let name = "notify2-presence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var profile = HostProfile(); profile.mock = false; profile.companionURL = "https://192.168.1.10:8099"
        defaults.set(try JSONEncoder().encode(profile), forKey: "omodachi.profile.v1")
        let pins = HostPinStore(service: "notify2.pins", records: PresenceKeychain())
        try pins.save(HostPin(hostID: hostA, hostName: "omarchy-fixture", fingerprintSHA256: String(repeating: "ab", count: 32),
                              endpoints: [.init(host: "192.168.1.10", port: 8099, kind: .lan)], ssh: nil, grants: nil),
                      account: "https://192.168.1.10:8099")
        let service = PresenceHost()
        let home = HomeStore(defaults: defaults, pinStore: pins, clientFactory: { _, _ in service }, autoConnect: false)
        let attention = AttentionNotifier(system: false)
        home.attention = attention
        await home.connectCompanion()
        for _ in 0..<400 where await service.presence.isEmpty { await Task.yield() }
        let sent = await service.presence
        XCTAssertEqual(sent.first?.foreground, true)
        XCTAssertEqual(sent.first?.alerts, ["host_notification"], "no permission read in a test host: toasts only")
        XCTAssertEqual(attention.agentStatus, "waiting_on_approval", "the snapshot is the first look")
        // The badge's reading follows the host's events, not the Agent panel.
        await service.send(SanitizedHostEvent(sequence: 2, eventID: "e2", type: "agent.changed", instanceID: "n2",
                                              snapshot: nil, needsResync: false, agentStatus: "working"))
        for _ in 0..<400 where attention.agentStatus != "working" { await Task.yield() }
        XCTAssertEqual(attention.agentStatus, "working")
        let back = await home.reportPresence(foreground: false)
        XCTAssertEqual(back?.quiets, [])
        let last = await service.presence.last
        XCTAssertEqual(last?.foreground, false)
        XCTAssertEqual(last?.alerts, [], "in the background the app holds nothing back")
        await home.disconnectCompanion()
    }
}
