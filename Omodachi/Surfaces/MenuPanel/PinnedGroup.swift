import SwiftUI

/// N-39's `PINNED` group: a label with an 编辑 button at its right end, the
/// pinned rows, and a rule under them.
///
/// Two of these exist, one at the top of each half of panel ① — menu pins in
/// the menu half, keybinding pins in the Keybindings half, never mixed. A pinned
/// row is drawn **exactly like an ordinary one** (50 high, 36 glyph box, the same
/// pressed state); the only difference is which group it is in. That is the whole
/// design: a pin is a position, not a new kind of thing.
///
/// Empty, the group still takes its place and says how to fill it (A-33).
/// Without that nobody discovers pinning exists.
struct PinnedGroup<Content: View>: View {
    var title = Strings.pinnedTitle
    @Binding var editing: Bool
    let isEmpty: Bool
    let identifier: String
    /// The sentence shown when nothing is pinned. It names both ways in.
    let emptyHint: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(title)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .kerning(1)
                Spacer(minLength: OmodachiTheme.space("lg"))
                TextTap(editing ? Strings.pinnedEditDone : Strings.pinnedEdit, step: "body-small", role: .accent,
                        minimumHeight: NativeBarMetrics.hit) { editing.toggle() }
                    .accessibilityIdentifier("\(identifier)-edit")
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(height: NativeBarMetrics.hit)
            if isEmpty {
                EmptyState(title: Strings.pinnedEmpty, detail: emptyHint,
                           identifier: "\(identifier)-empty")
            } else {
                content()
            }
            Rectangle().fill(OmodachiTheme.border.opacity(0.35))
                .frame(height: OmodachiTheme.controlBorderWidth)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
