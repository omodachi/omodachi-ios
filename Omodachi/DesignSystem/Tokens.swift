import Foundation
import Observation
import SwiftUI
import UIKit

/// The one place the app reads its palette, its type scale and its fonts from.
///
/// It is `@Observable`, so every SwiftUI `body` that touches `OmodachiTheme`
/// registers a dependency on it and redraws when a `theme.changed` event lands
/// — without a `.id()` on the root, which would tear down navigation stacks,
/// terminal sessions and the Remote surface.
///
/// Order of authority: the live host document, then the last one this device
/// cached, then `FallbackTheme` — which is the only theme that was never on a
/// host, and the only one carrying literals.
@MainActor @Observable final class ThemeRuntime {
    static let shared = ThemeRuntime()

    private(set) var theme: HostTheme
    private(set) var fonts: HostFontSet
    /// `host`, `cache` or `bundled`. Reported in Setup so a screenshot can say
    /// which one it is rather than leaving it to be inferred from the colours.
    private(set) var origin: Origin
    private(set) var backgroundImage: UIImage?

    enum Origin: String, Sendable { case host, cache, bundled }

    private let defaults: UserDefaults
    private static let themeKey = "omodachi.theme.v1"
    private static let fontsKey = "omodachi.fonts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.themeKey),
           let cached = try? JSONDecoder().decode(HostTheme.self, from: data), cached.isComplete {
            theme = cached
            origin = .cache
        } else {
            theme = FallbackTheme.theme
            origin = .bundled
        }
        fonts = .unavailable
    }

    func apply(_ value: HostTheme, origin: Origin = .host) {
        guard value.isComplete else { return }
        guard value != theme || self.origin != origin else { return }
        theme = value
        self.origin = origin
        if origin == .host, let data = try? JSONEncoder().encode(CachedTheme(value)) {
            defaults.set(data, forKey: Self.themeKey)
        }
    }

    func apply(_ value: HostFontSet) { fonts = value }
    func apply(background: UIImage?) { backgroundImage = background }

    /// Back to the placeholder. Used when a device is unpaired, never on a
    /// transient network failure: a disconnected app keeps the host's look.
    func reset() {
        defaults.removeObject(forKey: Self.themeKey)
        defaults.removeObject(forKey: Self.fontsKey)
        theme = FallbackTheme.theme
        origin = .bundled
        fonts = .unavailable
        backgroundImage = nil
    }
}

/// `HostTheme` decodes the host document; this re-encodes exactly the same
/// shape so the cache round-trips through the same decoder.
private struct CachedTheme: Encodable {
    struct Background: Encodable {
        let sha256: String, bytes: Int, content_type: String?
    }
    let name: String, mode: String, colors: [String: String]
    let shell: [String: [String: ShellValueBox]], revision: Int
    let background: Background?
    init(_ theme: HostTheme) {
        name = theme.name; mode = theme.mode; colors = theme.colors; revision = theme.revision
        shell = theme.shell.mapValues { $0.mapValues(ShellValueBox.init) }
        background = theme.background.map { .init(sha256: $0.sha256, bytes: $0.bytes, content_type: $0.contentType) }
    }
}

private struct ShellValueBox: Encodable {
    let value: ShellValue
    init(_ value: ShellValue) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let .text(text): try container.encode(text)
        case let .number(number): try container.encode(number)
        case let .flag(flag): try container.encode(flag)
        }
    }
}

/// The drawable half of the theme document. `Host/HostTheme` decodes what the
/// host published and answers in numbers; this is where those numbers become
/// something a view can use, because the DesignSystem is the only layer that
/// may know what a `Color` is (ARCH-1 §1).
extension HostTheme {
    public func color(_ role: ThemeColorRole) -> Color { Color(rgb: rgb(role)) }

    /// A `shell.toml` colour key with its `-alpha` companion applied.
    public func shellColor(_ section: String, _ key: String, fallback: ThemeColorRole) -> Color {
        let value = shellRGBA(section, key, fallback: fallback)
        return Color(rgb: value.rgb, opacity: value.alpha)
    }
}

