import CoreText
import SwiftUI
import UIKit

/// One decision, in one place, for every host-supplied glyph the app draws.
///
/// UX-1 item 8. The host's `icon` field is not always a glyph. Three shapes
/// arrive on a real Omarchy install and the old code drew all three the same
/// way — in the bundled symbols-only face:
///
/// 1. a Nerd Font code point (`U+F489`, `U+F0343`), which is what the field is
///    for;
/// 2. `"iconFont": "omarchy"` plus a private code point from `omarchy.ttf`;
/// 3. **an XDG icon *name*** — `org.gnome.Nautilus`, `google-chrome`,
///    `docker`, `x` — on every `apps.*` row core compiles from a `.desktop`
///    file, plus a handful of literal emoji (`🟢`) and `✓`.
///
/// `Symbols Nerd Font Mono` carries no letterforms, so case 3 rendered as a row
/// of empty boxes inside the 36pt glyph column with the label beside it: Leo's
/// "很多方块+文字渲染的有问题". Case 1 also has a hole — Omarchy still ships a
/// few pre-3.0 Material Design code points (`U+F835`) that current Nerd Font
/// releases moved to the `U+F0000` plane and no installed face carries.
///
/// So the rule is not "which family is this row tagged for" but **"which
/// registered family actually has a glyph for these code points"**, asked of
/// CoreText, with the row's own SF Symbol as the answer when none does. That is
/// the only way the fallback can be honest: a family can be registered and
/// still be missing the code point.
enum HostGlyph {

    /// What to draw for one host row.
    enum Resolution: Equatable, Sendable {
        /// Draw `text` in this font family (`nil` = the platform's own font,
        /// which is what carries emoji).
        case text(family: String?)
        /// Nothing installed can draw it; the caller uses its SF Symbol.
        case symbol
    }

    /// Whether a registered family has a real glyph for every scalar in `text`.
    ///
    /// `CTFontGetGlyphsForCharacters` answers `false` and writes glyph 0
    /// (`.notdef`) for a code point the font does not map, which is exactly the
    /// tofu box. It is asked per family rather than per font size because the
    /// cmap does not vary with size.
    nonisolated static func covers(_ text: String, family: String) -> Bool {
        guard !text.isEmpty else { return false }
        let key = Key(text: text, family: family)
        if let cached = Cache.shared.value(key) { return cached }
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        // One scalar at a time. `CTFontGetGlyphsForCharacters` takes UTF-16,
        // and for a non-BMP scalar — every `U+F0000`-plane Material Design icon
        // Omarchy uses — it writes the real glyph into the first slot and
        // leaves the surrogate's slot as 0. Asking about the whole string at
        // once therefore reports `.notdef` for exactly the code points this
        // resolver exists to find.
        var value = true
        for scalar in text.unicodeScalars {
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
            if glyphs.first == 0 || glyphs.first == nil { value = false; break }
        }
        Cache.shared.store(key, value)
        return value
    }

