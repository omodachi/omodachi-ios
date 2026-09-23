import XCTest
@testable import Omodachi

private actor CoveredRowTransport: ShortcutPanelTransport {
    var snapshot: ShortcutSnapshot
    private(set) var executions: [ShortcutExecutionRequest] = []
    init(_ snapshot: ShortcutSnapshot) { self.snapshot = snapshot }
    func list(context: ShortcutContext) async throws -> ShortcutSnapshot { snapshot }
    func execute(_ request: ShortcutExecutionRequest) async throws -> ShortcutExecutionResult {
        executions.append(request)
        return .init(status: .applied, message: "host ran it")
    }
}

/// REMOTE-2 item 5. A keybinding row the app's own GUI covers used to be listed,
/// enabled, hittable — and dropped by a bare `guard` inside `execute`. MERGE-1
/// §7.2 measured exactly that on `Omarchy menu`: "亮着、可点、什么都不发生、
/// 也不说话". UX-1 item B's rule is that lit and works mean the same thing, so a
/// row is now either executable or dimmed with a reason, and a covered row's
/// execution is the control that covers it, run on this device.
@MainActor final class ShortcutCoveredRowTests: XCTestCase {

    /// The host's own records, shortened: the two rows core publishes on the
    /// native route (`SUPER + SPACE` → `omarchy-menu toggle`, `SUPER + K` →
    /// `omarchy-menu-keybindings`), one workspace row and one plain host row.
    private func snapshot() throws -> ShortcutSnapshot {
        let json = #"""
        {"contract_revision":"omodachi.v1","revision":"cat-1","source":"hyprland","available":true,"reason":null,
         "items":[
          {"id":"menu","label":"Omarchy menu","shortcut_display":"SUPER + SPACE","order":1,"enabled":true,"disabled_reason":null,"action_ref":"ref.menu","requires_target":false},
          {"id":"keys","label":"Keybindings","shortcut_display":"SUPER + K","order":2,"enabled":true,"disabled_reason":null,"action_ref":"ref.keys","requires_target":false},
          {"id":"ws3","label":"Switch to workspace 3","shortcut_display":"SUPER + 3","order":3,"enabled":true,"disabled_reason":null,"action_ref":"ref.ws3","requires_target":false},
          {"id":"term","label":"Terminal","shortcut_display":"SUPER + RETURN","order":4,"enabled":true,"disabled_reason":null,"action_ref":"ref.term","requires_target":false}]}
        """#
        return try JSONDecoder().decode(ShortcutListDTO.self, from: Data(json.utf8)).snapshot()
    }

    private func store(_ snapshot: ShortcutSnapshot,
                       coverage: ShortcutGUICoverage) -> (ShortcutPanelStore, CoveredRowTransport, ShortcutContext) {
        let context = ShortcutContext(hostID: "omarchy", surface: .controller, stateRevision: 1, targetToken: "win")
        let transport = CoveredRowTransport(snapshot)
        return (ShortcutPanelStore(context: context, transport: transport, coverage: coverage), transport, context)
    }

    func testTheKeyCombinationResolvesToTheControlThatCoversIt() {
        XCTAssertEqual(ShortcutGUIMap.capability(forDisplay: "SUPER + SPACE"), .panel)
        XCTAssertEqual(ShortcutGUIMap.capability(forDisplay: "SUPER + K"), .keybindings)
        XCTAssertEqual(ShortcutGUIMap.capability(forDisplay: "SUPER + 3"), .workspace(3))
        XCTAssertEqual(ShortcutGUIMap.capability(forDisplay: "SUPER + 0"), .workspace(10))
        XCTAssertNil(ShortcutGUIMap.capability(forDisplay: "SUPER + RETURN"))
    }

    /// ARCH-1 §7 (1). **Two rows are this app's own, and only two.**
    ///
    /// `SUPER+SPACE` is panel ①'s menu half and `SUPER+K` is its other half, so
    /// pressing either row here opens a panel on this device — the host's own
    /// `omarchy-menu toggle` would open a menu on a desktop the user is looking
    /// at through a stream. Everything else travels, including the workspace
    /// rows, which used to be run against the bar's own squares: SHORTCUT-1
    /// makes the host run every binding the way the key itself would, and
    /// `SUPER+3` in this list has to mean what `SUPER+3` means.
    func testOnlyTheTwoPanelRowsRunHereAndEverythingElseTravels() async throws {
        let snapshot = try snapshot()
        let coverage = ShortcutGUICoverage.fromGUI(panelAvailable: true, keybindingsAvailable: true,
                                                   reachableWorkspaces: [3])
        let (store, transport, context) = self.store(snapshot, coverage: coverage)
        var performed: [ShortcutGUIMap.Capability] = []
        store.performLocally = { performed.append($0); return true }
        await store.refresh()

        // N-03 still hides the duplicates behind the footer; that is a listing
        // rule, not a greying rule, and it is untouched.
        XCTAssertEqual(store.model.visibleEntries(in: context).map(\.id), ["term"])
        XCTAssertEqual(store.model.coveredEntries(in: context).map(\.id), ["menu", "keys", "ws3"])

        store.model.showsCoveredEntries = true
        for entry in store.model.visibleEntries(in: context) where entry.id != "term" {
            XCTAssertNil(store.model.disabledReason(for: entry, context: context),
                         "\(entry.label) is greyed only when core says so")
            await store.execute(entry)
        }
        XCTAssertEqual(performed, [.panel, .keybindings], "the workspace row is not this app's")
        let sent = await transport.executions
        XCTAssertEqual(sent.map(\.actionRef), ["ref.ws3"], "it goes to the host, like the key would")
        XCTAssertEqual(store.model.notice, "host ran it")
    }

    /// ARCH-1 §7 (1). The client-side greying rules are gone: coverage, a
    /// missing focused window and a host that is busy no longer dim a row. What
    /// dims one is `enabled: false`, and the line it shows is core's own
    /// `disabled_reason`.
    func testARowIsGreyedOnlyWhenCoreSaysSo() async throws {
        let snapshot = try snapshot()
        let coverage = ShortcutGUICoverage(reachableActionRefs: ["ref.term"])
        let (store, _, context) = self.store(snapshot, coverage: coverage)
        await store.refresh()
        let terminal = try XCTUnwrap(snapshot.entries.first { $0.id == "term" })
        XCTAssertNil(store.model.disabledReason(for: terminal, context: context),
                     "covered by a bar entry is not a reason to grey it")

        // A row core itself refuses, under either contract.
        let refused = ShortcutEntry(id: "x", label: "Something", keys: "SUPER+X", order: 9,
                                    actionRef: "ref.x", enabled: false,
                                    disabledReason: "binding_adapter_unavailable")
        for contract in [ShortcutBindingContract.perAction, .universal] {
            store.model.contract = contract
            XCTAssertEqual(store.model.disabledReason(for: refused, context: context),
                           ShortcutPanelModel.explain("binding_adapter_unavailable"), "\(contract)")
        }
    }

    /// The adapter is the switch, and it is one line. Under `universal` a row
    /// core has not refused is live even when this client would once have
    /// greyed it — no action reference, a window it wants and does not have, a
    /// Remote surface between sessions.
    func testTheUniversalContractLeavesEveryUnrefusedRowLive() async throws {
        let snapshot = try snapshot()
        let (store, _, _) = self.store(snapshot, coverage: ShortcutGUICoverage())
        await store.refresh()
        let needsWindow = ShortcutEntry(id: "move", label: "Move window", keys: "SUPER+SHIFT+3",
                                        order: 8, actionRef: nil, enabled: true,
                                        disabledReason: nil, requiresTarget: true)
        let noTarget = ShortcutContext(hostID: "omarchy", surface: .controller, stateRevision: 1)
        store.model.contract = .perAction
        XCTAssertNotNil(store.model.disabledReason(for: needsWindow, context: noTarget),
                        "today: no reviewed adapter, so it cannot be sent from here")
        store.model.contract = .universal
        XCTAssertNil(store.model.disabledReason(for: needsWindow, context: noTarget),
                     "SHORTCUT-1: the host runs it, and says `no_focused_window` if it cannot")
    }

    /// A row covered only by a catalog reference the bar can invoke, with no
    /// key combination this app maps, has no control to run: it is dimmed with
    /// where the control is rather than left lit.
    func testARowWithNoLocalControlStillReachesTheHost() async throws {
        let snapshot = try snapshot()
        let coverage = ShortcutGUICoverage(reachableActionRefs: ["ref.term"])
        let (store, transport, context) = self.store(snapshot, coverage: coverage)
        store.performLocally = { _ in true }
        await store.refresh()
        let terminal = try XCTUnwrap(snapshot.entries.first { $0.id == "term" })
        // `SUPER + RETURN` maps to no control in this app, so the bar entry is
        // the coverage and the host is the only road. It is open, so the row is
        // not dimmed and the tap travels.
        XCTAssertNil(store.model.disabledReason(for: terminal, context: context))
        await store.execute(terminal)
        let sent = await transport.executions
        XCTAssertEqual(sent.map(\.actionRef), ["ref.term"])
    }
}
