import SwiftUI

// AGENT-COLLIE-1 ideas 1 and 2: a step in a few words, an edit as a card with
// its change, and a run of steps folded into one line. The folding rules are
// ported from Collie (`chat-cards.tsx` `ToolGroup`, MIT, Copyright (c) 2026
// Altan Sarisin); the drawing is this app's own (A-20 rows, D-01 borders).

/// A-20. One turn's structure has to stay readable on a phone, so a tool call
/// is a 28-high control row with the 1px control border; only expanding it
/// turns the output into a mono block.
///
/// AGENT-COLLIE-1: the row says what the step did in a few words ("$ git
/// status", "Read app.py") rather than codex's whole shell line, and a file
/// change is drawn as its change cards.
struct AgentToolRow: View {
    let tool: AgentChatTool
    /// Inside a run: an edit is one line per file, its diff behind a tap.
    var compact = false
    /// A prompt waiting for the person is about this step.
    var waiting = false
    /// What Find is looking for, marked in the step line.
    var query = ""
    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    private var symbol: String {
        switch tool.status {
        case .running: "ellipsis" // non-copy: a glyph name
        case .succeeded: "checkmark" // non-copy: a glyph name
        case .failed: "exclamationmark" // non-copy: a glyph name
        case .cancelled, .interrupted: "minus" // non-copy: a glyph name
        case .unknown: "questionmark" // non-copy: a glyph name
        }
    }
    private var role: ThemeColorRole {
        switch tool.status {
        case .succeeded: .green
        case .failed: .red
        case .cancelled, .interrupted, .unknown: .muted
        case .running: .accent
        }
    }
    private var statusLabel: String {
        if tool.status == .failed, let code = tool.exitCode, code != 0 {
            return Strings.pair(tool.status.label, Strings.agentToolExit(String(code)))
        }
        return tool.status.label
    }

