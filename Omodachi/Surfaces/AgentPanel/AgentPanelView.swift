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
    var onSend: (String) -> Void
    var onCancel: () -> Void
    var onRetry: () -> Void
    var onPrepareHandoff: () -> Void = {}
    var onConfirmHandoff: () -> Void = {}
    var onDeferHandoff: () -> Void = {}
    var onLoadSlash: () -> Void = {}
    var onSelectSlash: (AgentSlashDescriptor) -> Void = { _ in }
    var onSteer: () -> Void = {}
    var onDecide: (String, String) -> Void = { _, _ in }
    var onAnswer: (String, [String: [String]]) -> Void = { _, _ in }
    var onLoadModels: () -> Void = {}
    var onChooseModel: (String?, String?) -> Void = { _, _ in }
    /// The push-to-talk control, supplied by the surface so this view does not
    /// own an audio session.
    @State private var modelPickerVisible = false

    /// A-23. 760 ≈ 90 characters at the 14pt body step.
    private static let column: CGFloat = 760

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(OmodachiTheme.border).frame(height: NativeBarMetrics.edgeRule)
            // A-55: a panel fills the panel area, so the model list opens *in*
            // it rather than as a sheet over it. It was the last modal left in
            // a surface, and a sheet over a panel is the second navigation
            // model this spec exists to delete.
            if modelPickerVisible {
                AgentModelPicker(model: $model, onLoad: onLoadModels, onChoose: onChooseModel,
                                 onChosen: { modelPickerVisible = false })
            } else {
                transcript
                composer
            }
        }
        .background(OmodachiTheme.background)
        .foregroundStyle(OmodachiTheme.text).tint(OmodachiTheme.accent)
        .onChange(of: model.draft) { old, new in
            if AgentSlashInvocation.parse(new) == nil { model.slash.literalText = false }
            if AgentSlashInvocation.parse(new) != nil && AgentSlashInvocation.parse(old) == nil { onLoadSlash() }
        }
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
            BrandGlyph(mark: BrandMark.provider(model.identity?.provider),
                       fallback: Icon.agent)
                .foregroundStyle(OmodachiTheme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.identity.map { "\($0.agentID) · \($0.provider)" } ?? Strings.agentDefault)
                    .font(OmodachiTheme.font("body-small", weight: .semibold))
                    .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                Text(statusLine)
                    .font(OmodachiTheme.font("caption"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agent-identity")

            Spacer(minLength: OmodachiTheme.space("sm"))

            AgentUsageBar(usage: model.usage)
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
    private var modelControl: some View {
        Tap(action: {
            modelPickerVisible.toggle()
            if modelPickerVisible { onLoadModels() }
        }) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                Text(model.effectiveModel ?? Strings.agentModel)
                    .lineLimit(1).truncationMode(.middle)
                if let effort = model.effectiveEffort {
                    Text(effort).foregroundStyle(OmodachiTheme.secondaryText)
                }
                // A choice that has not ridden a turn yet is still a choice, so
                // it is marked rather than shown as if the provider agreed.
                if model.selectedModel != nil || model.selectedEffort != nil {
                    Glyph(symbol: "arrow.up", points: OmodachiTheme.fontSize("caption"))
                }
            }
            .font(OmodachiTheme.font("body-small"))
            .padding(.horizontal, OmodachiTheme.space("xl"))
            .frame(height: OmodachiTheme.controlHeight)
            // The cap has to be on the outermost frame: a height-only frame
            // after it would take the full proposal back and the control's
            // border would be drawn around half the header.
            .frame(maxWidth: 190, minHeight: NativeBarMetrics.hit)
            .contentShape(Rectangle())
        }
        .control(bordered: true)
        .disabled(model.identity == nil)
        .accessibilityIdentifier("agent-model-control")
        .accessibilityLabel(Strings.agentModelValue(model.effectiveModel ?? "—", model.effectiveEffort ?? "—"))
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OmodachiTheme.space("huge")) {
                    ForEach(model.rows) { row in
                        switch row {
                        case .message(let message): messageView(message)
                        case .tool(let tool): AgentToolRow(tool: tool)
                        }
                    }
                    ForEach(model.approvals) { approval in
                        AgentApprovalCard(approval: approval, onDecide: onDecide, onAnswer: onAnswer)
                    }
                    if model.rows.isEmpty && model.approvals.isEmpty {
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
            .onChange(of: model.rows.count) { _, _ in scroll(proxy) }
            .onChange(of: model.approvals.count) { _, _ in scroll(proxy) }
        }
    }

    private static let bottomAnchor = "agent-transcript-bottom"
    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.14)) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
    }

    /// N-06. The speaker is an 11pt label; the user's own words additionally
    /// carry the 2px accent rule, which is the window-border language again.
    @ViewBuilder private func messageView(_ message: AgentChatMessage) -> some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            Text(message.role == .user ? Strings.agentRoleYou : Strings.agentRoleAgent)
                .font(OmodachiTheme.font("body-small", weight: .semibold))
                .foregroundStyle(message.role == .user ? OmodachiTheme.accent : OmodachiTheme.muted)
            HStack(alignment: .top, spacing: 0) {
                Text(.init(message.text))
                    .font(OmodachiTheme.bodyFont("title"))
                    .textSelection(.enabled)
                if streaming(message) { StreamingCursor() }
                Spacer(minLength: 0)
            }
            // A-23: 760 ≈ 90 characters. It is the line length prose is
            // readable at, so it belongs to the prose and to nothing else.
            .frame(maxWidth: Self.column, alignment: .leading)
        }
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
            if let notice = model.slash.notice { noticeRow(notice) }
            if AgentSlashInvocation.parse(model.draft) != nil && !model.slash.literalText { slashList }
            // N-35 rev 5: no microphone in it. The `Composer` primitive is the
            // one input shape in the app, and it has none to give.
            Composer(placeholder: Strings.agentComposer, text: $model.draft,
                     identifier: "agent-chat-composer") {
                composerActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A running turn is not a closed door: the words go in as an interjection
    /// (`turn/steer`), and stopping it is a separate, explicit control.
    @ViewBuilder private var composerActions: some View {
        if AgentSlashInvocation.parse(model.draft) != nil && !model.slash.literalText {
            action(Strings.agentRun, identifier: "agent-run-command", enabled: !model.slash.executing && model.identity != nil) {
                onSend(model.draft)
            }
        } else if model.phase == .running || model.phase == .cancelling {
            action(Strings.agentSteer, identifier: "agent-steer", enabled: model.canSteer, onSteer)
            action(Strings.agentInterrupt, identifier: "agent-interrupt", enabled: model.canCancel, onCancel)
        } else {
            action(Strings.agentSend, identifier: "agent-send", enabled: model.canSend && !model.slash.executing) {
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
            Tap(action: { model.slash.notice = nil }) {
                Glyph(symbol: "xmark").frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                    .contentShape(Rectangle())
            }
            
            .accessibilityLabel(Strings.agentDismissResult)
        }
        .padding(.horizontal, OmodachiTheme.panelPadding)
        .accessibilityIdentifier("agent-command-result")
    }

    /// A-16. The list grows upward from the composer's own top edge rather than
    /// opening centred, because a centred list is half under the keyboard.
    private var slashList: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            if model.slash.loading { ProgressView(Strings.agentLoadingCommands) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.slash.matches(model.draft)) { command in
                        Tap(action: { onSelectSlash(command) }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(command.name.hasPrefix("/") ? command.name : "/" + command.name)
                                    .font(OmodachiTheme.font("body-small"))
                                    .foregroundStyle(OmodachiTheme.accent)
                                Text(command.description).font(OmodachiTheme.bodyFont("body-small"))
                                if let hint = command.argumentHint {
                                    Text(hint).font(OmodachiTheme.font("body-small")).foregroundStyle(OmodachiTheme.secondaryText)
                                }
                                if !command.available {
                                    Text(command.reason ?? Strings.agentCommandUnsupported)
                                        .font(OmodachiTheme.bodyFont("body-small"))
                                        .foregroundStyle(OmodachiTheme.warning)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        
                    }
                }
            }
            // A-16: at most five 50-high rows, then it scrolls.
            .frame(maxHeight: 250)
            HStack {
                TextTap(Strings.agentRefreshCommands, action: onLoadSlash)
                Spacer()
                TextTap(Strings.agentLiteralText) { model.slash.literalText = true }
            }
            .font(OmodachiTheme.font("body-small"))
            .frame(minHeight: NativeBarMetrics.hit)
        }
        .padding(.horizontal, OmodachiTheme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent-slash-commands")
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

/// A-20. One turn's structure has to stay readable on a phone, so a tool call
/// is a 28-high control row with the 1px control border; only expanding it
/// turns the output into a mono block.
struct AgentToolRow: View {
    let tool: AgentChatTool
    @State private var expanded = false

    private var symbol: String {
        switch tool.status {
        case .running: "ellipsis" // non-copy: a glyph name
        case .succeeded: "checkmark" // non-copy: a glyph name
        case .failed: "exclamationmark" // non-copy: a glyph name
        case .cancelled: "minus" // non-copy: a glyph name
        case .unknown: "questionmark" // non-copy: a glyph name
        }
    }
    private var role: ThemeColorRole {
        switch tool.status {
        case .succeeded: .green
        case .failed: .red
        case .cancelled, .unknown: .muted
        case .running: .accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Tap(action: { expanded.toggle() }) {
                HStack(spacing: OmodachiTheme.space("lg")) {
                    Glyph(symbol: symbol, points: OmodachiTheme.fontSize("caption"))
                        .foregroundStyle(OmodachiTheme.current.color(role))
                    Text(tool.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: OmodachiTheme.space("sm"))
                    Text(tool.status.label).foregroundStyle(OmodachiTheme.secondaryText)
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
        .accessibilityLabel(Strings.pair(tool.name, tool.status.rawValue))
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
            HStack(spacing: OmodachiTheme.space("sm")) {
                Text(descriptor.name).font(OmodachiTheme.font("subtitle", weight: .semibold))
                if descriptor.isDefault { Text(Strings.agentDefault).font(OmodachiTheme.font("caption")).foregroundStyle(OmodachiTheme.secondaryText) }
                Spacer()
                if model.effectiveModel == descriptor.id { Glyph(symbol: "checkmark").foregroundStyle(OmodachiTheme.accent) }
            }
            if let description = descriptor.description, !description.isEmpty {
                Text(description).font(OmodachiTheme.bodyFont("body-small")).foregroundStyle(OmodachiTheme.secondaryText)
            }
            // Effort is part of the same choice: picking one picks the model.
            HStack(spacing: OmodachiTheme.space("md")) {
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
