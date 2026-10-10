import SwiftUI

/// Independent native surface. The integration owner keeps model and draft
/// across navigation; callbacks use the existing host/default-agent identity.
///
/// Study 01 §04: no bubbles, no avatars, no timestamps (N-06) — an 11pt speaker
/// label and a 2px accent rule down the user's own words. Prose is the platform
/// text face and machine text is the host's mono (A-07). The column stops at
/// 760 and stays left, so the composer, the messages and the tool rows share
/// one left edge (A-23).
struct AgentChatView: View {
    @Binding var model: AgentChatModel
    /// ATTACH-1: the chips above the composer (the store's own tray).
    @ObservedObject var attachments: AttachmentTray
    /// MOTION-1: what the agent is doing, for the face in the header and the
    /// large one on the empty transcript.
    var face: (state: AgentFaceState, tool: Bool) = (.idle, false)
    var onSend: (String) -> Void
    var onCancel: () -> Void
    var onRetry: () -> Void
    var onPrepareHandoff: () -> Void = {}
    var onConfirmHandoff: () -> Void = {}
    var onDeferHandoff: () -> Void = {}
    var onSteer: () -> Void = {}
    var onDecide: (String, String) -> Void = { _, _ in }
    var onAnswer: (String, [String: [String]]) -> Void = { _, _ in }
    var onLoadModels: () -> Void = {}
    var onChooseModel: (String?, String?) -> Void = { _, _ in }
    /// AGENT-NEW-1: the header's New conversation control and its card.
    var onAskNew: () -> Void = {}
    var onCancelNew: () -> Void = {}
    var onConfirmNew: () -> Void = {}
    /// AGENT-PLAN-1: the Plan chip (back to the default mode) and a plan's
    /// "Implement this plan".
    var onLeavePlan: () -> Void = {}
    var onImplementPlan: () -> Void = {}
    /// AGENT-PLAN-1: the `/diff` card's close.
    var onCloseDiff: () -> Void = {}
    /// AGENT-QUEUE-1: Send while a turn runs (codex's queue), a waiting
    /// message's Send now / Edit / Delete, "Earlier messages", and a decline
    /// with one line of why.
    var onQueue: () -> Void = {}
    var onQueueItem: (String, AgentQueueAction, String?) -> Void = { _, _, _ in }
    var onLoadEarlier: () -> Void = {}
    var onDeclineWhy: (String, String) -> Void = { _, _ in }
    /// LINKS-1: a tapped link and the row it was in (`LinkOpener`). The row's
    /// id is what core checks the path against, so it travels with the URL.
    var onOpenLink: (URL, LinkSource) -> Void = { _, _ in }
    /// The push-to-talk control, supplied by the surface so this view does not
    /// own an audio session.
    @State private var modelPickerVisible = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// AGENT-NEW-1 (Leo: the panel opened at the top of the conversation):
    /// whether the transcript follows new output. True on open; the person
    /// scrolling up to read turns it off, scrolling back to the end on again.
    @State private var followsEnd = true
    /// AGENT-COLLIE-1 idea 4: output arrived while the person was reading
    /// further up (the dot on "jump to the newest").
    @State private var unseen = false
    /// Find in the conversation: open, its words, and the match on screen.
    @State private var findOpen = false
    @State private var findQuery = ""
    @State private var findCurrent: String?
    @FocusState private var findFocused: Bool
    /// Idea 2: what the person chose for each run, and the runs that were
    /// working while on screen (they stay open when they finish).
    @State private var runChoices: [String: Bool] = [:]
    @State private var heldRuns: Set<String> = []
    /// A run opened because Find or "See the change" points inside it.
    @State private var revealedRun: String?
    /// AGENT-QUEUE-1: "Keep planning" puts the cursor in the composer; the
    /// row that was first before earlier messages came in front of it.
    @State private var composerFocus = 0
    @State private var earlierAnchor: String?