    var body: some View {
        if let changes = tool.changes, !changes.isEmpty {
            AgentChangeCards(tool: tool, changes: changes, compact: compact, waiting: waiting, query: query,
                             glyph: (symbol, role))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                row
                // Outside the labelled row: a label on the row folds what is
                // inside it into one element, and each file has to be its own.
                if let paths = tool.paths, !paths.isEmpty { files(paths) }
            }
        }
    }

    private var row: some View {
        let line = tool.stepLine
        return VStack(alignment: .leading, spacing: 0) {
            Tap(action: { expanded.toggle() }) {
                HStack(spacing: OmodachiTheme.space("lg")) {
                    Glyph(symbol: symbol, points: OmodachiTheme.fontSize("caption"))
                        .foregroundStyle(OmodachiTheme.current.color(role))
                    AgentStepLineText(line: line, query: query)
                    Spacer(minLength: OmodachiTheme.space("sm"))
                    Text(statusLabel).foregroundStyle(OmodachiTheme.secondaryText).lineLimit(1)
                    Glyph(symbol: expanded ? "chevron.up" : "chevron.down", points: OmodachiTheme.fontSize("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                }
                .font(OmodachiTheme.font("body-small"))
                .padding(.horizontal, OmodachiTheme.space("xl"))
                .frame(height: OmodachiTheme.controlHeight)
                .frame(minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
            }
            .control(bordered: true)
            if expanded, !tool.detail.isEmpty {
                if let truncated = tool.detailTruncated {
                    // AGENT-FIX-2: core keeps a command's newest output only.
                    Text(Strings.agentToolTruncated(Format.size(truncated)))
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .padding(.horizontal, OmodachiTheme.space("xl"))
                        .padding(.top, OmodachiTheme.space("md"))
                        .accessibilityIdentifier("agent-tool-truncated-\(tool.id)")
                }
                ScrollView(.horizontal) {
                    Text(tool.detail)
                        .font(OmodachiTheme.font("body"))
                        .textSelection(.enabled)
                        .padding(OmodachiTheme.space("xl"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .background(OmodachiTheme.normalFill)
                .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
            }
        }
        .accessibilityIdentifier("agent-tool-\(tool.id)")
        .accessibilityLabel(Strings.pair(line.text, statusLabel))
    }

    /// LINKS-1: the files this step touched or looked at, each one a tap away
    /// from opening on the computer.
    private func files(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(paths.enumerated()), id: \.offset) { offset, path in
                AgentPathLink(path: path, identifier: "agent-tool-path-\(tool.id)-\(offset)")
            }
        }
        .padding(.horizontal, OmodachiTheme.space("xl"))
    }
}

/// The verb in the chrome face, the subject in the host's mono when it is
/// machine text, Find's matches marked.
struct AgentStepLineText: View {
    let line: AgentStepLine
    var query = ""

    var body: some View {
        HStack(spacing: OmodachiTheme.space("sm")) {
            if !line.verb.isEmpty {
                Text(verbatim: line.verb).foregroundStyle(OmodachiTheme.secondaryText).lineLimit(1).layoutPriority(1)
            }
            Text(FindHighlight.mark(line.subject, query))
                .font(line.mono ? OmodachiTheme.font("body-small") : OmodachiTheme.bodyFont("body-small"))
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// LINKS-1: a path that opens on the computer, never on the phone.
struct AgentPathLink: View {
    let path: String
    let identifier: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        Tap(action: {
            if let url = LinkCarrier.url(for: .path(path)) { openURL(url) }
        }) {
            Text(verbatim: path)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.accent)
                .underline()
                .lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Idea 1: change cards

/// Every file a `fileChange` changed, one card each: "Edited app.py +3 −2"
/// and the change itself, as codex sent it. Never more than that: the phone
/// is not a file viewer, and the path opens on the computer.
struct AgentChangeCards: View {
    let tool: AgentChatTool
    let changes: [AgentChatChange]
    var compact = false
    var waiting = false
    var query = ""
    let glyph: (symbol: String, role: ThemeColorRole)

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            if waiting {
                Text(Strings.agentChangeWaiting)
                    .font(OmodachiTheme.bodyFont("body-small", weight: .semibold))
                    .foregroundStyle(OmodachiTheme.warning)
                    .accessibilityIdentifier("agent-change-waiting-\(tool.id)")
            }
            ForEach(Array(changes.enumerated()), id: \.offset) { offset, change in
                AgentChangeCard(tool: tool, change: change, index: offset, compact: compact, waiting: waiting,
                                query: query, glyph: glyph)
            }
            if let omitted = tool.changesOmitted {
                Text(Strings.agentChangeFilesOmitted(Format.count(omitted)))
                    .font(OmodachiTheme.bodyFont("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-tool-\(tool.id)")
    }
}

struct AgentChangeCard: View {
    let tool: AgentChatTool
    let change: AgentChatChange
    let index: Int
    var compact = false
    var waiting = false
    var query = ""
    let glyph: (symbol: String, role: ThemeColorRole)
    /// Compact (inside a run) starts closed; a card on its own starts open
    /// with its first lines, and so does one a waiting prompt is about.
    @State private var open: Bool?
    @State private var everything = false

    /// Collie draws 16 lines of a diff before its fold; a phone gets 12.
    static let preview = 12

    private var isOpen: Bool { open ?? (!compact || waiting) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Tap(action: { open = !isOpen }) {
                HStack(spacing: OmodachiTheme.space("lg")) {
                    Glyph(symbol: glyph.symbol, points: OmodachiTheme.fontSize("caption"))
                        .foregroundStyle(OmodachiTheme.current.color(glyph.role))
                    AgentStepLineText(line: AgentStepLine(verb: change.verb, subject: change.subject, mono: true),
                                      query: query)
                    Spacer(minLength: OmodachiTheme.space("sm"))
                    HStack(spacing: OmodachiTheme.space("sm")) {
                        if change.added > 0 || change.removed == 0 {
                            Text(verbatim: "+\(change.added)").foregroundStyle(OmodachiTheme.current.color(.green))
                        }
                        if change.removed > 0 {
                            Text(verbatim: "−\(change.removed)").foregroundStyle(OmodachiTheme.current.color(.red))
                        }
                    }
                    .font(OmodachiTheme.font("body-small"))
                    .accessibilityHidden(true)
                    Glyph(symbol: isOpen ? "chevron.up" : "chevron.down", points: OmodachiTheme.fontSize("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                }
                .font(OmodachiTheme.font("body-small"))
                .padding(.horizontal, OmodachiTheme.space("xl"))
                .frame(minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Strings.pair(Strings.pair(change.verb + " " + change.subject, // non-copy: catalog verb and file
                                                          Strings.agentChangeLinesLabel(Format.count(change.added),
                                                                                        Format.count(change.removed))),
                                             tool.status.label))
            .accessibilityValue(isOpen ? Strings.actionCollapse : "")
            .accessibilityIdentifier("agent-change-\(tool.id)-\(index)")
            if isOpen {
                AgentPathLink(path: change.path, identifier: "agent-tool-path-\(tool.id)-\(index)")
                    .padding(.horizontal, OmodachiTheme.space("xl"))
                diff
            }
        }
        .background(OmodachiTheme.background)
        // A card a waiting prompt is about lights the edge it always has
        // (Collie "a card waiting recolours its edge"): paint, not layout.
        .overlay(Rectangle().strokeBorder(waiting ? OmodachiTheme.warning : OmodachiTheme.controlBorder,
                                          lineWidth: waiting ? OmodachiTheme.popupBorderWidth : OmodachiTheme.controlBorderWidth)
            .allowsHitTesting(false))
    }

    @ViewBuilder private var diff: some View {
        let lines = change.lines
        if !lines.isEmpty {
            let shown = everything ? lines : Array(lines.prefix(Self.preview))
            VStack(alignment: .leading, spacing: 0) {
                // One element for VoiceOver: the change, line after line.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in diffRow(line) }
                }
                .accessibilityElement(children: .combine)
                if lines.count > Self.preview {
                    TextTap(everything ? Strings.agentChangeLess : Strings.agentChangeMore(Format.count(lines.count - Self.preview))) {
                        everything.toggle()
                    }
                    .accessibilityIdentifier("agent-change-more-\(tool.id)-\(index)")
                }
            }
            .padding(.bottom, OmodachiTheme.space("sm"))
            .accessibilityIdentifier("agent-change-diff-\(tool.id)-\(index)")
        }
        if change.diffOmitted > 0 {
            Text(Strings.agentChangeOmitted(Format.count(change.diffOmitted)))
                .font(OmodachiTheme.bodyFont("caption"))
                .foregroundStyle(OmodachiTheme.secondaryText)
                .padding(.horizontal, OmodachiTheme.space("xl"))
                .padding(.bottom, OmodachiTheme.space("md"))
        }
    }

    /// A tinted row with its sign; a hunk header is a gap, as Collie draws a
    /// diff that has no line numbers.
    @ViewBuilder private func diffRow(_ line: AgentChatChange.Line) -> some View {
        switch line {
        case .hunk:
            Text(verbatim: "⋯").foregroundStyle(OmodachiTheme.secondaryText)
                .font(OmodachiTheme.font("caption"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, OmodachiTheme.space("xl"))
                .accessibilityHidden(true)
        case .added(let text): signed(text, .green)
        case .removed(let text): signed(text, .red)
        case .context(let text): signed(text, nil)
        }
    }

    private func signed(_ text: String, _ role: ThemeColorRole?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OmodachiTheme.space("sm")) {
            Text(verbatim: role == .green ? "+" : role == .red ? "−" : " ").foregroundStyle(role.map { OmodachiTheme.current.color($0) } ?? OmodachiTheme.secondaryText)
                .frame(width: 12)
            Text(verbatim: text.isEmpty ? " " : text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(OmodachiTheme.font("caption"))
        .padding(.horizontal, OmodachiTheme.space("lg"))
        .background(role.map { OmodachiTheme.current.color($0).opacity(0.12) } ?? .clear)
    }
}

// MARK: - Idea 2: runs

/// Three or more steps in a row, folded into one line ("4 commands, 2 edits ·
/// 1 failed") with the newest step under it. A run that is working draws open
/// with its newest six steps, and stays open once it finishes so nothing
/// moves under the reader's eye; the person's own tap wins over both.
struct AgentRunView<Step: View>: View {
    let run: AgentRun
    let waitingItems: Set<String>
    /// The person's own choice: true opened, false folded, nil not chosen.
    @Binding var choice: Bool?
    /// This run was working while it was on screen.
    @Binding var held: Bool
    /// Find (or "See the change") is pointing inside it.
    var revealed = false
    @ViewBuilder let step: (AgentTimelineEntry) -> Step

    private var live: Bool { run.running || run.waiting(on: waitingItems) }

    var body: some View {
        Group {
            if revealed || choice == true {
                VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                    foldRow
                    entries(run.entries[...])
                }
            } else if choice == nil && (live || held) {
                let start = run.tailStart(waiting: waitingItems)
                VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                    if start > 0 {
                        earlierRow(run.steps(before: start))
                    } else {
                        foldRow
                    }
                    entries(run.entries[start...])
                }
            } else {
                folded
            }
        }
        .onAppear { if live { held = true } }
        .onChange(of: live) { _, now in if now { held = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(run.id.replacingOccurrences(of: "run:", with: "agent-run-"))
    }

    private func entries(_ slice: ArraySlice<AgentTimelineEntry>) -> some View {
        ForEach(Array(slice)) { entry in step(entry).id(entry.id) }
    }

    private var summary: String { run.counts.summary }

    /// The one line a finished run is.
    private var folded: some View {
        Tap(action: { choice = true }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: OmodachiTheme.space("lg")) {
                    Glyph(symbol: "chevron.right", points: OmodachiTheme.fontSize("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                    Text(summary).lineLimit(1)
                    if run.failed > 0 {
                        Text(Strings.agentRunFailed(Format.count(run.failed)))
                            .foregroundStyle(OmodachiTheme.current.color(.red))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .font(OmodachiTheme.font("body-small", weight: .semibold))
                if let last = run.tools.last {
                    AgentStepLineText(line: last.stepLine)
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .padding(.leading, OmodachiTheme.space("xxl"))
                }
            }
            .padding(.horizontal, OmodachiTheme.space("xl"))
            .padding(.vertical, OmodachiTheme.space("sm"))
            .frame(maxWidth: .infinity, minHeight: NativeBarMetrics.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .control(bordered: true)
        .accessibilityLabel(run.failed > 0 ? Strings.pair(summary, Strings.agentRunFailed(Format.count(run.failed))) : summary)
        .accessibilityHint(Strings.agentRunExpandHint)
        .accessibilityIdentifier(run.id.replacingOccurrences(of: "run:", with: "agent-run-toggle-"))
    }

    private var foldRow: some View {
        Tap(action: { choice = false }) {
            HStack(spacing: OmodachiTheme.space("lg")) {
                Glyph(symbol: "chevron.down", points: OmodachiTheme.fontSize("caption"))
                Text(summary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(OmodachiTheme.font("body-small"))
            .foregroundStyle(OmodachiTheme.secondaryText)
            .padding(.horizontal, OmodachiTheme.space("xl"))
            .frame(maxWidth: .infinity, minHeight: NativeBarMetrics.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Strings.pair(Strings.agentRunFold, summary))
        .accessibilityIdentifier(run.id.replacingOccurrences(of: "run:", with: "agent-run-fold-"))
    }

    private func earlierRow(_ count: Int) -> some View {
        Tap(action: { choice = true }) {
            HStack(spacing: OmodachiTheme.space("lg")) {
                Glyph(symbol: "chevron.right", points: OmodachiTheme.fontSize("caption"))
                Text(count == 1 ? Strings.agentRunEarlier : Strings.agentRunEarlierMany(Format.count(count)))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(OmodachiTheme.font("body-small"))
            .foregroundStyle(OmodachiTheme.secondaryText)
            .padding(.horizontal, OmodachiTheme.space("xl"))
            .frame(maxWidth: .infinity, minHeight: NativeBarMetrics.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .control(bordered: true)
        .accessibilityHint(Strings.agentRunExpandHint)
        .accessibilityIdentifier(run.id.replacingOccurrences(of: "run:", with: "agent-run-earlier-"))
    }
}
