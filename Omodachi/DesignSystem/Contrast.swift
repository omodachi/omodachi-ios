import CoreGraphics
import SwiftUI

/// A-48's second half, as arithmetic.
///
/// UX-1 item 5. Omarchy's `muted` is a *border and fill* colour — on the
/// bundled Tokyo Night fallback it is `#414868`, which is 1.91:1 against the
/// panel background, and the app was using it for every secondary line of text
/// in the Panel, the bar, the Keybindings list and Settings. Half of those
/// then multiplied it by `0.52`, which is 1.36:1. On a desktop at a metre that
/// reads as "dim"; on an iPad in the hand it reads as "可读性有点差".
///
/// A-48's instruction is not to invent a colour but to **pick a
/// higher-contrast token out of the same theme when the intended one does not
/// clear 4.5:1**. That is a measurement, so it is made here, at runtime,
/// against whatever theme the host sent — a palette whose `muted` *is*
/// legible keeps it.
enum OmodachiContrast {
    /// WCAG 2.1 relative luminance, sRGB.
    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
    }

    static func ratio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// A-48's floor for body and secondary text.
    static let minimum: Double = 4.5

    /// The first role in `preference` that clears `minimum` against `background`,
    /// or the last one — which is always the theme's own foreground, and is the
    /// most legible thing the theme has to offer.
    static func legibleRole(_ preference: [ThemeColorRole], on background: ThemeColorRole,
                            in theme: HostTheme) -> ThemeColorRole {
        let bg = theme.rgb(background)
        for role in preference where ratio(theme.rgb(role), bg) >= minimum { return role }
        return preference.last ?? .foreground
    }
}

extension OmodachiTheme {
    /// Secondary text — status lines, group labels, the bar's surface name.
    /// The theme's `muted` when that is legible, and the dimmest legible
    /// foreground the theme has when it is not.
    static var secondaryText: Color {
        current.color(OmodachiContrast.legibleRole([.muted, .lightForeground, .foreground],
                                                   on: .background, in: current))
    }

    /// The third level — the lines that used to be `muted.opacity(0.52)`: a
    /// row's "also in the bar", a key binding's reason, a note under a setting.
    /// It is still the dimmest of the three, but it is a token rather than a
    /// literal alpha over an already-dim one.
    static var tertiaryText: Color {
        current.color(OmodachiContrast.legibleRole([.darkForeground, .muted, .lightForeground, .foreground],
                                                   on: .background, in: current))
    }
}
