import Foundation
import XCTest
@testable import Omodachi

/// STORE-6 §B. The three fixes queued for the next build: the SSH header names
/// the computer, `ended_on_computer` is a sentence, and a `confirm` row's
/// second tap carries the host's `confirm_token`.

private enum ConfirmFixtures {
    static let catalog = #"{"contract_revision":"omodachi.v1","revision":"catalog-confirm-v1","entries":[{"id":"root","label":"Go","parent_id":"","visible":true,"route":{"route":"host","supported":false}},{"id":"system","label":"System","parent_id":"root","visible":true,"route":{"route":"host","supported":false}},{"id":"system.lock","label":"Lock","parent_id":"system","visible":true,"route":{"route":"host","supported":true,"ready":true,"confirm":true,"entry_id":"system.lock"}},{"id":"system.screensaver","label":"Screensaver","parent_id":"system","visible":true,"route":{"route":"host","supported":true,"ready":true,"entry_id":"system.screensaver"}}]}"#
    static var state: String {
        #"{"contract_revision":"omodachi.v1","revision":4,"instance_id":"instance-fixture","event_cursor":2,"host":{"name":"fixture-host","connected":true},"workspace":{"active":1},"catalog":CATALOG}"#
            .replacingOccurrences(of: "CATALOG", with: catalog)
    }
    static let token = String(repeating: "a", count: 21) + "-_" + String(repeating: "Z", count: 20)
    static func decode<T: Decodable>(_ text: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    static func snapshot() throws -> CompanionSnapshot {
        try .init(state: decode(state), capabilities: decode(#"{"terminal":true,"desktop":false,"sunshine":false,"native":[]}"#),
                  catalog: decode(catalog), herdr: decode(#"{"available":false,"agent_count":0}"#))
    }
}

/// A host that enforces RELEASE-9's rule: a `confirm` row's first call is
/// refused with a token, and it runs only on a call that carries it.
private actor ConfirmingHost: CompanionServing {
    var calls: [(entryID: String, token: String?)] = []
    let snapshot: CompanionSnapshot
    /// Rows the host asks to confirm, whatever the catalog says.
    var confirmRows: Set<String> = ["system.lock"]
    init(snapshot: CompanionSnapshot) { self.snapshot = snapshot }
    func markConfirm(_ id: String) { confirmRows.insert(id) }
    func connect() async throws {}
    func disconnect() async {}
    func fetchState() async throws -> HostStateDTO { snapshot.state }
    func fetchSnapshot() async throws -> CompanionSnapshot { snapshot }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter],
                targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse {
        try await invoke(entryID: entryID, catalogRevision: catalogRevision, parameters: parameters,
                         targetToken: targetToken, stateRevision: stateRevision, confirmToken: nil)
    }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter],
                targetToken: String?, stateRevision: Int?, confirmToken: String?) async throws -> CompanionActionResponse {
        calls.append((entryID, confirmToken))
        if confirmRows.contains(entryID), confirmToken != ConfirmFixtures.token {
            throw HostConfirmationRequired(token: ConfirmFixtures.token, expiresIn: 30)
        }
        let json = #"{"status":"accepted","request_id":"r","entry_id":"ID","catalog_revision":"catalog-confirm-v1","route":{"route":"host","supported":true,"entry_id":"ID"}}"#
            .replacingOccurrences(of: "ID", with: entryID)
        return try JSONDecoder().decode(CompanionActionResponse.self, from: Data(json.utf8))
    }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse {
        throw CompanionHostError.notConnected
    }
    func invokeWorkspaceLayout(_ request: WorkspaceLayoutRequest) async throws -> CompanionActionResponse {
        throw CompanionHostError.notConnected
    }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}

@MainActor final class STORE6ConfirmTokenTests: XCTestCase {
    private func store(_ host: ConfirmingHost) throws -> HomeStore {
        let defaults = UserDefaults(suiteName: "store6-\(UUID().uuidString)")!
        var profile = HostProfile(); profile.mock = false; profile.companionURL = "https://fixture.invalid:8443"
        defaults.set(try JSONEncoder().encode(profile), forKey: "omodachi.profile.v1")
        return HomeStore(defaults: defaults, credentials: FixtureCredential(),
                         clientFactory: { _, _ in host }, autoConnect: false)
    }

    /// The person tapped twice (ConfirmGate); the host asks once more; the app
    /// answers with the token at once. Two calls, the second carrying it, and
    /// the row runs - not the four taps RELEASE-9B measured.
    func testASecondTapIsResentWithTheHostsToken() async throws {
        let host = try ConfirmingHost(snapshot: ConfirmFixtures.snapshot())
        let store = try store(host)
        await store.connectCompanion()
        let lock = try XCTUnwrap(store.flattened.first { $0.id == "system.lock" })
        XCTAssertTrue(lock.confirm)
        XCTAssertFalse(store.passesConfirm(lock), "the first tap arms the row")
        XCTAssertTrue(store.passesConfirm(lock), "the second tap sends it")
        await store.invoke(lock)
        let calls = await host.calls
        XCTAssertEqual(calls.map(\.entryID), ["system.lock", "system.lock"])
        XCTAssertNil(calls[0].token)
        XCTAssertEqual(calls[1].token, ConfirmFixtures.token)
        XCTAssertNil(store.rowFailures["system.lock"], "the row ran; nothing to explain")
        await store.disconnectCompanion()
    }

