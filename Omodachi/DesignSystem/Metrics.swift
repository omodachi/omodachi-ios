import SwiftUI

/// The bar's own numbers. Every one of them is either a host `shell.toml`
/// token or a cross-platform adaptation the study names with a rule number —
/// there is no third kind.
enum NativeBarMetrics {
    /// A-03. The host bar is 26 (horizontal) / 28 (vertical); the touch bar is
    /// 44 and the extra is whitespace, not a bigger glyph.
    static let thickness: CGFloat = 44
    /// A-01. Every control keeps its desktop size inside a 44×44 hit region.
    static let hit: CGFloat = 44
    /// `BarIconButton.qml 8–21`: icon slot 27, glyph 13. The glyph is drawn at
    /// the study's 22 inside the 44 slot, which is 27's optical ratio held at
    /// touch size (Study 01 §2.6: enlarge the hit area, not the drawing).
    static let glyph: CGFloat = 22
    /// D-14 / `Workspaces.qml 63,66–67`: the square is a constant, occupied or
    /// not. A vacant one only loses opacity.
    static let workspaceSquare: CGFloat = 28
    /// `Workspaces.qml 66`: `opacity: occupied || focused ? 1 : 0.5`.
    static let vacantOpacity: Double = 0.5
    /// D-01: the panel/bar edge is the 2px Hyprland family, not the 1px control
    /// family.
    static let edgeRule: CGFloat = 2

    /// A-02. The bar is always on a long edge: the top/bottom pair in landscape
    /// and the left/right pair in portrait. A square viewport keeps whichever
    /// edge it already had rather than flipping under the user's finger.
    static func isVertical(_ edge: HostBarPosition) -> Bool { edge == .left || edge == .right }
}

/// The modules this client can actually draw, and what each one needs.
///
/// A host module is rendered only when there is a real `state.*` field behind
/// it. Omarchy's bar carries network, volume, battery and notification widgets;
/// core publishes no state for any of them, so they are skipped rather than
/// mocked (SPEC-F2 §2: "没有的就不画，不造假").
enum NativeBarModule: String, CaseIterable, Sendable {
    case panel, workspaces, clock, focus

    /// The `state.bar` role IDs that resolve to this module.
    static func module(for role: String) -> NativeBarModule? {
        switch role {
        case "logo", "panel", "omodachi": .panel
        case "workspaces", "workspace": .workspaces
        case "clock", "time": .clock
        case "focus", "focused_window", "window", "activewindow": .focus
        // Everything else the host published — tray, agent usage, weather,
        // keyboard layout, updates, bluetooth, network, audio, power, and every
        // third-party widget — has no state contract here yet.
        default: nil
        }
    }

    /// The order this client draws, given one `state.bar` placement list. The
    /// Panel entry is this app's own and always leads, so a host whose menu
    /// widget was replaced by a plugin still has a way into the Panel.
    static func plan(leading: [String], centre: [String], trailing: [String]) -> [NativeBarModule] {
        var planned: [NativeBarModule] = [.panel]
        for role in leading + centre + trailing {
            guard let module = module(for: role), !planned.contains(module) else { continue }
            planned.append(module)
        }
        return planned
    }
}
