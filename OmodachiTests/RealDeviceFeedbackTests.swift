import CoreText
import SwiftUI
import XCTest
@testable import Omodachi

/// UX-1. The rules Leo's first hour on a real iPad produced, asserted against
/// the data that produced them.
///
/// Where a test needs host data it uses the real thing: the glyph set below is
/// the `icon` field of the merged catalog on `omarchy` on 2026-09-19, and the
/// binding rows are what `omarchy-menu-keybindings --print` prints there.
@MainActor
final class RealDeviceFeedbackTests: XCTestCase {

    // MARK: - §8 · glyphs (and §3, which is the same root cause)

    /// The three shapes the host's `icon` field actually carries. Only the
    /// first is a glyph.
    private static let nerdCodePoints = ["\u{f489}", "\u{e659}", "\u{f0343}", "\u{f15c}", "\u{eb11}"]
    private static let xdgIconNames = ["org.gnome.Nautilus", "google-chrome", "docker", "x",
                                       "com.github.xournalpp.xournalpp", "libreoffice-calc",
                                       "audio-input-microphone", "omarchy-discord"]
    private static let literals = ["🟢", "🟡", "🟠", "🔴", "✓"]
    /// Omarchy still ships a handful of pre-3.0 Material Design code points
    /// that current Nerd Font releases moved to the `U+F0000` plane; nothing
    /// installed carries them. `apps.Battle.net` is the live example.
    private static let orphanCodePoint = "\u{f835}"

    private var hostFonts: HostFontSet {
        // `fc-match monospace` on the omarchy host answers Nimbus Mono PS,
        // which is not a Nerd Font. That is the case that matters.
        var set = HostFontSet()
        set.mono = "Helvetica"
        set.monoHasNerdGlyphs = false
        set.icons = nil
        return set
    }

    func testEveryNerdCodePointTheHostPublishesResolvesToAFontThatHasAGlyphForIt() {
        for glyph in Self.nerdCodePoints {
            let resolution = HostGlyph.resolve(glyph, iconFont: nil, fonts: hostFonts)
            guard case .text(let family) = resolution, let family else {
                return XCTFail("\(glyph.unicodeScalars.map { String($0.value, radix: 16) }) fell through to a symbol")
            }
            XCTAssertEqual(family, HostFontSet.bundledSymbols)
            XCTAssertTrue(HostGlyph.covers(glyph, family: family),
                          "the resolver must never name a family whose cmap lacks the code point")
        }
    }

    /// UX-1 item 8, the whole bug in one assertion. `apps.*` rows carry an XDG
    /// icon *name*, and the old code drew that name in a symbols-only face —
    /// one empty box per letter, with the label beside it.
    func testAnXDGIconNameIsNeverDrawnAsGlyphs() {
        for name in Self.xdgIconNames {
            XCTAssertEqual(HostGlyph.resolve(name, iconFont: nil, fonts: hostFonts), .symbol,
                           "\(name) is an icon name, not a glyph")
        }
    }

    func testEmojiAndPlainCharactersGoToAFontThatCanDrawThem() {
        for literal in Self.literals {
            guard case .text(let family) = HostGlyph.resolve(literal, iconFont: nil, fonts: hostFonts) else {
                return XCTFail("\(literal) should still be drawn, just not in the symbols face")
            }
            XCTAssertNotEqual(family, HostFontSet.bundledSymbols,
                              "\(literal) is not in the bundled symbols font; drawing it there is a tofu box")
        }
    }

    func testACodePointNothingInstalledCarriesFallsBackToTheRowsOwnSymbol() {
        XCTAssertEqual(HostGlyph.resolve(Self.orphanCodePoint, iconFont: nil, fonts: hostFonts), .symbol)
    }

    /// The `"iconFont": "omarchy"` rows. With the host's own file missing —
    /// which is every state before `GET /v1/fonts/icons` lands, and the whole
    /// of item 3's "icons 在 remote 时失效" window — the row shows its symbol
    /// rather than a private-use code point in the wrong face.
    func testAnOmarchyTaggedRowNeedsTheHostsOwnFileAndFallsBackWithoutIt() {
        var set = hostFonts
        XCTAssertEqual(HostGlyph.resolve("\u{e90d}", iconFont: "omarchy", fonts: set), .symbol)
        set.icons = HostFontSet.bundledSymbols
        // Even with a file registered, a code point it does not carry still
        // falls back: a registered family is not a covered code point.
        XCTAssertEqual(HostGlyph.resolve("\u{e90d}", iconFont: "omarchy", fonts: set),
                       HostGlyph.covers("\u{e90d}", family: HostFontSet.bundledSymbols)
                           ? .text(family: HostFontSet.bundledSymbols) : .symbol)
    }