    /// A-23. 760 ≈ 90 characters at the 14pt body step.
    private static let column: CGFloat = 760
    /// One link notice and the gap around it (`LinkNoticeHost`).
    private static let noticeRoom: CGFloat = NativeBarMetrics.hit + 16
    /// MOTION-1 matrix: the header face is 28–32 (32 turns the shade on),
    /// the empty-state art 64–128 (96 is where the fine grid starts).
    private static let headerFace: CGFloat = 32
    private static let largeFace: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(OmodachiTheme.border).frame(height: NativeBarMetrics.edgeRule)
            if findOpen && !modelPickerVisible { findBar }
            // AGENT-QUEUE-1: codex's checklist, pinned while its plan is active.
            if let list = model.checklistShown, !modelPickerVisible { AgentChecklistBar(list: list) }
            // A-55: a panel fills the panel area, so the model list opens *in*
            // it rather than as a sheet over it. It was the last modal left in
            // a surface, and a sheet over a panel is the second navigation
            // model this spec exists to delete.
            if modelPickerVisible {
                AgentModelPicker(model: $model, onLoad: onLoadModels, onChoose: onChooseModel,
                                 onChosen: { modelPickerVisible = false })
            } else {
                // POLISH-U: a link's notice lies over the top of the
                // conversation, under the header and its face.
                // AGENT-PLAN-1: with no `/` hint above the composer any more,
                // a phone on its side with the keyboard up left the
                // conversation 24 points - less than a link notice, which then
                // lay over the composer. It keeps room for one notice.
                transcript.frame(minHeight: Self.noticeRoom).linkNoticeRegion()
                composer
            }
        }
        .background(OmodachiTheme.background)
        .foregroundStyle(OmodachiTheme.text).tint(OmodachiTheme.accent)
        .statusBarHidden(true).persistentSystemOverlays(.hidden)
    }

    // MARK: - Header

    /// The minimal identity strip: who this is, whether it is connected, which
    /// model and effort the next turn carries, and what it has spent. Control
    /// height is still 28 — only the hit area is 44 (A-01).
    private var header: some View {
        // A-55 took the back arrow away: the way out of a panel is the entry
        // that opened it, or the logo. So the header is what this agent *is*,
        // and nothing about where you came from.
        HStack(spacing: OmodachiTheme.space("lg")) {
            // The provider's own mark, monochromed to the panel's foreground.
            // It says whose agent this is in the one place the agent is named;
            // it is not the app's mark and it is never drawn larger than ours.
            // MOTION-1: the agent's own face, with the shade step (≥32). The
            // provider is named in the line beside it.
            // AGENT-UI-2: the face and the words beside it are one element, so
            // VoiceOver reads who this is however much of it a phone can draw.
            HStack(spacing: OmodachiTheme.space("lg")) {
                AgentFace(state: face.state, tool: face.tool, surface: .header, size: Self.headerFace)
                // AGENT-UI-2 (Leo: "一行全是折叠"): a phone's header is short of
                // room, and it is the identity that gives way - whole, then the
                // agent's name alone, then only the face - never the model.
                ViewThatFits(in: .horizontal) {
                    identityWords(model.identity.map { "\($0.agentID) · \($0.provider)" } ?? Strings.agentDefault)
                    identityWords(model.identity?.agentID ?? Strings.agentDefault)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.pair(model.identity.map { "\($0.agentID) · \($0.provider)" } ?? Strings.agentDefault,
                                             statusLine))
            .accessibilityValue(AgentFaceWords.word(face.state, tool: face.tool))
            .accessibilityIdentifier("agent-identity")
            .layoutPriority(1)

            Spacer(minLength: OmodachiTheme.space("sm"))

            if model.planOn { planChip }
            // A phone's header has no room for both: while Plan mode is on its
            // chip takes the usage meters' place (`/usage` still says them).
            // AGENT-UI-2: and the meters come after the model and the agent's
            // name - when they do not fit whole they are left out, not folded.
            if !(model.planOn && sizeClass == .compact) {
                ViewThatFits(in: .horizontal) {
                    AgentUsageBar(usage: model.usage)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            findControl
            newConversationControl
            modelControl
        }
        .padding(.horizontal, OmodachiTheme.space("sm"))
        .frame(height: NativeBarMetrics.hit)
    }

    private var statusLine: String {
        var parts: [String] = [phaseLabel]
        if model.status.waiting != nil { parts.append(model.status.label) }
        if !model.pendingApprovals.isEmpty { parts.append(Strings.agentWaitingCount(Format.count(model.pendingApprovals.count))) }
        return parts.joined(separator: " · ")
    }

    /// The agent's name over its status line, at its own width.
    private func identityWords(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: name)
                .font(OmodachiTheme.font("body-small", weight: .semibold))
                .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
            Text(statusLine)
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(OmodachiTheme.secondaryText)
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// Model and effort in one control. Tapping it lists what the provider
    /// itself advertises; this client never types a model name of its own.
    ///
    /// UX-4 §4 / A-55: tapping it again puts it away. The picker used to have
    /// a Done button, which is a second way out of one thing and the only
    /// control in the panel that worked that way — every other entry in this
    /// app is its own way back, from the bar to the gear. So the entry is a
    /// toggle and the Done button is gone. It reads the model and the effort
    /// the next turn carries, which is what a person taps it to check, so a
    /// tap that closes the list is also a tap that shows them the answer.
    ///
    /// AGENT-UI-2 (Leo: "模型和effort 一行全是折叠"): the model on one line and
    /// the effort under it, so a phone reads both whole; the control is laid
    /// out before anything else in the header takes its room.
    private var modelControl: some View {
        Tap(action: {
            modelPickerVisible.toggle()
            if modelPickerVisible { onLoadModels() }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: OmodachiTheme.space("xs")) {
                    Text(model.effectiveModel ?? Strings.agentModel)
                        .lineLimit(1).truncationMode(.middle)
                    // A choice that has not ridden a turn yet is still a
                    // choice, so it is marked rather than shown as if the
                    // provider agreed.
                    if model.selectedModel != nil || model.selectedEffort != nil {
                        Glyph(symbol: "arrow.up", points: OmodachiTheme.fontSize("caption"))
                    }
                }
                .font(OmodachiTheme.font("body-small"))
                if let effort = model.effectiveEffort {
                    Text(effort)
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, OmodachiTheme.space("lg"))
            .frame(minHeight: NativeBarMetrics.hit)
            // AGENT-UI-2: room for a long id ("gpt-5.6-sol-codex-max") on a
            // phone, and a shorter one takes only its own width - a
            // `maxWidth` frame would stretch every model to the cap.
            .modifier(AgentWidthCap(cap: sizeClass == .compact ? 176 : 240))
            .contentShape(Rectangle())
        }
        .control(bordered: true)
        .disabled(model.identity == nil)
        .layoutPriority(2)
        .accessibilityIdentifier("agent-model-control")
        .accessibilityLabel(Strings.agentModelValue(model.effectiveModel ?? "—", model.effectiveEffort ?? "—"))
    }

    /// AGENT-NEW-1: a quiet square in the header, not a big button. It is
    /// never dimmed (A-65: a dimmed control is a disabled one, and then nobody
    /// could learn why); while a turn runs or a question waits, the card it
    /// opens says why and keeps its own button off.
    private var newConversationControl: some View {
        Tap(action: {
            modelPickerVisible = false
            if model.fresh == .none { onAskNew() } else { onCancelNew() }
        }) {
            Glyph(Icon.newConversation, points: OmodachiTheme.fontSize("body-small"))
                .frame(width: OmodachiTheme.controlHeight, height: OmodachiTheme.controlHeight)
                .frame(minWidth: NativeBarMetrics.hit, minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
        }
        .control(bordered: true)
        .disabled(model.identity == nil)
        .accessibilityIdentifier("agent-new")
        .accessibilityLabel(Strings.agentNewAction)
        .accessibilityHint(model.newConversationRefusal ?? Strings.agentNewBody)
    }

    /// AGENT-PLAN-1: codex's Plan mode is on for this thread - a small chip in
    /// the accent. A tap goes back to the default mode; while a turn runs it
    /// says why it cannot (A-65: never a dimmed control nobody can learn from).
    private var planChip: some View {
        Tap(action: onLeavePlan) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                Glyph(Icon.plan, points: OmodachiTheme.fontSize("caption"))
                Text(Strings.agentPlanChip).lineLimit(1)
            }
            .font(OmodachiTheme.font("body-small", weight: .semibold))
            .foregroundStyle(OmodachiTheme.accent)
            .padding(.horizontal, OmodachiTheme.space("lg"))
            .frame(height: OmodachiTheme.controlHeight)
            .frame(minHeight: NativeBarMetrics.hit)
            .contentShape(Rectangle())
        }
        .control(bordered: true)
        .fixedSize()
        .accessibilityIdentifier("agent-plan-chip")
        .accessibilityLabel(Strings.agentPlanChipLabel)
        .accessibilityHint(model.modeRefusal ?? Strings.agentPlanChipHint)
    }

    /// AGENT-COLLIE-1 idea 4: Find, a quiet square beside New conversation;
    /// ⌘F on a hardware keyboard.
    private var findControl: some View {
        Tap(action: { findOpen ? closeFind() : openFind() }) {
            Glyph(Icon.search, points: OmodachiTheme.fontSize("body-small"))
                .frame(width: OmodachiTheme.controlHeight, height: OmodachiTheme.controlHeight)
                .frame(minWidth: NativeBarMetrics.hit, minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
        }
        .control(bordered: true)
        .disabled(model.rows.isEmpty)
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityIdentifier("agent-find")
        .accessibilityLabel(Strings.agentFind)
        .accessibilityAddTraits(findOpen ? [.isSelected] : [])
    }

    private func openFind() {
        modelPickerVisible = false
        findOpen = true
        findFocused = true
    }
    private func closeFind() {
        findOpen = false
        findQuery = ""
        findCurrent = nil
        revealedRun = nil
        findFocused = false
    }

    private var findMatches: [String] {
        findOpen ? AgentFind.matches(model.timeline, query: findQuery) : []
    }

    /// One row under the header: the words, "2/5", previous, next, close.
    /// Return steps to the next match; the ends wrap.
    private var findBar: some View {
        let matches = findMatches
        let position = findCurrent.flatMap { matches.firstIndex(of: $0) }
        let searching = !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: OmodachiTheme.space("md")) {
            Glyph(Icon.search, points: OmodachiTheme.fontSize("body-small"))
                .foregroundStyle(OmodachiTheme.secondaryText)
            TextField(Strings.agentFindPlaceholder, text: $findQuery)
                .font(OmodachiTheme.bodyFont("body"))
                .focused($findFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { stepFind(forward: true) }
                .frame(minHeight: NativeBarMetrics.hit)
                .accessibilityIdentifier("agent-find-field")
            if searching {
                Text(verbatim: matches.isEmpty ? "0/0" : "\((position ?? -1) + 1)/\(matches.count)")
                    .font(OmodachiTheme.font("caption"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .monospacedDigit()
                    .accessibilityLabel(matches.isEmpty ? Strings.agentFindNone
                                        : Strings.agentFindCountLabel(Format.count((position ?? -1) + 1), Format.count(matches.count)))
                    .accessibilityIdentifier("agent-find-count")
            }
            findButton(Icon.chevronUp, label: Strings.agentFindPrevious, identifier: "agent-find-previous",
                       enabled: !matches.isEmpty) { stepFind(forward: false) }
            findButton(Icon.chevronDown, label: Strings.agentFindNext, identifier: "agent-find-next",
                       enabled: !matches.isEmpty) { stepFind(forward: true) }
            findButton(Icon.close, label: Strings.agentFindClose, identifier: "agent-find-close",
                       enabled: true) { closeFind() }
        }
        .padding(.horizontal, OmodachiTheme.space("lg"))
        .frame(minHeight: NativeBarMetrics.hit)
        .background(OmodachiTheme.elevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OmodachiTheme.border).frame(height: NativeBarMetrics.edgeRule)
        }
        .onChange(of: findQuery) { _, _ in
            // New words: the first match, from the top, is the one on screen.
            findCurrent = nil
            stepFind(forward: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-find-bar")
    }

    private func findButton(_ icon: (symbol: String, nerd: String), label: String, identifier: String,
                            enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Tap(enabled: enabled, action: action) {
            Glyph(icon, points: OmodachiTheme.fontSize("body-small"))
                .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func stepFind(forward: Bool) {
        let order = model.timeline.map(\.id)
        guard let next = AgentFind.step(findMatches, in: order, from: findCurrent, forward: forward) else {
            findCurrent = nil
            return
        }
        findCurrent = next
        reveal(next)
    }

    /// Scrolls a timeline entry into view, opening the run it is in.
    private func reveal(_ id: String) {
        revealedRun = transcriptItems.first { item in
            if case .run(let run) = item { run.entries.contains { $0.id == id } } else { false }
        }?.id
        followsEnd = false
        scrollTarget = id
        scrollRequests += 1
    }
    @State private var scrollTarget: String?
    @State private var scrollRequests = 0

    @ViewBuilder private var newConversationCard: some View {
        if model.fresh != .none {
            VStack(alignment: .leading, spacing: OmodachiTheme.space("xl")) {
                Text(Strings.agentNewAction)
                    .font(OmodachiTheme.bodyFont("title", weight: .semibold))
                if model.fresh == .starting {
                    ProgressView(Strings.agentNewStarting)
                } else {
                    let refusal = model.newConversationRefusal
                    Text(refusal ?? Strings.agentNewBody)
                        .accessibilityIdentifier("agent-new-body")
                    if case .problem(let message) = model.fresh {
                        Text(message).foregroundStyle(OmodachiTheme.warning)
                    }
                    TextTap(Strings.agentNewStart, bordered: true, enabled: refusal == nil, action: onConfirmNew)
                        .accessibilityIdentifier("agent-new-confirm")
                    TextTap(Strings.agentNewLater, action: onCancelNew)
                        .accessibilityIdentifier("agent-new-later")
                }
            }
            .font(OmodachiTheme.bodyFont("body"))
            .padding(OmodachiTheme.space("xxxl"))
            .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-new-card")
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OmodachiTheme.space("huge")) {
                    // AGENT-QUEUE-1: a huge thread opens on its newest rows;
                    // reaching the top brings the page before them.
                    if model.earlier { earlierRow }
                    // AGENT-FIX-2: an answered prompt is one line under the
                    // row it was about, where it happened; only a prompt that
                    // still waits for the person is at the end.
                    // AGENT-COLLIE-1: three or more steps in a row are a run.
                    ForEach(transcriptItems) { item in
                        switch item {
                        case .entry(let entry):
                            entryView(entry, compact: false)
                        case .run(let run):
                            AgentRunView(run: run, waitingItems: waitingItems,
                                         choice: Binding(get: { runChoices[run.id] },
                                                         set: { runChoices[run.id] = $0 }),
                                         held: Binding(get: { heldRuns.contains(run.id) },
                                                       set: { if $0 { heldRuns.insert(run.id) } else { heldRuns.remove(run.id) } }),
                                         revealed: revealedRun == run.id) { entry in
                                entryView(entry, compact: true)
                            }
                        }
                    }
                    ForEach(model.waitingApprovals) { approval in
                        AgentApprovalCard(approval: approval, onDecide: onDecide, onAnswer: onAnswer,
                                          changes: approval.itemID.flatMap(changes(of:)) ?? [],
                                          onShowChange: approval.itemID.flatMap { item in
                                              changes(of: item) == nil ? nil : { reveal("tool:\(item)") }
                                          },
                                          onDeclineWhy: onDeclineWhy,
                                          questionDraft: model.draft(for: approval),
                                          onQuestionDraft: { model.keep($0, for: approval.requestID) })
                    }
                    if model.rows.isEmpty && model.approvals.isEmpty {
                        // MOTION-1: the large art — the only place the head
                        // hops in a loop; shade on, the fine grid at ≥96.
                        AgentFace(state: face.state, tool: face.tool, surface: .large, size: Self.largeFace)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Strings.agentFaceLabel(Strings.agentDefault,
                                                                       AgentFaceWords.word(face.state, tool: face.tool)))
                            .accessibilityIdentifier("agent-face-large")
                        Text(model.phase == .starting ? Strings.agentStarting : Strings.agentContinue)
                            .font(OmodachiTheme.bodyFont("subtitle")).foregroundStyle(OmodachiTheme.secondaryText)
                    }
                    if model.phase == .reconnecting {
                        TextTap(Strings.agentReconnect, action: onRetry).frame(minHeight: NativeBarMetrics.hit)
                    }
                    // The words the user just typed, before the provider has
                    // echoed them back. They are drawn exactly like the real
                    // row, because they are the same sentence — what is
                    // provisional is the delivery, not the text.
                    if let echo = model.localEcho { messageView(echo) }
                    if model.awaitingFirstToken {
                        ProgressRow(title: Strings.agentThinking, identifier: "agent-thinking")
                    }
                    handoffCard
                    newConversationCard
                    diffCard
                    if let error = model.error, model.handoff == .none {
                        VStack(alignment: .leading, spacing: OmodachiTheme.space("lg")) {
                            Text(error).font(OmodachiTheme.bodyFont("body")).foregroundStyle(OmodachiTheme.warning)
                            TextTap(Strings.actionRetry, action: onRetry).frame(minHeight: NativeBarMetrics.hit)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(OmodachiTheme.panelPadding)
                // A-56: ③ is a work surface, so the list is the panel area's
                // width and the composer under it starts and ends on the same
                // two edges. A-23's 760 is a *measure for prose* and is applied
                // to the message text itself (see `messageView`), not to this
                // container — applying it here is what left an iPad's composer
                // stopping 400 points short: "发送框不是全宽的在 iPad 上".
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            // Opens at the newest message, not at the top of the history.
            .defaultScrollAnchor(.bottom)
            .modifier(FollowsEnd(following: $followsEnd))
            // AGENT-COLLIE-1 idea 4: the way back to the end. AGENT-UI-3: the
            // ↑ / ↓ between the person's own messages is gone - scrolling does
            // it better, and the buttons sat on the conversation.
            .overlay(alignment: .bottom) { jumpToNewest(proxy) }
            .onChange(of: followsEnd) { _, following in if following { unseen = false } }
            .onChange(of: scrollRequests) { _, _ in
                guard let target = scrollTarget else { return }
                // A run opened this frame is measured on the next one; its
                // own id first, then the line inside it.
                if let run = revealedRun { proxy.scrollTo(run, anchor: .top) }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.14)) { proxy.scrollTo(target, anchor: .center) }
                }
            }
            .onAppear {
                followsEnd = true
                scroll(proxy, animated: false)
                // Once more after the lazy rows have been measured.
                DispatchQueue.main.async { scroll(proxy, animated: false) }
            }
            // A conversation loaded or replaced is read from its end.
            .onChange(of: model.identity) { _, _ in
                followsEnd = true
                scroll(proxy, animated: false)
            }
            // New rows, streamed words, a card: followed only while at the end.
            .onChange(of: tailSignature) { _, _ in
                if followsEnd { scroll(proxy, animated: false) } else { unseen = true }
            }
            .onChange(of: model.localEcho) { _, echo in
                // The person just sent: they want to see the answer.
                if echo != nil { followsEnd = true; scroll(proxy, animated: true) }
            }
            // AGENT-QUEUE-1: earlier rows came in front - the reader stays on
            // the row they were reading.
            .onChange(of: model.rows.first?.id) { _, _ in
                guard let anchor = earlierAnchor else { return }
                earlierAnchor = nil
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    /// AGENT-QUEUE-1: "Earlier messages" at the top; it loads itself when it
    /// comes into view, and stays as a button while a page is on its way or
    /// did not come.
    private var earlierRow: some View {
        TextTap(model.loadingEarlier ? Strings.agentEarlierLoading : Strings.agentEarlier,
                enabled: !model.loadingEarlier, action: loadEarlier)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("agent-earlier")
            .onAppear { if !followsEnd { loadEarlier() } }
    }

    private func loadEarlier() {
        guard !model.loadingEarlier else { return }
        earlierAnchor = model.rows.first?.id
        followsEnd = false
        onLoadEarlier()
    }

    // MARK: - AGENT-COLLIE-1: the transcript's items

    private var transcriptItems: [AgentTranscriptItem] { AgentRun.group(model.timeline) }
    /// The steps a prompt is waiting on right now.
    private var waitingItems: Set<String> { Set(model.waitingApprovals.compactMap(\.itemID)) }
    private func changes(of item: String) -> [AgentChatChange]? {
        for row in model.rows { if case .tool(let tool) = row, tool.id == item { return tool.changes } }
        return nil
    }

    /// One line of the conversation, marked when Find matches it.
    @ViewBuilder private func entryView(_ entry: AgentTimelineEntry, compact: Bool) -> some View {
        let query = findOpen ? findQuery : ""
        let matched = findOpen && AgentFind.contains(AgentFind.searchable(entry), findQuery)
        Group {
            switch entry {
            case .row(.message(let message)): messageView(message)
            case .row(.tool(let tool)):
                AgentToolRow(tool: tool, compact: compact, waiting: waitingItems.contains(tool.id), query: query)
                    .environment(\.openURL, OpenURLAction { url in
                        onOpenLink(url, .agent(item: tool.id))
                        return .handled
                    })
            case .answered(let approval):
                AgentApprovalCard(approval: approval, onDecide: onDecide, onAnswer: onAnswer)
            }
        }
        .environment(\.findHighlight, query)
        .background(matched ? OmodachiTheme.accent.opacity(0.08) : .clear)
        .overlay {
            if findCurrent == entry.id {
                Rectangle().strokeBorder(OmodachiTheme.accent, lineWidth: OmodachiTheme.popupBorderWidth)
                    .padding(-OmodachiTheme.space("sm"))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Down to the newest, when the person has scrolled away from it; the dot
    /// says output arrived meanwhile.
    @ViewBuilder private func jumpToNewest(_ proxy: ScrollViewProxy) -> some View {
        if !followsEnd && !model.rows.isEmpty {
            Tap(action: {
                followsEnd = true
                unseen = false
                scroll(proxy, animated: true)
            }) {
                Glyph(symbol: "arrow.down", points: OmodachiTheme.fontSize("body"))
                    .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                    .background(OmodachiTheme.elevated)
                    .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
                    .overlay(alignment: .topTrailing) {
                        if unseen {
                            Rectangle().fill(OmodachiTheme.accent).frame(width: 9, height: 9)
                                .offset(x: 3, y: -3)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Strings.agentJumpNewest)
            .accessibilityValue(unseen ? Strings.agentJumpUnseen : "")
            .accessibilityIdentifier(unseen ? "agent-jump-newest-unseen" : "agent-jump-newest")
            .padding(.bottom, OmodachiTheme.space("xl"))
        }
    }

    private static let bottomAnchor = "agent-transcript-bottom"
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.14)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    /// Everything that grows the end of the transcript: a row, the words
    /// streaming into the last one, a tool's output, a card.
    private var tailSignature: String {
        let last: String
        switch model.rows.last {
        case .message(let message)?: last = message.id + ":" + String(message.text.count)
        case .tool(let tool)?: last = tool.id + ":" + String(tool.detail.count) + ":" + tool.status.rawValue
        case nil: last = ""
        }
        // AGENT-FIX-2: the phase too - "Reconnect" appearing at the end of
        // the list used to stay below the visible part of it.
        // AGENT-QUEUE-1: the newest row, not how many there are - earlier
        // messages loaded at the top are not new output at the end.
        return [last, String(model.approvals.count),
                String(model.waitingApprovals.count), String(model.awaitingFirstToken),
                String(model.fresh != .none), String(model.error != nil), String(model.diff?.changes.count ?? -1),
                model.phase.rawValue].joined(separator: "|")
    }

    /// N-06. The speaker is an 11pt label; the user's own words additionally
    /// carry the 2px accent rule, which is the window-border language again.
    @ViewBuilder private func messageView(_ message: AgentChatMessage) -> some View {
        if message.isPlan { planCard(message) } else { plainMessageView(message) }
    }

    /// AGENT-PLAN-1: the plan codex proposed in Plan mode, as a card of its
    /// own - its title, the plan's markdown, and on the newest one while Plan
    /// mode is on, what codex's TUI asks next: implement it (back to the
    /// default mode and the words that ask for it), or keep writing to refine.
    @ViewBuilder private func planCard(_ message: AgentChatMessage) -> some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("lg")) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                Glyph(Icon.plan, points: OmodachiTheme.fontSize("caption"))
                Text(Strings.agentPlanTitle)
            }
            .font(OmodachiTheme.font("body-small", weight: .semibold))
            .foregroundStyle(OmodachiTheme.accent)
            .accessibilityAddTraits(.isHeader)
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                MarkdownText(blocks: AgentMarkdown.parse(message.text))
                    .contextMenu {
                        TextTap(Strings.agentCopyReply) { UIPasteboard.general.string = message.text }
                    }
                if streaming(message) { StreamingCursor() }
                Spacer(minLength: 0)
            }
            if let cut = message.textTruncated { trimmed(cut, message.id) }
            if model.actionablePlanID == message.id {
                let refusal = model.modeRefusal
                VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                    HStack(spacing: OmodachiTheme.space("lg")) {
                        TextTap(Strings.agentPlanImplement, bordered: true, enabled: refusal == nil, action: onImplementPlan)
                            .accessibilityIdentifier("agent-plan-implement")
                            .accessibilityHint(refusal ?? Strings.agentPlanImplementHint)
                        // AGENT-QUEUE-1: or stay in Plan mode and say what to
                        // change - the cursor goes to the composer.
                        TextTap(Strings.agentPlanKeep, bordered: true) { composerFocus += 1 }
                            .accessibilityIdentifier("agent-plan-keep")
                            .accessibilityHint(Strings.agentPlanKeepHint)
                    }
                    Text(refusal ?? Strings.agentPlanImplementHint)
                        .accessibilityIdentifier("agent-plan-implement-note")
                }
                .font(OmodachiTheme.bodyFont("body-small"))
                .foregroundStyle(OmodachiTheme.secondaryText)
            }
        }
        .padding(OmodachiTheme.space("xl"))
        .frame(maxWidth: Self.column, alignment: .leading)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.accent, lineWidth: OmodachiTheme.popupBorderWidth)
            .accessibilityHidden(true))
        .environment(\.openURL, OpenURLAction { url in
            onOpenLink(url, .agent(item: message.id))
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.agentPlanTitle)
        .accessibilityIdentifier("agent-plan-\(message.id)")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func plainMessageView(_ message: AgentChatMessage) -> some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            Text(message.role == .user ? Strings.agentRoleYou : Strings.agentRoleAgent)
                .font(OmodachiTheme.font("body-small", weight: .semibold))
                .foregroundStyle(message.role == .user ? OmodachiTheme.accent : OmodachiTheme.muted)
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                if message.role == .assistant {
                    // LINKS-1 §3: the agent's markdown as blocks. The person's
                    // own words are drawn exactly as typed — and verbatim, so a
                    // message that happens to equal a catalog key is never
                    // swapped for its translation (ATTACH-2 §8-5).
                    // Not selectable: on iOS 27 a selectable Text nested in
                    // a list item keeps the touch and its links never open.
                    // The whole reply is copied from its menu instead.
                    MarkdownText(blocks: AgentMarkdown.parse(message.text))
                        .contextMenu {
                            TextTap(Strings.agentCopyReply) { UIPasteboard.general.string = message.text }
                        }
                } else {
                    Text(verbatim: message.text)
                        .font(OmodachiTheme.bodyFont("title"))
                        .textSelection(.enabled)
                }
                if streaming(message) { StreamingCursor() }
                Spacer(minLength: 0)
            }
            // A-23: 760 ≈ 90 characters. It is the line length prose is
            // readable at, so it belongs to the prose and to nothing else.
            .frame(maxWidth: Self.column, alignment: .leading)
            if let images = message.images, images > 0 {
                AgentMessagePictures(count: images)
                    .accessibilityIdentifier("agent-message-pictures-\(message.id)")
            }
            if let cut = message.textTruncated { trimmed(cut, message.id) }
        }
        // A link's tap goes to the app, never to iOS: a path would otherwise
        // be opened as a file on the phone, and a web page in Safari.
        .environment(\.openURL, OpenURLAction { url in
            onOpenLink(url, .agent(item: message.id))
            return .handled
        })
        .padding(.leading, message.role == .user ? OmodachiTheme.space("xl") : 0)
        .overlay(alignment: .leading) {
            if message.role == .user {
                Rectangle().fill(OmodachiTheme.accent)
                    .frame(width: OmodachiTheme.popupBorderWidth)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// AGENT-QUEUE-1: a giant message arrived as its beginning; say so.
    private func trimmed(_ count: Int, _ id: String) -> some View {
        Text(Strings.agentTrimmed(Format.count(count)))
            .font(OmodachiTheme.bodyFont("body-small"))
            .foregroundStyle(OmodachiTheme.secondaryText)
            .accessibilityIdentifier("agent-message-trimmed-\(id)")
    }

    /// The cursor belongs to the assistant row of the turn that is running, and
    /// to no other row.
    private func streaming(_ message: AgentChatMessage) -> Bool {
        message.role == .assistant && model.phase == .running && message.turnID == model.turnID
            && model.rows.last?.id == "message:\(message.id)"
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: OmodachiTheme.space("lg")) {
            Rectangle().fill(OmodachiTheme.border).frame(height: NativeBarMetrics.edgeRule)
            if let notice = model.notice { noticeRow(notice) }
            // AGENT-QUEUE-1: what waits for the turn to end.
            if let queue = model.queue, !queue.isEmpty {
                AgentQueueRows(queue: queue, running: model.phase == .running || model.phase == .cancelling,
                               onItem: onQueueItem)
            }
            // ATTACH-1: what goes with the next Send, and why a pick was refused.
            AttachmentChipStrip(tray: attachments, identifier: "agent-chips")
            // N-35 rev 5: no microphone in it. The `Composer` primitive is the
            // one input shape in the app, and it has none to give.
            Composer(placeholder: Strings.agentComposer, text: $model.draft,
                     identifier: "agent-chat-composer", leading: {
                let running = model.phase == .running || model.phase == .cancelling
                AttachButton(tray: attachments, enabled: model.identity != nil && !running,
                             identifier: "agent-attach")
            }) {
                composerActions
            }
            .focusing(composerFocus)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // AGENT-UI-1: the composer is its own surface, drawn after (so over)
        // the transcript. It no longer borrows the panel's background through
        // a gap, so nothing of the conversation can show in it — the same
        // shape as Herdr's control area.
        .background(OmodachiTheme.background)
    }

    /// A running turn is not a closed door: the words go in as an interjection
    /// (`turn/steer`), and stopping it is a separate, explicit control.
    /// AGENT-PLAN-1 (Leo): no `/` button and no Run - what is typed is sent as
    /// typed, a slash command too.
    @ViewBuilder private var composerActions: some View {
        if model.phase == .running || model.phase == .cancelling {
            // AGENT-QUEUE-1: Send waits in codex's queue for the turn to end;
            // a codex without the queue is steered into, as before.
            if model.queue != nil {
                action(Strings.agentSend, identifier: "agent-queue-send", enabled: model.canQueue && attachments.isEmpty, onQueue)
            } else {
                action(Strings.agentSteer, identifier: "agent-steer", enabled: model.canSteer && attachments.isEmpty, onSteer)
            }
            action(Strings.agentInterrupt, identifier: "agent-interrupt", enabled: model.canCancel, onCancel)
        } else {
            action(Strings.agentSend, identifier: "agent-send",
                   enabled: model.canSend(attached: attachments.hasReady) && !attachments.isUploading) {
                onSend(model.draft)
            }
        }
    }

    private func action(_ title: String, identifier: String, enabled: Bool, _ handler: @escaping () -> Void) -> some View {
        Tap(action: handler) {
            Text(title)
                .font(OmodachiTheme.font("body-small"))
                .padding(.horizontal, OmodachiTheme.space("xl"))
                .frame(height: OmodachiTheme.controlHeight)
                .frame(minWidth: 60, minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
        }
        .control(bordered: true)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    private func noticeRow(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: OmodachiTheme.space("lg")) {
            ScrollView {
                Text(notice).font(OmodachiTheme.bodyFont("body-small"))
                    .foregroundStyle(OmodachiTheme.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140)
            Tap(action: { model.notice = nil }) {
                Glyph(symbol: "xmark").frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                    .contentShape(Rectangle())
            }
            
            .accessibilityLabel(Strings.agentDismissResult)
        }
        .padding(.horizontal, OmodachiTheme.panelPadding)
        .accessibilityIdentifier("agent-command-result")
    }

    /// AGENT-PLAN-1: what `/diff` brought - the files this conversation
    /// changed, as the change cards codex's own edits make (never a file
    /// viewer; a path opens on the computer). Closed with its own button.
    @ViewBuilder private var diffCard: some View {
        if let diff = model.diff {
            VStack(alignment: .leading, spacing: OmodachiTheme.space("xl")) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Strings.agentDiffTitle)
                        .font(OmodachiTheme.bodyFont("title", weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: OmodachiTheme.space("lg"))
                    Tap(action: onCloseDiff) {
                        Glyph(symbol: "xmark").frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Strings.agentDiffClose)
                    .accessibilityIdentifier("agent-diff-close")
                }
                if diff.changes.isEmpty {
                    Text(Strings.agentDiffEmpty)
                        .accessibilityIdentifier("agent-diff-empty")
                } else {
                    AgentChangeCards(tool: diff.tool, changes: diff.changes,
                                     glyph: ("checkmark", .green)) // non-copy: a glyph name
                        .environment(\.openURL, OpenURLAction { url in
                            onOpenLink(url, .agent(item: AgentDiffState.itemID))
                            return .handled
                        })
                }
                if diff.omitted > 0 {
                    Text(Strings.agentDiffOmitted(Format.count(diff.omitted)))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                }
            }
            .font(OmodachiTheme.bodyFont("body"))
            .padding(OmodachiTheme.space("xxxl"))
            .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-diff")
        }
    }

    @ViewBuilder private var handoffCard: some View {
        if model.handoff != .none {
            VStack(alignment: .leading, spacing: OmodachiTheme.space("xl")) {
                Text(Strings.agentHandoffKeep)
                    .font(OmodachiTheme.bodyFont("title", weight: .semibold))
                switch model.handoff {
                case .required:
                    Text(Strings.agentHandoffDetail)
                    TextTap(Strings.agentHandoffReview, action: onPrepareHandoff).frame(minHeight: NativeBarMetrics.hit)
                case .preparing:
                    ProgressView(Strings.agentCheckingSession)
                case .prepared(let plan), .confirming(let plan):
                    Text(verbatim: "\(plan.agentID) · \(plan.provider)")
                    Text(plan.impact)
                    DisclosureGroup(Strings.agentHandoffRollback) { Text(plan.rollback) }
                    if case .confirming = model.handoff {
                        ProgressView(Strings.agentConnectingConversation)
                    } else {
                        TextTap(Strings.agentHandoffConfirm, action: onConfirmHandoff).frame(minHeight: NativeBarMetrics.hit)
                        TextTap(Strings.agentHandoffLater, action: onDeferHandoff).frame(minHeight: NativeBarMetrics.hit)
                    }
                case .problem(let message):
                    Text(message).foregroundStyle(OmodachiTheme.warning)
                    TextTap(Strings.agentHandoffAgain, action: onPrepareHandoff).frame(minHeight: NativeBarMetrics.hit)
                case .none: EmptyView()
                }
            }
            .font(OmodachiTheme.bodyFont("body"))
            .padding(OmodachiTheme.space("xxxl"))
            .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
            .accessibilityIdentifier("agent-handoff-card")
        }
    }

    private var phaseLabel: String {
        switch model.phase {
        case .dormant: "—"
        case .starting: Strings.agentPhaseStarting
        case .ready: Strings.agentPhaseReady
        case .sending: Strings.agentPhaseSending
        case .running: Strings.agentPhaseWorking
        case .cancelling: Strings.agentPhaseStopping
        case .reconnecting: Strings.agentPhaseReconnecting
        case .failed: Strings.agentPhaseFailed
        }
    }
}

/// D-10. A block, not a rounded caret: `rounding 0` applies to the cursor too.
/// 8 wide (one mono character) by 15 high (the 12pt line box).
struct StreamingCursor: View {
    @State private var on = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(OmodachiTheme.accent)
            .frame(width: 8, height: 15)
            .padding(.leading, 2)
            .opacity(on ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { on = false }
            }
            .accessibilityHidden(true)
    }
}

/// `state.agent.usage`: how much of the context window the last turn used, and
/// whatever quota windows the provider actually reported. A host on an API key
/// receives no rate limits at all, so the quota half simply is not drawn rather
/// than being drawn empty (`SPEC-G1-report.md` §5.1).
struct AgentUsageBar: View {
    let usage: AgentChatUsage

    var body: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            if let fraction = usage.contextFraction { meter(label: Strings.agentContext, fraction: fraction) }
            ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                if let percent = window.usedPercent {
                    meter(label: window.label, fraction: min(1, max(0, percent / 100)))
                }
            }
        }
        .font(OmodachiTheme.font("caption"))
        .foregroundStyle(OmodachiTheme.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-usage")
    }

    private func meter(label: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Strings.pair(label, Format.percent(fraction)))
            ZStack(alignment: .leading) {
                Rectangle().fill(OmodachiTheme.normalFill).frame(width: 44, height: 4)
                Rectangle()
                    .fill(fraction > 0.9 ? OmodachiTheme.warning : OmodachiTheme.accent)
                    .frame(width: 44 * fraction, height: 4)
            }
        }
        .accessibilityLabel(Strings.pair(label, Format.percent(fraction)))
    }
}

/// The provider's own model list. Nothing is typed in here: the ids, the
/// display names and the reasoning efforts all come from `model/list`.
struct AgentModelPicker: View {
    @Binding var model: AgentChatModel
    var onLoad: () -> Void
    var onChoose: (String?, String?) -> Void
    /// UX-4 §4. Called by the one row that finishes on its own — "use the
    /// thread's own model", which takes the selection away and so has nothing
    /// left to adjust. Every other way out is the control that opened this,
    /// exactly as it is for every other entry (A-55). Picking a model still
    /// leaves the list up, because the effort beside it is the same choice.
    let onChosen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: OmodachiTheme.space("lg")) {
                Text(Strings.agentModel)
                    .font(OmodachiTheme.font("heading"))
                    .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(height: NativeBarMetrics.hit)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OmodachiTheme.space("lg")) {
                    if model.modelsLoading { ProgressView(Strings.agentLoadingModels) }
                    if let notice = model.modelsNotice {
                        Text(notice).font(OmodachiTheme.bodyFont("body-small")).foregroundStyle(OmodachiTheme.warning)
                    }
                    ForEach(model.models?.offered ?? []) { descriptor in
                        row(descriptor)
                    }
                    if model.selectedModel != nil || model.selectedEffort != nil {
                        TextTap(Strings.agentModelThread) {
                            onChoose(nil, nil)
                            onChosen()
                        }
                    }
                }
                .padding(OmodachiTheme.panelPadding)
            }
            .background(OmodachiTheme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-model-picker")
        .task { onLoad() }
        .accessibilityIdentifier("agent-model-picker")
    }

    @ViewBuilder private func row(_ descriptor: AgentModelDescriptor) -> some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            // AGENT-UI-2: the name wraps rather than folding, and "default"
            // goes under it when the two do not share a line.
            HStack(alignment: .top, spacing: OmodachiTheme.space("sm")) {
                AgentWrapRow(spacing: OmodachiTheme.space("sm")) {
                    Text(verbatim: descriptor.name).font(OmodachiTheme.font("subtitle", weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if descriptor.isDefault { Text(Strings.agentDefault).font(OmodachiTheme.font("caption")).foregroundStyle(OmodachiTheme.secondaryText) }
                }
                Spacer(minLength: 0)
                if model.effectiveModel == descriptor.id { Glyph(symbol: "checkmark").foregroundStyle(OmodachiTheme.accent) }
            }
            if let description = descriptor.description, !description.isEmpty {
                Text(description).font(OmodachiTheme.bodyFont("body-small")).foregroundStyle(OmodachiTheme.secondaryText)
            }
            // Effort is part of the same choice: picking one picks the model.
            // AGENT-UI-2: its own line under the model, and five efforts on a
            // narrow phone go on to a second line rather than off the edge.
            AgentWrapRow(spacing: OmodachiTheme.space("md")) {
                ForEach(descriptor.efforts, id: \.self) { effort in
                    Tap(action: {
                        onChoose(descriptor.id, effort)
                    }) {
                        Text(effort)
                            .font(OmodachiTheme.font("body-small"))
                            .padding(.horizontal, OmodachiTheme.space("xl"))
                            .frame(height: OmodachiTheme.controlHeight)
                            .frame(minHeight: NativeBarMetrics.hit)
                            .contentShape(Rectangle())
                    }
                    .control(selected: model.effectiveModel == descriptor.id
                             && model.effectiveEffort == effort, bordered: true)
                    .accessibilityIdentifier("agent-effort-\(descriptor.id)-\(effort)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, OmodachiTheme.space("lg"))
    }
}

/// AGENT-UI-2: at most `cap` wide, otherwise exactly as wide as its content.
struct AgentWidthCap: ViewModifier {
    let cap: CGFloat
    func body(content: Content) -> some View { Capped(cap: cap) { content } }

    private struct Capped: Layout {
        let cap: CGFloat
        private func narrowed(_ proposal: ProposedViewSize) -> ProposedViewSize {
            ProposedViewSize(width: min(proposal.width ?? cap, cap), height: proposal.height)
        }
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            subviews.first?.sizeThatFits(narrowed(proposal)) ?? .zero
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: narrowed(proposal))
        }
    }
}

/// AGENT-UI-2: children left to right at their own size, onto the next line
/// when the width runs out - never squeezed, never truncated.
struct AgentWrapRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [(Int, CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                // Wider than the line on its own: it wraps inside itself.
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// AGENT-NEW-1: only the person's own scrolling decides whether the
/// transcript follows its end - content growing under a pinned view must not
/// read as "scrolled away". iOS 17 has no scroll phase, so there it always
/// follows (the old behaviour, now also for streamed words).
private struct FollowsEnd: ViewModifier {
    @Binding var following: Bool
    @State private var personScrolling = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    personScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 48
                } action: { _, atEnd in
                    if personScrolling { following = atEnd }
                }
        } else {
            content
        }
    }
}
