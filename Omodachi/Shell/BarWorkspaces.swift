import SwiftUI

/// Which workspaces the bar draws, and how.
///
/// N-16 / `Workspaces.qml 20–31`: the official bar starts from `[1,2,3,4,5]`
/// and unions in every workspace that exists, so it usually shows five to
/// seven squares rather than a constant ten. `state.workspace.items` marks the
/// fixed five with `persistent`, which is exactly that rule expressed on the
/// wire (`omodachi-core/docs/local-integration.md`). A self-drawn bar that
/// showed ten would not line up with the bar in the stream.
enum NativeWorkspacePolicy {
    static func visible(_ rows: [BarWorkspace]) -> [BarWorkspace] {
        var seen = Set<Int>()
        return rows
            .filter { $0.id > 0 && seen.insert($0.id).inserted }
            // `occupied == nil` is "no compositor reading", which the state
            // contract says is not a claim of emptiness — so the row stays.
            .filter { $0.persistent || $0.occupied != false || $0.active == true }
            .sorted { $0.id < $1.id }
    }

    /// `Workspaces.qml 57`: workspace 10 is drawn as `0`, matching its
    /// `SUPER + 0` binding.
    static func label(_ id: Int) -> String { id == 10 ? "0" : String(id) }
}

/// The workspace squares in the bar's left segment.
///
/// N-34: the long press here is the only long press on the whole bar, and it
/// has the visible alternative the rule demands — the Keybindings list's
/// `Move window to workspace`, which N-03 hides from the browse list and shows
/// in search.
struct BarWorkspaceButtons: View {
    let workspaces: [BarWorkspace]
    var vertical = false
    let onSelect: (Int) -> Void
    let onMoveFocusedWindow: (Int) -> Void

    var body: some View {
        ForEach(workspaces, id: \.id) { workspace in
            Tap(enabled: workspace.canSelect, action: { onSelect(workspace.id) }) { square(workspace) }
                .accessibilityIdentifier("workspace-\(workspace.id)")
                .accessibilityLabel(Strings.barWorkspaceName(NativeWorkspacePolicy.label(workspace.id)))
                .accessibilityValue(value(workspace))
                .accessibilityAddTraits(workspace.active == true ? [.isSelected] : [])
                .contextMenu {
                    TextTap(Strings.barWorkspaceMoveHere, enabled: workspace.canMoveFocusedWindow) {
                        onMoveFocusedWindow(workspace.id)
                    }
                }
        }
    }

    /// A-65: the square is a number; what a screen reader needs is its state.
    private func value(_ workspace: BarWorkspace) -> String {
        if workspace.active == true { return Strings.barWorkspaceCurrent }
        switch workspace.occupied {
        case true: return Strings.barWorkspaceOccupied
        case false: return Strings.barWorkspaceEmpty
        default: return Strings.barWorkspaceUnknown
        }
    }

    /// D-14: one size for every state. A vacant workspace only loses opacity —
    /// it is not smaller, not lower and not a different type size, because a
    /// row of numbers whose baseline moves is a row that jitters.
    private func square(_ workspace: BarWorkspace) -> some View {
        let active = workspace.active == true
        let vacant = workspace.occupied == false && !active
        return Text(NativeWorkspacePolicy.label(workspace.id))
            .font(OmodachiTheme.font("body", weight: active ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(active ? OmodachiTheme.selectedText : OmodachiTheme.barText)
            .frame(width: NativeBarMetrics.workspaceSquare, height: NativeBarMetrics.workspaceSquare)
            .background(active ? OmodachiTheme.selectedFill : OmodachiTheme.normalFill)
            .overlay(Rectangle()
                .strokeBorder(active ? .clear : OmodachiTheme.controlBorder,
                              lineWidth: OmodachiTheme.controlBorderWidth))
            .opacity(vacant ? NativeBarMetrics.vacantOpacity : 1)
            .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
            .contentShape(Rectangle())
    }
}
