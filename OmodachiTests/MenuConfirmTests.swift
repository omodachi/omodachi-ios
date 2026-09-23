import XCTest
@testable import Omodachi

/// MENU-4. The host now runs every Omarchy menu row, and marks the ones that
/// change the machine `confirm` (Study 04 A-68). What the client owes it: read
/// the mark, arm the row on the first tap, send on the second inside two
/// seconds, and say in words why a row the host will not run is grey.
@MainActor final class MenuConfirmTests: XCTestCase {
    private func build(_ route: String, id: String = "system.shutdown") throws -> MenuItem {
        let parent = #"{"id": "system", "parent_id": "root", "label": "System", "kind": "menu", "visible": true}"#
        let row = #"""
        {"id": "\#(id)", "parent_id": "system", "label": "\#(id)", "kind": "action", "visible": true,
         "conditions": {"when": {"status": "available", "value": true}, "checked": {"status": "available", "value": null}},
         "route": \#(route)}
        """#
        let json = #"{"revision": "r", "entries": [\#(parent), \#(row)]}"#
        let catalog = try JSONDecoder().decode(HostCatalogDTO.self, from: Data(json.utf8))
        return try XCTUnwrap(HostMenu.build(from: catalog.entries).flatMap(\.all).first { $0.id == id })
    }

    func testTheHostsConfirmMarkIsRead() throws {
        let shutdown = try build(#"{"route": "host", "supported": true, "ready": true, "confirm": true,"#
                                 + #" "argv": ["omodachi-menu-action", "system.shutdown"]}"#)
        XCTAssertTrue(shutdown.enabled)
        XCTAssertTrue(shutdown.confirm)
        let about = try build(#"{"route": "host", "supported": true, "ready": true}"#, id: "about")
        XCTAssertFalse(about.confirm, "no mark means no second tap")
    }

    func testAGreyRowTheHostWillNotRunSaysWhy() throws {
        for reason in ["menu_action_needs_terminal", "menu_action_empty"] {
            let row = try build(#"{"route": "host", "supported": false, "ready": false, "readiness_reason": "\#(reason)"}"#)
            XCTAssertFalse(row.enabled)
            XCTAssertEqual(row.disabledReason, reason)
            XCTAssertNotEqual(ReasonText.message(reason, domain: .host), Strings.reasonHostUnknown(reason))
        }
        let unregistered = try build(#"{"route": "host", "supported": false, "ready": false,"#
                                     + #" "readiness_reason": "route adapter is not registered"}"#)
        XCTAssertNil(unregistered.disabledReason, "a sentence core never meant for a screen stays 不可用")
    }

    func testTheFirstTapArmsAndTheSecondSends() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = ConfirmGate.tap("system.shutdown", confirm: true, armed: nil, now: now)
        XCTAssertFalse(first.send)
        XCTAssertEqual(first.armed, ConfirmArm(entryID: "system.shutdown", until: now.addingTimeInterval(2)))
        let second = ConfirmGate.tap("system.shutdown", confirm: true, armed: first.armed, now: now.addingTimeInterval(1.5))
        XCTAssertTrue(second.send)
        XCTAssertNil(second.armed)
    }

    func testTheArmLapsesAfterTwoSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let armed = ConfirmGate.tap("remove.theme", confirm: true, armed: nil, now: now).armed
        let late = ConfirmGate.tap("remove.theme", confirm: true, armed: armed, now: now.addingTimeInterval(2.01))
        XCTAssertFalse(late.send, "a tap after the window is a first tap again")
        XCTAssertEqual(late.armed?.entryID, "remove.theme")
    }

    func testAnotherRowPutsTheQuestionAway() {
        let now = Date(timeIntervalSince1970: 1_000)
        let armed = ConfirmGate.tap("system.reboot", confirm: true, armed: nil, now: now).armed
        let other = ConfirmGate.tap("about", confirm: false, armed: armed, now: now.addingTimeInterval(0.5))
        XCTAssertTrue(other.send)
        XCTAssertNil(other.armed)
        let sibling = ConfirmGate.tap("system.shutdown", confirm: true, armed: armed, now: now.addingTimeInterval(0.5))
        XCTAssertFalse(sibling.send, "arming Reboot never lets Shutdown through")
        XCTAssertEqual(sibling.armed?.entryID, "system.shutdown")
    }

    func testARowWithoutTheMarkIsSentOnTheFirstTap() {
        XCTAssertTrue(ConfirmGate.tap("about", confirm: false, armed: nil).send)
    }

    func testTheStoreArmsAndDisarmsOnItsOwn() async throws {
        let suite = "omodachi.menu-4.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = HomeStore(defaults: defaults, autoConnect: false)
        let row = MenuItem(id: "system.lock", label: "Lock", confirm: true)
        let now = Date()
        XCTAssertFalse(home.passesConfirm(row, now: now))
        XCTAssertEqual(home.armedConfirm?.entryID, "system.lock")
        XCTAssertTrue(home.passesConfirm(row, now: now.addingTimeInterval(0.5)))
        XCTAssertNil(home.armedConfirm)
        // Armed and left alone, it goes away by itself.
        XCTAssertFalse(home.passesConfirm(row))
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertNil(home.armedConfirm)
    }

    func testASubmenuWithNothingVisibleIsLeftOutUnlessAProviderFillsIt() throws {
        let rows = [
            #"{"id": "remove", "parent_id": "root", "label": "Remove", "kind": "menu", "visible": true}"#,
            #"{"id": "remove.gaming", "parent_id": "remove", "label": "Gaming", "kind": "menu", "visible": true}"#,
            #"{"id": "remove.gaming.steam", "parent_id": "remove.gaming", "label": "Steam", "kind": "action", "visible": false}"#,
            #"{"id": "remove.theme", "parent_id": "remove", "label": "Theme", "kind": "action", "visible": true, "route": {"route": "host", "supported": true, "ready": true, "confirm": true}}"#,
            #"{"id": "apps", "parent_id": "root", "label": "Apps", "kind": "menu", "visible": true, "provider_state": {"status": "unavailable"}}"#,
        ]
        let json = #"{"revision": "r", "entries": [\#(rows.joined(separator: ","))]}"#
        let catalog = try JSONDecoder().decode(HostCatalogDTO.self, from: Data(json.utf8))
        let items = HostMenu.build(from: catalog.entries).flatMap(\.all)
        XCTAssertNil(items.first { $0.id == "remove.gaming" }, "Omarchy's isVisible leaves an empty submenu out")
        XCTAssertNotNil(items.first { $0.id == "remove" })
        XCTAssertNotNil(items.first { $0.id == "apps" }, "a provider's submenu stays while it is empty")
    }

    func testTheNewReasonsHaveSentences() {
        for code in ["menu_action_needs_terminal", "menu_action_empty", "menu_row_not_invocable",
                     "graphical_session_unavailable"] {
            XCTAssertNotNil(ReasonText.shared(code), code)
            XCTAssertEqual(ReasonText.knownCodes[code], .host, code)
        }
        XCTAssertEqual(HomeStore.rowFailure(code: "executable_missing"), Strings.reasonExecutableMissing)
    }
}
