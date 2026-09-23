import XCTest
@testable import Omodachi

/// ARCH-1 §7, against SHORTCUT-1's real shapes (core `43d2a4d`).
///
/// Core now runs every binding the way the key itself would — `exec`,
/// `hyprctl dispatch`, `eval` — so 222 of the host's 227 rows are `enabled` and
/// the five that are not carry a `disabled_reason_detail` saying why. Two
/// things follow for this client, and both are what this file pins:
///
/// * **a row is greyed only when core says so**, with core's own sentence on
///   it. Every client-side greying rule is gone: the GUI-coverage map, the
///   `requires_target` check, the "Remote is updating" guard;
/// * **what a row reports is what the host observed** — the compositor before
///   and after — rather than a sentence this client composed about a request it
///   only knows it sent.
@MainActor final class ShortcutContractTests: XCTestCase {

    /// The five rows core refuses, in the shape it refuses them: `enabled`
    /// false, a code, and a sentence about *this* record.
    func testARefusedRowShowsCoresOwnSentenceRatherThanOurGlossOnItsCode() throws {
        let json = #"""
        {"contract_revision":"omodachi.v1","revision":"r1","source":"hyprland","available":true,"reason":null,
         "items":[{"id":"copy","label":"Universal copy","shortcut_display":"SUPER + C","order":0,
                   "enabled":false,"disabled_reason":"binding_adapter_unavailable",
                   "disabled_reason_detail":"host record carries no executable binding: dispatcher=\"\" arg=\"\"",
                   "action_ref":null,"requires_target":false}]}
        """#
        let snapshot = try JSONDecoder().decode(ShortcutListDTO.self, from: Data(json.utf8)).snapshot()
        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertFalse(entry.enabled)
        XCTAssertEqual(entry.disabledReasonDetail,
                       #"host record carries no executable binding: dispatcher="" arg="""#)

        var model = ShortcutPanelModel()
        model.snapshot = snapshot
        let context = ShortcutContext(hostID: "omarchy", surface: .controller, stateRevision: 1)
        XCTAssertEqual(model.contract, .universal, "SHORTCUT-1 has landed")
        XCTAssertEqual(model.disabledReason(for: entry, context: context), entry.disabledReasonDetail,
                       "the host's sentence about this row, not our gloss on its code")
    }

    /// The other 222. Nothing this client used to grey greys them any more —
    /// not a window they want and do not have, not a bar entry that covers
    /// them, not a Remote surface between sessions.
    func testEveryRowCoreAcceptsIsLive() throws {
        let json = #"""
        {"contract_revision":"omodachi.v1","revision":"r1","source":"hyprland","available":true,"reason":null,
         "items":[{"id":"close","label":"Close window","shortcut_display":"SUPER + W","order":0,
                   "enabled":true,"disabled_reason":null,"disabled_reason_detail":null,
                   "action_ref":"omodachi.shortcut.close","requires_target":true},
                  {"id":"ws3","label":"Switch to workspace 3","shortcut_display":"SUPER + 3","order":1,
                   "enabled":true,"disabled_reason":null,"disabled_reason_detail":null,
                   "action_ref":"omodachi.shortcut.ws3","requires_target":false}]}
        """#
        let snapshot = try JSONDecoder().decode(ShortcutListDTO.self, from: Data(json.utf8)).snapshot()
        var model = ShortcutPanelModel()
        model.snapshot = snapshot
        // The bar covers workspace 3, and there is no focused window.
        model.coverage = .fromGUI(panelAvailable: true, keybindingsAvailable: true, reachableWorkspaces: [3])
        let noWindow = ShortcutContext(hostID: "omarchy", surface: .controller, stateRevision: 1)
        for entry in snapshot.entries {
            XCTAssertNil(model.disabledReason(for: entry, context: noWindow), entry.label)
        }
    }

    /// SHORTCUT-1's receipt, read the way the row reads it.
    func testTheRowSaysWhatTheHostObservedAndNothingWhenNothingMoved() throws {
        func observation(_ payload: String) throws -> ShortcutObservation {
            try JSONDecoder().decode(ShortcutObservation.self, from: Data(payload.utf8))
        }
        let moved = try observation(#"""
        {"kind":"eval",
         "before":{"workspace":{"id":2,"name":"2","monitor":"m"},"window":null},
         "after":{"workspace":{"id":3,"name":"3","monitor":"m"},"window":null},
         "changed":true}
        """#)
        XCTAssertEqual(moved.summary, Strings.keybindingsNowOnWorkspace("3"))

        let focused = try observation(#"""
        {"kind":"dispatch",
         "before":{"workspace":{"id":3,"name":"3","monitor":"m"},
                   "window":{"address":"0x1","app_id":"kitty","fullscreen":0,"floating":false,"workspace_id":3}},
         "after":{"workspace":{"id":3,"name":"3","monitor":"m"},
                  "window":{"address":"0x2","app_id":"chromium","fullscreen":0,"floating":false,"workspace_id":3}},
         "changed":true}
        """#)
        XCTAssertEqual(focused.summary, Strings.keybindingsNowFocused("chromium"))

        // `changed: false` is the honest answer for a binding that ran and
        // moved nothing — a workspace switch to the workspace you are on. The
        // row says nothing rather than claiming something happened.
        let still = try observation(#"""
        {"kind":"eval",
         "before":{"workspace":{"id":3,"name":"3","monitor":"m"},"window":null},
         "after":{"workspace":{"id":3,"name":"3","monitor":"m"},"window":null},
         "changed":false}
        """#)
        XCTAssertNil(still.summary)
    }

    /// The whole action result, as core sends it, decoded by the client that
    /// has to act on two of its codes.
    func testTheActionResultCarriesTheReceiptAndTheCode() throws {
        let json = #"""
        {"contract_revision":"omodachi.v1","request_id":"r","entry_id":"omodachi.shortcut.ws3",
         "status":"accepted","code":"no_focused_window",
         "observed":{"kind":"eval",
                     "before":{"workspace":{"id":3,"name":"3","monitor":"m"},"window":null},
                     "after":{"workspace":{"id":3,"name":"3","monitor":"m"},"window":null},
                     "changed":false}}
        """#
        let response = try JSONDecoder().decode(CompanionActionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.code, "no_focused_window")
        XCTAssertEqual(response.observed?.changed, false)
        XCTAssertEqual(response.observed?.kind, "eval")
    }

    /// ARCH-1 §7 (1): two rows stay on this device, and they are the two whose
    /// destination *is* this device.
    func testOnlyTheTwoPanelRowsAreLocal() {
        XCTAssertEqual(ShortcutGUIMap.localCapability(.panel), .panel)
        XCTAssertEqual(ShortcutGUIMap.localCapability(.keybindings), .keybindings)
        XCTAssertNil(ShortcutGUIMap.localCapability(.workspace(3)))
        XCTAssertEqual(ShortcutGUIMap.capability(forDisplay: "SUPER + SPACE"), .panel)
        XCTAssertEqual(ShortcutGUIMap.capability(forDisplay: "SUPER + K"), .keybindings)
    }
}
