import Foundation

/// **The only file in this target that may contain a colour, alpha or size
/// literal.** (`docs/specs/SPEC-F2-ios-panel-bar-shortcut.md` §1, §7.1.)
///
/// It is the placeholder a device paints with before it has ever reached a
/// host, and the floor under a `shell.toml` section a theme replaced without
/// re-declaring every key. Once `/v1/theme` has answered once, the cached host
/// document wins for every key it carries.
///
/// Provenance, value for value:
///
/// - `colors` are Omarchy's own `themes/tokyo-night/colors.toml`, copied at
///   `omodachi-brand/design-system/research/source-evidence/themes__tokyo-night__colors.toml`
///   (upstream `omacom/omarchy` @ `2fbac0c8e88eca704af1650ce721a494bd11a3d0`).
/// - `numbers` are the defaults in Omarchy's own
///   `/usr/share/omarchy/default/themed/shell.toml.tpl`, copied at
///   `omodachi-core/contracts/fixtures/theme/shell.toml.tpl`. The `[spacing]`
///   and `[font]` steps are the values that file ships **commented out**, which
///   `docs/theme.md` documents as "the defaults they are".
///
/// Nothing here is a design decision taken in this repository.
enum FallbackTheme {
    /// The placeholder theme's own name. Not copy: it is what `/v1/theme`
    /// would have called this document, shown in Settings as provenance.
    static let placeholderName = "tokyo-night (bundled placeholder)"

    /// `themes/tokyo-night/colors.toml`, role for role.
    static let colors: [String: String] = [
        "accent": "#7aa2f7",
        "selection": "#292e42",
        "muted": "#414868",
        "background": "#1a1b26",
        "dark_background": "#13141c",
        "darker_background": "#0e0e14",
        "lighter_background": "#24283b",
        "foreground": "#a9b1d6",
        "dark_foreground": "#565f89",
        "light_foreground": "#b4bee6",
        "bright_foreground": "#c0caf5",
        "red": "#f7768e",
        "yellow": "#e0af68",
        "orange": "#eb927b",
        "green": "#9ece6a",
        "cyan": "#449dab",
        "blue": "#7aa2f7",
        "magenta": "#ad8ee6",
        "brown": "#75493d",
        "bright_red": "#ff7a93",
        "bright_yellow": "#ff9e64",
        "bright_green": "#b9f27c",
        "bright_cyan": "#0db9d7",
        "bright_blue": "#7da6ff",
        "bright_magenta": "#bb9af7",
    ]