    /// Emoji are neither a Nerd Font code point nor a name: no monospace face
    /// carries them and the platform's own emoji font does. Asking CoreText the
    /// coverage question about `Apple Color Emoji` by family name is unreliable
    /// (it is resolved through the cascade, not by name), so the scalar's own
    /// property is the authority.
    nonisolated static func isEmoji(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return false }
        return scalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }
    }

    /// The whole rule. `fonts` is passed in so this stays testable without the
    /// shared runtime, and so a test can assert the real host's font set.
    nonisolated static func resolve(_ text: String, iconFont: String?, fonts: HostFontSet) -> Resolution {
        guard !text.isEmpty else { return .symbol }
        if isEmoji(text) { return .text(family: nil) }
        // Anything with more than one scalar is a name, not a glyph. Every real
        // glyph the host publishes is a single code point; `org.gnome.Nautilus`
        // is not, and neither is `google-chrome`. Drawing a name is never right,
        // so the row falls back to its own symbol rather than to letterforms in
        // an icon column that is 36pt wide.
        guard text.unicodeScalars.count == 1 else { return .symbol }
        // A one-character name is still a name. `apps.X` publishes `"x"`, and
        // the only reason it is not caught by the rule above is its length; a
        // bare ASCII letter or digit is never a Nerd Font code point.
        if let scalar = text.unicodeScalars.first, scalar.isASCII,
           CharacterSet.alphanumerics.contains(scalar) { return .symbol }
        // A row tagged for Omarchy's private face only ever comes from it; the
        // code points are private-use and mean something else everywhere else.
        if iconFont == "omarchy" {
            guard let icons = fonts.icons, covers(text, family: icons) else { return .symbol }
            return .text(family: icons)
        }
        // A Nerd Font code point, in preference order: the host monospace when
        // it is patched, then the bundled symbols-only face.
        if fonts.monoHasNerdGlyphs, let mono = fonts.mono, covers(text, family: mono) {
            return .text(family: mono)
        }
        if covers(text, family: HostFontSet.bundledSymbols) {
            return .text(family: HostFontSet.bundledSymbols)
        }
        // A plain character the host meant literally (`✓`) is still drawable by
        // the body font; only a code point nothing carries falls through.
        if text.unicodeScalars.allSatisfy({ $0.value < 0xE000 }) { return .text(family: nil) }
        return .symbol
    }

    @MainActor static func resolve(_ text: String, iconFont: String?) -> Resolution {
        resolve(text, iconFont: iconFont, fonts: OmodachiTheme.fonts)
    }

    private struct Key: Hashable { let text: String; let family: String }

    /// `CTFontGetGlyphsForCharacters` creates a font and reads its cmap; the
    /// menu asks the same question for the same handful of strings on every
    /// scroll, so the answer is remembered. It is keyed on the family name, and
    /// a family that is replaced by `fonts.changed` re-registers under a new
    /// name or is unregistered, so a stale `true` cannot outlive its file.
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var values: [Key: Bool] = [:]
        func value(_ key: Key) -> Bool? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func store(_ key: Key, _ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            if values.count > 2048 { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
    }
}

/// What a row draws when — and only when — the host published nothing this
/// device can draw (MENU-1 §2).
///
/// It is never a substitute for a host glyph: `HostGlyph.resolve` is asked
/// first, always, and a row whose `icon` is a real code point never reaches
/// here. A fallback is the answer to "the host left this field empty, or filled
/// it with a name", so the three cases are the three reasons that happens.
///
/// `ExpressibleByStringLiteral` so a surface that just wants an SF Symbol still
/// writes `fallbackSymbol: "xmark"`.
enum GlyphFallback: Hashable, Sendable, ExpressibleByStringLiteral {
    /// An SF Symbol name.
    case symbol(String)
    /// The app's own mark. Core publishes the `omodachi` row with `"icon": ""`
    /// (`omodachi_core/data/omodachi-menu.jsonc`) because that row is ours, not
    /// Omarchy's — so the glyph for it is ours too, not a stock laptop.
    case mark
    /// A generic application window, for a `kind == "app"` row whose icon name
    /// this host cannot resolve. Those rows carry an XDG icon *name*
    /// (`org.gnome.Nautilus`, `google-chrome`); the host draws the icon theme's
    /// PNG for it (`Menu.qml` `appIconImage`). One honest generic beats a
    /// column of circles, and beats tofu.
    case app
    /// ICON-1. The host published an icon **name**, and the host will answer
    /// with the picture: `GET /v1/icons/{name}`
    /// (`omodachi-core/docs/icons.md`). Until the bytes arrive — and for ever
    /// if the host answers `404` — this draws `.app`, so a row never waits and
    /// never blinks.
    case icon(String)
    /// AGENT-2's vendor mark, demoted by ICON-1 to a fallback.
    ///
    /// ③ and ④ are windows onto somebody else's product, and Leo asked for
    /// their own marks there. But the thing he then compared them against was
    /// the host's bar, where Omarchy draws a Nerd Font code point for both, so
    /// **the host's glyph comes first** and the mark is what is drawn when no
    /// installed face carries it.
    case vendor(BrandMark, symbol: String)

