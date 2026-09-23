import SwiftUI

/// Study 03 §15. Two cards ask what the user wants to do; which backend does it
/// is one collapsed row underneath (N-22, A-38).
///
/// The old screen put "画面后端 Sunshine / VNC" and "桌面方式 扩展屏 / 接管桌面"
/// side by side as two equally large segmented controls, which asked the user
/// to understand the host's encoding chain before pressing connect. It also
/// spliced core's `sunshine_desktop_unavailable` into a Chinese sentence; every
/// reason now goes through `RemoteReasonCopy` (N-23).
struct RemoteEntryCards: View {
    @ObservedObject var controller: RemoteSessionController
    let hostName: String
    /// A-56 rev 4b: 349 and 422 cannot hold two cards side by side, so they
    /// stack. Nothing else about them changes — not the row heights, not the
    /// control sizes, not the hit areas. Only the direction.
    var narrow = false
    /// N-32: the router takes `returnTo` at this press, which is why starting
    /// is the caller's closure rather than `controller.start()` in here.
    let onStart: () -> Void

    @State private var advancedOpen = false
    @State private var confirmingTakeover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.phase.isBusy {
                progress
            } else if let owner = controller.sessionOwner {
                occupied(owner)
            } else if controller.pairingPIN != nil || !controller.pairingStatus.isEmpty,
                      controller.phase.isFailed || controller.pairingPIN != nil {
                sunshineRepair
            } else if confirmingTakeover {
                takeoverConfirm
            } else {
                entry
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Without `children: .contain` this identifier is pushed down onto
        // every descendant and the cards lose their own (OVERLAY-1).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-entry")
    }

    // MARK: - ① two cards

