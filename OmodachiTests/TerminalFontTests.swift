import CoreText
import UIKit
import XCTest
@testable import Omodachi

/// TERM-1. The terminal's font is a chain, not a family.
///
/// Every assertion here is about a property a screenshot cannot prove and a
/// regression would hide: that the cascade is attached to all four faces, that
/// it still carries CJK and emoji after a Nerd Font is put in front of them, and
/// that CoreText really selects out of it for a private-use code point.
final class TerminalFontTests: XCTestCase {

    private func cascadeFamilies(_ font: UIFont) -> [String] {
        let key = UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String)
        let list = font.fontDescriptor.fontAttributes[key] as? [CTFontDescriptor] ?? []
        return list.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
    }

    /// The chain is host-symbols, then the platform's CJK and emoji, in that
    /// order and under the names layout really uses — not the dot-prefixed
    /// optical variants `CTFontCreateForString` answers with.
    func testTheCascadeCarriesSymbolsAndThenTheseCJKAndEmojiFaces() throws {
        var set = HostFontSet()
        set.mono = "Menlo"
        let menlo = try XCTUnwrap(UIFont(name: "Menlo", size: 14))
        let families = TerminalFont.cascade(set, base: menlo)
        XCTAssertEqual(families.first, HostFontSet.bundledSymbols,
                       "Until the host's own face arrives, the bundled symbols face is the fallback.")
        let cjk = try XCTUnwrap(PlatformFallback.family(for: PlatformFallback.cjkSample, base: menlo))
        let emoji = try XCTUnwrap(PlatformFallback.family(for: PlatformFallback.emojiSample, base: menlo))
        XCTAssertEqual(families, [HostFontSet.bundledSymbols, cjk, emoji])
        XCTAssertNotEqual(cjk, emoji)
        for family in [cjk, emoji] {
            XCTAssertFalse(family.hasPrefix("."), "a private optical variant is not a name to register: \(family)")
            XCTAssertNotNil(UIFont(name: family, size: 12), "\(family) has to resolve by name to be a cascade entry")
        }
    }

    /// Measured, because the whole shape of the chain depends on it: the
    /// cascade list is consulted **before** the platform's own fallback and
    /// does not replace it. With nothing but a symbols face behind Menlo, a Han
    /// ideograph and an emoji still find their platform faces.
    ///
    /// If a future iOS makes the attribute replace the default instead, the
    /// explicit CJK and emoji entries are already in the chain and this test is
    /// where the change will announce itself.
    func testThePlatformsOwnFallbackSurvivesTheCascade() throws {
        let menlo = try XCTUnwrap(UIFont(name: "Menlo", size: 14))
        let symbolsOnly = cascading(menlo, [HostFontSet.bundledSymbols])
        XCTAssertEqual(coveringFamily(PlatformFallback.cjkSample, in: symbolsOnly),
                       PlatformFallback.family(for: PlatformFallback.cjkSample, base: menlo))
        XCTAssertEqual(coveringFamily(PlatformFallback.emojiSample, in: symbolsOnly),
                       PlatformFallback.family(for: PlatformFallback.emojiSample, base: menlo))
    }

    /// The host's own fallback family replaces the bundled one rather than
    /// joining it: the first face that carries a code point wins, so a second
    /// copy of the same glyph would only be a lookup nobody reads.
    func testTheHostsOwnFallbackFamilyReplacesTheBundledOne() throws {
        var set = HostFontSet()
        set.mono = "Menlo"
        set.symbolFallbacks = ["Courier New"]
        let menlo = try XCTUnwrap(UIFont(name: "Menlo", size: 14))
        XCTAssertEqual(TerminalFont.cascade(set, base: menlo).first, "Courier New")
        XCTAssertFalse(TerminalFont.cascade(set, base: menlo).contains(HostFontSet.bundledSymbols))
    }

    /// `TerminalView.font = x` derives bold and italic with
    /// `withSymbolicTraits`, and a face built any other way would drop the
    /// cascade — a bold prompt would go back to drawing boxes.
    func testAllFourFacesCarryTheSameChain() throws {
        var set = HostFontSet()
        set.mono = "Menlo"
        set.monoBold = "Menlo"
        let faces = TerminalFont.faces(size: 14, fonts: set)
        let expected = TerminalFont.cascade(set, base: try XCTUnwrap(UIFont(name: "Menlo", size: 14)))
        for face in [faces.normal, faces.bold, faces.italic, faces.boldItalic] {
            XCTAssertEqual(cascadeFamilies(face), expected)
            XCTAssertEqual(face.pointSize, 14)
        }
    }

    /// The end of the whole change, asked of CoreText rather than of a
    /// screenshot: the face that would draw `U+F07B` (`nf-fa-folder`, the glyph
    /// in front of every directory in Omarchy's `ls`) in a run of terminal text.
    ///
    /// The base family has no glyph there, so a plain font answers with itself
    /// and draws `.notdef`. With the cascade it answers with a face that has one.
    func testCoreTextPicksAFaceForANerdFontCodePointOnlyWithTheCascade() throws {
        var set = HostFontSet()
        set.mono = "Menlo"
        let folder = "\u{F07B}"
        let plain = try XCTUnwrap(UIFont(name: "Menlo", size: 14))
        // Not `.notdef`: CoreText substitutes `.LastResort`, whose glyph for an
        // unassigned private-use point is a box with a question mark in it.
        // That is the thing Leo photographed.
        XCTAssertEqual(coveringFamily(folder, in: plain), PlatformFallback.lastResort)

        let withChain = TerminalFont.faces(size: 14, fonts: set).normal
        XCTAssertEqual(coveringFamily(folder, in: withChain), HostFontSet.bundledSymbols)
    }

    /// And the other three characters the acceptance run types: a letter stays
    /// in the host's own face, a Han ideograph and an emoji reach the
    /// platform's, all out of the one cascade.
    func testTheSameCascadeStillAnswersLatinCJKAndEmoji() throws {
        var set = HostFontSet()
        set.mono = "Menlo"
        let font = TerminalFont.faces(size: 14, fonts: set).normal
        XCTAssertEqual(coveringFamily("A", in: font), "Menlo")
        let menlo = try XCTUnwrap(UIFont(name: "Menlo", size: 14))
        XCTAssertEqual(coveringFamily(PlatformFallback.cjkSample, in: font),
                       PlatformFallback.family(for: PlatformFallback.cjkSample, base: menlo))
        XCTAssertEqual(coveringFamily(PlatformFallback.emojiSample, in: font),
                       PlatformFallback.family(for: PlatformFallback.emojiSample, base: menlo))
    }

    // MARK: - What the client takes from the host's chain

    private func listing(_ json: String) throws -> HostFontListDTO {
        try JSONDecoder().decode(HostFontListDTO.self, from: Data(json.utf8))
    }

    private func row(_ id: String, _ role: String, _ family: String, bytes: Int) -> String {
        """
        {"id": "\(id)", "role": "\(role)", "family": "\(family)",
         "sha256": "\(String(repeating: "b", count: 64))", "bytes": \(bytes), "content_type": "font/ttf"}
        """
    }

    /// Leo's host, as core publishes it. The 19 MB CJK collection and the 10 MB
    /// emoji font are links this device does not take: it has its own faces for
    /// both, and taking them would turn every reconnect into 30 MB.
    func testOnlyTheSymbolLinksAreWorthDownloading() throws {
        let document = try listing("""
        {"revision": 4, "fonts": [
          \(row("mono-regular", "mono", "Nimbus Mono PS", bytes: 77936)),
          \(row("mono-bold", "mono", "Nimbus Mono PS", bytes: 87520)),
          \(row("icons", "icons", "omarchy", bytes: 5412)),
          \(row("fallback-symbols", "fallback", "JetBrainsMono Nerd Font", bytes: 2571596)),
          \(row("fallback-symbols-2", "fallback", "Font Awesome 7 Brands", bytes: 115536)),
          \(row("fallback-cjk", "fallback", "Noto Sans Mono CJK KR", bytes: 19484784)),
          \(row("fallback-emoji", "fallback", "Noto Color Emoji", bytes: 10673480))],
         "fallback_chain": [
          {"coverage": "symbols", "family": "JetBrainsMono Nerd Font", "font": "fallback-symbols", "probes": ["U+F07B"]},
          {"coverage": "symbols", "family": "Font Awesome 7 Brands", "font": "fallback-symbols-2", "probes": ["U+F835"]},
          {"coverage": "cjk", "family": "Noto Sans Mono CJK KR", "font": "fallback-cjk", "probes": ["U+4E2D"]},
          {"coverage": "emoji", "family": "Noto Color Emoji", "font": "fallback-emoji", "probes": ["U+1F600"]}]}
        """)
        XCTAssertEqual(HostFontPlan.wanted(document),
                       ["mono-regular", "mono-bold", "icons", "fallback-symbols", "fallback-symbols-2"])
        // A link whose file did not register never reaches `registered`, and
        // the chain simply goes on without it.
        let registered = ["mono-regular": "Nimbus Mono PS", "icons": "omarchy",
                          "fallback-symbols": "JetBrainsMono Nerd Font"]
        XCTAssertEqual(HostFontPlan.fallbacks(document, registered: registered), ["JetBrainsMono Nerd Font"])

        var set = HostFontSet()
        set.mono = "Nimbus Mono PS"
        set.symbolFallbacks = HostFontPlan.fallbacks(document, registered: registered)
        XCTAssertEqual(set.symbolCascade.first, "JetBrainsMono Nerd Font")
    }

    /// The download guard and the listing filter have to agree about what an id
    /// is, or the client asks for a row it then refuses to fetch. They did not:
    /// `fetchFontFile` checked a list of three spellings, so the first real run
    /// took the three old rows and silently left the host's Nerd Font behind.
    func testTheDownloadGuardAcceptsExactlyWhatCorePublishes() {
        for id in ["mono-regular", "mono-bold", "icons",
                   "fallback-symbols", "fallback-symbols-2", "fallback-cjk", "fallback-emoji"] {
            XCTAssertTrue(HostFontRowDTO.isPublished(id), id)
        }
        for id in ["", "mono-italic", "fallback", "fallback-", "fallback-../../etc/passwd",
                   "fallback-Symbols", "fallback-a/b", "../icons",
                   "fallback-" + String(repeating: "a", count: 64)] {
            XCTAssertFalse(HostFontRowDTO.isPublished(id), id)
        }
    }

    /// A link that lands on the matched family itself is not a fallback: it is
    /// already the first face of the cascade.
    func testALinkOnTheMatchedFamilyIsNotAddedBehindItself() throws {
        let document = try listing("""
        {"revision": 1, "fonts": [\(row("mono-regular", "mono", "JetBrainsMono Nerd Font", bytes: 2571596))],
         "fallback_chain": [{"coverage": "symbols", "family": "JetBrainsMono Nerd Font",
                             "font": "mono-regular", "probes": ["U+F07B"]}]}
        """)
        XCTAssertEqual(HostFontPlan.wanted(document), ["mono-regular"])
        XCTAssertEqual(HostFontPlan.fallbacks(document, registered: ["mono-regular": "JetBrainsMono Nerd Font"]), [])
    }

    /// An outsized fallback file is left on the host. The link is still true;
    /// the bytes are not worth a reconnect, and the bundled face covers.
    func testAnOutsizedFallbackIsNotFetched() throws {
        let document = try listing("""
        {"revision": 1, "fonts": [\(row("fallback-symbols", "fallback", "Huge NF", bytes: 33554432))],
         "fallback_chain": [{"coverage": "symbols", "family": "Huge NF",
                             "font": "fallback-symbols", "probes": ["U+F07B"]}]}
        """)
        XCTAssertEqual(HostFontPlan.wanted(document), [])
        var set = HostFontSet()
        set.symbolFallbacks = HostFontPlan.fallbacks(document, registered: [:])
        XCTAssertEqual(set.symbolCascade.first, HostFontSet.bundledSymbols)
    }

    /// Which family CoreText would really use for `text` in a run set in `font`
    /// — the same question the renderer asks when it lays out a line, not a
    /// coverage table this test wrote down. `nil` when the answer is the base
    /// family but the base family has no glyph: that is tofu.
    private func cascading(_ font: UIFont, _ families: [String]) -> UIFont {
        let key = UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String)
        let descriptors = families.map {
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: $0] as CFDictionary)
        }
        return UIFont(descriptor: font.fontDescriptor.addingAttributes([key: descriptors]),
                      size: font.pointSize)
    }

    private func coveringFamily(_ text: String, in font: UIFont) -> String? {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return nil }
        var glyph = CGGlyph(0)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        guard glyph != 0 else { return nil }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let runFont = attributes.object(forKey: NSAttributedString.Key.font) as? UIFont else { return nil }
        return runFont.familyName
    }
}
