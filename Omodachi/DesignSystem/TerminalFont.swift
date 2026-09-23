import CoreText
import SwiftTerm
import UIKit

/// The four faces a terminal draws with, each carrying the host's fallback
/// chain behind it (TERM-1).
///
/// The app used to hand SwiftTerm one `UIFont` built from the host's monospace
/// family and nothing else. On Leo's machine that family is Nimbus Mono PS,
/// which has not one Nerd Font code point, so `ls` drew a box in front of every
/// filename while the same command in kitty two feet away drew icons. The host
/// was not misconfigured: fontconfig asks again per character and lands on
/// JetBrainsMono Nerd Font. The client asked once.
///
/// So the font handed over is a cascade: the host monospace first, then the
/// faces that answer what it cannot draw. Two properties of
/// `kCTFontCascadeListAttribute` shape everything here:
///
/// * CoreText picks per character and rewrites the run's `.font` attribute, and
///   SwiftTerm draws each glyph at `column × cellWidth` with the run's own font
///   (`AppleTerminalView.swift`), so a substituted glyph lands on the grid and
///   cannot push the rest of the line sideways;
/// * the list is consulted **before** the platform's own fallback and does not
///   replace it. That was measured, not assumed
///   (`TerminalFontTests.testThePlatformsOwnFallbackSurvivesTheCascade`): with
///   an empty cascade a Han ideograph still reaches PingFang SC. So the CJK and
///   emoji entries below are insurance against a future release that does
///   replace it, and the symbols entry is the one doing the work.
///
/// What a missing glyph actually looks like is worth writing down: CoreText does
/// not leave `.notdef` on screen, it substitutes `.LastResort`, whose glyph for
/// an unassigned private-use point is a box with a question mark in it. That is
/// Leo's 方块问号, exactly.
enum TerminalFont {

    /// Apply the host's faces to one terminal view.
    ///
    /// `TerminalView.font = x` derives bold and italic from that one font and
    /// would throw the cascade away on the derived faces, so all four are set
    /// explicitly.
    @MainActor static func apply(to view: TerminalView, size: CGFloat,
                                 fonts: HostFontSet = OmodachiTheme.fonts) {
        let set = faces(size: size, fonts: fonts)
        view.setFonts(normal: set.normal, bold: set.bold, italic: set.italic, boldItalic: set.boldItalic)
    }

    struct Faces {
        let normal: UIFont
        let bold: UIFont
        let italic: UIFont
        let boldItalic: UIFont
    }