    func testAnEmptyGlyphIsTheRowsSymbol() {
        XCTAssertEqual(HostGlyph.resolve("", iconFont: nil, fonts: hostFonts), .symbol)
    }

    // MARK: - §5 · A-48 readability

    func testTheTabletFloorsHoldForEveryStepTheHostPublishes() {
        let previous = OmodachiTypeScale.isTablet
        defer { OmodachiTypeScale.isTablet = previous }
        OmodachiTypeScale.isTablet = true

        // The host's own numbers, from `FallbackTheme` and the real nord/shell
        // documents alike: Omarchy writes a desktop scale.
        let host: [String: CGFloat] = ["caption": 10, "body-small": 11, "body": 12,
                                       "subtitle": 13, "title": 14, "heading": 16,
                                       "icon-small": 11, "icon": 14]
        for (step, value) in host {
            let drawn = OmodachiTypeScale.size(step: step, hostValue: value)
            let floor = OmodachiTypeScale.secondarySteps.contains(step)
                ? OmodachiTypeScale.secondaryFloor : OmodachiTypeScale.bodyFloor
            XCTAssertGreaterThanOrEqual(drawn, floor, "\(step) drew at \(drawn)")
            XCTAssertGreaterThanOrEqual(drawn, value, "the floor never shrinks the host's own step")
        }
        // The host's hierarchy survives the lift.
        XCTAssertLessThan(OmodachiTypeScale.size(step: "body-small", hostValue: 11),
                          OmodachiTypeScale.size(step: "heading", hostValue: 16))
        // A-48's monospace floor is the same 13, and every step is monospace.
        XCTAssertGreaterThanOrEqual(OmodachiTypeScale.size(step: "caption", hostValue: 10), 13)
    }

    func testAnIPhoneKeepsTheHostsOwnStepsExactly() {
        let previous = OmodachiTypeScale.isTablet
        defer { OmodachiTypeScale.isTablet = previous }
        OmodachiTypeScale.isTablet = false
        XCTAssertEqual(OmodachiTypeScale.size(step: "body", hostValue: 12), 12)
        XCTAssertEqual(OmodachiTypeScale.size(points: 11), 11)
        XCTAssertEqual(OmodachiTypeScale.lineSpacing, 0)
    }

    func testTheTabletLineHeightClearsA48sMultiple() {
        let previous = OmodachiTypeScale.isTablet
        defer { OmodachiTypeScale.isTablet = previous }
        OmodachiTypeScale.isTablet = true
        for size: CGFloat in [13, 15, 16, 18] {
            XCTAssertGreaterThanOrEqual(OmodachiTypeScale.lineHeightMultiple(pointSize: size), 1.3,
                                        "\(size)pt line height")
        }
    }

    /// A-48's contrast half, measured on the theme's own numbers rather than
    /// asserted by eye. The bundled fallback is the one palette that ships, so
    /// it is the one that can be checked without a host.
    func testBodyAndSecondaryTextClearWCAGOnTheBundledPalette() {
        let background = FallbackTheme.rgb(.background)
        XCTAssertGreaterThanOrEqual(OmodachiContrast.ratio(FallbackTheme.rgb(.foreground), background), 4.5,
                                    "body text on the panel background")
        XCTAssertGreaterThanOrEqual(OmodachiContrast.ratio(FallbackTheme.rgb(.brightForeground), background), 4.5,
                                    "headings on the panel background")
    }

    /// The finding this test exists to pin: `muted` is a *border and fill*
    /// colour in the host's vocabulary, and the app was also using it for
    /// secondary text. A-48 says pick a higher-contrast token from the theme
    /// rather than invent one, which is what `OmodachiTheme.secondaryText` now
    /// does.
    func testTheSecondaryTextTokenIsNotTheBorderColour() {
        let background = FallbackTheme.rgb(.background)
        let muted = OmodachiContrast.ratio(FallbackTheme.rgb(.muted), background)
        XCTAssertLessThan(muted, 4.5, "if this ever passes, `muted` became a text colour and this rule can relax")
        XCTAssertGreaterThanOrEqual(OmodachiContrast.ratio(FallbackTheme.rgb(.lightForeground), background), 4.5,
                                    "the token A-48 sends secondary text to instead")
    }