extension Color {
    init(rgb: (Double, Double, Double), opacity: Double = 1) {
        self.init(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: opacity)
    }
}

extension UIColor {
    convenience init(rgb: (Double, Double, Double), opacity: Double = 1) {
        self.init(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: opacity)
    }
}

/// The app's names for the host's roles. Nothing here decides a value; each
/// property names the `colors.toml` role or `shell.toml` key it reads.
@MainActor enum OmodachiTheme {
    static var current: HostTheme { ThemeRuntime.shared.theme }
    /// One number that moves when either the theme or the font set does.
    /// A SwiftUI body that reads it becomes a dependency of both, which is how
    /// the two UIKit terminal views get repainted without an `.id()` that
    /// would tear down the emulator and the session behind it.
    static var appearanceRevision: Int { current.revision &* 31 &+ fonts.revision }
    static var fonts: HostFontSet { ThemeRuntime.shared.fonts }

    // MARK: - Surfaces

    /// The Panel is a menu card: `[menu] background` (`Color.qml` role map,
    /// `ui-study-02.md` §5).
    static var background: Color { current.shellColor("menu", "background", fallback: .background) }
    static var panel: Color { background }
    /// `[notifications] background` is the raised surface in the same map.
    static var elevated: Color { current.shellColor("notifications", "background", fallback: .lighterBackground) }
    /// `[menu] border`.
    static var border: Color { current.shellColor("menu", "border", fallback: .foreground) }
    /// `[popups] border` — the 2px family (D-01).
    static var popupBorder: Color { current.shellColor("popups", "border", fallback: .accent) }
    static var popupBorderWidth: CGFloat { CGFloat(current.shellNumber("popups", "border-width", fallback: 2)) }
    static var accent: Color { current.color(.accent) }
    static var text: Color { current.shellColor("menu", "text", fallback: .foreground) }
    static var muted: Color { current.color(.muted) }
    static var dimText: Color { current.color(.darkForeground) }
    static var warning: Color { current.color(.yellow) }
    static var danger: Color { current.color(.red) }
    static var success: Color { current.color(.green) }
    /// A terminal is machine text on the deepest background role.
    static var terminal: Color { current.color(.darkBackground) }
    /// The letterbox beside a video picture, and **the one colour in this app
    /// that is not a theme role**. The bars around a 16:9 stream on a 4:3 screen
    /// are the absence of picture; tinting them with the shell's background
    /// would read as a panel the user could touch. Every theme, light or dark,
    /// gets the same black, because that is what "no signal here" looks like.
    static var pictureLetterbox: Color { .black }
    static var selected: Color { current.shellColor("menu", "selected-background", fallback: .foreground) }
    static var selectedText: Color { current.shellColor("menu", "selected-text", fallback: .accent) }
    static var scrim: Color {
        current.shellColor("menu", "scrim", fallback: .background).opacity(current.alpha("menu", "scrim-alpha"))
    }

    // MARK: - Bar

    static var barBackground: Color { current.shellColor("bar", "background", fallback: .background) }
    static var barText: Color { current.shellColor("bar", "text", fallback: .foreground) }
    static var barActive: Color { current.shellColor("bar", "active", fallback: .red) }

    // MARK: - Control states (`[controls]`)

    /// `normal .04 / hover .08 / selected .18 / pressed .22 / selection .35`
    /// (A-08). Touch has no hover, so the hover slot stays empty and a press
    /// goes straight to `pressed`.
    static var normalFill: Color { text.opacity(current.alpha("controls", "normal-fill-alpha")) }
    static var pressedFill: Color { text.opacity(current.alpha("controls", "pressed-fill-alpha")) }
    static var selectedFill: Color { text.opacity(current.alpha("controls", "selected-fill-alpha")) }
    static var focusFill: Color { text.opacity(current.alpha("controls", "focus-fill-alpha")) }
    static var selectionFill: Color { text.opacity(current.alpha("controls", "selection-fill-alpha")) }
    static var controlBorder: Color {
        current.shellColor("controls", "normal-border", fallback: .foreground)
            .opacity(current.alpha("controls", "normal-border-alpha"))
    }
    static var focusBorder: Color {
        current.shellColor("controls", "focus-border", fallback: .foreground)
            .opacity(current.alpha("controls", "focus-border-alpha"))
    }
    /// D-01: controls are 1px, panels are 2px. Two numbers, two sources.
    static var controlBorderWidth: CGFloat { CGFloat(current.shellNumber("controls", "normal-border-width", fallback: 1)) }

