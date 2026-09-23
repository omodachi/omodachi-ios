import CoreText
import SwiftUI
import XCTest
@testable import Omodachi

/// MENU-1. The ten rows at the top of Omarchy's menu, and the promise that the
/// app draws the host's own glyph for each of them.
///
/// Every constant here was read off the host, not invented:
///
/// * the code points are `"icon"` in
///   `/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc` on `omarchy`
///   (Omarchy `4.0.0.alpha`), which is the file core compiles the catalog from;
/// * `Menu.qml:1243` draws that field in `row.iconFont` or, when the row has
///   none, in `Style.font.menuFamily` — which is `Style.qml:269`'s literal
///   `"monospace"`, i.e. the fontconfig alias. On this host `fc-match
///   monospace` is **Nimbus Mono PS**, which carries none of these code points,
///   so what the user sees is fontconfig's *fallback*:
///   `fc-match "monospace:charset=f003b"` → `JetBrainsMono Nerd Font`
///   (`ttf-jetbrains-mono-nerd-basic 3.5.1-1`).
/// * the app bundles Symbols Nerd Font Mono from the **same** Nerd Fonts
///   release (3.5.1), so the same code point is the same drawing.
///
/// The assertion is therefore: each of the ten resolves to a *font*, never to a
/// fallback symbol, and that font has a real (non-zero) glyph id for it.
@MainActor
final class MenuIconSyncTests: XCTestCase {

    /// id, label, and the host's code point — the whole root menu.
    static let topLevel: [(id: String, label: String, glyph: String)] = [
        ("apps", "Apps", "\u{f003b}"),
        ("learn", "Learn", "\u{f09d1}"),
        ("trigger", "Trigger", "\u{f14de}"),
        ("style", "Style", "\u{ebcf}"),
        ("setup", "Setup", "\u{e615}"),
        ("install", "Install", "\u{f0249}"),
        ("remove", "Remove", "\u{f0b4c}"),
        ("update", "Update", "\u{f021}"),
        ("about", "About", "\u{ea74}"),
        ("system", "System", "\u{f011}"),
    ]

    /// The real host's font set: a monospace family that is not a Nerd Font,
    /// and no `omarchy.ttf` yet. This is the state the menu is drawn in.
    private var hostFonts: HostFontSet {
        var set = HostFontSet()
        set.mono = "Helvetica"
        set.monoHasNerdGlyphs = false
        set.icons = nil
        return set
    }

    /// The glyph id a family actually has for a code point. Zero is `.notdef`,
    /// which is the tofu box; `CTFontGetGlyphsForCharacters` takes UTF-16, so a
    /// non-BMP scalar — most of these — is asked about as its surrogate pair
    /// and answers in the first slot.
    private func glyphID(_ text: String, family: String) -> CGGlyph {
        let font = CTFontCreateWithName(family as CFString, 16, nil)
        var units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        return glyphs.first ?? 0
    }

    // MARK: - §3 · the ten code points resolve to a real glyph

    func testEveryTopLevelRowResolvesToAFontWithANonZeroGlyphForIt() {
        for row in Self.topLevel {
            let resolution = HostGlyph.resolve(row.glyph, iconFont: "", fonts: hostFonts)
            guard case .text(let family) = resolution, let family else {
                return XCTFail("\(row.label) (U+\(String(row.glyph.unicodeScalars.first!.value, radix: 16, uppercase: true))) fell back to a symbol")
            }
            XCTAssertEqual(family, HostFontSet.bundledSymbols,
                           "\(row.label) must be drawn in the host icon face, not the body font")
            XCTAssertNotEqual(glyphID(row.glyph, family: family), 0,
                              "\(row.label) resolved to \(family), which draws .notdef for it")
        }
    }

    /// The face the ten land in has to be a Nerd Font, not merely a family that
    /// happens to answer to the name. `U+F00A` is in the Font Awesome block
    /// every Nerd Font patch carries and no plain monospace family does.
    func testTheFaceTheTenLandInIsANerdFont() {
        XCTAssertTrue(HostFontInstaller.hasNerdGlyphs(family: HostFontSet.bundledSymbols))
    }