    // MARK: - §7 · the bar, after A-49 replaced A-47

    /// A-47 asked "which of three bars is on screen", and the answer depended on
    /// the surface. A-49 deletes the question: there is **one** bar, always the
    /// same three segments, and the only thing a session changes is that the
    /// centre segment has something in it.
    ///
    /// Leo's reading of the old behaviour — "有时候有、有时候没有，没找到规律" —
    /// was correct, and this is the rule that replaces it.
    func testThereIsOneBarAndOnlyItsCentreDependsOnContext() {
        let workspaces = [1, 2, 3, 4, 5, 7]
        let withoutSession = BarMetrics.plan(available: 1174, workspaces: workspaces,
                                             occupied: [1, 2, 7], entries: 6, actions: [])
        let withSession = BarMetrics.plan(available: 1174, workspaces: workspaces,
                                          occupied: [1, 2, 7], entries: 6,
                                          actions: QuickAction.allCases)
        XCTAssertTrue(withoutSession.visibleActions.isEmpty)
        XCTAssertEqual(withSession.visibleActions.count, 5)
        // Everything else is identical: the same entries, the same workspaces,
        // the same slot width.
        XCTAssertEqual(withoutSession.workspaces, withSession.workspaces)
        XCTAssertEqual(withoutSession.centreSlot, withSession.centreSlot)
        XCTAssertEqual(withoutSession.ladder, withSession.ladder)
    }

    /// A-50 / N-30: the six entries live on the bar and nowhere else, and the
    /// seventh panel is the logo's. A panel that is switched off loses its slot
    /// and keeps its panel (N-38 rev 5).
    @MainActor func testTheEntriesAreTheOnlyWayInAndSwitchingOneOffOnlyHidesItsSlot() {
        let registry = PanelRegistry(hostID: "host-a",
                                     defaults: UserDefaults(suiteName: "arch1.rdf.\(UUID())")!)
        XCTAssertEqual(registry.barEntries.count, 6)
        XCTAssertFalse(registry.entries.contains { $0.id == .menu })
        registry.setEnabled(.herdr, false)
        XCTAssertEqual(registry.barEntries.count, 5)
        let router = SurfaceRouter(registry: registry)
        router.show(.herdr)
        XCTAssertEqual(router.panel, .herdr, "settings and a summon still reach it")
    }

    // MARK: - §4 · A-45 notifications

    private func notification(_ id: String, active: Bool) -> HostNotification {
        HostNotification(id: id, app: "app", summary: "s", body: "b",
                         urgency: .normal, timestamp: 1, hasAction: false, active: active)
    }

    func testEveryRowCanBeDeletedIncludingHistoryAndTheCountIsTheActiveOnes() {
        var list = HostNotificationList()
        list.replace(with: [notification("1-1", active: true), notification("2-2", active: true),
                            notification("3-3", active: false)])
        XCTAssertEqual(list.rows.count, 3)
        XCTAssertEqual(list.unreadCount, 2)
        XCTAssertTrue(list.canDelete(list.rows[0]))
        // A-45: history deletes too. `canDismiss` — which is about the host's
        // screen — stays false for it.
        let history = try? XCTUnwrap(list.rows.first { !$0.active })
        XCTAssertNotNil(history)
        XCTAssertTrue(list.canDelete(history!))
        XCTAssertFalse(list.canDismiss(history!))
    }

    func testADeletedRowStaysDeletedAcrossAReloadAndALateEvent() {
        var list = HostNotificationList()
        list.replace(with: [notification("1-1", active: true), notification("2-2", active: true)])
        XCTAssertTrue(list.remove(id: "2-2"))
        XCTAssertEqual(list.rows.map(\.id), ["1-1"])
        // The host still holds it; a reload must not put it back.
        list.replace(with: [notification("1-1", active: true), notification("2-2", active: true)])
        XCTAssertEqual(list.rows.map(\.id), ["1-1"])
        // Nor may a `notification.posted` for the same id.
        list.post(notification("2-2", active: true))
        XCTAssertEqual(list.rows.map(\.id), ["1-1"])
    }

