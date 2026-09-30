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

    func testEnteringShowsTheDemoAndExitingPutsTheOldProfileBack() async throws {
        let home = makeHome()
        let before = home.profile
        let stored = defaults.data(forKey: "omodachi.profile.v1")

        home.enterDemo()
        XCTAssertTrue(home.demoActive)
        XCTAssertTrue(home.profile.mock)
        XCTAssertEqual(home.profile.hostname, "desktop")
        XCTAssertEqual(home.profile.username, "demo")
        XCTAssertEqual(home.profile.companionURL, "")
        XCTAssertEqual(home.state.hostName, "desktop")
        // The menu is the demo's catalog, not the built-in placeholder.
        XCTAssertTrue(home.flattened.contains { $0.id == "omodachi.workspace.select.1" })
        XCTAssertTrue(home.flattened.contains { $0.id == "style.theme" })
        XCTAssertFalse(home.flattened.contains { $0.id == "apps.launcher" })
        XCTAssertEqual(home.notifications.rows.count, 5)
        let shortcuts = try await home.loadShortcuts()
        XCTAssertGreaterThan(shortcuts.entries.count, 100)
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

    /// STORE-6 §A2. No row in the demo is `Unavailable`: every leaf runs, every
    /// submenu has something in it, and the rows a host asks twice for ask
    /// twice here too.
    func testEveryDemoRowCanBeTapped() {
        let home = makeHome()
        home.enterDemo()
        let rows = home.flattened
        XCTAssertGreaterThan(rows.count, 300)
        for row in rows {
            XCTAssertTrue(row.enabled, "\(row.id) would draw as unavailable")
            XCTAssertNil(row.disabledReason, row.id)
        }
        for id in ["system.lock", "system.shutdown", "system.reboot", "remove.package", "update.firmware"] {
            XCTAssertEqual(rows.first { $0.id == id }?.confirm, true, "\(id) asks for a second tap, as on a host")
        }
        XCTAssertEqual(rows.first { $0.id == "style.theme" }?.confirm, false)
        for id in ["apps", "style", "setup", "remove", "system", "style.font"] {
            XCTAssertFalse(rows.first { $0.id == id }?.children.isEmpty ?? true, "\(id) opens onto something")
        }
    }

    /// STORE-6 §A2. A tap in the demo says it ran, and where: on the demo
    /// computer, in the same `applied` a real host's success draws.
    func testADemoRowAndKeybindingSayWhereTheyRan() async throws {
        let home = makeHome()
        home.enterDemo()
        let lock = try XCTUnwrap(home.flattened.first { $0.id == "system.lock" })
        XCTAssertFalse(home.passesConfirm(lock), "the first tap only arms it")
        XCTAssertNil(home.panelToast)
        XCTAssertTrue(home.passesConfirm(lock))
        await home.invoke(lock)
        XCTAssertEqual(home.panelToast?.stage, .applied)
        XCTAssertEqual(home.panelToast?.label, "Lock")
        XCTAssertEqual(home.panelToast?.detail, Strings.demoRanHere)

        let shortcuts = try await home.loadShortcuts()
        let terminal = try XCTUnwrap(shortcuts.entries.first { $0.label == "Terminal" })
        let result = try await home.runShortcut(.init(requestID: UUID(), entryID: terminal.id,
                                                      actionRef: terminal.actionRef ?? "", revision: shortcuts.revision,
                                                      context: .init(hostID: "", surface: .controller)))
        XCTAssertEqual(result.status, .accepted)
        XCTAssertEqual(result.message, Strings.demoRanNamed("Terminal"))
        XCTAssertEqual(dialled, 0)
    }

    /// STORE-6 §A3. The panels have something to show: pins, Herdr's panes
    /// with their text, and an Agent conversation that says it is the demo's.
    func testThePanelsHaveTheirDemoData() async throws {
        let home = makeHome()
        home.enterDemo()
        let pins = DemoHost.pinStore.pins(hostID: DemoHost.pinHostID)
        XCTAssertEqual(pins.filter { $0.kind == .menu }.map(\.stableKey),
                       ["Trigger › Capture", "Style › Theme", "System › Lock"])
        XCTAssertEqual(pins.filter { $0.kind == .keybinding }.map(\.label), ["Full screen", "Screenshot"])
        let paths = Set(home.flattened.map(\.pinKey))
        for pin in pins where pin.kind == .menu { XCTAssertTrue(paths.contains(pin.stableKey), pin.stableKey) }

        let herdr = try XCTUnwrap(DemoHost.herdr())
        XCTAssertEqual(herdr.layout.panes.count, 3)
        for pane in herdr.layout.panes { XCTAssertFalse(herdr.screens[pane.id]?.isEmpty ?? true, pane.id) }
        XCTAssertEqual(herdr.sessions.selected, "omodachi")

        let transport = AgentChatDemoTransport()
        let snapshot = try await transport.ensureDefault()
        XCTAssertEqual(snapshot.identity.provider, "demo")
        XCTAssertEqual(snapshot.rows.count, 2)
        let stream = try await transport.events(for: snapshot.identity, after: snapshot.sequence)
        try await transport.send("hello", requestID: UUID(), to: snapshot.identity)
        var events: [AgentChatEvent] = []
        for try await envelope in stream {
            if let event = envelope.event { events.append(event) }
            if events.count == 4 { break }
        }
        guard case .message(let reply) = events[2] else { return XCTFail("the demo answers") }
        XCTAssertEqual(reply.role, .assistant)
        XCTAssertEqual(reply.text, Strings.demoAgentReply)
    }

    /// The demo's own data names nobody and — STORE-6 §A5 — never the desktop
    /// OS: not the host, not a sender, not a row, not a pane.
    func testTheDemoDataNamesNobody() throws {
        for name in ["demo-catalog", "demo-notifications", "demo-shortcuts", "demo-herdr"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json"),
                                    "\(name).json is bundled with the app")
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
            for forbidden in ["omarchy", "alex", "zxyleo", "secondfirst", "/home/", "/users/", "192.168.",
                              "10.0.", "10.201.", "@gmail", "sf-omodachi"] {
                XCTAssertFalse(text.contains(forbidden), "\(name).json contains \(forbidden)")
            }
        }
        XCTAssertFalse(DemoHost.profile.username.contains("leo"))
        XCTAssertFalse(DemoHost.hostname.lowercased().contains("omarchy"))
        for row in DemoHost.notifications() { XCTAssertFalse(row.app.lowercased().contains("omarchy"), row.app) }
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