    init(stringLiteral value: String) { self = .symbol(value) }
}

/// The one component that draws a host glyph. Every surface uses it — the menu
/// tree, the Remote entry cards, Settings, the host list, the pairing card —
/// so a row that cannot be drawn falls back the same way everywhere (UX-1 §8).
struct HostGlyphView: View {
    /// What the host published for this row. May be a code point, a name, or
    /// empty.
    let glyph: String
    /// The font tag the host published alongside it.
    var iconFont: String = ""
    /// What to draw when nothing can draw `glyph`.
    var fallbackSymbol: GlyphFallback
    var size: CGFloat

    var body: some View {
        switch HostGlyph.resolve(glyph, iconFont: iconFont) {
        case .text(let family):
            Text(glyph)
                .font(family.map { Font.custom($0, size: size) } ?? .system(size: size))
                // A face whose advance is wider than the column must not push
                // the label; the box is the column.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        case .symbol:
            switch fallbackSymbol {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: size))
            case .mark:
                OmodachiSymbol.view(size: size)
            case .app:
                // Drawn through the same resolver, so it lands in the host's
                // icon face beside the rows that did publish a code point
                // rather than in a second, foreign icon language.
                HostGlyphView(glyph: Icon.app.nerd, fallbackSymbol: .symbol(Icon.app.symbol), size: size)
            case .icon(let name):
                HostIconImage(name: name, size: size)
            case .vendor(let mark, let symbol):
                if UIImage(named: mark.rawValue) != nil {
                    Image(mark.rawValue)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        // A mark is drawn to the same optical size as the glyph
                        // it replaces, so turning one on does not move the bar.
                        .frame(width: size, height: size)
                } else {
                    Image(systemName: symbol).font(.system(size: size))
                }
            }
        }
    }
}

/// One host icon, or the generic application glyph until it is here.
///
/// ICON-1. The picture is fetched by `HostIconStore`, which never blocks a
/// render: the first pass draws the generic glyph and asks, and the row swaps
/// to the real icon when the bytes land. An icon the host has no picture for
/// stays generic for ever rather than being re-asked on every scroll.
struct HostIconImage: View {
    let name: String
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var store = HostIconStore.shared

    var body: some View {
        if let image = store.image(named: name, points: size, scale: displayScale) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            HostGlyphView(glyph: Icon.app.nerd, fallbackSymbol: .symbol(Icon.app.symbol), size: size)
        }
    }
}

/// The app's own icon entry, and the only one (ARCH-1 §1).
///
/// Every glyph outside `DesignSystem` goes through this, so three rules hold
/// everywhere at once instead of per call site:
///
/// * the size is a `[font]` step, never a number a view picked (A-48);
/// * when the host's own face carries the Nerd Font code point this icon has a
///   name for, that is what is drawn — the bar and the menu then look like one
///   shell rather than like Omarchy with an iOS toolbar bolted on;
/// * it is hidden from VoiceOver (A-65). A glyph is never the label: the
///   control around it carries the words, because "" read aloud is noise.
struct Glyph: View {
    /// The SF Symbol to fall back to, which is also what this icon *means*.
    let symbol: String
    /// The Nerd Font code point to prefer when an installed face has it. Empty
    /// means this icon has no host equivalent worth asking for.
    var nerd: String = ""
    /// A `[font]` step name. `icon` is the bar and row default (14 → 16 on a
    /// tablet), `icon-small` the inline one, `icon-large` the card one.
    var step = "icon"
    /// Set only where the caller genuinely owns the box (the 22 bar glyph
    /// inside its 44 slot, A-03).
    var points: CGFloat?

    var body: some View {
        HostGlyphView(glyph: nerd, iconFont: "", fallbackSymbol: .symbol(symbol),
                      size: points ?? OmodachiTheme.fontSize(step))
            .accessibilityHidden(true)
    }
}