    func testClearAllEmptiesTheGroupAndKeepsItEmpty() {
        var list = HostNotificationList()
        list.replace(with: [notification("1-1", active: true), notification("2-2", active: false)])
        list.removeAll()
        XCTAssertTrue(list.rows.isEmpty)
        XCTAssertEqual(list.unreadCount, 0)
        list.replace(with: [notification("1-1", active: true), notification("2-2", active: false)])
        XCTAssertTrue(list.rows.isEmpty, "clearing is this device's decision, and a reload does not undo it")
    }

    // MARK: - §1 / A-57 · ending a session

    /// A-41 put "end this session" on the Panel's pinned Remote tile. A-57
    /// moves it to panel ②'s session card and A-50 deletes the tile, so there
    /// is exactly one place a session can be ended and it is behind N-14's two
    /// taps. The bar's Remote entry only opens the panel.
    @MainActor func testEndingASessionIsOnlyEverTheSessionCard() {
        let registry = PanelRegistry(hostID: "host-a",
                                     defaults: UserDefaults(suiteName: "arch1.end.\(UUID())")!)
        let router = SurfaceRouter(registry: registry)
        router.show(.agent)
        router.rememberReturn()
        router.enterPicture()
        // The entry opens ②; it does not end anything.
        _ = router.consume(.init(sessionID: "rs_1", revision: 1, view: .overview))
        router.tapEntry(.remote)
        XCTAssertEqual(router.panel, .remote)
        XCTAssertTrue(router.hasSession)
        // Ending is the card's, and it lands where N-32 says.
        router.endSession()
        XCTAssertFalse(router.hasSession)
        XCTAssertEqual(router.panel, .agent)
    }

    // MARK: - §B · the Remote execution context on the wire

    /// Core's `validate_context` accepts exactly `{surface, session_id,
    /// revision}` for a remote surface and refuses anything else as
    /// `invalid_request`. The client used to encode `connection_generation` and
    /// `geometry_epoch` instead — a shape core has never accepted.
    func testTheRemoteExecutionContextMatchesWhatCoreValidates() throws {
        var context = ShortcutContext(hostID: "https://h", surface: .remote)
        context.remoteSessionID = "rs_0123456789abcdef"
        context.connectionGeneration = 4
        context.geometryEpoch = 7
        context.sessionRevision = 3
        let request = ShortcutExecutionRequest(requestID: UUID(), entryID: "e",
                                               actionRef: "omodachi.shortcut.abc", revision: "r1",
                                               context: context)
        let encoded = try JSONEncoder().encode(ShortcutInvokeBody(request))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let execution = try XCTUnwrap(body["execution_context"] as? [String: Any])
        XCTAssertEqual(Set(execution.keys), ["surface", "session_id", "revision"])
        XCTAssertEqual(execution["surface"] as? String, "remote")
        XCTAssertEqual(execution["revision"] as? Int, 3)
    }

    /// The Panel's own surface sends the one key core accepts for it, which is
    /// the path A-‍B keeps Remote on as well.
    func testTheControllerExecutionContextIsExactlyOneKey() throws {
        let context = ShortcutContext(hostID: "https://h", surface: .controller)
        let request = ShortcutExecutionRequest(requestID: UUID(), entryID: "e",
                                               actionRef: "omodachi.shortcut.abc", revision: "r1",
                                               context: context)
        let encoded = try JSONEncoder().encode(ShortcutInvokeBody(request))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(body["execution_context"] as? [String: String], ["surface": "omarchy"])
    }
}

/// The `state` documents these assertions need. `HostStateDTO` is decode-only
/// — it is a wire type — so a fixture is JSON, which also keeps the test honest
/// about the shape core actually sends.
enum HostStateFixture {
    static func remote(sessionID: String?, mode: String) -> HostStateDTO {
        let session = sessionID.map { "\"session_id\": \"\($0)\"," } ?? ""
        let json = """
        {"revision": 1, "host": {"name": "omarchy", "connected": true},
         "remote": {\(session) "state": "ready", "mode": "\(mode)", "backend": "sunshine", "revision": 1}}
        """
        return try! JSONDecoder().decode(HostStateDTO.self, from: Data(json.utf8))
    }
}