    /// The host's own file wins when it can draw the row. `omarchy font set
    /// "JetBrainsMono Nerd Font"` is one command away on the host, and after it
    /// the bundled copy must stop being what the menu is drawn in.
    func testAPatchedHostMonospaceIsPreferredOverTheBundledCopy() {
        var set = hostFonts
        // Stand in for a patched host mono with the one registered family that
        // really does carry these code points.
        set.mono = HostFontSet.bundledSymbols
        set.monoHasNerdGlyphs = true
        for row in Self.topLevel {
            XCTAssertEqual(HostGlyph.resolve(row.glyph, iconFont: "", fonts: set),
                           .text(family: HostFontSet.bundledSymbols),
                           "\(row.label) must follow the host's own face")
        }
    }

    // MARK: - §2 · the curated substitution table is gone

    private func entry(id: String, icon: String?, kind: String?) throws -> CatalogEntryDTO {
        var fields: [String] = ["\"id\":\"\(id)\"", "\"parent_id\":\"root\"", "\"label\":\"\(id)\""]
        if let icon { fields.append("\"icon\":\"\(icon)\"") }
        if let kind { fields.append("\"kind\":\"\(kind)\"") }
        let data = Data("{\(fields.joined(separator: ","))}".utf8)
        return try JSONDecoder().decode(CatalogEntryDTO.self, from: data)
    }

    /// The menu row carries the host's code point through untouched. Before
    /// MENU-1 the row also carried an SF Symbol picked from a table keyed on
    /// the row id, which is what made `install` a floppy-vs-plus argument
    /// instead of "whatever Omarchy published".
    func testAMenuRowCarriesTheHostsOwnCodePointAndNoSubstituteForIt() throws {
        for row in Self.topLevel {
            let built = HostMenu.build(from: [try entry(id: row.id, icon: row.glyph, kind: "menu")])
            XCTAssertEqual(built.count, 1)
            XCTAssertEqual(built.first?.glyph, row.glyph)
            XCTAssertEqual(built.first?.icon, .symbol("circle"),
                           "\(row.id) must have no opinion of its own about what it looks like")
        }
    }

    /// The one row that is ours. Core publishes it with `"icon": ""`
    /// (`omodachi_core/data/omodachi-menu.jsonc`) precisely because Omarchy has
    /// no glyph for it, so the app supplies its own mark rather than a stock
    /// laptop-and-phone symbol.
    func testTheOmodachiRowDrawsOurOwnMark() throws {
        let built = HostMenu.build(from: [try entry(id: "omodachi", icon: "", kind: "menu")])
        XCTAssertEqual(built.first?.icon, .mark)
        XCTAssertEqual(built.first?.glyph, "")
    }

    /// An `apps.*` row's `icon` is an XDG icon *name*: the host draws the icon
    /// theme's PNG for it (`Menu.qml` `appIconImage`), which this client has no
    /// copy of. The name must never be drawn as letters in a 36pt icon column,
    /// and the row must not come out as an anonymous circle either.
    /// ICON-1 changed the answer, not the question. MENU-1 gave these rows the
    /// generic application glyph because nothing on the device could turn a
    /// name into a picture; now the host can (`GET /v1/icons`), so the row
    /// carries the name and draws the generic only until the bytes arrive.
    func testAnAppRowAsksTheHostForThePictureBehindItsName() throws {
        for name in ["org.gnome.Nautilus", "google-chrome", "docker", "x"] {
            let built = HostMenu.build(from: [try entry(id: "apps.\(name)", icon: name, kind: "app")])
            XCTAssertEqual(built.first?.icon, .icon(name), "\(name) is a name the host can resolve")
            XCTAssertEqual(HostGlyph.resolve(name, iconFont: "", fonts: hostFonts), .symbol,
                           "\(name) must never be drawn as glyphs")
        }
    }

