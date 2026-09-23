import XCTest
@testable import Omodachi

private actor ShortcutFixtureTransport: ShortcutPanelTransport {
    var snapshot: ShortcutSnapshot
    private(set) var listCalls = 0
    private(set) var requests: [ShortcutExecutionRequest] = []
    init(_ snapshot: ShortcutSnapshot) { self.snapshot = snapshot }
    func list(context: ShortcutContext) async throws -> ShortcutSnapshot { listCalls += 1; return snapshot }
    func execute(_ request: ShortcutExecutionRequest) async throws -> ShortcutExecutionResult {
        requests.append(request)
        return .init(status: .applied, message: "Fixture only: applied")
    }
    func unavailable() { snapshot.available = false; snapshot.unavailableReason = "Fixture provider unavailable" }
}

/// Shortcut official DTO, opaque execution, GUI de-duplication, fixed-sidebar
/// state, nonRemote/Remote scopes, Herdr exclusion and unavailable provider.
@MainActor
final class ShortcutPanelStoreTests: XCTestCase {
    func testShortcutPanelContractAndScopes() async throws {
        let json = #"{"contract_revision":"omodachi.v1","revision":"catalog-real-ref","source":"hyprland","available":true,"reason":null,"items":[{"id":"ws","label":"Workspace 2","shortcut_display":"SUPER + 2","order":10,"enabled":true,"disabled_reason":null,"action_ref":"shortcut.opaque.ws","requires_target":false},{"id":"full","label":"Full screen","shortcut_display":"SUPER + F","order":2,"enabled":true,"disabled_reason":null,"action_ref":"shortcut.opaque.full","requires_target":true},{"id":"unsupported","label":"Custom action","shortcut_display":"SUPER + Z","order":20,"enabled":false,"disabled_reason":"Unsupported host binding","action_ref":null,"requires_target":false}]}"#
        let snapshot = try JSONDecoder().decode(ShortcutListDTO.self, from: Data(json.utf8)).snapshot()
        let transport = ShortcutFixtureTransport(snapshot)
        let context = ShortcutContext(hostID: "fixture-host", surface: .controller, stateRevision: 4, targetToken: "actual-window-ref")
        let coverage = ShortcutGUICoverage(reachableActionRefs: ["shortcut.opaque.ws"])
        let store = ShortcutPanelStore(context: context, transport: transport, coverage: coverage)
        await store.refresh()
        XCTAssertEqual(store.model.visibleEntries(in: context).map(\.id), ["full", "unsupported"],
                       "hide only actual reachable GUI equivalent, retain official relative order")
        let full = snapshot.entries[1]
        store.model.query = "super + f"
        store.model.scrollEntryID = "full"
        XCTAssertEqual(store.model.visibleEntries(in: context).map(\.id), ["full"], "search includes actual binding text")
        await store.execute(full)
        XCTAssertEqual(store.model.query, "super + f", "fixed sidebar preserves query and scroll")
        XCTAssertEqual(store.model.scrollEntryID, "full", "fixed sidebar preserves query and scroll")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].actionRef, "shortcut.opaque.full", "execute opaque host action not display label")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ShortcutInvokeBody(requests[0]))) as? [String: Any])
        XCTAssertEqual(body["catalog_revision"] as? String, "catalog-real-ref")
        let wireContext = try XCTUnwrap(body["execution_context"] as? [String: Any])
        XCTAssertEqual(wireContext["surface"] as? String, "omarchy", "controller does not require/start streaming")
        XCTAssertNil(wireContext["session_id"], "controller does not require/start streaming")
        XCTAssertEqual(body["target_token"] as? String, "actual-window-ref")
        XCTAssertEqual(store.model.notice, "Fixture only: applied")
        store.model.query = ""
        XCTAssertEqual(store.model.disabledReason(for: snapshot.entries[2], context: context), "Unsupported host binding")
        // ARCH-1 §7 (1): a missing focused window no longer greys the row. The
        // host is what knows, and it answers `no_focused_window` when it does
        // not have one — a line on the row, not a control the user cannot press.
        var missingTarget = context; missingTarget.targetToken = nil
        XCTAssertNil(store.model.disabledReason(for: full, context: missingTarget))
        var heartbeat = context; heartbeat.stateRevision = 5
        XCTAssertTrue(context.sameScope(as: heartbeat), "unrelated state refresh does not invalidate list")
        let remote = ShortcutContext(hostID: "fixture-host", surface: .remote, remoteSessionID: "lease-1",
                                     sessionRevision: 6, connectionGeneration: 3, geometryEpoch: 7,
                                     stateRevision: 5, targetToken: "target")
        let request = ShortcutExecutionRequest(requestID: UUID(), entryID: full.id, actionRef: full.actionRef!, revision: snapshot.revision, context: remote)
        let remoteBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ShortcutInvokeBody(request))) as? [String: Any])
        // UX-1 item B: core validates `{surface, session_id, revision}` and
        // refuses any other key set, so that is what goes on the wire.
        let remoteContext = try XCTUnwrap(remoteBody["execution_context"] as? [String: Any])
        XCTAssertEqual(Set(remoteContext.keys), ["surface", "session_id", "revision"])
        XCTAssertEqual(remoteContext["revision"] as? Int, 6)
        // ARCH-1 §7 (1): "Remote is updating" was another client-side greying
        // rule, and it is gone too. The row travels and the host answers; a
        // binding that cannot run right now says so in its own words.
        var changing = remote; changing.inputReady = false
        XCTAssertNil(store.model.disabledReason(for: full, context: changing))
        let herdr = ShortcutContext(hostID: "fixture-host", surface: .herdr)
        store.updateContext(herdr, coverage: coverage)
        await store.refresh()
        XCTAssertTrue(store.model.visibleEntries(in: herdr).isEmpty)
        let afterHerdr = await transport.listCalls
        XCTAssertEqual(afterHerdr, 1, "Herdr must not load global Omarchy shortcuts")
        store.updateContext(context, coverage: .init())
        XCTAssertTrue(store.model.visibleEntries(in: context).contains { $0.id == "ws" },
                      "no real GUI coverage means unique action remains available")
        await transport.unavailable()
        await store.refresh()
        XCTAssertTrue(store.model.failed, "provider failure is not empty success")
        XCTAssertEqual(store.model.notice, "Fixture provider unavailable", "provider failure is not empty success")
        XCTAssertNotNil(store.model.disabledReason(for: full, context: context))
    }
}
