import XCTest
@testable import Omodachi

/// STORE-1 §1. The demo App Review walks through: entered from the first
/// screen, drawn from the canonical fixtures, never stored, never connected.
@MainActor
final class DemoModeTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var dialled = 0

    override func setUp() async throws {
        try await super.setUp()
        suite = "omodachi.store-1.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        dialled = 0
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func makeHome() -> HomeStore {
        HomeStore(defaults: defaults, clientFactory: { [weak self] _, _ in
            self?.dialled += 1
            return DemoNoService()
        }, autoConnect: false)
    }

    func testEnteringShowsTheFixturesAndExitingPutsTheOldProfileBack() async throws {
        let home = makeHome()
        let before = home.profile
        let stored = defaults.data(forKey: "omodachi.profile.v1")

        home.enterDemo()
        XCTAssertTrue(home.demoActive)
        XCTAssertTrue(home.profile.mock)
        XCTAssertEqual(home.profile.hostname, "demo-omarchy")
        XCTAssertEqual(home.profile.username, "demo")
        XCTAssertEqual(home.profile.companionURL, "")
        XCTAssertEqual(home.state.hostName, "demo-omarchy")
        // The menu is the fixture catalog, not the built-in placeholder.
        XCTAssertTrue(home.flattened.contains { $0.id == "omodachi.workspace.select.1" })
        XCTAssertFalse(home.flattened.contains { $0.id == "apps.launcher" })
        XCTAssertEqual(home.notifications.rows.count, 2)
        let shortcuts = try await home.loadShortcuts()
        XCTAssertFalse(shortcuts.entries.isEmpty)
        // Never written down.
        XCTAssertEqual(defaults.data(forKey: "omodachi.profile.v1"), stored)

        home.exitDemo()
        XCTAssertFalse(home.demoActive)
        XCTAssertEqual(home.profile, before)
        XCTAssertEqual(defaults.data(forKey: "omodachi.profile.v1"), stored)
        XCTAssertTrue(home.flattened.contains { $0.id == "apps.launcher" })
        XCTAssertEqual(dialled, 0, "the demo never builds a host client")
        XCTAssertFalse(home.companionConnected)
    }

    func testTheDemoFixturesNameNobody() throws {
        for name in ["state", "notifications", "shortcuts"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json"),
                                    "\(name).json is bundled with the app")
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
            for forbidden in ["alex", "zxyleo", "secondfirst", "/home/", "/users/", "192.168.", "10.0.", "@"] {
                XCTAssertFalse(text.contains(forbidden), "\(name).json contains \(forbidden)")
            }
        }
        XCTAssertFalse(DemoHost.profile.username.contains("leo"))
    }
}

private struct DemoNoService: CompanionServing {
    func connect() async throws { throw CompanionHostError.notConnected }
    func disconnect() async {}
    func fetchState() async throws -> HostStateDTO { throw CompanionHostError.notConnected }
    func fetchSnapshot() async throws -> CompanionSnapshot { throw CompanionHostError.notConnected }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter],
                targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse {
        throw CompanionHostError.notConnected
    }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse {
        throw CompanionHostError.notConnected
    }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