    /// And a row core classifies as an app but leaves without any icon at all
    /// still gets the generic, because there is no name to ask about.
    func testAnAppRowWithNoIconAtAllKeepsTheGenericApplicationGlyph() throws {
        let built = HostMenu.build(from: [try entry(id: "apps.nameless", icon: nil, kind: "app")])
        XCTAssertEqual(built.first?.icon, .app)
    }

    /// And the generic itself is drawable, or the fallback would be a new tofu
    /// box in place of the old one.
    func testTheGenericApplicationGlyphIsDrawable() {
        guard case .text(let family) = HostGlyph.resolve(Icon.app.nerd, iconFont: "", fonts: hostFonts),
              let family else {
            return XCTFail("the generic application glyph must itself resolve to a font")
        }
        XCTAssertNotEqual(glyphID(Icon.app.nerd, family: family), 0)
    }

    /// A row core does not classify as an app keeps the neutral fallback, so
    /// the generic is not sprayed over the rest of the tree.
    func testANonAppRowWithoutAGlyphKeepsTheNeutralFallback() throws {
        let built = HostMenu.build(from: [try entry(id: "style.theme", icon: "", kind: "menu")])
        XCTAssertEqual(built.first?.icon, .symbol("circle"))
    }

    // MARK: - §2 · the surfaces that must not move

    /// The bar entries and the Keybindings group rows are drawn from `Icon`,
    /// not from the catalog, so MENU-1 cannot have changed them. This pins the
    /// code points so a later edit to `Icon` has to say so out loud.
    /// ICON-1 moved two of these on purpose (③ and ④, see `ICON1Tests`); the
    /// rest are still pinned here so a later change to the bar has to be
    /// deliberate.
    func testTheBarAndKeybindingGlyphsAreUnchanged() {
        XCTAssertEqual(Icon.remote.nerd, "\u{f108}")
        XCTAssertEqual(Icon.agent.nerd, "\u{f16a3}", "ICON-1: the host's own agents glyph")
        XCTAssertEqual(Icon.herdr.nerd, "\u{f233}", "ICON-1: the host's own Herdr glyph")
        XCTAssertEqual(Icon.ssh.nerd, "\u{f120}")
        XCTAssertEqual(Icon.settings.nerd, "\u{f013}")
        XCTAssertEqual(Icon.bell.nerd, "\u{f0f3}")
        XCTAssertEqual(Icon.keyboard.nerd, "\u{f11c}")
        for icon in [Icon.remote, Icon.agent, Icon.herdr, Icon.ssh, Icon.settings, Icon.bell, Icon.keyboard] {
            XCTAssertNotEqual(glyphID(icon.nerd, family: HostFontSet.bundledSymbols), 0,
                              "\(icon.symbol)'s code point must still draw")
        }
    }

    /// AGENT-2's `BrandMark` is for the marks that are *not* ours —
    /// `Resources/Brand.xcassets` holds codex and herdr, with their provenance
    /// written down in `SOURCES.md`. Ours has exactly one source, the v6 outline
    /// in `OmodachiSymbol`, and both the bar (`BarView.swift:73`,
    /// `HerdrControlBar.swift:21`) and the `omodachi` menu row's `.mark` draw it
    /// from there. What this forbids is a second copy of our own mark arriving
    /// as an asset beside the vendors'.
    func testOurOwnMarkHasExactlyOneSource() {
        for mark in BrandMark.allCases {
            XCTAssertFalse(mark.rawValue.lowercased().contains("omodachi"),
                           "\(mark.rawValue): our mark is OmodachiSymbol, never a brand asset")
        }
        XCTAssertNil(BrandMark.provider("omodachi"))
        XCTAssertFalse(OmodachiSymbol().path(in: CGRect(x: 0, y: 0, width: 36, height: 36)).isEmpty,
                       "`.mark` must draw something")
    }

    /// `GlyphFallback` keeps behaving like the string it replaced everywhere a
    /// surface only ever wanted an SF Symbol.
    func testAStringLiteralIsStillAnSFSymbolFallback() {
        let fallback: GlyphFallback = "xmark"
        XCTAssertEqual(fallback, .symbol("xmark"))
    }
}
