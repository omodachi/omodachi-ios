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
    /// AGENT-COLLIE-1: a `fileChange` prompt's change, from the row it is
    /// about, and the way to that row's cards.
    var changes: [AgentChatChange] = []
    var onShowChange: (() -> Void)? = nil
    /// AGENT-QUEUE-1: "No, and here's why" - a decline with one optional line.
    var onDeclineWhy: ((String, String) -> Void)? = nil
    /// AGENT-QUEUE-1 (the looping question card): a question's saved progress
    /// and where to keep it as it changes.
    var questionDraft: AgentQuestionDraft? = nil
    var onQuestionDraft: ((AgentQuestionDraft) -> Void)? = nil
    @State private var expanded = false
    @State private var why: String?
    @FocusState private var whyFocused: Bool

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
                .lineLimit(1).truncationMode(.tail)
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
    ///
    /// AGENT-COLLIE-1: a question this device answered says what was chosen
    /// ("Answered: main"); a secret answer is never shown.
    private func tail(decision: String?, source: String) -> String {
        if source == "client", let answered = approval.answered, !answered.isEmpty {
            return Strings.approvalAnsweredWith(answered.joined(separator: ", ")) // non-copy: the person's own words
        }
        let name = decision.map { AgentChatApproval.label(decision: $0) } ?? Strings.approvalAnswered
        return source == "client" ? name : Strings.approvalAnsweredOnHost(name)
    }

    // MARK: - Pending

    private var card: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("xl")) {
            Text(approval.title)
                .font(OmodachiTheme.bodyFont("title", weight: .semibold))
                .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
            // A file change's summary is core's own "Apply file changes" unless
            // codex gave a reason; the title already says that.
            if !approval.summary.isEmpty && !approval.decisions.isEmpty
                && (approval.kind != "fileChange" || approval.details.contains { $0.key == "reason" }) {
                // The summary is a command or a reason: machine text.
                Text(approval.summary)
                    .font(OmodachiTheme.font("body"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if approval.kind == "fileChange" { changeSummary }
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
            if approval.decisions.isEmpty {
                AgentQuestionCard(approval: approval, onAnswer: onAnswer, draft: questionDraft,
                                  onDraft: onQuestionDraft ?? { _ in })
            } else {
                decisions
                if onDeclineWhy != nil && approval.decisions.contains("decline") && !approval.isDeciding { declineWhy }
            }
        }
        // The card is the column's width whatever its words are.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OmodachiTheme.space("xxxl"))
        .background(OmodachiTheme.elevated)
        // A prompt that stops the turn gets the 2px panel border, not the 1px
        // control one (D-01): it is a card, and it is the thing to look at.
        .overlay(Rectangle().strokeBorder(OmodachiTheme.popupBorder, lineWidth: OmodachiTheme.popupBorderWidth))
        .frame(maxWidth: .infinity, alignment: .leading)
        // AGENT-COLLIE-1: a container, so the controls inside keep their own
        // names (they used to take the card's).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-approval-\(approval.requestID)")
    }

    /// AGENT-COLLIE-1 idea 1: what this prompt allows - "2 files · +14 −3" and
    /// their names - and the way to the change cards above, which are lit.
    @ViewBuilder private var changeSummary: some View {
        let names = changes.isEmpty ? approval.changeFiles.map(AgentChatChange.name) : changes.map(\.subject)
        let added = changes.isEmpty ? approval.changeAdded : changes.reduce(0) { $0 + $1.added }
        let removed = changes.isEmpty ? approval.changeRemoved : changes.reduce(0) { $0 + $1.removed }
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                HStack(spacing: OmodachiTheme.space("lg")) {
                    Text(names.count == 1 ? Strings.agentChangeFile : Strings.agentChangeFiles(Format.count(names.count)))
                    Text(verbatim: "+\(added)").foregroundStyle(OmodachiTheme.current.color(.green))
                    Text(verbatim: "−\(removed)").foregroundStyle(OmodachiTheme.current.color(.red))
                }
                .font(OmodachiTheme.font("body-small"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Strings.pair(
                    names.count == 1 ? Strings.agentChangeFile : Strings.agentChangeFiles(Format.count(names.count)),
                    Strings.agentChangeLinesLabel(Format.count(added), Format.count(removed))))
                ForEach(Array(names.prefix(8).enumerated()), id: \.offset) { _, name in
                    Text(verbatim: name).font(OmodachiTheme.font("body-small")).lineLimit(1).truncationMode(.middle)
                }
                if let onShowChange {
                    TextTap(Strings.agentChangeSee, bordered: true, action: onShowChange)
                        .accessibilityIdentifier("agent-approval-see-change-\(approval.requestID)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-approval-change-\(approval.requestID)")
        }
    }

    /// AGENT-QUEUE-1: a quiet link under the decisions; it opens one line for
    /// the reason and a Decline that sends it (empty: today's decline). codex
    /// takes no words with a decision, so core steers them into the turn.
    @ViewBuilder private var declineWhy: some View {
        if let text = why {
            VStack(alignment: .leading, spacing: OmodachiTheme.space("lg")) {
                TextField(Strings.agentDeclinePlaceholder, text: Binding(get: { text }, set: { why = $0 }))
                    .font(OmodachiTheme.bodyFont("body"))
                    .focused($whyFocused)
                    .submitLabel(.send)
                    .onSubmit { onDeclineWhy?(approval.requestID, why ?? "") }
                    .padding(.horizontal, OmodachiTheme.space("lg"))
                    .frame(minHeight: NativeBarMetrics.hit)
                    .textEntrySurface(focused: whyFocused)
                    .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth)
                        .allowsHitTesting(false))
                    .accessibilityIdentifier("agent-approval-why-field-\(approval.requestID)")
                HStack(spacing: OmodachiTheme.space("lg")) {
                    TextTap(Strings.approvalDecline, bordered: true) {
                        onDeclineWhy?(approval.requestID, why ?? "")
                    }
                    .accessibilityIdentifier("agent-approval-why-send-\(approval.requestID)")
                    TextTap(Strings.actionCancel) { why = nil }
                        .accessibilityIdentifier("agent-approval-why-cancel-\(approval.requestID)")
                }
            }
            .onAppear { whyFocused = true }
        } else {
            TextTap(Strings.agentDeclineWhy) { why = "" }
                .accessibilityIdentifier("agent-approval-why-\(approval.requestID)")
        }
    }

    private var decisions: some View {
        // The provider decides what may be answered; this list is never padded
        // out with a decision it did not offer.
        //
        // DUO-1: one row while every label fits on one line; otherwise two to
        // a row, then one. The iPhone Duo's outer screen leaves the card 20
        // points less than an iPhone 17 does, and a single row there broke
        // "Decline" in the middle of the word.
        ViewThatFits(in: .horizontal) {
            decisionRow(approval.decisions, spinner: true)
            VStack(alignment: .leading, spacing: OmodachiTheme.space("lg")) {
                ForEach(Array(stride(from: 0, to: approval.decisions.count, by: 2)), id: \.self) { start in
                    decisionRow(Array(approval.decisions[start..<min(start + 2, approval.decisions.count)]),
                                spinner: start == 0)
                }
            }
            VStack(alignment: .leading, spacing: OmodachiTheme.space("lg")) {
                ForEach(Array(approval.decisions.enumerated()), id: \.element) { index, decision in
                    decisionRow([decision], spinner: index == 0)
                }
            }
        }
    }

    private func decisionRow(_ decisions: [String], spinner: Bool) -> some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            ForEach(decisions, id: \.self) { decision in
                Tap(action: { onDecide(approval.requestID, decision) }) {
                    Text(AgentChatApproval.label(decision: decision))
                        .font(OmodachiTheme.font("body-small"))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, OmodachiTheme.space("xl"))
                        .frame(height: OmodachiTheme.controlHeight)
                        .frame(minHeight: NativeBarMetrics.hit)
                        .contentShape(Rectangle())
                }
                .control(bordered: true)
                .disabled(approval.isDeciding)
                .accessibilityIdentifier("agent-approval-\(decision)-\(approval.requestID)")
            }
            if spinner && approval.isDeciding { ProgressView().controlSize(.small) }
        }
    }
}

