import SwiftTerm
import SwiftUI
import UIKit

/// The colours the two terminal surfaces draw with (§3).
///
/// `shell.toml` has no `[terminal]` section on the host this was built against
/// — its sections are bar, hyprland, controls, spacing, font, popups, tooltip,
/// notifications, launcher, menu, polkit, lock, image-picker — so the palette is
/// built from `colors`, which is the same 16-colour set Omarchy's own
/// `alacritty.toml` template is rendered from. If a host ever does publish
/// `[terminal]`, those keys win: the theme document is the authority, and this
/// file is only the mapping from role names to ANSI slots.
enum TerminalPalette {
    /// The ANSI slot each role fills. `color0`/`color15` are the two ends of the
    /// background/foreground pair rather than literal black and white, because
    /// a light Omarchy theme has no black to draw.
    static let ansiRoles: [ThemeColorRole] = [
        .darkerBackground, .red, .green, .yellow, .blue, .magenta, .cyan, .foreground,
        .darkForeground, .brightRed, .brightGreen, .brightYellow, .brightBlue, .brightMagenta,
        .brightCyan, .brightForeground
    ]

    /// `[terminal] color0…color15`, if a host publishes them.
    static func key(_ index: Int) -> String { "color\(index)" }

    static func ansi(_ theme: HostTheme) -> [(Double, Double, Double)] {
        ansiRoles.enumerated().map { index, role in
            theme.shell["terminal"]?[key(index)]?.string.flatMap(HostTheme.parse(hex:)) ?? theme.rgb(role)
        }
    }

    static func background(_ theme: HostTheme) -> (Double, Double, Double) {
        theme.shell["terminal"]?["background"]?.string.flatMap(HostTheme.parse(hex:)) ?? theme.rgb(.background)
    }

    static func foreground(_ theme: HostTheme) -> (Double, Double, Double) {
        theme.shell["terminal"]?["foreground"]?.string.flatMap(HostTheme.parse(hex:)) ?? theme.rgb(.foreground)
    }

    static func cursor(_ theme: HostTheme) -> (Double, Double, Double) {
        theme.shell["terminal"]?["cursor"]?.string.flatMap(HostTheme.parse(hex:)) ?? theme.rgb(.accent)
    }

    private static func swiftTerm(_ value: (Double, Double, Double)) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(value.0 * 65535), green: UInt16(value.1 * 65535), blue: UInt16(value.2 * 65535))
    }

    /// Repaint one terminal view from the theme that is current right now.
    @MainActor static func apply(to view: TerminalView, theme: HostTheme = OmodachiTheme.current) {
        view.installColors(ansi(theme).map(swiftTerm))
        view.nativeBackgroundColor = UIColor(rgb: background(theme))
        view.nativeForegroundColor = UIColor(rgb: foreground(theme))
        view.caretColor = UIColor(rgb: cursor(theme))
        view.selectedTextBackgroundColor = UIColor(rgb: theme.rgb(.selection))
    }
}
