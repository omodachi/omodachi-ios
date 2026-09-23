import SwiftUI

/// The other half of panel ① (A-54): the host's real keybindings
/// (`GET /v1/shortcuts`), as the list Study 01 §02 draws — a 44 search row, 58
/// detail rows with the key block right aligned, and one expandable line at the
/// bottom naming what the app's own controls already cover.
///
/// It has its own `PINNED` group (N-39) and its own search and scroll (A-31).
/// Executing a row never dismisses it and never resets either (A-26).
///
/// The title row belongs to `PanelArea` now, so there is no header and no ×
/// here: A-55 took both away.
struct KeybindingsView: View {
    @ObservedObject var store: ShortcutPanelStore
    /// CLIP-1 §1. ⑥'s switch: whether the rows the host publishes with no
    /// executable binding are in the list at all. They are never runnable —
    /// when they are shown they are greyed with the host's own reason.
    var showsUnrunnable = false
    /// A-25: `SUPER + K` lands on the search field, not on the first row.
    var focusSearchOnAppear = false
    @Binding var editing: Bool
    var pins: [ResolvedPin<ShortcutEntry>] = []
    var isPinned: (ShortcutEntry) -> Bool = { _ in false }
    var onTogglePin: (ShortcutEntry) -> Void = { _ in }

