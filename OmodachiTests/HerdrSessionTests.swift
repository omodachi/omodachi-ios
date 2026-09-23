import XCTest
@testable import Omodachi

/// HERDR-2. The session list the panel's dropdown is drawn from, the name that
/// is allowed to become a path segment, and the two things that make a failed
/// layout read ask again instead of sitting there.
@MainActor
final class HerdrSessionTests: XCTestCase {
    private func fixtures() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["OMODACHI_CORE_FIXTURES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
    }

    private func sessions() throws -> HerdrSessionsDTO {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("herdr-sessions.json"))
        return try JSONDecoder().decode(HerdrSessionsDTO.self, from: data)
    }

    func testTheCoreSessionsFixtureDecodesIntoTheRowsTheDropdownDraws() throws {
        let value = try sessions()
        XCTAssertEqual(value.selected, "omodachi")
        XCTAssertEqual(value.owned, "omodachi")
        XCTAssertEqual(value.sessions.map(\.name), ["omodachi", "default", "herdr2-probe"])
        XCTAssertEqual(value.sessions.map(\.owned), [true, false, false])
        // The user's own session is the one a plain `herdr` attaches to, and it
        // is the reason the dropdown exists.
        XCTAssertEqual(value.session("default")?.herdrDefault, true)
        XCTAssertEqual(value.session("omodachi")?.herdrDefault, false)
        XCTAssertEqual(value.session("default")?.panes, 2)
        XCTAssertEqual(value.session("omodachi")?.version, "0.8.2")
    }

    /// A session that is on the machine but stopped is listed, not hidden: the
    /// user knows it exists, so the row says why it cannot be entered.
    func testAStoppedSessionIsListedWithNoCountsAndNoWayIn() throws {
        let stopped = try XCTUnwrap(try sessions().session("herdr2-probe"))
        XCTAssertFalse(stopped.running)
        XCTAssertFalse(stopped.readable)
        XCTAssertNil(stopped.panes)
        XCTAssertNil(stopped.workspaces)
        XCTAssertFalse(stopped.isEmpty, "unreadable is not the same as empty")
    }

    func testASessionWithNoPaneSaysSoRatherThanOfferingAnEmptyGrid() throws {
        let data = Data("""
        {"selected":"a","owned":"a","sessions":[{"name":"a","running":true,"owned":true,
         "herdr_default":false,"readable":true,"workspaces":0,"tabs":0,"panes":0,"agents":0,
         "protocol":20,"version":"0.8.2"}]}
        """.utf8)
        let value = try JSONDecoder().decode(HerdrSessionsDTO.self, from: data)
        XCTAssertTrue(try XCTUnwrap(value.session("a")).isEmpty)
    }

    /// The bridge's own alphabet (`herdr_bridge.py:40`). A name that fails this
    /// never becomes a path segment, so it can never become a flag either.
    func testOnlyAHerdrSessionNameCanBecomeAPathSegment() {
        for name in ["omodachi", "default", "herdr2-probe", "a", "A.b_c-1", String(repeating: "x", count: 64)] {
            XCTAssertTrue(CompanionHostClient.isHerdrSession(name), name)
        }
        for name in ["", "-takeover", "--takeover", ".hidden", "_x", "a/b", "a b", "a:b", "a%2Fb",
                     "中文", "a\nb", String(repeating: "x", count: 65)] {
            XCTAssertFalse(CompanionHostClient.isHerdrSession(name), name)
        }
    }

    // MARK: - The two routes

    private func client() throws -> CompanionHostClient {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        return CompanionHostClient(
            configuration: try CompanionHostConfiguration(endpoint: XCTUnwrap(URL(string: "https://fixture.invalid:8443"))),
            credentials: FixtureCredential(), pinnedFingerprint: nil,
            session: URLSession(configuration: options))
    }

    func testTheTwoSessionRoutesAreTheOnesTheBridgePublishes() async throws {
        let client = try client()
        try await client.connect()
        let listing = try String(decoding: Data(contentsOf:
            fixtures().appendingPathComponent("herdr-sessions.json")), as: UTF8.self)
        CompanionURLProtocol.storage.set("/v1/herdr/sessions", body: listing)
        let listed = try await client.herdrSessions()
        XCTAssertEqual(listed.selected, "omodachi")
        XCTAssertEqual(CompanionURLProtocol.storage.requests.last?.url?.path, "/v1/herdr/sessions")

        CompanionURLProtocol.storage.set("/v1/herdr/sessions/default/select",
                                         body: #"{"selected":"default","owned":"omodachi","scope":"device"}"#)
        let selection = try await client.herdrSelectSession("default")
        XCTAssertEqual(selection.selected, "default")
        let request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/herdr/sessions/default/select")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    /// A name this client will not spell is refused before anything leaves the
    /// device, so it can never arrive at the host as a path segment.
    func testSelectingAnImpossibleSessionNeverReachesTheHost() async throws {
        let client = try client()
        try await client.connect()
        for name in ["../default", "--takeover", "a b", ""] {
            do {
                _ = try await client.herdrSelectSession(name)
                XCTFail("sent \(name)")
            } catch let error as CompanionHostError {
                guard case .protocolError = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(CompanionURLProtocol.storage.requests.isEmpty)
    }
}
