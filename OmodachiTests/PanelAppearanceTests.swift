import CoreText
import SwiftUI
import XCTest
@testable import Omodachi

/// SPEC-F2 §7.7. Four things have to hold without a host in the room: the theme
/// document decodes into the values the app paints with, a host font file
/// actually registers, the keybinding de-duplication hides exactly what the GUI
/// covers, and the layout policy answers the same way for every width the
/// study drew — including the three iPhone Duo geometries.
@MainActor
final class PanelAppearanceTests: XCTestCase {
    private func fixtures() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["OMODACHI_CORE_FIXTURES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
    }

    // MARK: - Theme

    func testTheHostThemeDecodesIntoEveryValueThePanelPaintsWith() throws {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("theme.json"))
        let theme = try JSONDecoder().decode(HostTheme.self, from: data)

        XCTAssertTrue(theme.isComplete, "The fixture carries all 25 roles and the seven always-present sections.")
        XCTAssertEqual(theme.colors.count, ThemeColorRole.allCases.count)
        XCTAssertEqual(theme.rgb(.accent).0, Double(0x5a) / 255, accuracy: 0.001)

        // The four state alphas A-08 names, straight out of [controls].
        XCTAssertEqual(theme.alpha("controls", "normal-fill-alpha"), 0.04, accuracy: 0.0001)
        XCTAssertEqual(theme.alpha("controls", "hover-cursor-fill-alpha"), 0.08, accuracy: 0.0001)
        XCTAssertEqual(theme.alpha("controls", "selected-fill-alpha"), 0.18, accuracy: 0.0001)
        XCTAssertEqual(theme.alpha("controls", "pressed-fill-alpha"), 0.22, accuracy: 0.0001)
        XCTAssertEqual(theme.alpha("controls", "selection-fill-alpha"), 0.35, accuracy: 0.0001)
        // The scrim the research corrected the study's guessed 0.35 to.
        XCTAssertEqual(theme.alpha("menu", "scrim-alpha"), 0.5, accuracy: 0.0001)
        // D-01's two border numbers, from two different sections.
        XCTAssertEqual(theme.shellNumber("controls", "normal-border-width"), 1)
        XCTAssertEqual(theme.shellNumber("popups", "border-width", fallback: 2), 2)
        // The geometry and type tokens the rows and the bar are measured with.
        XCTAssertEqual(theme.spacing("control-height"), 28)
        XCTAssertEqual(theme.spacing("row-padding-x"), 12)
        XCTAssertEqual(theme.fontStep("body"), 12)
        XCTAssertEqual(theme.fontStep("heading"), 16)
        XCTAssertEqual(theme.shellNumber("bar", "size-horizontal"), 26)
        XCTAssertEqual(theme.shellNumber("bar", "size-vertical"), 28)
    }

    /// A theme may replace `shell.toml` wholesale or override one section, so a
    /// missing key falls to Omarchy's own template default — never to a number
    /// chosen here.
    func testAMissingShellSectionFallsBackToOmarchysOwnTemplateDefaults() throws {
        let partial = HostTheme(name: "partial", mode: "dark",
                                colors: FallbackTheme.colors, shell: ["bar": [:]])
        XCTAssertEqual(partial.alpha("controls", "pressed-fill-alpha"), 0.22, accuracy: 0.0001)
        XCTAssertEqual(partial.spacing("panel-padding"), 18)
        XCTAssertEqual(partial.fontStep("icon-large"), 18)
    }

    func testGradientAndAlphaFormsResolveToAPaintableColour() throws {
        XCTAssertNotNil(HostTheme.parse(hex: "#81a1c1"))
        XCTAssertNotNil(HostTheme.parse(hex: "#81a1c1ff"))
        // `[popups] border = "hyprland.active-border"` resolves server-side to a
        // Hyprland gradient; the first stop is what a flat border can show.
        let gradient = try XCTUnwrap(HostTheme.parse(hex: "rgba(129,161,193,1.0) rgba(136,192,208,1.0) 45deg"))
        XCTAssertEqual(gradient.0, Double(129) / 255, accuracy: 0.001)
        XCTAssertNil(HostTheme.parse(hex: "not-a-colour"))
    }

    /// Losing the network must not lose the host's look, and a device that has
    /// never met a host must still be paintable.
    func testTheRuntimePrefersHostThenCacheThenTheBundledPlaceholder() throws {
        let suite = "omodachi.tests.theme.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let cold = ThemeRuntime(defaults: defaults)
        XCTAssertEqual(cold.origin, .bundled)
        XCTAssertEqual(cold.theme.name, FallbackTheme.theme.name)

        let data = try Data(contentsOf: fixtures().appendingPathComponent("theme.json"))
        let host = try JSONDecoder().decode(HostTheme.self, from: data)
        cold.apply(host, origin: .host)
        XCTAssertEqual(cold.origin, .host)
        XCTAssertEqual(cold.theme.name, "fixture-slate")

        let restarted = ThemeRuntime(defaults: defaults)
        XCTAssertEqual(restarted.origin, .cache)
        XCTAssertEqual(restarted.theme, host, "The cache must round-trip through the same decoder.")

        // A half-built document is refused rather than painted.
        restarted.apply(HostTheme(name: "broken", mode: "dark", colors: [:], shell: [:]))
        XCTAssertEqual(restarted.theme, host)
    }

    // MARK: - Fonts

    func testTheFontListingDecodesWithItsFallbackChain() throws {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("fonts.json"))
        let listing = try JSONDecoder().decode(HostFontListDTO.self, from: data)
        XCTAssertEqual(listing.fonts.prefix(3).map(\.id), ["mono-regular", "mono-bold", "icons"])
        XCTAssertTrue(listing.fonts.allSatisfy(\.isKnown))
        XCTAssertEqual(listing.fonts.first(where: { $0.id == "icons" })?.family, "omarchy")
        // TERM-1. The chain is ordered and each link names the row its bytes
        // come from; a link may point at a row the mono role already published.
        let chain = try XCTUnwrap(listing.fallbackChain)
        XCTAssertEqual(chain.map(\.coverage), ["symbols", "symbols", "cjk", "emoji"])
        XCTAssertEqual(chain.map(\.font), ["fallback-symbols", "mono-regular", "fallback-cjk", "fallback-emoji"])
        XCTAssertEqual(chain.first?.probes, ["U+E0B0", "U+E615", "U+F07B", "U+F0249"])
        for link in chain {
            guard let id = link.font else { continue }
            XCTAssertNotNil(listing.fonts.first { $0.id == id }, "every link names a row that exists")
        }
    }

    /// A host still running core from before TERM-1 publishes no chain at all,
    /// which decodes as no chain rather than as a decoding failure — the whole
    /// listing is what carries the host's fonts, and losing it would lose them.
    func testAListingWithoutAChainStillDecodes() throws {
        let json = Data("""
        {"revision": 3, "fonts": [{"id": "icons", "role": "icons", "family": "omarchy",
          "sha256": "\(String(repeating: "a", count: 64))", "bytes": 5412, "content_type": "font/ttf"}]}
        """.utf8)
        let listing = try JSONDecoder().decode(HostFontListDTO.self, from: json)
        XCTAssertNil(listing.fallbackChain)
        XCTAssertTrue(listing.fonts[0].isKnown)
    }

    /// The registration path itself: bytes in, a CoreText family name out, and
    /// the same file cached by digest so a second launch registers off disk.
    func testAHostFontFileCachesByDigestAndRegistersWithCoreText() async throws {
        // These unit tests are hosted by the app, so `Bundle.main` is the app
        // bundle the font actually ships in.
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf")
            ?? Bundle(for: Self.self).url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf"),
                                    "The symbols-only fallback ships in the app bundle.")
        let bytes = try Data(contentsOf: bundled)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omodachi-fonts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let installer = HostFontInstaller(directory: directory)
        let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let cachedBefore = await installer.hasCached(id: "icons", sha256: digest)
        XCTAssertFalse(cachedBefore)
        let url = try await installer.store(bytes, id: "icons", sha256: digest)
        let cachedAfter = await installer.hasCached(id: "icons", sha256: digest)
        XCTAssertTrue(cachedAfter, "A stored file is found again by its digest, without a second download.")

        let family = await installer.register(url, id: "icons")
        XCTAssertEqual(family, "Symbols Nerd Font Mono")
        await installer.unregister(id: "icons")
    }

    /// `docs/fonts.md`: the host monospace is whatever `fc-match monospace`
    /// resolves to and is often not a Nerd Font — this host answers Nimbus Mono
    /// PS. The probe has to tell the two apart, or the app would draw tofu.
    func testTheNerdGlyphProbeSeparatesAPatchedFamilyFromAPlainOne() {
        XCTAssertTrue(HostFontInstaller.hasNerdGlyphs(family: HostFontSet.bundledSymbols))
        XCTAssertFalse(HostFontInstaller.hasNerdGlyphs(family: "Helvetica"))
    }

    func testTheIconFamilyFollowsTheRowsOwnFontAndTheHostsCapability() {
        var set = HostFontSet()
        set.mono = "Nimbus Mono PS"
        set.icons = "omarchy"
        set.monoHasNerdGlyphs = false
        // A row tagged "omarchy" always uses the host's own icon file.
        XCTAssertEqual(set.iconFamily(iconFont: "omarchy"), "omarchy")
        // A Nerd Font code point on a non-Nerd host falls back to the bundle.
        XCTAssertEqual(set.iconFamily(iconFont: ""), HostFontSet.bundledSymbols)
        set.monoHasNerdGlyphs = true
        XCTAssertEqual(set.iconFamily(iconFont: nil), "Nimbus Mono PS")
    }

    // MARK: - Keybinding de-duplication

    func testTheGUIMapHidesExactlyTheBindingsTheBarAndPanelAlreadyOffer() {
        XCTAssertEqual(ShortcutGUIMap.normalize("SUPER SHIFT + 3"), "SUPER+SHIFT+3")
        XCTAssertEqual(ShortcutGUIMap.normalize("SUPER + 0"), "SUPER+0")
        XCTAssertEqual(ShortcutGUIMap.capability(forDisplay: "SUPER + 0"), .workspace(10))
        XCTAssertEqual(ShortcutGUIMap.capability(forDisplay: "SUPER + SPACE"), .panel)
        XCTAssertEqual(ShortcutGUIMap.capability(forDisplay: "SUPER + K"), .keybindings)
        // A modifier away is a different binding and stays listed.
        XCTAssertNil(ShortcutGUIMap.capability(forDisplay: "SUPER SHIFT + 3"))
        XCTAssertNil(ShortcutGUIMap.capability(forDisplay: "SUPER + F"))

        let rows = Self.hostRows
        let coverage = ShortcutGUICoverage.fromGUI(panelAvailable: true, keybindingsAvailable: true,
                                                   reachableWorkspaces: Set(1...10))
        var model = ShortcutPanelModel()
        model.snapshot = .init(revision: "r", source: "hyprland", entries: rows)
        model.coverage = coverage
        let context = ShortcutContext(hostID: "https://host", surface: .controller)

        let hidden = model.coveredEntries(in: context)
        XCTAssertEqual(Set(hidden.map(\.keys)),
                       Set(["SUPER + SPACE", "SUPER + K"] + (1...9).map { "SUPER + \($0)" } + ["SUPER + 0"]),
                       "Twelve rows: ten workspaces, the menu and this list.")
        XCTAssertEqual(hidden.count, 12)
        XCTAssertFalse(model.visibleEntries(in: context).contains { $0.keys == "SUPER + 1" })
        XCTAssertTrue(model.visibleEntries(in: context).contains { $0.keys == "SUPER + F" },
                      "Full screen has no GUI entry and must stay in the list.")

        // Expanding the footer puts them back in place, in host order.
        model.showsCoveredEntries = true
        XCTAssertEqual(model.visibleEntries(in: context).count, rows.count)
    }

    /// The map hides a row only while the control it duplicates is on screen.
    /// With no workspaces drawn — no host, or a Remote session holding them —
    /// this list is the only way to reach them, so they come back.
    func testWorkspaceBindingsReturnWhenTheBarIsNotDrawingThoseSquares() {
        var model = ShortcutPanelModel()
        model.snapshot = .init(revision: "r", source: "hyprland", entries: Self.hostRows)
        model.coverage = .fromGUI(panelAvailable: true, keybindingsAvailable: true,
                                  reachableWorkspaces: [1, 2, 3, 4, 5])
        let context = ShortcutContext(hostID: "https://host", surface: .controller)
        XCTAssertEqual(model.coveredEntries(in: context).count, 7, "Five squares plus the menu and this list.")
        XCTAssertTrue(model.visibleEntries(in: context).contains { $0.keys == "SUPER + 6" })

        model.coverage = .fromGUI(panelAvailable: false, keybindingsAvailable: true, reachableWorkspaces: [])
        XCTAssertEqual(model.coveredEntries(in: context).count, 1)
        XCTAssertTrue(model.visibleEntries(in: context).contains { $0.keys == "SUPER + SPACE" })
    }

    // MARK: - Workspace collection

    /// N-16 / `Workspaces.qml 20–31`: the fixed five plus whatever else is
    /// live, not a row of ten and not only the occupied ones.
    func testTheBarDrawsTheOfficialWorkspaceCollection() {
        let rows = [
            BarWorkspace(id: 1, active: true, occupied: false, persistent: true, canSelect: true, canMoveFocusedWindow: false),
            BarWorkspace(id: 4, active: false, occupied: false, persistent: true, canSelect: true, canMoveFocusedWindow: false),
            BarWorkspace(id: 6, active: false, occupied: true, persistent: false, canSelect: true, canMoveFocusedWindow: false),
            BarWorkspace(id: 7, active: false, occupied: false, persistent: false, canSelect: true, canMoveFocusedWindow: false),
            // No compositor reading: not a claim of emptiness, so it stays.
            BarWorkspace(id: 9, active: false, occupied: nil, persistent: false, canSelect: true, canMoveFocusedWindow: false),
        ]
        XCTAssertEqual(NativeWorkspacePolicy.visible(rows).map(\.id), [1, 4, 6, 9])
        XCTAssertEqual(NativeWorkspacePolicy.label(10), "0")
        XCTAssertEqual(NativeWorkspacePolicy.label(3), "3")
    }

    /// Only modules with a real `state.*` field behind them are drawn, and the
    /// Panel entry leads whatever the host's widget order is.
    func testTheBarPlanSkipsModulesWithNoStateBehindThem() {
        let plan = NativeBarModule.plan(
            leading: ["unsupported", "workspaces"],
            centre: ["unsupported", "clock", "unsupported"],
            trailing: ["system_tray", "agent_usage", "panel", "focused_window"])
        XCTAssertEqual(plan, [.panel, .workspaces, .clock, .focus])
        XCTAssertNil(NativeBarModule.module(for: "system_tray"))
        XCTAssertNil(NativeBarModule.module(for: "agent_usage"))
    }

    // MARK: - Layout

    /// A-54 rev 5, for every width Study 04 draws. The old `PanelLayoutPolicy`
    /// answered three questions — two columns, sidebar, overlay width — and
    /// A-55 deleted two of them: there is one panel in one block, so the only
    /// layout question left is whether panel ① puts its two halves side by side.
    ///
    /// rev 5's judgement is **orientation and width**, not orientation alone.
    /// `UIRequiresFullScreen=false` means a landscape window can be 320 points
    /// wide under Stage Manager, and a pure-orientation rule would squeeze two
    /// truncated columns into it.
    func testPanelOneSplitsOnlyWhenItIsLandscapeAndWideEnough() {
        let bar = NativeBarMetrics.thickness
        XCTAssertEqual(PanelMeasure.sideBySide, 360 + 5 + 420)
        XCTAssertEqual(PanelMeasure.menuColumn, 360)
        XCTAssertEqual(PanelMeasure.keybindingsColumn, 420)

        // iPad Pro 11 landscape, bar on top: side by side.
        XCTAssertTrue(PanelMeasure.sideBySide(landscape: true, width: 1194))
        // iPad Pro 11 portrait is 834 − 44 = 790, five points over the 785 —
        // and it still folds, because portrait always folds. Turning the device
        // has to do the same thing every time.
        XCTAssertFalse(PanelMeasure.sideBySide(landscape: false, width: 834 - bar))
        // iPhone: landscape splits (852 − 0 ≥ 785), portrait folds.
        XCTAssertTrue(PanelMeasure.sideBySide(landscape: true, width: 852))
        XCTAssertFalse(PanelMeasure.sideBySide(landscape: false, width: 393 - bar))
        // Duo outer 466 − 44 = 422 is portrait and narrow; Duo inner landscape
        // 890 clears the 785 (Study 04 rev 5's new board).
        XCTAssertFalse(PanelMeasure.sideBySide(landscape: false, width: 466 - bar))
        XCTAssertTrue(PanelMeasure.sideBySide(landscape: true, width: 890))
        // Stage Manager, 1/3 of an iPad: landscape, 320 − 44 = 276.
        XCTAssertFalse(PanelMeasure.sideBySide(landscape: true, width: 320 - bar))
    }

    /// A-56 rev 4b. The narrow column is the one that stacks: two Remote cards
    /// above each other, a setting's label above its control, a session card's
    /// buttons wrapped. Row heights and hit areas do not change — only direction.
    func testTheNarrowColumnStacksRatherThanShrinking() {
        XCTAssertTrue(PanelMeasure.isNarrow(349), "iPhone portrait")
        XCTAssertTrue(PanelMeasure.isNarrow(422), "Duo outer")
        XCTAssertFalse(PanelMeasure.isNarrow(470))
        XCTAssertFalse(PanelMeasure.isNarrow(760))
        XCTAssertFalse(PanelMeasure.isNarrow(0), "an unmeasured column is not narrow")
        XCTAssertEqual(PanelMeasure.column, 760, "A-23's body measure, inherited")
    }

    /// A-59 rev 5. The overlay over the picture is the same bar and the same
    /// panel area as off it — not a narrower column beside a strip, because
    /// A-40 deleted the strip and A-55 deleted the column. So the width it gets
    /// is the window minus the bar, and panel ① answers the same question about
    /// it that it answers anywhere else.
    func testTheRemoteOverlayIsTheSamePanelAreaAsEverywhereElse() {
        let bar = NativeBarMetrics.thickness
        XCTAssertEqual(SafeAreaLayoutPolicy.panelAreaWidth(edge: .left, size: CGSize(width: 834, height: 1194)),
                       834 - bar)
        XCTAssertEqual(SafeAreaLayoutPolicy.panelAreaWidth(edge: .top, size: CGSize(width: 1194, height: 834)),
                       1194, "a horizontal bar takes height, not width")
        // iPad portrait under Remote: 790, so ① folds — the same answer it
        // gives with no session at all.
        XCTAssertFalse(PanelMeasure.sideBySide(landscape: false, width: 834 - bar))
        // iPad landscape under Remote: 1194, so ① splits.
        XCTAssertTrue(PanelMeasure.sideBySide(landscape: true, width: 1194))
    }

    /// A-02: the bar is on a long edge, and a square viewport keeps whichever
    /// edge it had rather than flipping under the user's finger.
    func testTheBarStaysOnALongEdgeForEveryViewport() {
        var placement = NativeBarPlacement()
        placement.update(width: 393, height: 852, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .left)
        placement.update(width: 852, height: 393, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .top)
        // Duo: outer portrait, inner landscape, inner portrait.
        placement.update(width: 466, height: 678, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .left)
        placement.update(width: 890, height: 626, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .top)
        placement.update(width: 626, height: 890, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .left)
        // A keyboard or a Panel shrinking the visible part is not a rotation.
        placement.update(width: 890, height: 200, reason: .temporaryOcclusion)
        XCTAssertEqual(placement.edge, .left)
        XCTAssertTrue(NativeBarMetrics.isVertical(.right))
        XCTAssertFalse(NativeBarMetrics.isVertical(.bottom))
    }

    // MARK: - The host's recall

    /// `panel.summon` is the only event this client acts on rather than
    /// treating as "the snapshot is stale" (`service.py:763-778`).
    func testThePanelSummonEventDecodesItsDestination() throws {
        let frame = #"{"seq":42,"event_id":"evt_00000042","type":"panel.summon","payload":{"session_id":"rs_abc123","revision":6,"expires_in_seconds":900,"view":"keybindings"}}"#
        let event = try CompanionHostClient.decodeEvent(Data(frame.utf8))
        XCTAssertEqual(event.type, "panel.summon")
        XCTAssertEqual(event.panelSummon?.view, .keybindings)
        XCTAssertEqual(event.panelSummon?.sessionID, "rs_abc123")
        XCTAssertEqual(event.panelSummon?.revision, 6)
        XCTAssertFalse(event.needsResync)

        // An unknown destination is not silently downgraded to the root panel.
        let unknown = #"{"seq":43,"event_id":"evt_00000043","type":"panel.summon","payload":{"session_id":"rs_abc123","revision":6,"view":"nowhere"}}"#
        XCTAssertNil(try CompanionHostClient.decodeEvent(Data(unknown.utf8)).panelSummon)
        // Neither is a session id that is not one.
        let bogus = #"{"seq":44,"event_id":"evt_00000044","type":"panel.summon","payload":{"session_id":"../v1","revision":6,"view":"overview"}}"#
        XCTAssertNil(try CompanionHostClient.decodeEvent(Data(bogus.utf8)).panelSummon)
    }

    /// A-59 rev 5. The recall names where it lands, and asking for the same
    /// place twice puts it away — the toggle core's stateless push cannot do.
    @MainActor func testARecallNamesWhereItLandsAndAskingTwicePutsItAway() {
        let registry = PanelRegistry(hostID: "host-a",
                                     defaults: UserDefaults(suiteName: "arch1.appearance.\(UUID())")!)
        let router = SurfaceRouter(registry: registry)
        router.rememberReturn()
        router.enterPicture()

        XCTAssertEqual(router.consume(.init(sessionID: "rs_abc123", revision: 6, view: .keybindings)), .opened)
        XCTAssertTrue(router.overlayVisible)
        XCTAssertEqual(router.panel, .menu)
        XCTAssertEqual(router.column, .keybindings)
        XCTAssertTrue(router.focusKeybindingsSearch, "A-25: the recall lands on that list's search field")

        router.dismissOverlay()
        XCTAssertFalse(router.overlayVisible)
        XCTAssertFalse(router.focusKeybindingsSearch)
        XCTAssertEqual(router.column, .keybindings, "A-31: the column survives the close")

        XCTAssertEqual(router.consume(.init(sessionID: "rs_abc123", revision: 6, view: .overview)), .opened)
        XCTAssertEqual(router.column, .menu)
        XCTAssertFalse(router.focusKeybindingsSearch)
        XCTAssertEqual(router.consume(.init(sessionID: "rs_abc123", revision: 6, view: .overview)), .dismissed)
        XCTAssertFalse(router.overlayVisible)
    }

    // MARK: - Pins

    /// N-39 rev 5. A pin is `{host_id, kind, stable_key, label}`; the two groups
    /// never mix; and a pin whose row the host no longer has stays, dimmed,
    /// rather than disappearing.
    func testPinsAreKeyedPerHostAndPerKindAndSurviveTheRowGoingAway() {
        let store = PanelPinStore(defaults: UserDefaults(suiteName: "arch1.pins.\(UUID())")!)
        let menu = PanelPin(hostID: "host-a", kind: .menu, stableKey: "Style › Theme", label: "Theme")
        let binding = PanelPin(hostID: "host-a", kind: .keybinding,
                               stableKey: "omodachi.shortcut.3", label: "Full screen")
        _ = store.toggle(menu)
        _ = store.toggle(binding)
        XCTAssertEqual(store.pins(hostID: "host-a", kind: .menu).map(\.stableKey), ["Style › Theme"])
        XCTAssertEqual(store.pins(hostID: "host-a", kind: .keybinding).map(\.stableKey), ["omodachi.shortcut.3"])
        XCTAssertTrue(store.pins(hostID: "host-b").isEmpty)

        // The label snapshot follows the host while the row exists…
        store.refresh(hostID: "host-a", kind: .menu, resolved: ["Style › Theme": "主题"])
        XCTAssertEqual(store.pins(hostID: "host-a", kind: .menu).first?.label, "主题")
        // …and stays put when it stops, because a tombstone has to say
        // *something*, and the last real name is the honest one.
        store.refresh(hostID: "host-a", kind: .menu, resolved: [:])
        XCTAssertEqual(store.pins(hostID: "host-a", kind: .menu).first?.label, "主题")

        // Forgetting a host takes its pins; nothing else does.
        store.forget(hostID: "host-a")
        XCTAssertTrue(store.pins(hostID: "host-a").isEmpty)
    }

    private static var hostRows: [ShortcutEntry] {
        var order = 0
        func row(_ label: String, _ keys: String, enabled: Bool = true) -> ShortcutEntry {
            defer { order += 1 }
            return .init(id: "omodachi.shortcut.\(order)", label: label, keys: keys, order: order,
                         actionRef: enabled ? "omodachi.shortcut.\(order)" : nil,
                         enabled: enabled, disabledReason: enabled ? nil : "binding_adapter_unavailable")
        }
        // The shape of this host's real list: the two GUI entries, a window
        // action with no GUI entry, then the ten workspace switches.
        var rows = [row("Keybindings", "SUPER + K"),
                    row("Omarchy menu", "SUPER + SPACE", enabled: false),
                    row("Full screen", "SUPER + F"),
                    row("Switch to workspace 10", "SUPER + 0", enabled: false)]
        for number in 1...9 { rows.append(row("Switch to workspace \(number)", "SUPER + \(number)", enabled: false)) }
        rows.append(row("Move window to workspace 3", "SUPER SHIFT + 3", enabled: false))
        return rows
    }
}
