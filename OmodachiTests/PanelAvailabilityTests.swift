import XCTest
@testable import Omodachi

/// PERF-4 §1. What a row says about itself comes from the host, and only from
/// the host.
///
/// Leo, on the real iPad: *"点击之后所有的 Omarchy menu 显示 unavailable，过了好
/// 一会儿才恢复。"* Every row in the menu went grey after a tap and stayed that
/// way for several seconds. Nothing about those rows had changed: the client
/// had merely failed to re-read the state in time, dropped to "not connected",
/// and rebuilt the whole menu as unavailable — which it then undid when the
/// reconnect succeeded. A refresh in flight is not a statement about a row.
@MainActor final class PanelAvailabilityTests: XCTestCase {
    private func catalog() throws -> HostCatalogDTO {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
        return try JSONDecoder().decode(HostCatalogDTO.self,
                                        from: Data(contentsOf: root.appendingPathComponent("catalog.json")))
    }

    private func store() throws -> HomeStore {
        let name = "omodachi-availability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        var profile = HostProfile()
        profile.mock = false
        profile.companionURL = "https://198.51.100.9:8099"
        let home = HomeStore(defaults: defaults, autoConnect: false)
        home.profile = profile
        return home
    }

    /// The rows the panel would draw `不可用` on.
    private func unavailable(_ home: HomeStore) -> Set<String> {
        Set(home.flattened.filter { $0.children.isEmpty && !$0.enabled }.map(\.id))
    }

    func testARefreshInFlightDoesNotChangeAnyRowsAvailability() throws {
        let home = try store()
        home.companionConnected = true
        home.applyCatalog(try catalog())
        let rows = home.flattened.filter { $0.children.isEmpty }
        XCTAssertFalse(rows.isEmpty, "the fixture has to have rows for this to mean anything")
        let before = unavailable(home)
        let identifiers = home.flattened.map(\.id)
        XCTAssertLessThan(before.count, rows.count, "the fixture has to have available rows too")

        // What happens when a state read times out or the event stream breaks
        // while the host is busy: the connection is gone, and that is all.
        home.markUnavailable(CompanionHostError.transport(message: Strings.hostReconnecting))

        XCTAssertEqual(unavailable(home), before,
                       "a lost connection is the bar's dot; it says nothing about any row")
        XCTAssertEqual(home.flattened.map(\.id), identifiers, "the menu itself is untouched")
        // PAIR-5 calls a host that did not answer "offline"; either way it is
        // a statement about the connection and not about any row.
        XCTAssertEqual(home.connectionState, .offline)
        XCTAssertTrue(home.hostOffline)
        XCTAssertFalse(home.companionConnected)
    }

    func testTheHostIsTheOnlyThingThatGreysARow() throws {
        let entries = try catalog().entries
        let built = HostMenu.build(from: entries).flatMap(\.all)
        for row in built where row.children.isEmpty {
            guard let entry = entries.first(where: { $0.id == row.id }) else { continue }
            // MENU-3: a `when` the host ran and got no answer from (`unknown`)
            // counts as showing, as it does on the desktop.
            let hostSaysReady = HostMenu.hostShows(entry)
                && entry.descriptor?.supported == true && entry.descriptor?.ready != false
            // The two rows the client owns regardless (ARCH-1): Agent is a
            // native surface and Desktop is the picture.
            if row.id == "omodachi.agent" || (row.id == "omodachi.desktop" && row.route == "desktop") {
                XCTAssertTrue(row.enabled, row.id)
                continue
            }
            XCTAssertEqual(row.enabled, hostSaysReady, row.id)
        }
    }

    /// The other half of the same rule: the square moves on the tap, and the
    /// host's own snapshot is what settles it.
    func testTheBarDrawsTheTappedSquareBeforeTheHostHasAnswered() throws {
        let home = try store()
        home.companionConnected = true
        home.setOptimisticWorkspace(7)
        XCTAssertEqual(home.state.workspace, 7)
        XCTAssertEqual(home.shownWorkspace, 7)
        // A refusal puts it back where it was.
        home.setOptimisticWorkspace(nil)
        XCTAssertNil(home.optimisticWorkspace)
    }
}