    /// A row the catalog did not mark `confirm` is never confirmed on the
    /// person's behalf: it is armed, and only their next tap carries the token.
    func testARowTheCatalogDidNotMarkIsArmedNotConfirmed() async throws {
        let host = try ConfirmingHost(snapshot: ConfirmFixtures.snapshot())
        await host.markConfirm("system.screensaver")
        let store = try store(host)
        await store.connectCompanion()
        let row = try XCTUnwrap(store.flattened.first { $0.id == "system.screensaver" })
        XCTAssertFalse(row.confirm)
        await store.invoke(row)
        var calls = await host.calls
        XCTAssertEqual(calls.count, 1, "no automatic resend for a row the person was never asked about")
        XCTAssertEqual(store.armedConfirm?.entryID, "system.screensaver", "the row now asks for its second tap")
        XCTAssertNil(store.rowFailures["system.screensaver"])
        XCTAssertTrue(store.passesConfirm(row))
        await store.invoke(row)
        calls = await host.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].token, ConfirmFixtures.token)
        await store.disconnectCompanion()
    }

    /// Core's 409 body, read the way the client reads it: only a token of
    /// core's own shape counts.
    func testTheConfirmationBodyIsReadStrictly() {
        let body = #"{"contract_revision":"omodachi.v1","error":{"code":"confirmation_required","message":"m","detail":{"confirm_token":"TOKEN","expires_in":30}}}"#
        let good = CompanionHostClient.confirmation(Data(body.replacingOccurrences(of: "TOKEN", with: ConfirmFixtures.token).utf8))
        XCTAssertEqual(good, HostConfirmationRequired(token: ConfirmFixtures.token, expiresIn: 30))
        for bad in ["short", String(repeating: "a", count: 44), String(repeating: "a", count: 42) + "/"] {
            XCTAssertNil(CompanionHostClient.confirmation(Data(body.replacingOccurrences(of: "TOKEN", with: bad).utf8)), bad)
        }
        XCTAssertNil(CompanionHostClient.confirmation(Data(#"{"error":{"code":"confirmation_required"}}"#.utf8)))
    }
}

final class STORE6SmallFixesTests: XCTestCase {
    /// REMOTE-STOP-1 §3: the person at the computer ended it. A sentence of its
    /// own, in both languages, not the unmapped-code fallback.
    func testEndedOnComputerIsASentence() {
        let text = ReasonText.message("ended_on_computer", domain: .remote)
        XCTAssertEqual(text, Strings.reasonEndedOnComputer)
        XCTAssertFalse(text.contains("ended_on_computer"))
        XCTAssertEqual(ReasonText.knownCodes["ended_on_computer"], .remote)
    }

    /// The SSH header names the computer it paired with, not the address the
    /// session dials; anything unusable as a label falls back to the address.
    func testTheSSHHeaderNamesThePairedComputer() {
        var profile = HostProfile()
        profile.hostname = "192.168.1.20"; profile.username = "alex"; profile.mock = false
        var descriptor = SurfaceRouteTargets.shell(host: profile, title: "t", argv: [])
        XCTAssertEqual(descriptor.headerLabel, "alex@192.168.1.20")
        descriptor.hostDisplayName = "desktop"
        XCTAssertEqual(descriptor.headerLabel, "alex@desktop")
        XCTAssertEqual(descriptor.endpointLabel, "alex@192.168.1.20", "where it dials is unchanged")
        for unusable in ["", "  ", "bad\nname", "a@b", String(repeating: "x", count: 300)] {
            descriptor.hostDisplayName = unusable
            XCTAssertEqual(descriptor.headerLabel, "alex@192.168.1.20", unusable)
        }
        // A descriptor stored before the field existed still decodes.
        let old = #"{"id":"0D3E0D3E-0D3E-4D3E-8D3E-0D3E0D3E0D3F","title":"t","kind":"shell","argv":[],"createdAt":0,"host":{"id":"0D3E0D3E-0D3E-4D3E-8D3E-0D3E0D3E0D3E","hostname":"10.0.0.2","port":22,"username":"alex","mock":false,"herdrSession":"","companionURL":""}}"#
        let decoded = try? JSONDecoder().decode(SessionDescriptor.self, from: Data(old.utf8))
        XCTAssertEqual(decoded?.headerLabel, "alex@10.0.0.2")
    }

    /// §B4: nothing in this build can ask for the microphone, and it carries no
    /// sentence for a prompt it never shows.
    func testNoMicrophonePurposeString() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription"))
    }
}
