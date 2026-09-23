import XCTest
@testable import Omodachi

/// MENU-3. How a row the host has evaluated is drawn.
///
/// Leo's menu had 57 rows the host marked `condition_adapter_unavailable` —
/// every Install/Remove toolchain, Suspend, Hibernate, Stop screenrecording —
/// and the panel drew each of them `不可用`. The host now runs every `when` in
/// bash; what the client owes it is to draw the four answers the way the
/// desktop menu does: false hides, true and `unknown` are usable, a true
/// `disabled` is grey with the host's reason, and the check mark is the value.
@MainActor final class MenuConditionTests: XCTestCase {
    private func row(_ id: String, parent: String = "install", visible: String, when: String,
                     checked: String = #"{"status": "available", "value": null}"#,
                     checkedState: String = "null", ready: Bool = true,
                     readinessReason: String? = nil, disabled: String? = nil) -> String {
        let reason = readinessReason.map { #", "readiness_reason": "\#($0)""# } ?? ""
        let disabledField = disabled.map { #", "disabled": \#($0)"# } ?? ""
        return #"""
        {"id": "\#(id)", "parent_id": "\#(parent)", "label": "\#(id)", "kind": "action",
         "visible": \#(visible), "checked_state": \#(checkedState),
         "conditions": {"when": \#(when), "checked": \#(checked)\#(disabledField)},
         "route": {"route": "host", "supported": true, "ready": \#(ready)\#(reason)}}
        """#
    }

    private func build(_ rows: [String]) throws -> [MenuItem] {
        let parent = #"{"id": "install", "parent_id": "root", "label": "Install", "kind": "menu", "visible": true}"#
        let json = #"{"revision": "r", "entries": [\#(([parent] + rows).joined(separator: ","))]}"#
        let catalog = try JSONDecoder().decode(HostCatalogDTO.self, from: Data(json.utf8))
        return HostMenu.build(from: catalog.entries).flatMap(\.all)
    }

    func testAnUnknownWhenIsDrawnAndUsable() throws {
        let items = try build([row("install.ruby", visible: "null",
                                   when: #"{"status": "unknown", "value": null, "reason": "condition_timeout"}"#)])
        let ruby = try XCTUnwrap(items.first { $0.id == "install.ruby" })
        XCTAssertTrue(ruby.enabled, "unknown is not unavailable: the host decides what the tap does")
        XCTAssertNil(ruby.disabledReason)
    }

    func testFalseHidesTrueShowsAndNoEvaluatorIsStillGrey() throws {
        let items = try build([
            row("install.go", visible: "false", when: #"{"status": "available", "value": false}"#),
            row("install.zig", visible: "true", when: #"{"status": "available", "value": true}"#),
            row("install.old", visible: "null",
                when: #"{"status": "unavailable", "value": null, "reason": "condition_adapter_unavailable"}"#),
        ])
        XCTAssertNil(items.first { $0.id == "install.go" }, "a false `when` hides the row, as on the host")
        XCTAssertEqual(items.first { $0.id == "install.zig" }?.enabled, true)
        XCTAssertEqual(items.first { $0.id == "install.old" }?.enabled, false,
                       "a condition the host cannot evaluate at all is refused there too")
    }

    func testDisabledIsGreyWithTheHostsReason() throws {
        let items = try build([row("install.locked", visible: "true", when: #"{"status": "available", "value": true}"#,
                                   ready: false, readinessReason: "condition_disabled",
                                   disabled: #"{"status": "available", "value": true}"#)])
        let locked = try XCTUnwrap(items.first { $0.id == "install.locked" })
        XCTAssertFalse(locked.enabled)
        XCTAssertEqual(locked.disabledReason, "condition_disabled")
        XCTAssertEqual(ReasonText.message("condition_disabled", domain: .host), Strings.reasonConditionDisabled)
    }

    func testTheCheckMarkFollowsTheValue() throws {
        let items = try build([
            row("setup.a", visible: "true", when: #"{"status": "available", "value": true}"#,
                checked: #"{"status": "available", "value": true}"#, checkedState: "true"),
            row("setup.b", visible: "true", when: #"{"status": "available", "value": true}"#,
                checked: #"{"status": "unknown", "value": null, "reason": "condition_timeout"}"#),
        ])
        XCTAssertEqual(items.first { $0.id == "setup.a" }?.checked, true)
        XCTAssertNil(items.first { $0.id == "setup.b" }?.checked, "no answer draws no mark")
    }

    func testEveryNewReasonHasASentenceInBothLanguages() {
        for code in ["condition_disabled", "condition_timeout", "condition_spawn_failed", "condition_pending"] {
            XCTAssertEqual(ReasonText.knownCodes[code], .host, code)
            XCTAssertNotNil(ReasonText.shared(code), code)
        }
    }
}