    /// `shell.toml.tpl`'s numeric defaults, section by section. Keys whose
    /// template value is a `{{ }}` colour placeholder are not here: those are
    /// colours the live file always carries (`docs/theme.md`), and they resolve
    /// through `HostTheme.shellColor(_:_:fallback:)` to a colour role instead.
    static let numbers: [String: [String: Double]] = [
        "bar": ["background-alpha": 1.0, "size-horizontal": 26, "size-vertical": 28],
        "controls": [
            "normal-fill-alpha": 0.04, "normal-border-width": 1, "normal-border-alpha": 0.4,
            "hover-cursor-fill-alpha": 0.08, "hover-cursor-border-width": 1, "hover-cursor-border-alpha": 0.25,
            "focus-fill-alpha": 0.08, "focus-border-width": 1, "focus-border-alpha": 0.25,
            "selected-fill-alpha": 0.18, "selected-border-width": 0, "selected-border-alpha": 1.0,
            "pressed-fill-alpha": 0.22, "selection-fill-alpha": 0.35,
        ],
        "spacing": [
            "scale": 1.0,
            "xxs": 2, "xs": 3, "sm": 4, "md": 6, "lg": 8, "xl": 10, "xxl": 12, "xxxl": 14, "huge": 18,
            "control-gap": 8, "control-padding-x": 10, "control-padding-y": 6, "input-padding-y": 7,
            "control-height": 28, "popup-row-height": 28, "row-gap": 8, "row-padding-x": 12,
            "label-gap": 4, "panel-gap": 14, "panel-padding": 18, "popup-padding": 14,
            "dropdown-width": 240, "searchable-dropdown-width": 260, "number-field-width": 120,
            "searchable-popup-min-height": 220,
        ],
        "font": [
            "base-size": 12, "caption": 10, "body-small": 11, "body": 12, "subtitle": 13,
            "title": 14, "heading": 16, "display": 24, "display-large": 28,
            "icon-small": 11, "icon": 14, "icon-large": 18,
        ],
        "menu": ["background-alpha": 1.0, "border-alpha": 1.0, "scrim-alpha": 0.5,
                 "selected-background-alpha": 0.08, "selected-border-alpha": 0.25],
        "launcher": ["background-alpha": 0.95, "border-alpha": 1.0, "scrim-alpha": 0.5,
                     "selected-background-alpha": 0.08, "selected-border-alpha": 0.25],
        "popups": ["background-alpha": 1.0, "border-alpha": 1.0, "border-width": 2],
        "tooltip": ["background-alpha": 0.97, "border-alpha": 1.0],
        "notifications": ["background-alpha": 1.0, "border-alpha": 1.0, "border-width": 2],
        "polkit": ["background-alpha": 1.0, "border-alpha": 1.0, "scrim-alpha": 0.5],
        "lock": ["background-alpha": 0.8, "border-alpha": 1.0, "selection-alpha": 0.45],
        "image-picker": ["scrim-alpha": 0.5, "selected-border-alpha": 1.0, "unselected-border-alpha": 0.28],
    ]

    static func number(_ section: String, _ key: String) -> Double? { numbers[section]?[key] }

    static func rgb(_ role: ThemeColorRole) -> (Double, Double, Double) {
        // Every role above parses; the tuple keeps this function total.
        colors[role.rawValue].flatMap(HostTheme.parse(hex:)) ?? (0, 0, 0)
    }

    /// The placeholder theme: Tokyo Night's palette on the template's defaults.
    /// It carries no wallpaper and revision 0, so any host document replaces it.
    static var theme: HostTheme {
        var shell: [String: [String: ShellValue]] = [:]
        for (section, values) in numbers {
            shell[section] = values.mapValues { ShellValue.number($0) }
        }
        // The colour keys the template interpolates, resolved to the roles it
        // names, so a client that has never met a host still has a whole
        // `[bar]` / `[menu]` / `[popups]` surface rather than half of one.
        shell["bar", default: [:]]["background"] = .text(colors["background"]!)
        shell["bar", default: [:]]["text"] = .text(colors["foreground"]!)
        shell["bar", default: [:]]["active"] = .text(colors["red"]!)
        shell["hyprland"] = ["active-border": .text(colors["accent"]!),
                             "active-border-foreground": .text(colors["foreground"]!)]
        for surface in ["menu", "launcher", "popups", "tooltip", "notifications", "polkit", "lock"] {
            shell[surface, default: [:]]["background"] = .text(colors["background"]!)
            shell[surface, default: [:]]["text"] = .text(colors["foreground"]!)
        }
        for surface in ["menu", "launcher"] {
            shell[surface, default: [:]]["scrim"] = .text(colors["background"]!)
            shell[surface, default: [:]]["selected-background"] = .text(colors["foreground"]!)
            shell[surface, default: [:]]["selected-text"] = .text(colors["accent"]!)
            shell[surface, default: [:]]["border"] = .text(colors["foreground"]!)
            shell[surface, default: [:]]["selected-border"] = .text(colors["foreground"]!)
        }
        shell["popups", default: [:]]["border"] = .text(colors["accent"]!)
        shell["notifications", default: [:]]["border"] = .text(colors["accent"]!)
        return HostTheme(name: placeholderName, mode: "dark",
                         colors: colors, shell: shell, background: nil, revision: 0)
    }
}
