import Foundation

/// Which host bindings this app already offers as a control, and therefore
/// hides from the Keybindings list.
///
/// N-03 / SPEC-F2 §4: the rule is the client's and it is explicit. Core does
/// not publish a semantic identity for a binding — a row is a display string,
/// a dispatcher and an opaque action reference — so the map is written here,
/// keyed on the key combination, which is the only stable handle a row has.
/// (`id` is a sha256 of the whole record and moves whenever the user edits a
/// binding; the label is host text in the host's language.)
///
/// A mapped row is only hidden when the GUI entry it duplicates is actually on
/// screen and usable. With no bar workspaces — no host connection, or a Remote
/// session that owns them — the workspace rows come back, because then the
/// list is the only way to reach them.
enum ShortcutGUIMap {
    /// The three GUI entries this app has for host bindings today.
    enum Capability: Hashable, Sendable {
        /// The bar's mark, which opens and closes the Panel.
        case panel
        /// This list.
        case keybindings
        /// One workspace square in the bar.
        case workspace(Int)

        var description: String {
            switch self {
            case .panel: Strings.shortcutTargetBarButton
            case .keybindings: Strings.shortcutTargetThisList
            case let .workspace(id): Strings.shortcutTargetWorkspace(Format.count(id))
            }
        }
    }

    /// Key combination → the GUI entry that already does it. Written out rather
    /// than derived, so adding an entry to the app is a deliberate edit here.
    static let table: [String: Capability] = {
        var value: [String: Capability] = [
            // `omarchy-menu`, the row the Panel replaces.
            "SUPER+SPACE": .panel,
            // `omarchy-menu-keybindings`, the row this list replaces.
            "SUPER+K": .keybindings,
        ]
        // `Switch to workspace 1`…`10`. Omarchy binds 10 to SUPER + 0, the same
        // way the bar draws it as `0` (`Workspaces.qml 57`).
        for number in 1...9 { value["SUPER+\(number)"] = .workspace(number) }
        value["SUPER+0"] = .workspace(10)
        return value
    }()

    /// `"SUPER SHIFT + 3"` → `"SUPER+SHIFT+3"`. The host prints modifiers
    /// space-separated before the ` + ` and the key after it.
    static func normalize(_ display: String) -> String {
        display
            .uppercased()
            .split(whereSeparator: { $0 == "+" || $0.isWhitespace })
            .joined(separator: "+")
    }

    static func capability(forDisplay display: String) -> Capability? {
        table[normalize(display)]
    }

    /// ARCH-1 §7 (1). The two rows this app runs itself, and no others.
    ///
    /// The workspace rows used to be in this set: the bar draws the squares, so
    /// tapping the row moved the bar's own selection. SHORTCUT-1 makes the host
    /// run every binding the way the key would, and a workspace row pressed in
    /// this list should do exactly what `SUPER+3` does — so it travels. What
    /// stays local is the two rows whose destination is *this device*: the
    /// Omarchy menu is panel ①'s menu half, and this list is its other half.
    static func localCapability(_ capability: Capability) -> Capability? {
        switch capability {
        case .panel, .keybindings: capability
        case .workspace: nil
        }
    }
}

extension ShortcutGUICoverage {
    /// The coverage for one snapshot of what the app is currently showing.
    /// `reachableWorkspaces` is the bar's own visible collection, so the map
    /// never hides a workspace the bar does not draw.
    static func fromGUI(panelAvailable: Bool, keybindingsAvailable: Bool,
                        reachableWorkspaces: Set<Int>, actionRefs: Set<String> = []) -> ShortcutGUICoverage {
        var capabilities: Set<String> = []
        if panelAvailable { capabilities.insert(key(.panel)) }
        if keybindingsAvailable { capabilities.insert(key(.keybindings)) }
        for id in reachableWorkspaces { capabilities.insert(key(.workspace(id))) }
        return .init(reachableActionRefs: actionRefs, reachableCapabilities: capabilities)
    }

    static func key(_ capability: ShortcutGUIMap.Capability) -> String {
        switch capability {
        case .panel: "gui.panel"
        case .keybindings: "gui.keybindings"
        case let .workspace(id): "gui.workspace.\(id)"
        }
    }
}

extension ShortcutEntry {
    /// The GUI entry this row duplicates, resolved from its key combination.
    var resolvedGUICapability: String? {
        ShortcutGUIMap.capability(forDisplay: keys).map(ShortcutGUICoverage.key)
    }

    /// Plain-language reason a row is hidden, for the expandable line at the
    /// bottom of the list.
    var guiCapabilityDescription: String? {
        ShortcutGUIMap.capability(forDisplay: keys)?.description
    }
}