    private var entries: [ShortcutEntry] { store.model.visibleEntries(in: store.context) }
    private var covered: [ShortcutEntry] { store.model.coveredEntries(in: store.context) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            search
            if store.context.supportsGlobalShortcuts { list } else { unsupported }
            if let notice = store.model.notice {
                Text(notice)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(store.model.failed ? OmodachiTheme.warning : OmodachiTheme.muted)
                    .padding(OmodachiTheme.rowPaddingX)
                    .accessibilityIdentifier("shortcut-result")
            }
            if store.model.failed {
                TextTap(Strings.actionRetry, bordered: true) { Task { await store.refresh() } }
                    .padding(.horizontal, OmodachiTheme.rowPaddingX)
            }
        }
        .background(OmodachiTheme.background)
        .foregroundStyle(OmodachiTheme.text)
        .task {
            store.model.showsUnrunnableEntries = showsUnrunnable
            if store.model.snapshot == nil { await store.refresh() }
        }
        // CLIP-1 §1: ⑥ can move the switch while this list is on screen.
        .onChange(of: showsUnrunnable) { _, value in store.model.showsUnrunnableEntries = value }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native-shortcut-panel")
    }

    /// A-06: the same 44 field as the Panel's — now literally the same one.
    ///
    /// It was a second copy of `Field`'s body written out here, which is how it
    /// inherited `Field`'s bug (a 22-high target inside a 44-high box) without
    /// being anywhere near the fix. A Surface composes primitives; it does not
    /// draw a control of its own (ARCH-1 §1).
    private var search: some View {
        Field(placeholder: Strings.keybindingsSearch, text: $store.model.query,
              identifier: "shortcut-search", focusOnAppear: focusSearchOnAppear)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.model.query.isEmpty {
                    PinnedGroup(editing: $editing, isEmpty: pins.isEmpty,
                                identifier: "pinned-keybindings",
                                emptyHint: Strings.pinnedEmptyKeyHint) {
                        ForEach(pins) { row in pinnedRow(row) }
                    }
                }
                ForEach(entries) { entry in actionRow(entry).id(entry.id) }
                if store.model.loading {
                    ProgressView().padding(OmodachiTheme.panelPadding)
                } else if entries.isEmpty && !store.model.failed {
                    Text(store.model.query.isEmpty ? Strings.keybindingsEmpty : Strings.keybindingsNoMatch)
                        .font(OmodachiTheme.font("subtitle"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .padding(.vertical, 22).padding(.horizontal, OmodachiTheme.rowPaddingX)
                }
                if !covered.isEmpty { coveredFooter }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $store.model.scrollEntryID, anchor: .top)
        .scrollDismissesKeyboard(.interactively)
    }

    /// The bottom line: how many rows the bar and the Panel already cover, and
    /// where they are. Tapping it puts them back into the list in place.
    private var coveredFooter: some View {
        let places = Set(covered.compactMap(\.guiCapabilityDescription))
        return Tap(action: { store.model.showsCoveredEntries.toggle() }) {
            HStack(spacing: OmodachiTheme.space("lg")) {
                Glyph(symbol: store.model.showsCoveredEntries ? "chevron.down" : "chevron.right", points: OmodachiTheme.fontSize("icon-small"))
                VStack(alignment: .leading, spacing: 0) {
                    Text(Strings.keybindingsHidden(Format.count(covered.count)))
                        .font(OmodachiTheme.font("body-small"))
                    Text(places.sorted().joined(separator: "、"))
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.tertiaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(OmodachiTheme.secondaryText)
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(maxWidth: .infinity, minHeight: NativeBarMetrics.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        
        .accessibilityIdentifier("shortcut-covered-toggle")
        .accessibilityLabel(Strings.keybindingsHidden(Format.count(covered.count)))
    }

    private var unsupported: some View {
        VStack(alignment: .leading) {
            Text(Strings.keybindingsUseSurface)
                .font(OmodachiTheme.font("subtitle"))
                .foregroundStyle(OmodachiTheme.secondaryText)
                .padding(.vertical, 22).padding(.horizontal, OmodachiTheme.rowPaddingX)
            Spacer()
        }
    }

    /// A-19: name on the first line, key block right aligned and never wrapped.
    /// A row the host cannot execute is dimmed with the host's own reason under
    /// it, rather than hidden.
    /// N-39 rev 5: a pin whose binding the host no longer has is drawn from its
    /// label snapshot, dimmed, and says so. It is never removed silently.
    @ViewBuilder private func pinnedRow(_ row: ResolvedPin<ShortcutEntry>) -> some View {
        if let entry = row.target {
            actionRow(entry)
        } else {
            Row(title: row.pin.label, detail: Strings.menuGone, icon: Icon.warning,
                enabled: false, identifier: "pin-tombstone-\(row.pin.stableKey)", action: { }) {
                EmptyView()
            }
        }
    }

    private func actionRow(_ entry: ShortcutEntry) -> some View {
        let reason = store.model.disabledReason(for: entry, context: store.context)
        let hidden = store.model.coverage.covers(entry)
        return Tap(action: { Task { await store.execute(entry) } }) {
            HStack(spacing: OmodachiTheme.space("lg")) {
                VStack(alignment: .leading, spacing: OmodachiTheme.space("label-gap")) {
                    Text(entry.label)
                        .font(OmodachiTheme.font("title"))
                        .foregroundStyle(entry.enabled ? OmodachiTheme.text : OmodachiTheme.muted)
                        .lineLimit(1).truncationMode(.tail)
                    if let reason, !entry.enabled || entry.actionRef == nil || entry.requiresTarget || hidden {
                        Text(reason)
                            .font(OmodachiTheme.font("body-small"))
                            .foregroundStyle(OmodachiTheme.tertiaryText)
                            .lineLimit(1).truncationMode(.tail)
                    } else if hidden, let place = entry.guiCapabilityDescription {
                        Text(Strings.keybindingsAlsoIn(place))
                            .font(OmodachiTheme.font("body-small"))
                            .foregroundStyle(OmodachiTheme.tertiaryText)
                    }
                }
                Spacer(minLength: OmodachiTheme.space("lg"))
                if store.model.executingEntryID == entry.id {
                    ProgressView().controlSize(.small)
                }
                KeyBlock(display: entry.keys)
                if editing {
                    PinButton(pinned: isPinned(entry), height: RowHeight.detail,
                              identifier: "pin-\(entry.id)", label: entry.label,
                              action: { onTogglePin(entry) })
                }
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(maxWidth: .infinity, minHeight: RowHeight.detail, alignment: .leading)
            .contentShape(Rectangle())
        }
        .onLongPressGesture { onTogglePin(entry) }
        .disabled(reason != nil)
        .accessibilityLabel(entry.label)
        .accessibilityValue(entry.keys)
        .accessibilityHint(reason ?? Strings.keybindingsRunHint)
        .accessibilityIdentifier("shortcut-\(entry.id)")
    }
}

/// `kbd` — one bordered cell per key, at `body-small`, in the host monospace.
/// The block is right aligned and does not wrap: A-19 says the description is
/// the half that gets truncated when the column is narrow, not the keys.
struct KeyBlock: View {
    let display: String

    private var keys: [String] {
        display.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: OmodachiTheme.space("sm")) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.text)
                    .padding(.horizontal, OmodachiTheme.space("md"))
                    .padding(.vertical, OmodachiTheme.space("sm"))
                    .background(OmodachiTheme.normalFill)
                    .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder,
                                                      lineWidth: OmodachiTheme.controlBorderWidth))
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}
