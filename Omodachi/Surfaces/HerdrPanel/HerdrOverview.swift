import SwiftUI

/// OVERVIEW-1. Where "everything that wants you" lives: on the Herdr session
/// switcher. That row is already the answer to "where am I looking"; with the
/// list beside it it also answers "where am I wanted" — across the Agent and
/// every session — without a new tab or a sheet (A-55: a panel fills the panel
/// area, so the list is a card under the switcher, like New session…).
///
/// * the switcher row ends with the counts ("Needs you 2 · Done 1"), and a tap
///   opens the list;
/// * the list is three groups — Needs you, Working, Done, not seen — each in
///   core's order (position, never status); a row says the exact ask with the
///   agent's mark and where it is, and one tap goes there;
/// * the session menu says each session's counts; the workspace chips carry
///   their most urgent state; a finished pane nobody has opened carries a
///   square (shape, not colour alone).
enum OverviewWords {
    /// What the row asks, in a few words. A question is the agent's own words,
    /// drawn verbatim after our lead-in.
    static func ask(_ row: OverviewRow) -> String {
        switch row.ask {
        case .approveCommand: return Strings.overviewAskApproveCommand
        case .approveFiles: return Strings.overviewAskApproveFiles
        case .approvePermissions: return Strings.overviewAskApprovePermissions
        case .approve: return Strings.overviewAskApprove
        case .answer: return Strings.overviewAskAnswer
        case .pick: return row.question.map(Strings.overviewAskPickQuestion) ?? Strings.overviewAskPick
        case .yesNo: return row.question.map(Strings.overviewAskYesNoQuestion) ?? Strings.overviewAskYesNo
        case .waiting: return Strings.herdrWaiting
        case .working: return Strings.overviewAskWorking
        case .yourMove: return row.question.map(Strings.overviewAskYourMove) ?? Strings.overviewAskFinished
        case .finished: return Strings.overviewAskFinished
        case .failed: return Strings.overviewAskFailed
        }
    }

    /// Where it is: the agent, then the Agent panel or session · workspace ·
    /// pane (the host's own names, verbatim; a pane named like its workspace
    /// is said once).
    static func place(_ row: OverviewRow) -> String {
        var parts: [String] = []
        if let agent = row.agent { parts.append(agent) }
        switch row.source {
        case .agent:
            parts.append(Strings.panelAgent)
        case .herdr:
            if let session = row.session { parts.append(session) }
            if let workspace = row.workspace { parts.append(workspace) }
            if let pane = row.pane, pane != row.workspace, pane != row.agent { parts.append(pane) }
        }
        return parts.joined(separator: " · ")
    }

