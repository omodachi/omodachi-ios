import SwiftUI

/// HERDR-4. The Quick dock: one-tap replies, the agent's own commands and the
/// operator's rows, between the screen and the composer.
///
/// Every row comes from core (`GET /v1/herdr/operator-rows`), resolved for the
/// pane on screen: an agent pane gets yes / no and continue / commit and push /
/// retry / skip, a shell gets y / n, unless the operator's Collie-format TOML
/// says otherwise. A tap is one `/text` with submit (the same proof as the
/// composer), and the dock closes so the screen shows what happened.
struct HerdrQuickDock: View {
    @ObservedObject var store: HerdrStore
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    /// VERIFY-1: the harness segment is in one place. Where the bar carries it
    /// (an iPad, regular both ways) the dock leaves it out; on a phone, and a
    /// phone on its side whose bar holds the keys, it heads the dock.
    private var harnessOnBar: Bool { horizontal != .compact && vertical != .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(OmodachiTheme.border)
                .frame(height: NativeBarMetrics.edgeRule).accessibilityHidden(true)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                    if let note = store.operatorWarning {
                        Text(note)
                            .font(OmodachiTheme.font("caption"))
                            .foregroundStyle(OmodachiTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("herdr-quick-warning")
                    }
                    if !harnessOnBar, !store.operatorRows.harness.isEmpty {
                        group(Strings.herdrQuickHarness, identifier: "herdr-quick-harness") {
                            ForEach(store.operatorRows.harness) { row in
                                armedTap(HerdrHarnessWords.title(row), id: "harness:" + row.command, // non-copy
                                         role: .accent) { store.send(harness: row) }
                                    .accessibilityHint(Strings.herdrHarnessHint(row.command))
                                    .accessibilityIdentifier("herdr-harness-\(row.harnessID ?? row.command)")
                            }
                        }
                    }
                    ForEach(store.operatorRows.quick, id: \.identity) { group in
                        self.group(HerdrHarnessWords.title(group), identifier: "herdr-quick-\(group.identity)") {
                            ForEach(group.items, id: \.self) { item in
                                TextTap(item, bordered: true) { store.sendQuick(item) }
                                    .accessibilityIdentifier("herdr-quick-item-\(item)")
                            }
                        }
                    }
                    if !store.operatorRows.commands.isEmpty {
                        group(Strings.herdrQuickCommands, identifier: "herdr-quick-commands") {
                            ForEach(store.operatorRows.commands) { row in
                                armedTap(row.command + (row.argHint.map { " " + $0 } ?? ""), id: "command:" + row.command, // non-copy
                                         role: nil) { store.run(command: row) }
                                    .accessibilityHint(row.description ?? "")
                                    .accessibilityIdentifier("herdr-command-\(row.command)")
                            }
                        }
                    }
                }
                .padding(.horizontal, OmodachiTheme.panelPadding)
                .padding(.vertical, OmodachiTheme.space("md"))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-quick-dock")
    }

    private func group<Content: View>(_ title: String, identifier: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("xs")) {
            Text(title)
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(OmodachiTheme.secondaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OmodachiTheme.space("sm")) { content() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// A row that may need a second tap says so on itself while it is armed.
    private func armedTap(_ title: String, id: String, role: ThemeColorRole?,
                          action: @escaping () -> Void) -> some View {
        let armed = store.isArmed(id)
        return TextTap(armed ? Strings.herdrTapAgain : title, role: armed ? .yellow : role,
                       selected: armed, bordered: true, action: action)
    }
}

/// The words for rows that ship: core sends an id, the app says it in the
/// reader's language. An operator's own words are drawn as written.
enum HerdrHarnessWords {
    static func title(_ row: HerdrOperatorRowsDTO.Harness) -> String {
        if let label = row.label { return label }
        switch row.harnessID {
        case "model": return Strings.herdrHarnessModel
        case "effort": return Strings.herdrHarnessEffort
        case "compact": return Strings.herdrHarnessCompact
        case "resume": return Strings.herdrHarnessResume
        default: return row.command
        }
    }

    static func title(_ group: HerdrOperatorRowsDTO.Quick) -> String {
        if let title = group.title { return title }
        switch group.id {
        case "confirm": return Strings.herdrQuickConfirm
        case "common": return Strings.herdrQuickCommon
        default: return ""
        }
    }
}
