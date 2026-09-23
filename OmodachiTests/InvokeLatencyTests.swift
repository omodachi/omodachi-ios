import Foundation
import XCTest
@testable import Omodachi

/// PERF-5. What a tap does before the host has answered, and what it does with
/// the answer.
///
/// The host side of PERF-5 is that `catalog_revision` stopped being a gate:
/// core resolves the row by id and reports which revision it actually ran
/// against. These are the three consequences on this side - the row says it is
/// on its way without waiting for anything, the receipt's revision is adopted,
/// and a refusal leaves one readable line on the row that the state re-read
/// following it does not wipe.

/// A deterministic host with one runnable row. Kept here rather than shared
/// with `CompanionClientTests` so a change to that suite's fixtures cannot
/// quietly change what these assertions mean.
private enum Perf5Fixtures {
    static let catalog = #"{"contract_revision":"omodachi.v1","revision":"catalog-fixture-v1","entries":[{"id":"root","label":"Go","parent_id":"","visible":true,"route":{"route":"host","supported":false}},{"id":"trigger","label":"Trigger","parent_id":"root","visible":true,"route":{"route":"host","supported":false}},{"id":"trigger.toggle.notifications","label":"Notifications","parent_id":"trigger","visible":true,"checked_state":false,"route":{"route":"host","supported":true,"ready":true,"entry_id":"trigger.toggle.notifications"}},{"id":"omodachi.herdr","label":"Herdr","parent_id":"root","visible":true,"route":{"route":"terminal","supported":true,"ready":true,"entry_id":"omodachi.herdr","argv":["herdr"]}}]}"#
    static var state: String {
        #"{"contract_revision":"omodachi.v1","revision":18,"instance_id":"instance-fixture","event_cursor":12,"host":{"name":"fixture-host","connected":true},"workspace":{"active":2},"catalog":CATALOG}"#
            .replacingOccurrences(of: "CATALOG", with: catalog)
    }
    static let capabilities = #"{"terminal":true,"desktop":false,"sunshine":false,"native":[]}"#
    static let herdr = #"{"available":false,"agent_count":0}"#
    static func decode<T: Decodable>(_ text: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    static func snapshot() throws -> CompanionSnapshot {
        try .init(state: decode(state), capabilities: decode(capabilities), catalog: decode(catalog), herdr: decode(herdr))
    }
}

private actor InvokeFixture: CompanionServing {
    struct Call: Sendable { let entryID: String; let catalogRevision: String }
    var calls: [Call] = []
    var stateReads = 0
    var snapshot: CompanionSnapshot
    var responseJSON = #"{"status":"accepted","request_id":"fixture","entry_id":"trigger.toggle.notifications","catalog_revision":"catalog-fixture-v2","route":{"route":"host","supported":true,"entry_id":"trigger.toggle.notifications"}}"#
    var gate: CheckedContinuation<Void, Never>?
    var held = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(snapshot: CompanionSnapshot) { self.snapshot = snapshot }
    func connect() async throws {}
    func disconnect() async {}
    func fetchState() async throws -> HostStateDTO { stateReads += 1; return snapshot.state }
    func fetchSnapshot() async throws -> CompanionSnapshot { snapshot }
    func respond(_ json: String) { responseJSON = json }
    func hold() { held = true }
    /// Resumes a call that is parked inside `invoke`, after waiting for it to
    /// get there - so the assertion about the in-flight row is not a race.
    func release() async {
        if gate == nil { await withCheckedContinuation { waiting = $0 } }
        held = false
        gate?.resume(); gate = nil
    }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter],
                targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse {
        calls.append(Call(entryID: entryID, catalogRevision: catalogRevision))
        if held {
            await withCheckedContinuation { continuation in
                gate = continuation
                waiting?.resume(); waiting = nil
            }
        }
        return try JSONDecoder().decode(CompanionActionResponse.self, from: Data(responseJSON.utf8))
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

@MainActor final class InvokeLatencyTests: XCTestCase {
    private func store(_ fake: InvokeFixture) throws -> HomeStore {
        let name = "perf5-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        var profile = HostProfile(); profile.mock = false; profile.companionURL = "https://fixture.invalid:8443"
        defaults.set(try JSONEncoder().encode(profile), forKey: "omodachi.profile.v1")
        return HomeStore(defaults: defaults, credentials: FixtureCredential(),
                         clientFactory: { _, _ in fake }, autoConnect: false)
    }

    private func item(_ store: HomeStore) throws -> MenuItem {
        try XCTUnwrap(store.flattened.first { $0.id == "trigger.toggle.notifications" })
    }

    func testTheRowSaysItIsOnItsWayBeforeTheHostHasAnswered() async throws {
        let fake = try InvokeFixture(snapshot: Perf5Fixtures.snapshot())
        let store = try store(fake)
        await store.connectCompanion()
        let row = try item(store)
        await fake.hold()
        let tap = Task { await store.invoke(row) }
        await fake.release()
        // The row was marked before the request was built, so it is already
        // pending by the time the fixture is inside `invoke`.
        XCTAssertTrue(store.pendingEntryIDs.contains(row.id))
        await tap.value
        XCTAssertFalse(store.pendingEntryIDs.contains(row.id), "The pending mark must come off on the answer")
        await store.disconnectCompanion()
    }

    func testTheTapGoesOutWithTheRevisionAlreadyInHand() async throws {
        let fake = try InvokeFixture(snapshot: Perf5Fixtures.snapshot())
        let store = try store(fake)
        await store.connectCompanion()
        XCTAssertEqual(store.catalogRevision, "catalog-fixture-v1")
        let readsBefore = await fake.stateReads
        await store.invoke(try item(store))
        let calls = await fake.calls
        XCTAssertEqual(calls.map(\.catalogRevision), ["catalog-fixture-v1"],
                       "The tap goes out with the revision already in hand, not one fetched for it")
        let readsAfter = await fake.stateReads
        XCTAssertEqual(readsBefore, readsAfter - 1,
                       "Exactly one state read, and it is the one *after* the answer")
        await store.disconnectCompanion()
    }

    func testTheReceiptsOwnRevisionIsAdopted() async throws {
        let fake = try InvokeFixture(snapshot: Perf5Fixtures.snapshot())
        let store = try store(fake)
        await store.connectCompanion()
        XCTAssertEqual(store.catalogRevision, "catalog-fixture-v1")
        // A prepared surface never re-reads the state, so what the store ends
        // up holding is the receipt's revision and nothing else.
        await fake.respond(#"{"status":"prepared","request_id":"fixture","entry_id":"omodachi.herdr","catalog_revision":"catalog-fixture-v2","route":{"route":"terminal","supported":true,"ready":true,"entry_id":"omodachi.herdr","argv":["herdr"]}}"#)
        let herdr = try XCTUnwrap(store.flattened.first { $0.id == "omodachi.herdr" })
        _ = await store.prepareAction(herdr)
        XCTAssertEqual(store.catalogRevision, "catalog-fixture-v2",
                       "The host said which revision it resolved against; the next tap uses that one")
        await store.disconnectCompanion()
    }

    func testARefusedRowKeepsOneLineOfItsOwnThroughTheStateRead() async throws {
        let fake = try InvokeFixture(snapshot: Perf5Fixtures.snapshot())
        let store = try store(fake)
        await store.connectCompanion()
        await fake.respond(#"{"status":"failed","request_id":"fixture","entry_id":"trigger.toggle.notifications","code":"no_focused_window","catalog_revision":"catalog-fixture-v1","route":{"route":"host","supported":true,"entry_id":"trigger.toggle.notifications"}}"#)
        let row = try item(store)
        await store.invoke(row)
        // `prepareAction` re-reads the state after a refusal. That read used to
        // be the only thing on screen afterwards.
        let reads = await fake.stateReads
        XCTAssertGreaterThan(reads, 0)
        XCTAssertEqual(store.rowFailures[row.id], Strings.menuFailedNoFocus)
        await fake.respond(#"{"status":"accepted","request_id":"fixture","entry_id":"trigger.toggle.notifications","catalog_revision":"catalog-fixture-v1","route":{"route":"host","supported":true,"entry_id":"trigger.toggle.notifications"}}"#)
        await store.invoke(row)
        XCTAssertNil(store.rowFailures[row.id], "Tapping the row again clears the last reason")
        await store.disconnectCompanion()
    }

    func testAnUnknownRefusalKeepsTheHostsOwnWordRatherThanInventingOne() {
        XCTAssertEqual(HomeStore.rowFailure(code: "stale_target"), Strings.menuFailedStale)
        XCTAssertEqual(HomeStore.rowFailure(code: "stale_binding"), Strings.menuFailedStale)
        XCTAssertEqual(HomeStore.rowFailure(code: "workspace_dispatch_failed"), "workspace_dispatch_failed")
        XCTAssertEqual(HomeStore.rowFailure(code: nil), Strings.menuFailedRefused)
        XCTAssertEqual(HomeStore.rowFailure(error: CompanionHostError.notConnected), Strings.menuFailedUnreachable)
    }

    func testTheResolvedRevisionIsOptionalAndBounded() throws {
        let decoder = JSONDecoder()
        let absent = try decoder.decode(CompanionActionResponse.self, from: Data(#"{"status":"accepted"}"#.utf8))
        XCTAssertNil(absent.catalogRevision)
        let long = String(repeating: "a", count: 129)
        let oversize = try decoder.decode(CompanionActionResponse.self,
                                          from: Data(#"{"status":"accepted","catalog_revision":"\#(long)"}"#.utf8))
        XCTAssertNil(oversize.catalogRevision, "An unbounded revision is not adopted")
        let empty = try decoder.decode(CompanionActionResponse.self,
                                       from: Data(#"{"status":"accepted","catalog_revision":""}"#.utf8))
        XCTAssertNil(empty.catalogRevision)
    }
}