    // MARK: - Metrics

    /// `[spacing]` tokens, in points. Never scaled here: the client's density is
    /// already rewritten by the touch rules (A-01/A-03/A-04) and iOS Dynamic
    /// Type is a third scale (`ui-study-02.md` open question 5).
    static func space(_ key: String) -> CGFloat { current.spacing(key) }
    static var controlHeight: CGFloat { current.spacing("control-height") }
    static var rowPaddingX: CGFloat { current.spacing("row-padding-x") }
    static var panelPadding: CGFloat { current.spacing("panel-padding") }
    static var panelGap: CGFloat { current.spacing("panel-gap") }

    // MARK: - Type

    /// A `[font]` step by name. `size:` remains available for the places that
    /// still ask for an explicit point size.
    static func font(_ step: String, weight: Font.Weight = .regular) -> Font {
        // A-48: the host names the step, `OmodachiTypeScale` decides the size.
        font(size: OmodachiTypeScale.size(step: step, hostValue: current.fontStep(step)),
             weight: weight, scaled: false)
    }

    /// The drawn point size of a host step, for the call sites that need the
    /// number rather than the `Font` — icon boxes, and the tests for A-48.
    static func fontSize(_ step: String) -> CGFloat {
        OmodachiTypeScale.size(step: step, hostValue: current.fontStep(step))
    }

    /// A-07. The shell is monospace throughout, but upstream's own
    /// `NotificationCard.qml` is not: it sets Liberation Sans 14 for prose. So
    /// machine text — the bar, the menu, key bindings, terminals, code blocks,
    /// tool rows — keeps the host's mono, and prose (agent message bodies,
    /// empty states, inline toasts) uses the platform text face, where mixed
    /// CJK/Latin line length and IME candidates behave.
    static func bodyFont(_ step: String, weight: Font.Weight = .regular) -> Font {
        .system(size: OmodachiTypeScale.size(step: step, hostValue: current.fontStep(step)), weight: weight)
    }

    static func bodyFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: OmodachiTypeScale.size(points: size), weight: weight)
    }

    /// A point size from a call site that named one itself; A-48's floor still
    /// applies. `scaled: false` is how the step-named overload above hands in a
    /// size it has already scaled, so the lift is never applied twice.
    static func font(size: CGFloat, weight: Font.Weight = .regular, scaled: Bool = true) -> Font {
        let drawn = scaled ? OmodachiTypeScale.size(points: size) : size
        let family = weight == .regular ? fonts.mono : (fonts.monoBold ?? fonts.mono)
        guard let family else { return .system(size: drawn, weight: weight, design: .monospaced) }
        return .custom(family, size: drawn, relativeTo: .body).weight(weight)
    }

    /// The glyph font for one catalog row's `icon`. Nerd Font code points come
    /// from the host monospace when it is a Nerd Font, and otherwise from the
    /// bundled symbols-only face; `"iconFont": "omarchy"` rows always come from
    /// the host's `omarchy.ttf`.
    static func iconFont(size: CGFloat, iconFont: String?) -> Font {
        guard let family = fonts.iconFamily(iconFont: iconFont) else {
            return .system(size: size, design: .monospaced)
        }
        return .custom(family, size: size, relativeTo: .body)
    }

    /// The terminal's regular face. TERM-1: it carries the host's fallback
    /// chain, so a `TerminalView` born with it draws icons even before
    /// `TerminalFont.apply` gives it the host's own bold as well.
    static func uiFont(size: CGFloat) -> UIFont {
        TerminalFont.faces(size: size, fonts: fonts).normal
    }
}