/// The Nerd Font code points this app asks the host's face for, by name.
///
/// They are written down once, here, so a surface names an icon rather than a
/// code point — and so the fallback SF Symbol and the host glyph for one idea
/// can never drift apart. Every value is a Nerd Font v3 code point; a host face
/// that does not carry one falls back through `HostGlyph.resolve`.
enum Icon {
    static let menu        = (symbol: "line.3.horizontal", nerd: "\u{f0c9}")
    static let search      = (symbol: "magnifyingglass", nerd: "\u{f002}")
    static let close       = (symbol: "xmark", nerd: "\u{f00d}")
    static let check       = (symbol: "checkmark", nerd: "\u{f00c}")
    static let chevronRight = (symbol: "chevron.right", nerd: "\u{f054}")
    static let chevronDown = (symbol: "chevron.down", nerd: "\u{f078}")
    static let chevronUp   = (symbol: "chevron.up", nerd: "\u{f077}")
    static let pin         = (symbol: "pin", nerd: "\u{f08d}")
    static let pinFilled   = (symbol: "pin.fill", nerd: "\u{f08d}")
    static let remote      = (symbol: "display", nerd: "\u{f108}")
    /// ICON-1 §2. What Omarchy's own bar draws for the agents widget, verbatim:
    /// `/usr/share/omarchy/shell/plugins/agents/Panel.qml:342  text: "\u{f16a3}"`.
    /// It was `U+F2BD`, a person in a circle, which is nothing the host has
    /// ever drawn for an agent.
    static let agent       = (symbol: "cpu", nerd: "\u{f16a3}")
    /// ICON-1 §2. What Omarchy's own bar draws for Herdr, verbatim:
    /// `~/.config/omarchy/plugins/jankeesvw.herdr/Panel.qml:54`
    /// `readonly property string iconServer: "\uF233"`, drawn by the
    /// `BarIconButton` at `:793-812`. It was `U+F00A`, a grid of squares.
    static let herdr       = (symbol: "server.rack", nerd: "\u{f233}")
    static let ssh         = (symbol: "terminal", nerd: "\u{f120}")
    static let settings    = (symbol: "gearshape", nerd: "\u{f013}")
    static let bell        = (symbol: "bell", nerd: "\u{f0f3}")
    static let bellOff     = (symbol: "bell.slash", nerd: "\u{f1f6}")
    static let keyboard    = (symbol: "keyboard", nerd: "\u{f11c}")
    static let keyboardDown = (symbol: "keyboard.chevron.compact.down", nerd: "\u{f11c}")
    static let rotationLock = (symbol: "lock.rotation", nerd: "\u{f023}")
    static let pointer     = (symbol: "cursorarrow.motionlines", nerd: "\u{f245}")
    static let speaker     = (symbol: "speaker.wave.2", nerd: "\u{f028}")
    static let speakerOff  = (symbol: "speaker.slash", nerd: "\u{f026}")
    static let stop        = (symbol: "stop.circle", nerd: "\u{f04d}")
    static let warning     = (symbol: "exclamationmark.triangle", nerd: "\u{f071}")
    static let error       = (symbol: "exclamationmark.circle", nerd: "\u{f06a}")
    static let working     = (symbol: "ellipsis", nerd: "\u{f141}")
    static let host        = (symbol: "desktopcomputer", nerd: "\u{f108}")
    static let send        = (symbol: "arrow.up.circle.fill", nerd: "\u{f062}")
    static let retry       = (symbol: "arrow.clockwise", nerd: "\u{f01e}")
    static let dnd         = (symbol: "moon", nerd: "\u{f186}")
    static let more        = (symbol: "ellipsis", nerd: "\u{f141}")
    /// `nf-md-application`. The generic stand-in for a `kind == "app"` row whose
    /// XDG icon name this device cannot resolve (MENU-1 §2).
    static let app         = (symbol: "macwindow", nerd: "\u{f08c6}")
}

extension Glyph {
    /// `Glyph(.remote)` — the form every surface uses.
    init(_ icon: (symbol: String, nerd: String), step: String = "icon", points: CGFloat? = nil) {
        self.init(symbol: icon.symbol, nerd: icon.nerd, step: step, points: points)
    }
}
