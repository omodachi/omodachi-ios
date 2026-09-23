import SwiftUI

/// The one catalog row that cannot be a plain row: changing a workspace's
/// layout needs a workspace *and* a layout, and the host refuses a request that
/// names neither.
///
/// N-14 rather than a dialog (ARCH-1 §1): the first tap turns the row into the
/// question, the second answers it. The selection is captured when the question
/// is asked, so a host update arriving while it is on screen cannot change what
/// the second tap applies — it can only make it stale, and a stale one is
/// refused with the reason written out.
struct WorkspaceLayoutControl: View {
    @EnvironmentObject private var home: HomeStore
    @State private var selection: WorkspaceLayoutSelection?

    var body: some View {
        let offer = home.workspaceLayoutOffer
        VStack(alignment: .leading, spacing: 0) {
            if let selection {
                confirmation(selection)
            } else {
                Row(title: offer?.label ?? Strings.menuLayoutUnknown,
                    icon: Icon.herdr,
                    enabled: offer != nil && !home.workspaceLayoutBusy,
                    identifier: "workspace-layout-select") {
                    self.selection = try? offer?.selection()
                }
            }
        }
    }

    @ViewBuilder private func confirmation(_ captured: WorkspaceLayoutSelection) -> some View {
        let stale = !captured.matchesCurrent(home.workspaceLayoutOffer)
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            Text(stale
                 ? Strings.menuLayoutStale
                 : Strings.menuLayoutScope)
                .font(OmodachiTheme.bodyFont("body-small"))
                .foregroundStyle(OmodachiTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: OmodachiTheme.space("lg")) {
                FlowButton(title: Strings.workspaceLayoutApply(Format.count(captured.request.params.workspaceID), captured.request.params.layout.label),
                           kind: .primary, enabled: !stale) {
                    selection = nil
                    Task { await home.applyWorkspaceLayout(captured) }
                }
                .accessibilityIdentifier("workspace-layout-apply")
                FlowButton(title: Strings.actionCancel, kind: .ghost) { selection = nil }
                    .accessibilityIdentifier("workspace-layout-cancel")
            }
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.vertical, OmodachiTheme.space("lg"))
        .accessibilityIdentifier("workspace-layout-confirm")
    }
}
