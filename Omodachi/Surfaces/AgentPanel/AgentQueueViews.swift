import SwiftUI

/// AGENT-QUEUE-1: codex's checklist (its `update_plan` tool), pinned under the
/// header while the plan is active: "Steps · 2 of 3 · Change the port", and the
/// whole list with a tap. codex 0.160 sends it only when its config turns
/// `update_plan` on; otherwise there is none and nothing is drawn.
struct AgentChecklistBar: View {
    let list: AgentChecklist
    @State private var open = false

    var body: some View {
        let line = list.line
        let progress = Strings.agentStepsProgress(Format.count(line.done), Format.count(line.total))
        VStack(alignment: .leading, spacing: 0) {
            Tap(action: { open.toggle() }) {
                HStack(spacing: OmodachiTheme.space("lg")) {
                    Glyph(Icon.plan, points: OmodachiTheme.fontSize("caption"))
                        .foregroundStyle(OmodachiTheme.accent)
                    Text(Strings.agentStepsTitle)
                        .font(OmodachiTheme.font("body-small", weight: .semibold))
                        .foregroundStyle(OmodachiTheme.accent)
                    Text(progress)
                        .font(OmodachiTheme.font("body-small"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .monospacedDigit()
                        .accessibilityIdentifier("agent-steps-progress")
                    Text(verbatim: line.current)
                        .font(OmodachiTheme.bodyFont("body-small"))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Glyph(open ? Icon.chevronDown : Icon.chevronRight, points: OmodachiTheme.fontSize("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                }
                .padding(.horizontal, OmodachiTheme.space("xl"))
                .frame(minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.pair(Strings.agentStepsTitle, progress))
            .accessibilityValue(line.current)
            .accessibilityHint(open ? Strings.agentStepsHide : Strings.agentStepsShow)
            .accessibilityIdentifier("agent-steps-toggle")
            if open {
                VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                    if let explanation = list.explanation {
                        Text(verbatim: explanation).foregroundStyle(OmodachiTheme.secondaryText)
                    }
                    ForEach(Array(list.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: OmodachiTheme.space("lg")) {
                            Glyph(symbol: step.status == .completed ? "checkmark" : step.status == .inProgress // non-copy: glyph names
                                  ? "chevron.right" : "circle", points: OmodachiTheme.fontSize("caption"))
                                .foregroundStyle(step.status == .completed ? OmodachiTheme.current.color(.green)
                                                 : step.status == .inProgress ? OmodachiTheme.accent : OmodachiTheme.secondaryText)
                            Text(verbatim: step.step)
                                .foregroundStyle(step.status == .completed ? OmodachiTheme.secondaryText : OmodachiTheme.text)
                                .strikethrough(step.status == .completed)
                                .fontWeight(step.status == .inProgress ? .semibold : .regular)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Strings.pair(step.step, word(step.status)))
                    }
                }
                .font(OmodachiTheme.bodyFont("body-small"))
                .padding(.horizontal, OmodachiTheme.space("xl"))
                .padding(.bottom, OmodachiTheme.space("lg"))
                .accessibilityIdentifier("agent-steps-list")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmodachiTheme.elevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OmodachiTheme.border).frame(height: NativeBarMetrics.edgeRule)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-steps")
    }

    private func word(_ status: AgentChecklist.Status) -> String {
        switch status {
        case .completed: Strings.agentStepsDone
        case .inProgress: Strings.agentStepsNow
        case .pending: Strings.agentStepsTodo
        }
    }
}

/// AGENT-QUEUE-1: what waits in codex's queue, above the composer - "2
/// waiting" and each message with Send now, Edit and Delete. Edit changes it
/// in its place; a message too long for this phone to hold has no Edit.
struct AgentQueueRows: View {
    let queue: [AgentQueuedMessage]
    let running: Bool
    var onItem: (String, AgentQueueAction, String?) -> Void
    @State private var editing: String?
    @State private var words = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            HStack(alignment: .firstTextBaseline, spacing: OmodachiTheme.space("lg")) {
                Text(Strings.agentQueueCount(Format.count(queue.count)))
                    .font(OmodachiTheme.font("body-small", weight: .semibold))
                    .foregroundStyle(OmodachiTheme.accent)
                    .accessibilityIdentifier("agent-queue-count")
                Text(running ? Strings.agentQueueWhenEnds : Strings.agentQueueWaiting)
                    .font(OmodachiTheme.bodyFont("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
            }
            // As tall as what waits; past two messages it scrolls, so the
            // conversation above keeps its room.
            if queue.count > 2 {
                ScrollView { items }
                    .frame(height: 220)
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                items
            }
        }
        .padding(.horizontal, OmodachiTheme.panelPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-queue")
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            ForEach(queue) { item in row(item) }
        }
    }

    @ViewBuilder private func row(_ item: AgentQueuedMessage) -> some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            if editing == item.id {
                TextField(Strings.agentQueueLabel, text: $words, axis: .vertical)
                    .lineLimit(1...4)
                    .font(OmodachiTheme.bodyFont("body"))
                    .padding(OmodachiTheme.space("lg"))
                    .focused($editFocused)
                    .textEntrySurface(focused: editFocused)
                    .accessibilityIdentifier("agent-queue-field-\(item.id)")
                    // Edit puts the cursor after the words, ready to change them.
                    .onAppear { editFocused = true }
                HStack(spacing: OmodachiTheme.space("lg")) {
                    TextTap(Strings.agentQueueSave, bordered: true,
                            enabled: !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        onItem(item.id, .edit, words)
                        editing = nil
                    }
                    .accessibilityIdentifier("agent-queue-save-\(item.id)")
                    TextTap(Strings.actionCancel) { editing = nil }
                        .accessibilityIdentifier("agent-queue-cancel-\(item.id)")
                }
            } else {
                Text(verbatim: item.text)
                    .font(OmodachiTheme.bodyFont("body"))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Strings.pair(Strings.agentQueueLabel, item.text))
                    .accessibilityIdentifier("agent-queue-text-\(item.id)")
                HStack(spacing: OmodachiTheme.space("lg")) {
                    TextTap(Strings.agentQueueSendNow, bordered: true) { onItem(item.id, .send, nil) }
                        .accessibilityIdentifier("agent-queue-send-\(item.id)")
                    if !item.clipped {
                        TextTap(Strings.agentQueueEdit, bordered: true) {
                            words = item.text
                            editing = item.id
                        }
                        .accessibilityIdentifier("agent-queue-edit-\(item.id)")
                    }
                    TextTap(Strings.agentQueueDelete, bordered: true) { onItem(item.id, .delete, nil) }
                        .accessibilityIdentifier("agent-queue-delete-\(item.id)")
                }
            }
        }
        .padding(OmodachiTheme.space("lg"))
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-queue-item-\(item.id)")
    }
}