/// AGENT-COLLIE-1 idea 3: a `userInput` question that fits a phone (after
/// Collie's prompt-select / wizard blocks, MIT, Copyright (c) 2026 Altan
/// Sarisin). Options stack as full-width rows with codex's description under
/// each; "Other…" takes the person's own words when codex allows it; several
/// questions go one at a time with Back, then a review; a secret answer is
/// typed into a secure field and never shown again. The answers live in this
/// card's state only and leave it as one `resolveApproval(input:)`.
struct AgentQuestionCard: View {
    let approval: AgentChatApproval
    var onAnswer: (String, [String: [String]]) -> Void
    /// AGENT-QUEUE-1 (Leo: "askuserquestion 的卡片 会循环"): the card's progress
    /// lives in the conversation (`AgentChatModel.questionDrafts`) and the
    /// card starts from it. A card drawn again - codex re-sending the same
    /// request after core re-attached, the panel shown again - used to start
    /// over at question 1 with nothing chosen.
    var onDraft: (AgentQuestionDraft) -> Void
    @State private var chosen: [String: String]
    @State private var others: Set<String>
    @State private var typed: [String: String]
    @State private var page: Int
    @FocusState private var focused: String?

    init(approval: AgentChatApproval, onAnswer: @escaping (String, [String: [String]]) -> Void,
         draft: AgentQuestionDraft? = nil, onDraft: @escaping (AgentQuestionDraft) -> Void = { _ in }) {
        self.approval = approval
        self.onAnswer = onAnswer
        self.onDraft = onDraft
        let saved = draft.flatMap { $0.fingerprint == approval.questionsFingerprint ? $0 : nil }
        _chosen = State(initialValue: saved?.chosen ?? [:])
        _others = State(initialValue: saved?.others ?? [])
        _typed = State(initialValue: saved?.typed ?? [:])
        _page = State(initialValue: min(saved?.page ?? 0, approval.questions.count > 1 ? approval.questions.count : 0))
    }

