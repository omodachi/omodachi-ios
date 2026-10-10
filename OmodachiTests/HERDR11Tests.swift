import XCTest
@testable import Omodachi

/// HERDR-11: a launcher with a new workspace and favourite folders; one
/// honest connection clock; a lighter state. (HERDR-12 took the App's
/// latest-reply card away; core still reads the log for OVERVIEW-1.)
///
/// The wire documents are core's own fixtures (`contracts/fixtures/` at the
/// herdr-11 commit), inline: `CoreFixtures/` is pinned to another core commit
/// and is synced when the branches meet.
@MainActor
final class HERDR11Tests: XCTestCase {
    // MARK: - Core's documents

    static let folders = #"""
    {"home": "/home/user", "recent": [{"path": "/home/user/Work/omodachi", "display": "~/Work/omodachi", "name": "omodachi"}],
     "common": [{"path": "/home/user", "display": "~", "name": "~"}], "browse": null,
     "favourites": [{"path": "/home/user/Work/notes", "display": "~/Work/notes", "name": "notes"}],
     "launchers": [{"command": "codex", "label": "codex"}, {"command": "claude", "label": "claude"}],
     "contract_revision": "omodachi.v1"}
    """#
    static let oldFolders = #"""
    {"home": "/home/user", "recent": [], "common": [{"path": "/home/user", "display": "~", "name": "~"}], "browse": null,
     "contract_revision": "omodachi.v1"}
    """#
    static let created = #"""
    {"contract_revision": "omodachi.v1", "selected": "work", "owned": "omodachi", "scope": "device",
     "workspace": {"id": "w3", "label": "home", "number": 3, "focused": false, "pane": "w3:p1", "cwd": "/home/user", "display": "~"},
     "launch": {"command": "codex", "pane": "w3:p1", "sent": true, "drawn": true, "reason": null}}
    """#
    func testCoresNewDocumentsDecodeAndAnOlderCoresStillDo() throws {
        let value = try JSONDecoder().decode(HerdrFoldersDTO.self, from: Data(Self.folders.utf8))
        XCTAssertEqual(value.launchers?.map(\.command), ["codex", "claude"])
        XCTAssertEqual(value.favourites?.map(\.display), ["~/Work/notes"])
        let old = try JSONDecoder().decode(HerdrFoldersDTO.self, from: Data(Self.oldFolders.utf8))
        XCTAssertNil(old.launchers)
        XCTAssertNil(old.favourites)
        let made = try JSONDecoder().decode(HerdrWorkspaceCreatedDTO.self, from: Data(Self.created.utf8))
        XCTAssertEqual(made.launch?.sent, true)
        XCTAssertEqual(made.launch?.command, "codex")
    }

    func testAStateWhoseCatalogIsUnchangedDecodes() throws {
        let catalog = try JSONDecoder().decode(HostCatalogDTO.self, from: Data(#"""
            {"contract_revision": "omodachi.v1", "revision": "3f0af054c4448610", "source_revision": "fcc7fbd06ce6a008",
             "entries": [], "unchanged": true}
            """#.utf8))
        XCTAssertEqual(catalog.unchanged, true)
        XCTAssertTrue(catalog.entries.isEmpty)
        let full = try JSONDecoder().decode(HostCatalogDTO.self, from: Data(#"{"revision": "r1", "entries": []}"#.utf8))
        XCTAssertNil(full.unchanged)
    }

    // MARK: - The client

    private func client() throws -> CompanionHostClient {
        H11URLProtocol.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [H11URLProtocol.self]
        return CompanionHostClient(
            configuration: try CompanionHostConfiguration(endpoint: XCTUnwrap(URL(string: "https://h11.invalid:8443"))),
            credentials: FixtureCredential(), pinnedFingerprint: nil,
            session: URLSession(configuration: options))
    }

    func testTheStateNamesTheCatalogItHoldsAndTheLayoutAnswers304() async throws {
        let client = try client()
        try await client.connect()
        H11URLProtocol.set("/v1/state", body: try String(contentsOf: XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
            .appendingPathComponent("state.json"), encoding: .utf8))
        _ = try await client.fetchState(knownCatalog: "3f0af054c4448610")
        XCTAssertEqual(H11URLProtocol.requests.last?.value(forHTTPHeaderField: "X-Omodachi-Catalog"), "3f0af054c4448610")
        _ = try await client.fetchState(knownCatalog: nil)
        XCTAssertNil(H11URLProtocol.requests.last?.value(forHTTPHeaderField: "X-Omodachi-Catalog"),
                     "a client without a catalog asks for the rows")

        H11URLProtocol.set("/v1/herdr/layout", status: 304, headers: ["ETag": #""omodachi:7""#], body: "")
        let (layout, etag) = try await client.herdrLayout(etag: #""omodachi:7""#)
        XCTAssertNil(layout, "304: the layout on hand stands")
        XCTAssertEqual(etag, #""omodachi:7""#)
        XCTAssertEqual(H11URLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"), #""omodachi:7""#)
    }

    func testCreateSendsTheLauncherAndAnEmptyFolderAsHome() async throws {
        let client = try client()
        try await client.connect()
        H11URLProtocol.set("/v1/herdr/sessions/work/workspaces", body: Self.created)
        let made = try await client.herdrCreateWorkspace(session: "work", cwd: "  ", name: nil, launch: "codex")
        XCTAssertEqual(made.launch?.sent, true)
        let body = try XCTUnwrap(H11URLProtocol.bodies.last)
        XCTAssertEqual(body["cwd"] as? String, "~")
        XCTAssertEqual(body["launch"] as? String, "codex")
        _ = try await client.herdrCreateWorkspace(session: "work", cwd: "~/code", name: "x")
        let plain = try XCTUnwrap(H11URLProtocol.bodies.last)
        XCTAssertNil(plain["launch"], "no launcher: a plain shell, and an older core sees no new field")

        H11URLProtocol.set("/v1/herdr/folders/favourites", body: Self.folders)
        let folders = try await client.herdrFavourite(path: "~/Work/notes", on: true)
        XCTAssertEqual(folders.favourites?.count, 1)
        let star = try XCTUnwrap(H11URLProtocol.bodies.last)
        XCTAssertEqual(star["path"] as? String, "~/Work/notes")
        XCTAssertEqual(star["favourite"] as? Bool, true)
    }

    func testANotAllowedLauncherIsASentence() {
        XCTAssertEqual(HerdrRequestError(code: "herdr_launch_not_allowed", status: 400).userMessage,
                       Strings.reasonHerdrLaunchNotAllowed)
    }

    // MARK: - The one clock

    func testTheClockGoesAmberAtFourSecondsAndRedAtFifteenWithTheCause() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ConnectionHealth.judge(now: start.addingTimeInterval(3.9), since: start, pathSatisfied: true), .live)
        XCTAssertEqual(ConnectionHealth.judge(now: start.addingTimeInterval(4), since: start, pathSatisfied: true), .trouble)
        XCTAssertEqual(ConnectionHealth.judge(now: start.addingTimeInterval(14.9), since: start, pathSatisfied: false), .trouble)
        XCTAssertEqual(ConnectionHealth.judge(now: start.addingTimeInterval(15), since: start, pathSatisfied: true),
                       .lost(.hostUnreachable))
        XCTAssertEqual(ConnectionHealth.judge(now: start.addingTimeInterval(15), since: start, pathSatisfied: false),
                       .lost(.deviceOffline))
        XCTAssertNil(ConnectionHealth.live.message(host: "omarchy"))
        XCTAssertEqual(ConnectionHealth.trouble.message(host: "omarchy"), Strings.connectionReconnecting)
        XCTAssertEqual(ConnectionHealth.lost(.hostUnreachable).message(host: "omarchy"),
                       Strings.connectionHostUnreachable("omarchy"))
        XCTAssertEqual(ConnectionHealth.lost(.herdrDown).message(host: "omarchy"), Strings.connectionHerdrDown("omarchy"))
        XCTAssertTrue(ConnectionHealth.lost(.deviceOffline).message(host: "omarchy")?.contains(ConnectionHealth.deviceWord) == true)
    }

    private func home() -> HomeStore {
        let suite = "h11-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return HomeStore(defaults: defaults, credentials: FixtureCredential(), autoConnect: false)
    }

    func testTheStoreClockCountsFromTheLastProofAndOnlyWhileAHostIsWanted() {
        let home = home()
        home.recomputeHealth(now: Date().addingTimeInterval(60))
        XCTAssertEqual(home.health, .live, "nothing wanted: nothing to be late for")
        home.profile.companionURL = "https://omarchy.example:8099"
        home.profile.mock = false
        home.connectionWanted = true
        home.restartHealthClock()
        let proof = Date()
        home.lastLiveAt = proof
        home.recomputeHealth(now: proof.addingTimeInterval(2))
        XCTAssertEqual(home.health, .live)
        home.recomputeHealth(now: proof.addingTimeInterval(5))
        XCTAssertEqual(home.health, .trouble)
        XCTAssertEqual(home.healthMessage, Strings.connectionReconnecting)
        home.recomputeHealth(now: proof.addingTimeInterval(16))
        XCTAssertEqual(home.health, .lost(.hostUnreachable))
        home.noteLive()
        XCTAssertEqual(home.health, .live, "one frame and it is live again")
        // Never connected this time: amber says "Connecting", not "Reconnecting".
        home.restartHealthClock()
        home.recomputeHealth(now: Date().addingTimeInterval(5))
        XCTAssertEqual(home.healthMessage, Strings.connectionConnecting(home.state.hostName))
        home.connectionWanted = false
        home.recomputeHealth(now: Date().addingTimeInterval(60))
        XCTAssertEqual(home.health, .live, "a deliberate disconnect is not 'reconnecting'")
    }

    func testThePathSaysWhenTheNetworkCameBackOrMoved() {
        let watcher = NetworkPathWatcher()
        var seen: [(Bool, Bool, Bool)] = []
        watcher.onChange = { seen.append(($0, $1, $2)) }
        watcher.update(satisfied: true, interfaces: ["wifi"])
        watcher.update(satisfied: false, interfaces: [])
        watcher.update(satisfied: true, interfaces: ["cellular"])
        watcher.update(satisfied: true, interfaces: ["wifi"])
        XCTAssertEqual(seen.map(\.0), [true, false, true, true])
        XCTAssertEqual(seen.map(\.1), [false, false, true, false], "returned: only after it was gone")
        XCTAssertEqual(seen.map(\.2), [false, false, false, true], "moved: Wi-Fi to cellular and back")
    }

    func testAnUnchangedCatalogKeepsTheMenuAndAChangedOneReplacesIt() throws {
        let home = home()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
        let catalog = try JSONDecoder().decode(HostCatalogDTO.self,
                                               from: Data(contentsOf: url.appendingPathComponent("catalog.json")))
        home.applyCatalog(catalog)
        let entries = home.catalogEntries.count
        XCTAssertGreaterThan(entries, 0)
        func state(_ revision: Int, _ catalog: String) throws -> HostStateDTO {
            try JSONDecoder().decode(HostStateDTO.self, from: Data(#"{"revision": \#(revision), "catalog": \#(catalog)}"#.utf8))
        }
        home.apply(try state(2, #"{"revision": "\#(catalog.revision)", "entries": [], "unchanged": true}"#))
        XCTAssertEqual(home.catalogEntries.count, entries, "the rows on hand stand")
        XCTAssertEqual(home.catalogRevision, catalog.revision)
        home.apply(try state(3, #"{"revision": "r2", "entries": []}"#))
        XCTAssertEqual(home.catalogRevision, "r2")
        XCTAssertEqual(home.catalogEntries.count, 0)
    }

    // MARK: - The Herdr panel

    func testOnlyThePanelsOwnSessionIsReadAgain() {
        XCTAssertTrue(HerdrStore.layoutEventIsMine(session: nil, mine: "work"), "an older core did not say")
        XCTAssertTrue(HerdrStore.layoutEventIsMine(session: "work", mine: "work"))
        XCTAssertFalse(HerdrStore.layoutEventIsMine(session: "debug", mine: "work"))
    }

    func testTheCardKeepsOnlyLaunchersTheHostStillListsAndRemembersTheChoice() throws {
        let home = home()
        let store = HerdrStore(home: home)
        store.chooseLauncher("claude")
        store.applyFolders(try JSONDecoder().decode(HerdrFoldersDTO.self, from: Data(Self.folders.utf8)))
        XCTAssertEqual(store.chosenLauncher, "claude")
        XCTAssertTrue(store.favouritesSupported)
        XCTAssertTrue(store.isFavourite(HerdrFolderDTO(path: "/home/user/Work/notes", display: "~/Work/notes", name: "notes")))
        XCTAssertEqual(HerdrStore(home: home).chosenLauncher, "claude", "remembered on this device")
        store.applyFolders(try JSONDecoder().decode(HerdrFoldersDTO.self, from: Data(Self.oldFolders.utf8)))
        XCTAssertNil(store.chosenLauncher, "an older core: a plain shell, never something else")
        XCTAssertTrue(store.launchers.isEmpty)
        XCTAssertFalse(store.favouritesSupported, "no stars where the host keeps none")
    }

    func testAMirrorNobodyHasHeardFromForFourSecondsIsDimmedWithItsTime() throws {
        let home = home()
        let store = HerdrStore(home: home)
        let layout = try JSONDecoder().decode(HerdrLayoutDTO.self, from: Data(#"""
            {"session": "omodachi", "protocol": 20, "version": "0.8.2", "revision": 3,
             "focused": {"workspace_id": "w1", "tab_id": "w1:t1", "pane_id": "w1:p1"},
             "workspaces": [{"id": "w1", "label": "~", "number": 1, "focused": true, "active_tab_id": "w1:t1",
               "tabs": [{"id": "w1:t1", "label": "1", "number": 1, "focused": true, "zoomed": false,
                 "panes": [{"id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1", "title": "zsh", "cwd": "/home/user",
                            "focused": true, "zoomed": false, "agent_status": "unknown", "agent": null,
                            "size": {"cols": 80, "rows": 24}, "revision": 1}]}]}]}
            """#.utf8))
        store.apply(layout)
        XCTAssertEqual(store.selected, "w1:p1")
        let seen = Date()
        store.mirrorSeenAt = seen
        store.recomputeStale(now: seen.addingTimeInterval(2))
        XCTAssertFalse(store.mirrorStale)
        XCTAssertNil(store.mirrorStaleLabel)
        store.recomputeStale(now: seen.addingTimeInterval(5))
        XCTAssertTrue(store.mirrorStale)
        XCTAssertEqual(store.mirrorStaleLabel,
                       Strings.herdrMirrorLastUpdate(seen.formatted(date: .omitted, time: .shortened)))
        store.mirrorSeen()
        XCTAssertFalse(store.mirrorStale, "a pong and it is current again")
    }
}

/// A stub host that answers with a status, headers and a body per path, and
/// keeps every request (and its JSON body) for the test to read back.
final class H11URLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (Int, [String: String], String)] = [:]
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var capturedBodies: [[String: Any]] = []

    static func reset() { lock.lock(); responses = [:]; captured = []; capturedBodies = []; lock.unlock() }
    static func set(_ path: String, status: Int = 200, headers: [String: String] = [:], body: String) {
        lock.lock(); responses[path] = (status, headers, body); lock.unlock()
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return capturedBodies }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "h11.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.captured.append(request)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { Self.capturedBodies.append(object) }
        let (status, headers, body) = Self.responses[request.url?.path ?? ""]
            ?? (404, [:], #"{"error":{"code":"route_unavailable","message":"not registered"}}"#)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"].merging(headers) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
