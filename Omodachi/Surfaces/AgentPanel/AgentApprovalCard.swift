import SwiftUI

/// The approval, in the message stream where the rest of the turn is.
///
/// Before it is answered it is a card with the provider's own summary, its
/// expandable detail and exactly the decisions the provider offered. After it
/// is answered it becomes one result line, because the fact that it happened is
/// part of the conversation and the buttons are not.
struct AgentApprovalCard: View {
    let approval: AgentChatApproval
    var onDecide: (String, String) -> Void
    var onAnswer: (String, [String: [String]]) -> Void
    @State private var expanded = false
    @State private var answers: [String: String] = [:]
    @FocusState private var focusedQuestion: String?

    var body: some View {
        if case .resolved(let decision, let source) = approval.state {
            resolvedRow(decision: decision, source: source)
        } else {
            card
        }
    }

    // MARK: - Resolved

    /// 28-high, the same control row a tool call collapses to (A-20): an
    /// answered prompt is history, not a control.
    private func resolvedRow(decision: String?, source: String) -> some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            Glyph(symbol: decision == "decline" || decision == "cancel" ? "minus" : "checkmark", points: OmodachiTheme.fontSize("caption"))
                .foregroundStyle(OmodachiTheme.current.color(
                    decision == "decline" || decision == "cancel" ? .muted : .green))
            Text(approval.summary.isEmpty ? approval.title : approval.summary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: OmodachiTheme.space("sm"))
            Text(tail(decision: decision, source: source)).foregroundStyle(OmodachiTheme.secondaryText)
        }
        .font(OmodachiTheme.font("body-small"))
        .padding(.horizontal, OmodachiTheme.space("xl"))
        .frame(height: OmodachiTheme.controlHeight)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-approval-resolved-\(approval.requestID)")
    }

    /// A prompt answered on the host says so: this device did not decide it,
    /// and pretending otherwise would be a lie about who acted.
    private func tail(decision: String?, source: String) -> String {
        let name = decision.map { AgentChatApproval.label(decision: $0) } ?? Strings.approvalAnswered
        return source == "client" ? name : Strings.approvalAnsweredOnHost(name)
    }

    // MARK: - Pending

    private var card: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("xl")) {
            Text(approval.title)
                .font(OmodachiTheme.bodyFont("title", weight: .semibold))
                .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
            if !approval.summary.isEmpty {
                // The summary is a command or a reason: machine text.
                Text(approval.summary)
                    .font(OmodachiTheme.font("body"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !approval.details.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                        ForEach(approval.details) { detail in
                            HStack(alignment: .top, spacing: OmodachiTheme.space("lg")) {
                                Text(detail.label).foregroundStyle(OmodachiTheme.secondaryText)
                                    .frame(width: 96, alignment: .leading)
                                Text(detail.value).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(OmodachiTheme.font("body-small"))
                    .padding(.top, OmodachiTheme.space("lg"))
                } label: {
                    Text(Strings.agentDetails).font(OmodachiTheme.font("body-small")).frame(minHeight: NativeBarMetrics.hit)
                }
                .accessibilityIdentifier("agent-approval-details-\(approval.requestID)")
            }
            if approval.decisions.isEmpty { questions } else { decisions }
        }
        .padding(OmodachiTheme.space("xxxl"))
        .background(OmodachiTheme.elevated)
        // A prompt that stops the turn gets the 2px panel border, not the 1px
        // control one (D-01): it is a card, and it is the thing to look at.
        .overlay(Rectangle().strokeBorder(OmodachiTheme.popupBorder, lineWidth: OmodachiTheme.popupBorderWidth))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent-approval-\(approval.requestID)")
    }

    private var decisions: some View {
        // The provider decides what may be answered; this list is never padded
        // out with a decision it did not offer.
        HStack(spacing: OmodachiTheme.space("lg")) {
            ForEach(approval.decisions, id: \.self) { decision in
                Tap(action: { onDecide(approval.requestID, decision) }) {
                    Text(AgentChatApproval.label(decision: decision))
                        .font(OmodachiTheme.font("body-small"))
                        .padding(.horizontal, OmodachiTheme.space("xl"))
                        .frame(height: OmodachiTheme.controlHeight)
                        .frame(minHeight: NativeBarMetrics.hit)
                        .contentShape(Rectangle())
                }
                .control(bordered: true)
                .disabled(approval.isDeciding)
                .accessibilityIdentifier("agent-approval-\(decision)-\(approval.requestID)")
            }
            if approval.isDeciding { ProgressView().controlSize(.small) }
        }
    }

    /// `userInput`: values, not a decision. Options are the provider's own
    /// labels; a question with none takes free text.
    @ViewBuilder private var questions: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("xl")) {
            ForEach(approval.questions) { question in
                VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                    if let header = question.header, !header.isEmpty {
                        Text(header).font(OmodachiTheme.bodyFont("body-small", weight: .semibold))
                    }
                    Text(question.question).font(OmodachiTheme.bodyFont("body"))
                    if question.options.isEmpty {
                        TextField(Strings.approvalYourAnswer, text: binding(for: question.id))
                            .font(OmodachiTheme.bodyFont("body"))
                            .focused($focusedQuestion, equals: question.id)
                            .accessibilityIdentifier("agent-approval-input-\(question.id)")
                            .padding(OmodachiTheme.space("xl"))
                            .frame(minHeight: NativeBarMetrics.hit)
                            .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder,
                                                              lineWidth: OmodachiTheme.controlBorderWidth)
                                .allowsHitTesting(false))
                            // A-01: the drawn box is the target, not the line
                            // of text inside it.
                            .contentShape(Rectangle())
                            .onTapGesture { focusedQuestion = question.id }
                    } else {
                        HStack(spacing: OmodachiTheme.space("md")) {
                            ForEach(question.options, id: \.self) { option in
                                Tap(action: { answers[question.id] = option }) {
                                    Text(option)
                                        .font(OmodachiTheme.font("body-small"))
                                        .padding(.horizontal, OmodachiTheme.space("xl"))
                                        .frame(height: OmodachiTheme.controlHeight)
                                        .frame(minHeight: NativeBarMetrics.hit)
                                        .contentShape(Rectangle())
                                }
                                .control(selected: answers[question.id] == option, bordered: true)
                            }
                        }
                    }
                }
            }
            Tap(action: { onAnswer(approval.requestID, submission) }) {
                Text(Strings.agentAnswer)
                    .font(OmodachiTheme.font("body-small"))
                    .padding(.horizontal, OmodachiTheme.space("xl"))
                    .frame(height: OmodachiTheme.controlHeight)
                    .frame(minHeight: NativeBarMetrics.hit)
                    .contentShape(Rectangle())
            }
            .control(bordered: true)
            .disabled(approval.isDeciding || submission.isEmpty)
            .accessibilityIdentifier("agent-approval-answer-\(approval.requestID)")
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    /// Only the questions that were actually answered are sent; the host
    /// refuses an empty list rather than letting a blank stand for a choice.
    private var submission: [String: [String]] {
        answers.compactMapValues { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : [value]
        }
    }
}