    @ViewBuilder private var entry: some View {
        // UX-1 item 2b: side by side once both cards fit at their own width,
        // stacked below it. Neither shape leaves a tall empty region under the
        // cards, because the page is sized to its content by the caller.
        Group {
            if narrow {
                VStack(spacing: 10) { extendCard; takeoverCard }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { extendCard; takeoverCard }
                        .frame(minWidth: 2 * Self.cardMinimumWidth + 12)
                    VStack(spacing: 10) { extendCard; takeoverCard }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        advanced
        // Whatever the controller has to say, not only what it says after it
        // has failed: `start()` can refuse before the phase moves at all, and
        // a refusal nobody is shown is indistinguishable from a dead button.
        if !controller.message.isEmpty {
            note(controller.message).foregroundStyle(OmodachiTheme.warning)
                .accessibilityIdentifier("remote-message")
        }
    }

    /// Study 03 §15's card is 260 wide before its own padding; below twice that
    /// plus the gap the two of them stack.
    static let cardMinimumWidth: CGFloat = 260

    private var extendCard: some View {
        BigModeCard(kind: .extend, isDefault: controller.mode == .extend,
                    notice: notice(for: .extend),
                    title: buttonTitle(for: .extend)) {
            controller.rememberMode(.extend)
            onStart()
        }
    }

    private var takeoverCard: some View {
        BigModeCard(kind: .takeover, isDefault: controller.mode == .takeover,
                    notice: notice(for: .takeover),
                    title: buttonTitle(for: .takeover)) {
            controller.rememberMode(.takeover)
            confirmingTakeover = true
        }
    }

    /// The one place a `capabilities.reason` reaches the screen, and it goes
    /// through the table on the way (N-23).
    private func notice(for mode: RemoteMode) -> BigModeCard.Notice? {
        guard let capabilities = controller.capabilities else { return nil }
        let backend = controller.backendChoice.resolve(capabilities)
        guard backend == .sunshine else { return nil }
        guard let reason = capabilities.reason(.sunshine) else { return nil }
        let entry = RemoteReasonCopy.entry(reason)
        if capabilities.available(.sunshine) {
            return entry.isAdvisory ? .init(text: entry.sentence, isError: false) : nil
        }
        return .init(text: entry.sentence, isError: true)
    }

    /// A-38's consequence: when Sunshine cannot run, the button says what it is
    /// going to do instead, rather than asking the user to learn what VNC is.
    private func buttonTitle(for mode: RemoteMode) -> String {
        let action = mode == .extend ? Strings.remoteStartExtend : Strings.remoteStartTakeoverShort
        guard let capabilities = controller.capabilities,
              controller.backendChoice.resolve(capabilities) == .vnc,
              !capabilities.available(.sunshine) else { return action }
        return Strings.remoteUseVNCWith(mode == .extend ? Strings.remoteStartExtend : Strings.remoteStartTakeoverShort)
    }

    // MARK: - ② advanced

    @ViewBuilder private var advanced: some View {
        Tap(action: { advancedOpen.toggle() }) {
            HStack(spacing: 6) {
                Glyph(advancedOpen ? Icon.chevronDown : Icon.chevronRight, step: "icon-small")
                    .foregroundStyle(OmodachiTheme.secondaryText)
                Text(Strings.remoteAdvanced)
                    .font(OmodachiTheme.font("subtitle"))
                    .foregroundStyle(OmodachiTheme.text)
                Spacer()
                Text(Strings.remoteAdvancedBackend(controller.backendChoice.resolve(controller.capabilities).title))
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: ConnectionParts.actionHeight)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Strings.remoteAdvanced)
        .accessibilityIdentifier("remote-advanced")
        if advancedOpen {
            SegmentedRow(options: RemoteBackendChoice.allCases.map { ($0.title, $0) },
                         selection: Binding(get: { controller.backendChoice },
                                            set: { controller.backendChoice = $0 }))
                .padding(.horizontal, 12)
                .accessibilityIdentifier("remote-backend")
        }
    }

    // MARK: - ⑥ the three-step connection row

    @ViewBuilder private var progress: some View {
        StepRow(steps: [(Strings.remoteStepPrepare, stepState(0)), (Strings.remoteStepWaitFrame, stepState(1)),
                        (Strings.remoteStepConnected, stepState(2))])
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .accessibilityIdentifier("remote-status")
        note(controller.message.isEmpty ? controller.statusText : controller.message)
        if !controller.decoded.isEmpty { note(controller.decoded) }
        FlowButton(title: Strings.actionCancel, kind: .ghost) { controller.stop() }
            .padding(.horizontal, 12)
            .accessibilityIdentifier("remote-disconnect")
    }

    private func stepState(_ index: Int) -> StepRow.State {
        let current: Int
        switch controller.phase {
        case .creating: current = 0
        case .connecting, .resizing: current = 1
        case .streaming: current = 2
        default: current = 0
        }
        if index < current { return .done }
        return index == current ? .now : .later
    }

    // MARK: - ⑦ the Sunshine certificate repair

    @ViewBuilder private var sunshineRepair: some View {
        StepRow(steps: [(Strings.remoteStepPrepare, .done), (Strings.remoteStepWaitFrame, .failed),
                        (Strings.remoteStepConnected, .later)])
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .accessibilityIdentifier("remote-status")
        Text(Strings.remoteSunshineUnapproved)
            .font(OmodachiTheme.font(size: 20))
            .foregroundStyle(OmodachiTheme.text)
            .padding(.horizontal, 12)
            .padding(.top, 14)
        if !controller.pairingStatus.isEmpty {
            note(controller.pairingStatus).accessibilityIdentifier("sunshine-pairing-status")
        }
        if controller.pairingPIN != nil {
            FlowButton(title: Strings.remotePairCancel, kind: .ghost) { controller.cancelSunshinePairing() }
                .padding(.horizontal, 12)
                .accessibilityIdentifier("sunshine-pairing-cancel")
        } else {
            FlowButton(title: Strings.remotePairAgain) { controller.pairSunshine(renewing: true) }
                .padding(.horizontal, 12)
                .accessibilityIdentifier("remote-pair")
            FlowButton(title: Strings.remoteUseVNC, kind: .ghost) {
                controller.backendChoice = .vnc
                controller.cancelSunshinePairing()
                onStart()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    // MARK: - ⑧ somebody else has the host

    @ViewBuilder private func occupied(_ owner: RemoteRequestError.Owner) -> some View {
        StepRow(steps: [(Strings.remoteStepPrepare, .failed), (Strings.remoteStepWaitFrame, .later),
                        (Strings.remoteStepConnected, .later)])
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .accessibilityIdentifier("remote-status")
        Text(Strings.remoteOccupied(hostName))
            .font(OmodachiTheme.font(size: 20))
            .foregroundStyle(OmodachiTheme.text)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .accessibilityIdentifier("remote-occupied")
        note(occupiedDetail(owner))
        if controller.canReclaimSession {
            FlowButton(title: Strings.remoteReclaim) { controller.reclaimSession() }
                .padding(.horizontal, 12)
                .accessibilityIdentifier("remote-reclaim")
        } else {
            note(Strings.remoteEndItThere(owner.deviceName))
        }
        FlowButton(title: Strings.actionCancel, kind: .ghost) { controller.stop() }
            .padding(.horizontal, 12)
    }

    private func occupiedDetail(_ owner: RemoteRequestError.Owner) -> String {
        // I18N-1: three already-localized parts laid out with a separator,
        // not a sentence built by hand. The time is the reader's own.
        var parts = [Strings.remoteOwnedBy(owner.deviceName)]
        if let startedAt = owner.startedAt { parts.append(Format.time(startedAt)) }
        if let mode = owner.mode { parts.append(mode.title) }
        return parts.joined(separator: " · ")
    }

    // MARK: - ⑨ the one confirmation in the whole flow

    @ViewBuilder private var takeoverConfirm: some View {
        ModeArt(kind: .takeover)
            .frame(height: 120)
            .padding(.horizontal, 12)
            .padding(.top, 10)
        Text(Strings.remoteTakeoverTitle(hostName))
            .font(OmodachiTheme.font(size: 20))
            .foregroundStyle(OmodachiTheme.text)
            .padding(.horizontal, 12)
            .padding(.top, 14)
        note(Strings.remoteTakeoverEffect)
        FlowRule()
        SquareToggleRow(title: Strings.remoteLockLocalInput,
                        detail: Strings.remoteLockLocalInputDetail,
                        isOn: $controller.lockLocalInput)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("remote-lock-local-input")
        HStack(spacing: 8) {
            FlowButton(title: Strings.remoteStartTakeover) {
                confirmingTakeover = false
                onStart()
            }
            .accessibilityIdentifier("remote-connect")
            FlowButton(title: Strings.actionCancel, kind: .ghost) { confirmingTakeover = false }
        }
        .padding(.horizontal, 12)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont(size: 11))
            .foregroundStyle(OmodachiTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

// MARK: - Parts

/// One of the two intent cards: a picture of what will happen, one sentence,
/// and the button that does it.
struct BigModeCard: View {
    struct Notice: Equatable { let text: String; let isError: Bool }

    let kind: RemoteMode
    let isDefault: Bool
    var notice: Notice?
    let title: String
    let action: () -> Void

    private var why: String { kind == .extend ? Strings.remoteExtendWhy : Strings.remoteTakeoverWhy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(kind.title)
                    .font(OmodachiTheme.font("title"))
                    .foregroundStyle(OmodachiTheme.text)
                if isDefault { StateChip(text: Strings.remoteDefault, kind: .paired) }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            Text(why)
                .font(OmodachiTheme.bodyFont(size: 12))
                .foregroundStyle(OmodachiTheme.text.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            // UX-1 item 2b: `ModeArt` lays its two rectangles out from the
            // card's *height*, so on a narrow column they were wider than the
            // card and a bare `GeometryReader` does not clip — the diagram ran
            // out past the 1px border ("背景超出线框"). It is clipped to its own
            // box now, and the box is shorter.
            ModeArt(kind: kind)
                .frame(height: 72)
                .clipped()
                .padding(.horizontal, 12)
                .padding(.top, 10)
            if let notice {
                HStack(spacing: 6) {
                    HostGlyphView(glyph: "\u{f071}", fallbackSymbol: "exclamationmark.triangle", size: 12)
                    Text(notice.text)
                        .font(OmodachiTheme.font(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(notice.isError ? OmodachiTheme.danger : OmodachiTheme.warning)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .accessibilityIdentifier("remote-card-reason-\(kind.rawValue)")
            }
            FlowButton(title: title, kind: isDefault ? .primary : .secondary, action: action)
                .padding(12)
                .accessibilityIdentifier("remote-start-\(kind.rawValue)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmodachiTheme.background)
        // `stroke` centres the line on the edge, so half of a 2pt border was
        // drawn *outside* the card and over whatever sat beside it.
        // `strokeBorder` insets it, which is what every other bordered control
        // in the app uses (D-01).
        .overlay(Rectangle().strokeBorder(isDefault ? OmodachiTheme.accent : OmodachiTheme.border.opacity(0.5),
                                          lineWidth: isDefault ? OmodachiTheme.popupBorderWidth : OmodachiTheme.controlBorderWidth))
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-card-\(kind.rawValue)")
    }
}

/// The diagram: extend leaves the computer's screen on and adds one beside it;
/// takeover crosses the computer's screen out and moves the desktop over.
struct ModeArt: View {
    let kind: RemoteMode

    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            let deviceW = h * 0.95
            let screenW = h * 1.35
            HStack(spacing: h * 0.18) {
                ZStack {
                    Rectangle().stroke(OmodachiTheme.text.opacity(kind == .extend ? 0.6 : 0.25),
                                       lineWidth: OmodachiTheme.controlBorderWidth)
                    if kind == .takeover {
                        Path { path in
                            path.move(to: .zero)
                            path.addLine(to: CGPoint(x: screenW, y: h * 0.7))
                            path.move(to: CGPoint(x: screenW, y: 0))
                            path.addLine(to: CGPoint(x: 0, y: h * 0.7))
                        }
                        .stroke(OmodachiTheme.danger.opacity(0.7), lineWidth: OmodachiTheme.controlBorderWidth)
                    } else {
                        Rectangle().fill(OmodachiTheme.text.opacity(0.12)).padding(6)
                    }
                }
                .frame(width: screenW, height: h * 0.7)
                ZStack {
                    Rectangle().stroke(OmodachiTheme.accent, lineWidth: OmodachiTheme.popupBorderWidth)
                    Rectangle().fill(OmodachiTheme.accent.opacity(0.18)).padding(5)
                }
                .frame(width: deviceW, height: h * 0.9)
            }
            .frame(width: proxy.size.width, height: h, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}

/// The 26-high row the whole connection is expressed in (Study 03 §15 ⑥).
struct StepRow: View {
    enum State { case done, now, later, failed }
    let steps: [(String, State)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Text(verbatim: "›").font(OmodachiTheme.font(size: 11)).foregroundStyle(OmodachiTheme.dimText)
                }
                Text(step.0)
                    .font(OmodachiTheme.font(size: 11))
                    .foregroundStyle(color(step.1))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(step.1 == .now ? OmodachiTheme.selectedFill : .clear)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 26)
    }

    private func color(_ state: State) -> Color {
        switch state {
        case .done: OmodachiTheme.success
        case .now: OmodachiTheme.accent
        case .later: OmodachiTheme.tertiaryText
        case .failed: OmodachiTheme.danger
        }
    }
}
