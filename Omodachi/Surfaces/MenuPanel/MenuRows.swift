import SwiftUI

/// The merged three-source Omarchy menu, as a tree.
///
/// A-05: depth is an 18pt indent plus a 1px rule at the row's left edge — not a
/// breadcrumb, and not a disclosure triangle that would make the tree jump under
/// the finger. Rows are 50 (`Menu.qml 99–115`); a search result is A-19's 58-high
/// detail row, whose second line is where the action lives.
///
/// A-55 took the push stack away, so a branch does not open a page: it expands
/// in place, one level at a time, and the indent is what says where you are.
struct MenuTree: View {
    let items: [MenuItem]
    var query: String = ""
    var searchResults: [MenuItem]?
    /// N-39: in edit mode every row shows the pin at its trailing end.
    var editing = false
    let isPinned: (MenuItem) -> Bool
    let onTogglePin: (MenuItem) -> Void
    let onRoute: (MenuItem) -> Void

    @State private var expanded: Set<String> = []

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// With a query: the host's own `GET /v1/catalog?q=` answer once it lands,
    /// and a local match over the same merged catalog until it does. Both are
    /// the same rows.
    private var visible: [MenuItem] {
        guard searching else { return items }
        if let searchResults { return searchResults }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return items.flatMap(\.all).filter { item in
            guard seen.insert(item.id).inserted else { return false }
            return item.id.localizedCaseInsensitiveContains(term)
                || item.label.localizedCaseInsensitiveContains(term)
                || item.aliases.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if visible.isEmpty {
                EmptyState(title: query.isEmpty ? Strings.menuEmpty : Strings.menuEmptyNoMatch,
                           detail: query.isEmpty ? nil : Strings.menuEmptySearchHint,
                           identifier: "menu-empty")
            } else if searching {
                GroupLabel(text: Strings.menuResults)
                ForEach(visible) { item in
                    MenuDetailRow(item: item, pinned: isPinned(item), editing: true,
                                  onTogglePin: { onTogglePin(item) }, onRoute: onRoute)
                }
            } else {
                GroupLabel(text: Strings.menuGroup)
                ForEach(visible) { item in rows(item, depth: 0) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("omarchy-menu")
    }

    @ViewBuilder private func rows(_ item: MenuItem, depth: Int) -> AnyView {
        AnyView(rowsBody(item, depth: depth))
    }

    @ViewBuilder private func rowsBody(_ item: MenuItem, depth: Int) -> some View {
        MenuActionRow(item: item, pinned: isPinned(item), editing: editing, depth: depth,
                      expanded: expanded.contains(item.id),
                      onTogglePin: { onTogglePin(item) },
                      onRoute: { row in
                          if row.children.isEmpty { onRoute(row) }
                          else if expanded.contains(row.id) { expanded.remove(row.id) }
                          else { expanded.insert(row.id) }
                      })
        if expanded.contains(item.id) {
            ForEach(item.children) { child in rows(child, depth: depth + 1) }
        }
    }
}

/// A 50-high tree row.
struct MenuActionRow: View {
    let item: MenuItem
    let pinned: Bool
    var editing = false
    var depth: Int = 0
    var expanded = false
    let onTogglePin: () -> Void
    let onRoute: (MenuItem) -> Void
    @EnvironmentObject private var home: HomeStore

    private var checked: Bool? { home.state.toggles[item.id] ?? item.checked }

    var body: some View {
        content
    }

    @ViewBuilder private var content: some View {
        if item.children.isEmpty, item.id == WorkspaceLayoutRequest.entryID {
            WorkspaceLayoutControl()
        } else {
            Row(title: item.label,
                hostGlyph: item.glyph, hostIconFont: item.iconFont, fallbackSymbol: item.icon,
                enabled: item.enabled, depth: depth,
                identifier: "menu-\(item.id)",
                action: { onRoute(item) }) {
                trailing
            }
            .onLongPressGesture { onTogglePin() }
        }
    }

    /// N-39's visible alternative to the long press, and the row's own state.
    ///
    /// PERF-5 adds the two states a row can be in on its own account: on its
    /// way to the host, and refused by it. They live here, next to `不可用`,
    /// rather than in the panel's toast, because the toast says what the last
    /// tap did and this says what *this row* is doing.
    @ViewBuilder private var trailing: some View {
        HStack(spacing: 0) {
            if let armed = home.armedConfirm, armed.entryID == item.id {
                // MENU-4 / A-68: the first tap armed this row; the second sends it.
                TapAgainCountdown(until: armed.until, window: ConfirmArm.window,
                                  identifier: "menu-confirm-\(item.id)")
            } else if home.pendingEntryIDs.contains(item.id) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, OmodachiTheme.space("sm"))
                    .accessibilityLabel(Strings.menuSending)
            } else if let reason = home.rowFailures[item.id] {
                Text(reason)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.trailing, OmodachiTheme.space("sm"))
            }
            if !item.enabled, item.children.isEmpty {
                Text(item.disabledReason.map { ReasonText.message($0, domain: .host) } ?? Strings.menuUnavailable)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
            }
            if checked == true {
                Glyph(Icon.check, step: "icon-small").foregroundStyle(OmodachiTheme.selectedText)
            }
            if !item.children.isEmpty {
                Glyph(expanded ? Icon.chevronDown : Icon.chevronRight, step: "icon-small")
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .padding(.trailing, OmodachiTheme.space("lg"))
            }
            if editing { PinButton(pinned: pinned, height: RowHeight.action,
                                   identifier: "pin-\(item.id)", label: item.label, action: onTogglePin) }
        }
    }
}

/// A-19's 58-high detail row: the action's name, and where it lives underneath.
struct MenuDetailRow: View {
    let item: MenuItem
    let pinned: Bool
    var editing = false
    let onTogglePin: () -> Void
    let onRoute: (MenuItem) -> Void
    @EnvironmentObject private var home: HomeStore

    private var source: String {
        item.path.isEmpty ? Strings.menuRootPath : item.path.joined(separator: " › ")
    }

    var body: some View {
        Row(title: item.label, detail: source,
            hostGlyph: item.glyph, hostIconFont: item.iconFont, fallbackSymbol: item.icon,
            enabled: item.enabled || !item.children.isEmpty,
            identifier: "menu-\(item.id)",
            action: { onRoute(item) }) {
            if let armed = home.armedConfirm, armed.entryID == item.id {
                TapAgainCountdown(until: armed.until, window: ConfirmArm.window,
                                  identifier: "menu-confirm-\(item.id)")
            }
            if editing {
                PinButton(pinned: pinned, height: RowHeight.detail,
                          identifier: "pin-\(item.id)", label: item.label, action: onTogglePin)
            }
        }
    }
}

/// N-34's visible alternative to a long press: a 16pt pin inside a 44 hit area
/// at the row's trailing end, filled accent when pinned and hollow at .55 when
/// not.
struct PinButton: View {
    let pinned: Bool
    let height: CGFloat
    let identifier: String
    let label: String
    let action: () -> Void

    var body: some View {
        Tap(selected: pinned, action: action) {
            Glyph(pinned ? Icon.pinFilled : Icon.pin, step: "icon-small")
                .foregroundStyle(pinned ? OmodachiTheme.selectedText : OmodachiTheme.muted)
                .opacity(pinned ? 1 : 0.55)
                .frame(width: NativeBarMetrics.hit, height: height)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(pinned ? Strings.pinnedUnpin(label) : Strings.pinnedPin(label))
    }
}
