import Foundation
import XCTest
@testable import Omodachi

// These deterministic responses preserve the omodachi.v1.2026-09-16.1 wire
// shape. No test talks to a production host or loads a real credential.
private enum CompanionFixtures {
    static let catalog = #"{"contract_revision":"omodachi.v1.2026-09-16.1","revision":"catalog-fixture-v1","entries":[{"id":"root","label":"Go","parent_id":"","visible":true,"route":{"route":"host","supported":false}},{"id":"trigger","label":"Trigger","parent_id":"root","visible":true,"route":{"route":"host","supported":false}},{"id":"trigger.toggle.notifications","label":"Notifications","parent_id":"trigger.toggle","visible":true,"checked_state":false,"checked":"host expression","route":{"route":"host","supported":true,"ready":true,"entry_id":"trigger.toggle.notifications"}},{"id":"omodachi.agent","label":"Agent","parent_id":"root","visible":true,"route":{"route":"terminal","supported":true,"ready":true,"entry_id":"omodachi.agent"}},{"id":"omodachi.herdr","label":"Herdr","parent_id":"root","visible":true,"route":{"route":"terminal","supported":true,"ready":true,"entry_id":"omodachi.herdr","argv":["herdr"]}},{"id":"omodachi.desktop","label":"Desktop","parent_id":"root","visible":true,"route":{"route":"desktop","supported":true,"ready":false,"entry_id":"omodachi.desktop"}}]}"#
    static let defaultAgent = #"{"omarchy_default_agent":"codex","configured_kind":"codex","actual_kind":"codex","kind_mismatch":false,"kind_supported":true,"default_agent_exists":true,"default_agent_probe":"available","pane_available":true,"pane_id":"pane-fixture-01","agent_status":"idle","ready_to_attach":true,"herdr_available":true}"#
    static var state: String {
        #"{"contract_revision":"omodachi.v1.2026-09-16.1","revision":18,"instance_id":"instance-fixture","event_cursor":12,"host":{"name":"fixture-host","connected":true},"workspace":{"active":2},"focus":{"window":"PRIVATE TITLE"},"agent":{"status":"idle","default_agent":DEFAULT},"herdr":{"available":true,"agent_count":1},"catalog":CATALOG}"#
            .replacingOccurrences(of: "DEFAULT", with: defaultAgent).replacingOccurrences(of: "CATALOG", with: catalog)
    }
    static let capabilities = #"{"terminal":true,"desktop":false,"sunshine":false,"native":[]}"#
    static let herdr = #"{"available":true,"agent_count":1,"snapshot":{"server_installed":true,"server_running":true,"socket_available":true,"agents":[{"agent_id":"default","kind":"codex","status":"idle","pane_id":"pane-fixture-01","pane_available":true}],"supported_kinds":["codex"],"pane_count":1}}"#
    static func decode<T: Decodable>(_ text: String, as type: T.Type = T.self) throws -> T { try JSONDecoder().decode(type, from: Data(text.utf8)) }
    static func snapshot() throws -> CompanionSnapshot { try .init(state: decode(state), capabilities: decode(capabilities), catalog: decode(catalog), herdr: decode(herdr)) }
    static func barSnapshot(targetToken: String? = "focus-fixture-18", layoutAvailable: Bool = true) throws -> CompanionSnapshot {
        var stateObject = try JSONSerialization.jsonObject(with: Data(state.utf8)) as! [String: Any]
        var catalogObject = try JSONSerialization.jsonObject(with: Data(catalog.utf8)) as! [String: Any]
        var entries = catalogObject["entries"] as! [[String: Any]]
        for number in [2, 3] {
            for operation in ["select", "move"] {
                let id = "omodachi.workspace.\(operation).\(number)"
                entries.append(["id": id, "label": operation == "select" ? "Workspace \(number)" : "Move focused window to \(number)",
                                "aliases": [String(number)], "parent_id": "root", "visible": true,
                                "route": ["route": "host", "supported": true, "ready": true, "entry_id": id]])
            }
        }
        catalogObject["entries"] = entries
        stateObject["catalog"] = catalogObject
        stateObject["bar"] = ["source": "shell.json", "source_status": layoutAvailable ? "fixture" : "unavailable", "revision": "1234567890abcdef",
                              "left": layoutAvailable ? [["id": "logo", "role": "logo"], ["id": "ws", "role": "workspaces"]] : [],
                              "center": layoutAvailable ? [["id": "focused", "role": "focused_window"], ["id": "custom", "role": "future_role"]] : [],
                              "right": layoutAvailable ? [["id": "time", "role": "clock"], ["id": "tray", "role": "system_tray"]] : []]
        stateObject["workspace"] = ["active": 2, "items": [
            ["id": 2, "label": "Workspace 2", "active": true, "occupied": true, "window_count": 2, "select_entry_id": "omodachi.workspace.select.2", "move_entry_id": "omodachi.workspace.move.2"],
            ["id": 3, "label": "Workspace 3", "active": false, "occupied": NSNull(), "window_count": NSNull(), "select_entry_id": "omodachi.workspace.select.3", "move_entry_id": "omodachi.workspace.move.3"]]]
        stateObject["focus"] = ["window": "PRIVATE WINDOW TITLE", "app_id": "org.example.Terminal", "app_name": "Fixture Terminal", "target_token": targetToken as Any? ?? NSNull()]
        let decoder = JSONDecoder()
        return try CompanionSnapshot(state: decoder.decode(HostStateDTO.self, from: JSONSerialization.data(withJSONObject: stateObject)),
                                     capabilities: decode(capabilities),
                                     catalog: decoder.decode(HostCatalogDTO.self, from: JSONSerialization.data(withJSONObject: catalogObject)), herdr: decode(herdr))
    }
}