    /// The four faces, built from the host's families and the platform's.
    ///
    /// The host publishes a regular and a bold and no italic — `fc-list` is
    /// asked for the family the user chose, and Omarchy's own terminal never
    /// asks for one either. So italic is the platform's synthesis of the same
    /// family, and the cascade behind it is the same chain: a Nerd Font icon in
    /// an italic run is still an icon, not a slanted box.
    nonisolated static func faces(size: CGFloat, fonts: HostFontSet) -> Faces {
        let base = named(fonts.mono, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = named(fonts.monoBold, size: size)
            ?? traited(base, .traitBold)
            ?? .monospacedSystemFont(ofSize: size, weight: .bold)
        let chain = cascade(fonts, base: base)
        return Faces(normal: cascading(base, chain),
                     bold: cascading(bold, chain),
                     italic: cascading(traited(base, .traitItalic) ?? base, chain),
                     boldItalic: cascading(traited(bold, .traitItalic) ?? bold, chain))
    }

    /// The families behind the host monospace, in the order they are asked:
    /// symbols, CJK, emoji.
    ///
    /// Symbols are the ones doing the work — nothing on this device carries a
    /// Nerd Font block. CJK and emoji are asked of `base` itself, so each entry
    /// is by construction the face this platform would have reached for anyway;
    /// naming them cannot change today's rendering and cannot pick a worse face
    /// than the default, and it keeps the chain whole if a future release stops
    /// consulting the default behind a cascade list.
    nonisolated static func cascade(_ fonts: HostFontSet, base: UIFont) -> [String] {
        var families = fonts.symbolCascade
        for sample in [PlatformFallback.cjkSample, PlatformFallback.emojiSample] {
            guard let family = PlatformFallback.family(for: sample, base: base),
                  !families.contains(family) else { continue }
            families.append(family)
        }
        return families
    }

    private nonisolated static func named(_ family: String?, size: CGFloat) -> UIFont? {
        guard let family else { return nil }
        return UIFont(name: family, size: size)
    }

    private nonisolated static func traited(_ font: UIFont, _ trait: UIFontDescriptor.SymbolicTraits) -> UIFont? {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(trait) else { return nil }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private nonisolated static func cascading(_ font: UIFont, _ families: [String]) -> UIFont {
        guard !families.isEmpty else { return font }
        let descriptors = families.map { family in
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        }
        let key = UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String)
        return UIFont(descriptor: font.fontDescriptor.addingAttributes([key: descriptors]),
                      size: font.pointSize)
    }
}

/// Which face *this* iOS really uses for a character, asked rather than written
/// down.
///
/// The names change between releases and between regions — `PingFang SC` is not
/// what a Japanese device reaches for — and a cascade entry built from a wrong
/// guess fails silently. So the question is asked the way the renderer asks it:
/// lay the character out and read back the font CoreText put on the run.
/// `CTFontCreateForString` is the shorter spelling and gives a different answer
/// — on iOS 27 it hands back `.PingFang UI SC` where layout uses
/// `PingFang SC` — and a private, dot-prefixed optical variant is not the name
/// to write into a cascade.
enum PlatformFallback {
    /// `U+4E2D` and `U+1F600`, spelled as escapes: they are probes, not words,
    /// and the string-catalog lint is right to ask about a Chinese literal.
    static let cjkSample = "\u{4E2D}"
    static let emojiSample = "\u{1F600}"

    /// The face a run of `sample` set in `base` ends up in, or `nil` when the
    /// platform has nothing for it.
    ///
    /// `base` is part of the question, not a detail: a *system* font falls back
    /// to the private optical variants (`.PingFang UI SC`), a named family like
    /// Menlo to the public ones (`PingFang SC`). Asking with the font that will
    /// actually carry the cascade is what makes the answer the same face the
    /// platform would have chosen by itself.
    ///
    /// `.LastResort` is Apple's own tofu face — the box with a question mark in
    /// it — so it is an answer of "nothing", not a family.
    static func family(for sample: String, base: UIFont) -> String? {
        let key = "\(base.familyName)\u{0}\(sample)"
        if let cached = Cache.shared.value(key) { return cached }
        let attributed = NSAttributedString(string: sample, attributes: [.font: base])
        let line = CTLineCreateWithAttributedString(attributed)
        var answer: String?
        if let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first,
           let font = (CTRunGetAttributes(run) as NSDictionary)
               .object(forKey: NSAttributedString.Key.font) as? UIFont,
           font.familyName != lastResort, font.familyName != base.familyName {
            answer = font.familyName
        }
        Cache.shared.store(key, answer)
        return answer
    }

    /// Apple's tofu face, by the name CoreText reports for it.
    static let lastResort = ".LastResort" // non-copy: a CoreText family name

    /// One layout pass per base family per probe. The terminal rebuilds its
    /// fonts on every `theme.changed`, every `fonts.changed` and every tap on
    /// the size control, and the answer cannot move between them.
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        /// `[key: .some(nil)]` is "asked, and the platform had nothing", which
        /// is an answer worth not asking twice.
        private var values: [String: String?] = [:]
        func value(_ key: String) -> String?? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }
        func store(_ key: String, _ value: String?) {
            lock.lock(); defer { lock.unlock() }
            values[key] = value
        }
    }
}
