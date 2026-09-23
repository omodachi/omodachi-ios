import XCTest
@testable import Omodachi

/// SPEC-G2 §3. The mirrored notification model and the two actions the shell
/// actually offers, against the documents core generates.
final class NotificationSyncTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json",
                                                           subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }

    func testHistoryDecodesAndReadsNewestFirst() throws {
        let page = try JSONDecoder().decode(HostNotificationPage.self, from: fixture("notifications"))
        XCTAssertEqual(page.cursor, "1789711988810-1")
        XCTAssertEqual(page.historyLimit, 500)
        var list = HostNotificationList()
        list.replace(with: page.notifications)
        XCTAssertEqual(list.rows.map(\.id), ["1789711988810-1", "1789608484220-52"],
                       "the host pages oldest first; the Panel reads newest first")
        XCTAssertEqual(list.rows.first?.urgency, .critical)
        XCTAssertTrue(list.rows.first?.hasAction == true)
        XCTAssertFalse(list.rows.last?.active == true)
    }

    /// `execArgv` exists in the shell's own file and is deliberately not on the
    /// wire: core reads it to answer "is there an action" and drops it, so this
    /// client has no stored command line to be asked to run.
    func testNoCommandLineArrivesWithANotification() throws {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("notifications")) as? [String: Any])
        let rows = try XCTUnwrap(raw["notifications"] as? [[String: Any]])
        for row in rows {
            XCTAssertNil(row["execArgv"])
            XCTAssertNil(row["exec_argv"])
        }
        XCTAssertFalse(String(decoding: try fixture("notifications"), as: UTF8.self).contains("exec"))
    }

    func testPostedEventCarriesTheWholeRow() throws {
        let event = try CompanionHostClient.decodeEvent(fixture("event-notification-posted"))
        XCTAssertEqual(event.type, "notification.posted")
        let row = try XCTUnwrap(event.notification, "the shell keeps ten and evicts the rest; the row has to ride the event")
        XCTAssertEqual(row.id, "1789711988810-1")
        XCTAssertEqual(row.app, "Omodachi")
        XCTAssertTrue(row.active)
        XCTAssertFalse(event.needsResync)
    }

    func testTranscriptEventCarriesTheHostsWords() throws {
        let event = try CompanionHostClient.decodeEvent(fixture("event-voice-transcript"))
        XCTAssertEqual(event.type, "voice.transcript")
        XCTAssertEqual(event.transcript?.text, "make the bar taller")
        XCTAssertEqual(event.transcript?.chars, 19)
    }

    func testTheSameIdIsTheSameRow() {
        var list = HostNotificationList()
        let first = HostNotification(id: "100-1", app: "omarchy-action", summary: "Theme set", body: "gruvbox",
                                     timestamp: 100, hasAction: false, active: true)
        list.post(first)
        list.post(HostNotification(id: "100-1", app: "omarchy-action", summary: "Theme set", body: "nord",
                                   timestamp: 100, hasAction: false, active: true))
        XCTAssertEqual(list.rows.count, 1, "the id is the shell's file name and the dedupe key")
        XCTAssertEqual(list.rows.first?.body, "nord")
        list.post(HostNotification(id: "200-2", app: "Omodachi", summary: "Newer", body: "",
                                   timestamp: 200, hasAction: true, active: true))
        XCTAssertEqual(list.rows.map(\.id), ["200-2", "100-1"])
    }

    /// The shell only offers "act on the newest popup". Anything else is
    /// `notification_not_actionable`, so the button must exist on exactly one
    /// row rather than being offered and then refused.
    func testOnlyTheNewestActiveNotificationWithAnActionMayBeInvoked() {
        var list = HostNotificationList()
        let older = HostNotification(id: "100-1", app: "A", summary: "older", body: "",
                                     timestamp: 100, hasAction: true, active: true)
        let newer = HostNotification(id: "200-2", app: "B", summary: "newer", body: "",
                                     timestamp: 200, hasAction: true, active: true)
        let silent = HostNotification(id: "300-3", app: "C", summary: "silenced", body: "",
                                      timestamp: 300, hasAction: true, active: false)
        list.replace(with: [older, newer, silent])
        XCTAssertFalse(list.canInvoke(older))
        XCTAssertTrue(list.canInvoke(newer))
        XCTAssertFalse(list.canInvoke(silent), "a DND-silenced notification was never on screen")
        XCTAssertTrue(list.canDismiss(newer))
        XCTAssertFalse(list.canDismiss(silent))

        list.markInactive(id: "200-2")
        XCTAssertFalse(list.canInvoke(newer))
        XCTAssertTrue(list.canInvoke(older), "the next one on screen becomes the newest")
    }

    func testNotificationWithoutAnActionIsNeverInvokable() {
        var list = HostNotificationList()
        let row = HostNotification(id: "100-1", app: "A", summary: "no action", body: "",
                                   timestamp: 100, hasAction: false, active: true)
        list.replace(with: [row])
        XCTAssertFalse(list.canInvoke(row))
        XCTAssertTrue(list.canDismiss(row))
    }

    func testActionAndDNDDocumentsDecode() throws {
        let action = try JSONDecoder().decode(HostNotificationActionResult.self, from: fixture("notification-action"))
        XCTAssertEqual(action.action, "dismiss")
        XCTAssertEqual(action.result, "ok")
        struct DND: Decodable { let dnd: Bool }
        XCTAssertFalse(try JSONDecoder().decode(DND.self, from: fixture("notifications-dnd")).dnd)
    }

    /// The id is the shell's own file name and becomes part of a route, so its
    /// shape is checked rather than trusted.
    func testOnlyAShellShapedIdBecomesARoute() {
        XCTAssertTrue(CompanionHostClient.isNotificationID("1789711988810-1"))
        XCTAssertTrue(CompanionHostClient.isNotificationID("1-52"))
        XCTAssertFalse(CompanionHostClient.isNotificationID("1789711988810-1:dismiss"))
        XCTAssertFalse(CompanionHostClient.isNotificationID("../dnd"))
        XCTAssertFalse(CompanionHostClient.isNotificationID("1789711988810"))
        XCTAssertFalse(CompanionHostClient.isNotificationID("17897119888101789711988810-1"))
        XCTAssertFalse(CompanionHostClient.isNotificationID(""))
    }

    /// The Panel holds what it can scroll; core keeps 500 and the shell keeps
    /// ten. Nothing here grows without a bound.
    func testTheListIsBounded() {
        var list = HostNotificationList()
        for index in 0..<(HostNotificationList.limit + 40) {
            list.post(HostNotification(id: "\(index)-1", app: "A", summary: "row \(index)", body: "",
                                       timestamp: index, hasAction: false, active: false))
        }
        XCTAssertEqual(list.rows.count, HostNotificationList.limit)
        XCTAssertEqual(list.rows.first?.id, "\(HostNotificationList.limit + 39)-1", "the newest survives")
    }
}