final class FixtureCredential: CompanionCredentialProviding {
    let token: String?
    init(_ token: String? = "fixture-token") { self.token = token }
    func loadToken(account: String) throws -> String? { token }
}

final class HTTPFixtureStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Int, String)] = [:]
    private var capturedRequests: [URLRequest] = []
    func reset() { lock.lock(); defer { lock.unlock() }; responses = [:]; capturedRequests = [] }
    func set(_ path: String, status: Int = 200, body: String) { lock.lock(); defer { lock.unlock() }; responses[path] = (status, body) }
    func receive(_ request: URLRequest) -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        capturedRequests.append(request)
        return responses[request.url?.path ?? ""] ?? (404, #"{"error":{"code":"route_unavailable","message":"not registered"}}"#)
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return capturedRequests }
}

/// Shared with `HerdrSessionTests`: one stub host for every client test.
final class CompanionURLProtocol: URLProtocol, @unchecked Sendable {
    static let storage = HTTPFixtureStorage()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.storage.receive(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor FixtureCompanion: CompanionServing {
    struct Invocation: Sendable {
        let entryID: String
        let catalogRevision: String
        let parameters: [String: CompanionParameter]
        let targetToken: String?
        let stateRevision: Int?
    }
    var invocations: [Invocation] = []
    var workspaceSelections: [Int] = []
    var invocationError: CompanionHostError?
    var snapshot: CompanionSnapshot
    var taskRequests: [String] = []
    var legacyAgentRoute = false
    var stateReads = 0
    var continuation: AsyncThrowingStream<SanitizedHostEvent, Error>.Continuation?
    init(snapshot: CompanionSnapshot) { self.snapshot = snapshot }
    func connect() async throws {}
    func disconnect() async { continuation?.finish(); continuation = nil }
    func fetchState() async throws -> HostStateDTO { stateReads += 1; return snapshot.state }
    func fetchSnapshot() async throws -> CompanionSnapshot { snapshot }
    func selectWorkspace(_ id: Int) async throws {
        workspaceSelections.append(id)
        if let invocationError { throw invocationError }
    }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter], targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse {
        invocations.append(Invocation(entryID: entryID, catalogRevision: catalogRevision, parameters: parameters, targetToken: targetToken, stateRevision: stateRevision))
        if let invocationError { throw invocationError }
        if entryID.hasPrefix("omodachi.workspace.") {
            return try CompanionFixtures.decode(#"{"status":"accepted"}"#)
        }
        if entryID == "omodachi.agent" {
            if legacyAgentRoute {
                return try CompanionFixtures.decode(#"{"status":"prepared","route":{"route":"terminal","supported":true,"ready":true,"entry_id":"omodachi.agent","argv":["herdr","agent","attach","default"]}}"#)
            }
            return try CompanionFixtures.decode(#"{"status":"prepared","route":{"route":"terminal","supported":true,"ready":true,"entry_id":"omodachi.agent","argv":["herdr","--session","omodachi","agent","attach","default"]}}"#)
        }
        return try CompanionFixtures.decode(#"{"status":"prepared","route":{"route":"terminal","supported":true,"ready":true,"entry_id":"omodachi.herdr","argv":["herdr"]}}"#)
    }
    func failInvocation(_ error: CompanionHostError) { invocationError = error }
    func useLegacyAgentRoute() { legacyAgentRoute = true }
    func taskRequestSnapshot() -> [String] { taskRequests }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse {
        taskRequests.append(text)
        return try CompanionFixtures.decode(#"{"status":"accepted","agent_id":"default","pane_id":"pane-fixture-01"}"#)
    }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> { AsyncThrowingStream { continuation = $0 } }
    func sendEvent(_ event: SanitizedHostEvent) { continuation?.yield(event) }
    func updateState(_ text: String) throws { snapshot = CompanionSnapshot(state: try CompanionFixtures.decode(text), capabilities: snapshot.capabilities, catalog: snapshot.catalog, herdr: snapshot.herdr) }
}

@MainActor final class CompanionClientTests: XCTestCase {
    private func client() throws -> CompanionHostClient {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        return CompanionHostClient(configuration: try CompanionHostConfiguration(endpoint: URL(string: "https://fixture.invalid:8443")!), credentials: FixtureCredential(), pinnedFingerprint: nil, session: URLSession(configuration: options))
    }

    func testWorkspaceSelectionUsesTheOneHostEndpoint() async throws {
        let client = try client()
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/workspaces/27/select", body: #"{"workspace":{"active":27}}"#)
        try await client.selectWorkspace(27)
        let request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/workspaces/27/select")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String], [:])
    }

    /// With a Remote session open the host refuses this outright, so a Panel tap
    /// cannot move the screen out from under the stream.
    func testASessionOwnedHostRefusesLocalWorkspaceSelection() async throws {
        let client = try client()
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/workspaces/3/select", status: 409,
                                         body: #"{"error":{"code":"remote_session_required","message":"remote_session_required"}}"#)
        do {
            try await client.selectWorkspace(3)
            XCTFail("a session-owned host must refuse")
        } catch let error as CompanionHostError {
            guard case let .blocked(code, message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "remote_session_required")
            XCTAssertTrue(message.contains("Remote"))
        }
        await client.disconnect()
    }

    func testInvalidWorkspaceIdentifiersNeverReachTheHost() async throws {
        let client = try client()
        try await client.connect()
        for value in [0, -1, 2147483648] {
            do { try await client.selectWorkspace(value); XCTFail("Invalid ID must fail") } catch {}
        }
        XCTAssertTrue(CompanionURLProtocol.storage.requests.isEmpty)
    }

    func testEndpointAndAuthorizationRequireExplicitConfiguration() async throws {
        for url in ["http://fixture.invalid", "https://user:secret@fixture.invalid", "https://fixture.invalid/path", "https://fixture.invalid?token=bad", "https://fixture.invalid#fragment", "https://fixture.invalid:0"] {
            XCTAssertThrowsError(try CompanionHostConfiguration(endpoint: URL(string: url)!))
        }
        let client = try client()
        XCTAssertTrue(CompanionURLProtocol.storage.requests.isEmpty)
        do { _ = try await client.fetchState(); XCTFail("Request before authorization") } catch { XCTAssertEqual(error as? CompanionHostError, .notConnected) }
        try await client.connect()
        XCTAssertTrue(CompanionURLProtocol.storage.requests.isEmpty)
        await client.disconnect()
    }

    func testSnapshotUsesCurrentCoreResourceShapesAndNoDesktopEndpoints() async throws {
        let client = try client()
        CompanionURLProtocol.storage.set("/v1/state", body: CompanionFixtures.state)
        CompanionURLProtocol.storage.set("/v1/capabilities", body: CompanionFixtures.capabilities)
        CompanionURLProtocol.storage.set("/v1/catalog", body: CompanionFixtures.catalog)
        CompanionURLProtocol.storage.set("/v1/herdr", body: CompanionFixtures.herdr)
        try await client.connect()
        let snapshot = try await client.fetchSnapshot()
        XCTAssertEqual(snapshot.state.revision, 18)
        XCTAssertEqual(snapshot.state.agent?.defaultAgent?.configuredKind, "codex")
        XCTAssertEqual(snapshot.catalog.revision, "catalog-fixture-v1")
        XCTAssertEqual(snapshot.herdr.agents.first?.agentID, "default")
        XCTAssertEqual(Set(CompanionURLProtocol.storage.requests.compactMap { $0.url?.path }), ["/v1/state", "/v1/capabilities", "/v1/catalog", "/v1/herdr"])
        for request in CompanionURLProtocol.storage.requests {
            XCTAssertEqual(request.url?.host, "fixture.invalid")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        }
        XCTAssertNil(snapshot.state.focus?.appID)
        XCTAssertNil(snapshot.state.focus?.targetToken)
        if let focus = snapshot.state.focus {
            let names = Mirror(reflecting: focus).children.compactMap(\.label)
            XCTAssertFalse(names.contains("window"))
        }
        await client.disconnect()
    }

    func testPromptIsOneJSONDataValueAndAcceptanceIsNotCompletion() async throws {
        let client = try client()
        CompanionURLProtocol.storage.set("/v1/agent/tasks", body: #"{"status":"accepted","agent_id":"default","message":"PRIVATE CONTENT"}"#)
        try await client.connect()
        let text = "修复中文 \"quoted\"\n$(touch never); `echo never`"
        let response = try await client.submitDefaultAgentTask(text, requestID: "fixture-request")
        let request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        let body = try requestBody(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, text)
        XCTAssertEqual(json["agent_id"] as? String, "default")
        XCTAssertEqual(json["request_id"] as? String, "fixture-request")
        XCTAssertEqual(Set(json.keys), ["text", "agent_id", "request_id"])
        XCTAssertEqual(response.status, .accepted)
        XCTAssertFalse(response.message?.contains("PRIVATE") == true)
        await client.disconnect()
    }

    func testNestedCoreMismatchAndMissingAgentEndpointRejectWithoutEchoingContent() async throws {
        let client = try client()
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/agent/tasks", status: 409, body: #"{"contract_revision":"omodachi.v1.2026-09-16.1","error":{"code":"agent_kind_mismatch","message":"PRIVATE CONTENT"}}"#)
        do { _ = try await client.submitDefaultAgentTask("task"); XCTFail("Mismatch accepted") }
        catch let CompanionHostError.mismatch(code, message) { XCTAssertEqual(code, "agent_kind_mismatch"); XCTAssertFalse(message.contains("PRIVATE")) }
        CompanionURLProtocol.storage.set("/v1/agent/tasks", status: 404, body: #"{"error":{"code":"route_unavailable","message":"not registered"}}"#)
        do { _ = try await client.submitDefaultAgentTask("task"); XCTFail("Unavailable endpoint accepted") }
        catch let CompanionHostError.unavailable(code, _) { XCTAssertEqual(code, "route_unavailable") }
        await client.disconnect()
    }

    func testInvokeRetainsOpaqueCatalogRevisionAndPreparedRoute() async throws {
        let client = try client()
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/actions/omodachi.herdr:invoke", body: #"{"status":"prepared","request_id":"fixture","route":{"route":"terminal","supported":true,"entry_id":"omodachi.herdr","argv":["herdr"]}}"#)
        let result = try await client.invoke(entryID: "omodachi.herdr", catalogRevision: "ab12cd", parameters: [:], stateRevision: 18)
        XCTAssertEqual(result.status, .prepared)
        XCTAssertEqual(result.descriptor?.argv, ["herdr"])
        XCTAssertTrue(result.message?.contains("prepared") == true)
        let body = try requestBody(XCTUnwrap(CompanionURLProtocol.storage.requests.last))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["catalog_revision"] as? String, "ab12cd")
        XCTAssertEqual(json["state_revision"] as? Int, 18)
        await client.disconnect()
    }

    func testEventFramesDecodeDirectAndWrapped() throws {
        let direct = #"{"seq":20,"event_id":"evt_20","type":"catalog.changed","payload":{"revision":"old-fixture-hash"}}"#
        let wrapped = #"{"event":{"seq":25,"event_id":"evt_25","type":"state.changed","payload":{"revision":25}},"instance_id":"instance-fixture"}"#
        let first = try CompanionHostClient.decodeEvent(Data(direct.utf8))
        XCTAssertEqual(first.type, "catalog.changed")
        XCTAssertEqual(first.sequence, 20)
        XCTAssertNil(first.instanceID)
        XCTAssertFalse(first.needsResync)
        let second = try CompanionHostClient.decodeEvent(Data(wrapped.utf8))
        XCTAssertEqual(second.type, "state.changed")
        XCTAssertEqual(second.sequence, 25)
        XCTAssertEqual(second.instanceID, "instance-fixture")
        // An event with no identity at all is not decodable into something the
        // store could act on.
        XCTAssertThrowsError(try CompanionHostClient.decodeEvent(Data(#"{"seq":1,"event_id":"","type":""}"#.utf8)))
    }

    func testSnapshotReadyAndResyncFramesMatchCoreWSS() throws {
        let snapshot = "{\"type\":\"snapshot\",\"state\":\(CompanionFixtures.state),\"instance_id\":\"instance-fixture\",\"cursor\":12}"
        let decoded = try CompanionHostClient.decodeEvent(Data(snapshot.utf8))
        XCTAssertEqual(decoded.snapshot?.workspace?.active, 2)
        XCTAssertEqual(decoded.instanceID, "instance-fixture")
        let ready = try CompanionHostClient.decodeEvent(Data(#"{"type":"ready","instance_id":"instance-fixture","cursor":12}"#.utf8))
        XCTAssertEqual(ready.type, "ready")
        let resync = try CompanionHostClient.decodeEvent(Data(#"{"event":{"seq":20,"event_id":"resync_20","type":"resync.required","payload":{"cursor":20,"snapshot_required":true}},"instance_id":"instance-fixture"}"#.utf8))
        XCTAssertTrue(resync.needsResync)
    }

    func testRealProfileBeginsWithoutDemoMenuOrInventedState() throws {
        let (store, defaults) = try homeStore()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        XCTAssertTrue(store.menu.isEmpty)
        XCTAssertEqual(store.barModel, .unavailable)
        XCTAssertTrue(store.state.toggles.isEmpty)
        XCTAssertEqual(store.state.workspace, 0)
        XCTAssertEqual(store.state.agentStatus, .unknown)
        XCTAssertFalse(store.state.online)
    }

    func testHomeConnectConsumesRealStateAndPreparesTerminalRoute() async throws {
        let (store, _) = try homeStore()
        await store.connectCompanion()
        XCTAssertTrue(store.companionConnected)
        XCTAssertEqual(store.state.hostName, "fixture-host")
        XCTAssertEqual(store.barModel, .unavailable, "Older core snapshots must not invent topbar state")
        XCTAssertEqual(store.state.workspace, 2)
        XCTAssertEqual(store.state.toggles["trigger.toggle.notifications"], false)
        XCTAssertFalse(store.flattened.contains { $0.id == "apps.launcher" })
        let desktop = try XCTUnwrap(store.flattened.first { $0.id == "omodachi.desktop" })
        XCTAssertTrue(desktop.enabled, "Remote setup remains navigable while media capability is unavailable")
        let herdr = try XCTUnwrap(store.flattened.first { $0.id == "omodachi.herdr" })
        XCTAssertNil(herdr.terminalArgv)
        let prepared = await store.prepareAction(herdr)
        XCTAssertEqual(prepared?.terminalArgv, ["herdr"])
        await store.disconnectCompanion()
        XCTAssertEqual(store.state.agentStatus, .unknown)
        XCTAssertTrue(store.state.toggles.isEmpty)
    }

    func testHomeAskPreservesTextWhenDefaultBusyAndNeverSendsTask() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.snapshot())
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        try await fake.updateState(CompanionFixtures.state.replacingOccurrences(of: #""status":"idle""#, with: #""status":"working""#))
        store.askText = "keep this task"
        let submitted = await store.submitTask()
        XCTAssertFalse(submitted)
        XCTAssertEqual(store.askText, "keep this task")
        let requests = await fake.taskRequestSnapshot()
        XCTAssertTrue(requests.isEmpty)
        await store.disconnectCompanion()
    }

    func testHomeAskUsesFreshStateAndClearsTextOnlyAfterAcceptance() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.snapshot())
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        store.askText = "中文数据"
        let submitted = await store.submitTask()
        XCTAssertTrue(submitted)
        XCTAssertTrue(store.askText.isEmpty)
        let requests = await fake.taskRequestSnapshot()
        XCTAssertEqual(requests, ["中文数据"])
        XCTAssertEqual(store.preparedAgentDescriptor?.argv, ["herdr", "--session", "omodachi", "agent", "attach", "default"])
        XCTAssertEqual(store.preparedAgentDescriptor?.host.herdrSession, "omodachi")
        let reads = await fake.stateReads
        XCTAssertEqual(reads, 2)
        await store.disconnectCompanion()
    }

    func testHomeAskRejectsTaskWhenPreparedAgentTargetIsUnnamed() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.snapshot())
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        store.askText = "不发送"
        // The fixture's action response is changed to the legacy unnamed argv.
        await fake.useLegacyAgentRoute()
        let submitted = await store.submitTask()
        XCTAssertFalse(submitted)
        XCTAssertEqual(store.askText, "不发送")
        XCTAssertEqual(store.notice, Strings.agentNoAttachTarget)
        let requests = await fake.taskRequestSnapshot()
        XCTAssertTrue(requests.isEmpty)
        await store.disconnectCompanion()
    }

    func testTaskPreflightRejectsUnknownUnsetUnsupportedMismatchAndBusy() throws {
        let valid: DefaultAgentCapabilityDTO = try CompanionFixtures.decode(CompanionFixtures.defaultAgent)
        XCTAssertNil(HomeStore.taskBlockReason(valid, status: .idle))
        XCTAssertNotNil(HomeStore.taskBlockReason(nil, status: .unknown))
        XCTAssertNotNil(HomeStore.taskBlockReason(valid, status: .working))
        XCTAssertNotNil(HomeStore.taskBlockReason(valid, status: .blocked))
        for text in [CompanionFixtures.defaultAgent.replacingOccurrences(of: #""kind_supported":true"#, with: #""kind_supported":false"#), CompanionFixtures.defaultAgent.replacingOccurrences(of: #""actual_kind":"codex""#, with: #""actual_kind":"claude""#), CompanionFixtures.defaultAgent.replacingOccurrences(of: #""default_agent_exists":true"#, with: #""default_agent_exists":false"#)] {
            let value: DefaultAgentCapabilityDTO = try CompanionFixtures.decode(text)
            XCTAssertNotNil(HomeStore.taskBlockReason(value, status: .idle))
        }
    }

    func testFlatCoreBarPreservesRolesUnknownOccupancyAndSanitizedFocus() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.barSnapshot())
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        XCTAssertTrue(store.barModel.available)
        XCTAssertEqual(store.barModel.layout?.left, ["logo", "workspaces"])
        XCTAssertEqual(store.barModel.layout?.center, ["focus", "unsupported"])
        XCTAssertEqual(store.barModel.layout?.right, ["clock", "tray"])
        XCTAssertEqual(store.barModel.workspaces.map(\.id), [2, 3])
        XCTAssertEqual(store.barModel.workspaces.first?.active, true)
        XCTAssertNil(store.barModel.workspaces.last?.occupied)
        XCTAssertEqual(store.barModel.focusedApp?.name, "Fixture Terminal")
        XCTAssertFalse(store.state.focusWindow.contains("PRIVATE"))
        XCTAssertEqual(store.state.occupiedWorkspaces, [2])
        let searchRows = store.flattened.filter { $0.aliases.contains("3") }
        XCTAssertTrue(searchRows.contains { $0.id == "omodachi.workspace.select.3" && $0.label == "Workspace 3" })
        await store.disconnectCompanion()
        XCTAssertEqual(store.barModel, .unavailable)
    }

    func testWorkspaceSelectionUsesHostIDWithoutInventingCheckedState() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.barSnapshot())
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        await store.workspace(3)
        let calls = await fake.workspaceSelections
        XCTAssertEqual(calls, [3])
        let legacyCalls = await fake.invocations
        XCTAssertTrue(legacyCalls.isEmpty)
        XCTAssertEqual(store.state.workspace, 2, "Acceptance alone cannot mark workspace 3 active")
        XCTAssertEqual(store.barModel.workspaces.last?.active, false)
        await store.disconnectCompanion()
    }

    func testFocusedWindowMoveUsesSameSnapshotTokenRevisionAndDoesNotRetryStale() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.barSnapshot())
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        await fake.failInvocation(.staleTarget(message: "The focus changed."))
        await store.moveFocusedWindow(to: 3)
        let calls = await fake.invocations
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.entryID, "omodachi.workspace.move.3")
        XCTAssertEqual(calls.first?.catalogRevision, "catalog-fixture-v1")
        XCTAssertEqual(calls.first?.targetToken, "focus-fixture-18")
        XCTAssertEqual(calls.first?.stateRevision, 18)
        XCTAssertEqual(calls.first?.parameters, [:])
        XCTAssertEqual(store.notice, "The focus changed.")
        await store.disconnectCompanion()
    }

    func testMissingFocusTokenDisablesMoveButKeepsWorkspaceSelectionIndependent() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.barSnapshot(targetToken: nil))
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        XCTAssertEqual(store.barModel.workspaces.last?.canSelect, true)
        XCTAssertEqual(store.barModel.workspaces.last?.canMoveFocusedWindow, false)
        await store.moveFocusedWindow(to: 3)
        let calls = await fake.invocations
        XCTAssertTrue(calls.isEmpty)
        await store.disconnectCompanion()
    }

    func testUnavailableShellLayoutNeverInventsTopbarFromWorkspaceSnapshot() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.barSnapshot(layoutAvailable: false))
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        XCTAssertEqual(store.barModel, .unavailable)
        await store.workspace(3)
        await store.moveFocusedWindow(to: 3)
        let calls = await fake.invocations
        XCTAssertTrue(calls.isEmpty)
        await store.disconnectCompanion()
    }

