import XCTest
@testable import Omodachi

/// NOTIFY-3. Omodachi's own request notifications: a tap explains instead of
/// firing a panel on the computer, a decided one leaves the list when core
/// withdraws it, and what was cleared here stays cleared. Rows and events are
/// core's own contract fixtures (`CoreFixtures/`).
@MainActor
final class NOTIFY3Tests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json",
                                                           subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }

    private func page() throws -> [HostNotification] {
        try JSONDecoder().decode(HostNotificationPage.self, from: fixture("notifications")).notifications
    }

    func testARequestRowCarriesItsKindAndNothingElseDoes() throws {
        let rows = try page()
        let request = try XCTUnwrap(rows.first { $0.app == "Omodachi" })
        XCTAssertEqual(request.kind, "pairing_request")
        XCTAssertTrue(request.isRequest)
        XCTAssertFalse(request.withdrawn)
        let other = try XCTUnwrap(rows.first { $0.app != "Omodachi" })
        XCTAssertNil(other.kind)
        XCTAssertFalse(other.isRequest)
    }

    /// The fixture's request is the newest row on the desktop and has an
    /// action — exactly the row that used to fire `invokeLast`, which summons
    /// the plugin's Devices view on the computer's screen.
    func testARequestIsNeverInvokedFromThePhone() throws {
        var list = HostNotificationList()
        list.replace(with: try page())
        let request = try XCTUnwrap(list.rows.first)
        XCTAssertTrue(request.isRequest && request.active && request.hasAction)
        XCTAssertEqual(list.newestActive?.id, request.id)
        XCTAssertFalse(list.canInvoke(request))
        XCTAssertTrue(list.canDelete(request))
        // Any other app's newest row still can, as before.
        let plain = HostNotification(id: "1789711999999-9", app: "omarchy-action", summary: "Theme set",
                                     body: "", timestamp: 1789711999999, hasAction: true, active: true)
        list.post(plain)
        XCTAssertTrue(list.canInvoke(plain))
    }

    func testTheUpdatedEventIsDecodedAndKeepsTheRowAsHistory() throws {
        let event = try CompanionHostClient.decodeEvent(fixture("event-notification-updated"))
        XCTAssertEqual(event.type, "notification.updated")
        let row = try XCTUnwrap(event.notification, "the updated row rides the event, like a posted one")
        XCTAssertFalse(row.withdrawn)
        var list = HostNotificationList()
        list.post(HostNotification(id: row.id, app: row.app, summary: row.summary, body: row.body,
                                   timestamp: row.timestamp, hasAction: false, active: true))
        list.update(row)
        XCTAssertEqual(list.rows.map(\.id), [row.id])
        XCTAssertFalse(list.rows[0].active)
    }

    func testAWithdrawnRequestLeavesTheList() throws {
        let posted = try XCTUnwrap(try CompanionHostClient.decodeEvent(fixture("event-notification-posted")).notification)
        let event = try CompanionHostClient.decodeEvent(fixture("event-notification-withdrawn"))
        XCTAssertEqual(event.type, "notification.updated")
        let row = try XCTUnwrap(event.notification)
        XCTAssertTrue(row.withdrawn)
        XCTAssertEqual(row.id, posted.id)
        var list = HostNotificationList()
        list.replace(with: try page())
        XCTAssertEqual(list.rows.count, 2)
        list.update(row)
        XCTAssertEqual(list.rows.map(\.id), ["1789608484220-52"], "gone, not history")
        XCTAssertFalse(list.removed.contains(row.id), "nobody here chose to hide it")
    }

    func testTheStoreDropsAWithdrawnRowAndItsToast() throws {
        let home = store()
        let posted = try XCTUnwrap(try CompanionHostClient.decodeEvent(fixture("event-notification-posted")).notification)
        home.notifications.post(posted)
        home.notificationToast = posted
        let withdrawn = try XCTUnwrap(try CompanionHostClient.decodeEvent(fixture("event-notification-withdrawn")).notification)
        home.notificationUpdated(withdrawn)
        XCTAssertTrue(home.notifications.rows.isEmpty)
        XCTAssertNil(home.notificationToast)
    }

    /// Leo's "点不掉": a cleared row came back on the next launch, because
    /// `removed` lived only as long as the connection.
    func testClearedRowsStayClearedForThatComputer() throws {
        let defaults = UserDefaults(suiteName: "notify3-\(UUID().uuidString)")!
        let first = store(defaults)
        first.notifications.replace(with: try page())
        first.deleteNotification(try XCTUnwrap(first.notifications.rows.last))
        XCTAssertEqual(first.notifications.rows.count, 1)

        let next = store(defaults)
        next.notifications.restore(removed: next.storedRemovedNotifications())
        next.notifications.replace(with: try page())
        XCTAssertEqual(next.notifications.rows.map(\.id), ["1789711988810-1"])
        next.clearNotifications()
        let third = store(defaults)
        third.notifications.restore(removed: third.storedRemovedNotifications())
        third.notifications.replace(with: try page())
        XCTAssertTrue(third.notifications.rows.isEmpty)

        // Another computer has its own list.
        let elsewhere = store(defaults, url: "https://other-fixture.example:8443")
        XCTAssertTrue(elsewhere.storedRemovedNotifications().isEmpty)
    }

    func testTheDemoKeepsNothing() throws {
        let defaults = UserDefaults(suiteName: "notify3-demo-\(UUID().uuidString)")!
        let home = HomeStore(defaults: defaults, clientFactory: { _, _ in NotifyThreeNoService() }, autoConnect: false)
        home.profile.mock = true
        home.notifications.replace(with: try page())
        home.deleteNotification(try XCTUnwrap(home.notifications.rows.first))
        XCTAssertTrue(home.storedRemovedNotifications().isEmpty)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("omodachi.notifications.removed") })
    }

    func testTheRememberedIdsAreBoundedToTheNewest() {
        var list = HostNotificationList()
        list.restore(removed: Set((0..<600).map { "\(1789711988000 + $0)-\($0)" }))
        let kept = list.removedToKeep()
        XCTAssertEqual(kept.count, 500)
        XCTAssertEqual(kept.last, "1789711988599-599")
        XCTAssertFalse(kept.contains("1789711988000-0"))
        // By stamp, then id - not by string length.
        list = HostNotificationList()
        list.restore(removed: ["1791102800000-12", "1791102837949-4"])
        XCTAssertEqual(list.removedToKeep(limit: 1), ["1791102837949-4"])
    }

    // MARK: -

    private func store(_ defaults: UserDefaults = UserDefaults(suiteName: "notify3-\(UUID().uuidString)")!,
                       url: String = "https://omarchy-fixture.example:8443") -> HomeStore {
        let home = HomeStore(defaults: defaults, clientFactory: { _, _ in NotifyThreeNoService() }, autoConnect: false)
        home.profile.mock = false
        home.profile.companionURL = url
        return home
    }
}

private struct NotifyThreeNoService: CompanionServing {
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