    private var current: AgentQuestionDraft {
        AgentQuestionDraft(fingerprint: approval.questionsFingerprint, chosen: chosen, others: others, typed: typed, page: page)
    }

    private var questions: [AgentChatQuestion] { approval.questions }
    private var stepped: Bool { questions.count > 1 }
    private var reviewing: Bool { stepped && page >= questions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("xl")) {
            if stepped {
                Text(reviewing ? Strings.agentQuestionReview
                     : Strings.agentQuestionStep(Format.count(page + 1), Format.count(questions.count)))
                    .font(OmodachiTheme.font("caption"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .accessibilityIdentifier("agent-question-step-\(approval.requestID)")
            }
            if reviewing {
                review
            } else if stepped {
                question(questions[min(page, questions.count - 1)])
            } else if let only = questions.first {
                question(only)
            }
            controls
        }
        .onChange(of: current) { _, draft in onDraft(draft) }
    }

    // MARK: One question

    private func question(_ question: AgentChatQuestion) -> some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            if let header = question.header, !header.isEmpty, header != question.question {
                Text(header).font(OmodachiTheme.bodyFont("body-small", weight: .semibold))
            }
            Text(question.question).font(OmodachiTheme.bodyFont("body"))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.choices.enumerated()), id: \.offset) { offset, choice in
                choiceRow(question, choice, offset)
            }
            if question.choices.isEmpty {
                field(question)
            } else if question.other {
                otherRow(question)
                if others.contains(question.id) { field(question) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-question-\(question.id)")
    }

    private func choiceRow(_ question: AgentChatQuestion, _ choice: AgentChatChoice, _ offset: Int) -> some View {
        let selected = !others.contains(question.id) && chosen[question.id] == choice.label
        return Tap(action: {
            chosen[question.id] = choice.label
            others.remove(question.id)
            focused = nil
        }) {
            HStack(alignment: .top, spacing: OmodachiTheme.space("lg")) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: choice.label).font(OmodachiTheme.bodyFont("body"))
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = choice.description {
                        Text(verbatim: description).font(OmodachiTheme.bodyFont("body-small"))
                            .foregroundStyle(OmodachiTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: OmodachiTheme.space("sm"))
                if selected { Glyph(Icon.check, points: OmodachiTheme.fontSize("body-small")) }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, OmodachiTheme.space("xl"))
            .padding(.vertical, OmodachiTheme.space("lg"))
            .frame(maxWidth: .infinity, minHeight: NativeBarMetrics.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .control(selected: selected, bordered: true)
        .disabled(approval.isDeciding)
        .accessibilityElement(children: .combine)
        .accessibilityValue(selected ? Strings.agentQuestionSelected : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("agent-question-choice-\(question.id)-\(offset)")
    }

    private func otherRow(_ question: AgentChatQuestion) -> some View {
        let selected = others.contains(question.id)
        return Tap(action: {
            others.insert(question.id)
            focused = question.id
        }) {
            HStack(spacing: OmodachiTheme.space("lg")) {
                Text(Strings.agentQuestionOther).font(OmodachiTheme.bodyFont("body"))
                Spacer(minLength: OmodachiTheme.space("sm"))
                if selected { Glyph(Icon.check, points: OmodachiTheme.fontSize("body-small")) }
            }
            .padding(.horizontal, OmodachiTheme.space("xl"))
            .frame(maxWidth: .infinity, minHeight: NativeBarMetrics.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .control(selected: selected, bordered: true)
        .disabled(approval.isDeciding)
        .accessibilityValue(selected ? Strings.agentQuestionSelected : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("agent-question-other-\(question.id)")
    }

    /// Free words. AGENT-COLLIE-1 goal 0: a secret question (a password, a
    /// token) is typed where it cannot be read.
    private func field(_ question: AgentChatQuestion) -> some View {
        let binding = Binding(get: { typed[question.id] ?? "" }, set: { typed[question.id] = $0 })
        return Group {
            if question.secret {
                SecureField(Strings.agentQuestionOtherPlaceholder, text: binding)
            } else {
                TextField(Strings.agentQuestionOtherPlaceholder, text: binding, axis: .vertical)
            }
        }
        .font(OmodachiTheme.bodyFont("body"))
        .focused($focused, equals: question.id)
        .textInputAutocapitalization(question.secret ? .never : .sentences)
        .autocorrectionDisabled(question.secret)
        .accessibilityIdentifier("agent-approval-input-\(question.id)")
        .padding(OmodachiTheme.space("xl"))
        .frame(minHeight: NativeBarMetrics.hit)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth)
            .allowsHitTesting(false))
        // A-01: the drawn box is the target, not the line of text inside it.
        .contentShape(Rectangle())
        .onTapGesture { focused = question.id }
    }

    // MARK: Several questions

    private var review: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("lg")) {
            ForEach(Array(questions.enumerated()), id: \.offset) { offset, question in
                Tap(action: { page = offset }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: question.header?.isEmpty == false ? question.header! : question.question)
                            .font(OmodachiTheme.bodyFont("body-small", weight: .semibold))
                        Text(shown(question))
                            .font(OmodachiTheme.bodyFont("body"))
                            .foregroundStyle(answer(question) == nil ? OmodachiTheme.warning : OmodachiTheme.text)
                    }
                    .padding(.horizontal, OmodachiTheme.space("xl"))
                    .padding(.vertical, OmodachiTheme.space("md"))
                    .frame(maxWidth: .infinity, minHeight: NativeBarMetrics.hit, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .control(bordered: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("agent-question-review-\(question.id)")
            }
        }
    }

    private func shown(_ question: AgentChatQuestion) -> String {
        guard let value = answer(question) else { return Strings.agentQuestionUnanswered }
        return question.secret ? Strings.agentQuestionHidden : value
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            if stepped && page > 0 {
                TextTap(Strings.agentQuestionBack, bordered: true) { page -= 1; focused = nil }
                    .accessibilityIdentifier("agent-question-back-\(approval.requestID)")
            }
            if stepped && !reviewing {
                let current = questions[min(page, questions.count - 1)]
                TextTap(Strings.agentQuestionNext, bordered: true, enabled: answer(current) != nil) {
                    page += 1; focused = nil
                }
                .accessibilityIdentifier("agent-question-next-\(approval.requestID)")
            } else {
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
            if approval.isDeciding { ProgressView().controlSize(.small) }
        }
    }

    /// A question's answer: the chosen label, or the person's own words.
    private func answer(_ question: AgentChatQuestion) -> String? {
        if others.contains(question.id) || question.choices.isEmpty {
            let words = (typed[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : words
        }
        return chosen[question.id]
    }

    /// Only the questions that were actually answered are sent; the host
    /// refuses an empty list rather than letting a blank stand for a choice.
    private var submission: [String: [String]] {
        var input: [String: [String]] = [:]
        for question in questions { if let value = answer(question) { input[question.id] = [value] } }
        return input
    }
}