    func testEventBurstCoalescesAndProfileChangeRejectsOldUpdates() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.snapshot())
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        for _ in 0..<10 { await Task.yield() }
        for index in 13...60 {
            let event = try CompanionHostClient.decodeEvent(Data("{\"seq\":\(index),\"event_id\":\"evt_\(index)\",\"type\":\"state.changed\",\"payload\":{\"revision\":19}}".utf8))
            await fake.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(1400))
        let reads = await fake.stateReads
        XCTAssertEqual(reads, 1, "A burst should trigger one GET, not a polling loop")
        store.profile.hostname = "other-host"
        XCTAssertFalse(store.companionConnected)
        XCTAssertTrue(store.menu.isEmpty)
        XCTAssertEqual(store.state.hostName, "other-host")
        XCTAssertEqual(store.state.agentStatus, .unknown)
        await store.disconnectCompanion()
    }

    func testForegroundSuspensionClosesCompanionWithoutLosingConfiguredProfile() async throws {
        let fake = try FixtureCompanion(snapshot: CompanionFixtures.snapshot())
        let (store, _) = try homeStore(fake: fake)
        await store.connectCompanion()
        let profileID = store.profile.id
        await store.setForeground(false)
        XCTAssertEqual(store.connectionState, .suspended)
        XCTAssertFalse(store.companionConnected)
        XCTAssertEqual(store.state.agentStatus, .unknown)
        await store.setForeground(true)
        XCTAssertTrue(store.companionConnected)
        XCTAssertEqual(store.profile.id, profileID)
        await store.disconnectCompanion()
    }

    func testCanonicalCoreFixtureResourcesAndBothEventPaths() throws {
        let root: URL
        if let path = ProcessInfo.processInfo.environment["OMODACHI_CORE_FIXTURES"] {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
        }
        func read(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
        let decoder = JSONDecoder()
        let state = try decoder.decode(HostStateDTO.self, from: read("state.json"))
        let catalog = try decoder.decode(HostCatalogDTO.self, from: read("catalog.json"))
        let capabilities = try decoder.decode(HostCapabilitiesDTO.self, from: read("capabilities.json"))
        let herdr = try decoder.decode(HostHerdrDTO.self, from: read("herdr-resource.json"))
        XCTAssertGreaterThan(state.revision, 0)
        XCTAssertFalse(catalog.entries.isEmpty)
        XCTAssertEqual(capabilities.desktop, false)
        XCTAssertEqual(herdr.available, true)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("bar.json").path) {
            let bar = try decoder.decode(HostBarDTO.self, from: read("bar.json"))
            let unavailable = try decoder.decode(HostBarDTO.self, from: read("bar-unavailable.json"))
            XCTAssertEqual(bar.position, "top")
            XCTAssertEqual(bar.nativeLayout?.position, .top)
            XCTAssertEqual(bar.nativeLayout?.left, ["logo", "workspaces", "focus"])
            XCTAssertEqual(bar.nativeLayout?.center, ["clock"])
            XCTAssertEqual(bar.nativeLayout?.right, ["tray", "agent", "stream"])
            XCTAssertNil(unavailable.nativeLayout)
            XCTAssertEqual(state.workspace?.items?.count, 10)
            XCTAssertEqual(state.workspace?.items?.first?.selectEntryID, "omodachi.workspace.select.1")
            XCTAssertEqual(state.workspace?.items?.first?.moveFocusedEntryID, "omodachi.workspace.move.1")
            XCTAssertEqual(state.focus?.displayName, "Editor")
            XCTAssertEqual(state.focus?.targetToken, "window-token-fixture-01")
        }
        for name in ["event-catalog-changed.json", "event-resync-required.json"] {
            let direct = try read(name)
            let object = try JSONSerialization.jsonObject(with: direct)
            let wrapped = try JSONSerialization.data(withJSONObject: ["event": object, "instance_id": "fixture-instance"])
            let first = try CompanionHostClient.decodeEvent(direct)
            let second = try CompanionHostClient.decodeEvent(wrapped)
            XCTAssertEqual(first.type, second.type)
            XCTAssertEqual(first.eventID, second.eventID)
            if name == "event-catalog-changed.json" { XCTAssertFalse(first.needsResync) }
            else { XCTAssertTrue(first.needsResync) }
        }
    }

    // MARK: - The VNC bridge socket

    /// The bridge rides the same origin, the same Bearer credential and the
    /// same pinned certificate as every other Remote call.
    func testTheVNCBridgeSocketIsTheSameAuthenticatedOrigin() async throws {
        let client = try client()
        try await client.connect()
        let task = try await client.makeVNCSocket(path: "/v1/remote/sessions/rs_0123456789abcdef0123456789abcdef/vnc")
        let request = try XCTUnwrap(task.originalRequest)
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "fixture.invalid")
        XCTAssertEqual(request.url?.port, 8443)
        XCTAssertEqual(request.url?.path, "/v1/remote/sessions/rs_0123456789abcdef0123456789abcdef/vnc")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        task.cancel()
    }

    /// The path is re-derived from the session ID rather than trusted verbatim,
    /// so a malformed connection document cannot aim this socket somewhere else.
    func testAVNCBridgePathThatIsNotASessionBridgeIsRefused() async throws {
        let client = try client()
        try await client.connect()
        for path in ["/v1/events", "/v1/remote/sessions/rs_abc/audio", "/v1/remote/sessions/../../vnc",
                     "/v1/remote/sessions/not-a-session/vnc", "/v1/remote/sessions/rs_abc/extra/vnc"] {
            do {
                let task = try await client.makeVNCSocket(path: path)
                task.cancel()
                XCTFail("accepted \(path)")
            } catch let error as RemoteRequestError {
                XCTAssertEqual(error.code, "invalid_request", path)
            }
        }
    }

    /// A bridge that never came up is reported as a refused channel, not as
    /// "the VNC client could not connect".
    func testTheBridgeReportsAFailedUpgradeAsItself() async throws {
        let client = try client()
        try await client.connect()
        let task = try await client.makeVNCSocket(path: "/v1/remote/sessions/rs_0123456789abcdef0123456789abcdef/vnc")
        let bridge = VNCWebSocketBridge()
        do {
            _ = try await bridge.start(task)
            XCTFail("a socket to a host that is not there must not produce a port")
        } catch let failure as VNCWebSocketBridge.Failure {
            guard case .handshake = failure else { return XCTFail("\(failure)") }
        }
        await bridge.close()
    }

    private func homeStore(fake: FixtureCompanion? = nil) throws -> (HomeStore, UserDefaults) {
        let name = "companion-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(name, forKey: "test-suite-name")
        var profile = HostProfile(); profile.mock = false; profile.companionURL = "https://fixture.invalid:8443"
        defaults.set(try JSONEncoder().encode(profile), forKey: "omodachi.profile.v1")
        let service = try fake ?? FixtureCompanion(snapshot: CompanionFixtures.snapshot())
        return (HomeStore(defaults: defaults, credentials: FixtureCredential(), clientFactory: { _, _ in service }, autoConnect: false), defaults)
    }
    private func defaultsSuite(_ defaults: UserDefaults) -> String { defaults.string(forKey: "test-suite-name")! }
    private func requestBody(_ request: URLRequest) throws -> Data {
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