    /// "Needs you 2 · Done 1 · Working 3", non-zero only; nil when all are zero.
    static func counts(_ counts: OverviewCounts) -> String? {
        var parts: [String] = []
        if counts.needsYou > 0 { parts.append(Strings.overviewCountNeedsYou(Format.count(counts.needsYou))) }
        if counts.done > 0 { parts.append(Strings.overviewCountDone(Format.count(counts.done))) }
        if counts.working > 0 { parts.append(Strings.overviewCountWorking(Format.count(counts.working))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The switcher's few words: only the most urgent count (a phone's row
    /// has room for one), the whole line in VoiceOver and in the list.
    static func headline(_ counts: OverviewCounts) -> String? {
        if counts.needsYou > 0 { return Strings.overviewCountNeedsYou(Format.count(counts.needsYou)) }
        if counts.done > 0 { return Strings.overviewCountDone(Format.count(counts.done)) }
        if counts.working > 0 { return Strings.overviewCountWorking(Format.count(counts.working)) }
        return nil
    }

    static func role(_ state: OverviewRow.State) -> ThemeColorRole {
        switch state {
        case .needsYou: AgentStatus.blocked.role
        case .working: AgentStatus.working.role
        case .done: AgentStatus.done.role
        }
    }

    static func section(_ state: OverviewRow.State) -> String {
        switch state {
        case .needsYou: Strings.overviewSectionNeedsYou
        case .working: Strings.overviewSectionWorking
        case .done: Strings.overviewSectionDone
        }
    }

    static func chipLabel(_ state: OverviewRow.State) -> String {
        switch state {
        case .needsYou: Strings.overviewChipNeedsYou
        case .working: Strings.overviewChipWorking
        case .done: Strings.badgeUnseen
        }
    }
}

/// A chip's or a row's state mark: a dot for waiting and working, a square for
/// finished and not seen (Collie: the square survives colour blindness and
/// does not compete with the status colours). Always `size` wide, drawn or
/// not, so nothing moves when it appears.
struct OverviewMark: View {
    let state: OverviewRow.State?
    var size: CGFloat = 6

    var body: some View {
        ZStack {
            if let state {
                if state == .done {
                    Rectangle().fill(OmodachiTheme.current.color(OverviewWords.role(state)))
                } else {
                    Circle().fill(OmodachiTheme.current.color(OverviewWords.role(state)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The counts at the end of the switcher row; a tap opens (or closes) the list.
struct HerdrOverviewSummary: View {
    @ObservedObject var store: HerdrStore
    let overview: OverviewReading

    var body: some View {
        if !overview.rows.isEmpty, let words = OverviewWords.counts(overview.counts),
           let headline = OverviewWords.headline(overview.counts) {
            Tap(selected: store.overviewOpen, bordered: true, action: toggle) {
                HStack(spacing: OmodachiTheme.space("sm")) {
                    OverviewMark(state: overview.counts.needsYou > 0 ? .needsYou
                                 : overview.counts.done > 0 ? .done : .working)
                    Text(headline)
                        .font(OmodachiTheme.font("caption", weight: .semibold))
                        .foregroundStyle(overview.counts.needsYou > 0 ? OmodachiTheme.current.color(.red)
                                         : OmodachiTheme.text)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, OmodachiTheme.space("lg"))
                .frame(height: OmodachiTheme.controlHeight)
                .contentShape(Rectangle())
            }
            .frame(height: NativeBarMetrics.hit)
            .fixedSize()
            .accessibilityLabel(Strings.overviewOpen)
            .accessibilityValue(words)
            .accessibilityHint(Strings.overviewOpenHint)
            .accessibilityAddTraits(store.overviewOpen ? [.isSelected] : [])
            .accessibilityIdentifier("herdr-overview-open")
        }
    }

    private func toggle() {
        if !store.overviewOpen {
            store.cancelNewSession()
            store.cancelNewWorkspace()
        }
        store.overviewOpen.toggle()
    }
}

/// The list, under the switcher.
struct HerdrOverviewCard: View {
    @ObservedObject var store: HerdrStore
    let overview: OverviewReading
    let open: (OverviewRow) -> Void
    /// The list scrolls inside the card, so a long one never pushes the pane
    /// off: at most this tall (the Herdr surface passes half its height, so a
    /// phone on its side keeps rows of the mirror).
    var listHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("sm")) {
            HStack(spacing: OmodachiTheme.space("md")) {
                Text(Strings.overviewTitle)
                    .font(OmodachiTheme.font("body", weight: .semibold))
                    .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                TextTap(Strings.actionCollapse, step: "caption") { store.overviewOpen = false }
                    .accessibilityIdentifier("herdr-overview-close")
            }
            if overview.rows.isEmpty {
                Text(Strings.overviewEmpty)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .accessibilityIdentifier("herdr-overview-empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(OverviewRow.State.allCases, id: \.self) { state in
                            let rows = overview.rows(state)
                            if !rows.isEmpty {
                                Text(OverviewWords.section(state))
                                    .font(OmodachiTheme.font("caption", weight: .semibold))
                                    .foregroundStyle(state == .needsYou ? OmodachiTheme.current.color(.red)
                                                     : OmodachiTheme.secondaryText)
                                    .padding(.top, OmodachiTheme.space("sm"))
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityIdentifier("herdr-overview-section-\(state.rawValue)")
                                ForEach(rows) { row in
                                    HerdrOverviewRowView(row: row) { open(row) }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: listHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(OmodachiTheme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmodachiTheme.normalFill)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-overview")
    }
}

/// One row: the agent's mark, the ask, where it is. The whole row is the tap.
struct HerdrOverviewRowView: View {
    let row: OverviewRow
    let action: () -> Void

    var body: some View {
        Tap(action: action) {
            HStack(alignment: .center, spacing: OmodachiTheme.space("md")) {
                HerdrAgentMarker(mark: BrandMark.provider(row.agent), role: OverviewWords.role(row.state))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: OverviewWords.ask(row))
                        .font(OmodachiTheme.font("body"))
                        .foregroundStyle(OmodachiTheme.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: OverviewWords.place(row))
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Glyph(Icon.chevronRight, step: "icon-small")
                    .foregroundStyle(OmodachiTheme.secondaryText)
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.vertical, OmodachiTheme.space("sm"))
            .frame(minHeight: NativeBarMetrics.hit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OverviewWords.ask(row))
        .accessibilityValue(OverviewWords.place(row))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("overview-row-\(row.id)")
    }
}
