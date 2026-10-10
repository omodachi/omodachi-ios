import SwiftUI

/// A-13, as HERDR-3 left it. 44 high, pinned to the top of the software
/// keyboard when there is one and to the bottom when there is not.
///
/// Left to right: **Type** (a named toggle, never implied
/// by tapping the screen); the **keys row** — Esc, Tab, ⇧Tab, Enter, Space,
/// the arrows (they repeat while held), ^C, ^D and 1–5, each one `/keys` call
/// that takes nothing and resizes nothing; what the pane is doing; and one
/// labelled **More** menu holding the routes (split, zoom, tabs, close —
/// HERDR-5 took "Show on the computer", "Open in Agent" and "Take keyboard"
/// out). The routes used to be a row of bare icons, two of which looked
/// exactly like arrow keys.
struct HerdrControlBar: View {
    @ObservedObject var store: HerdrStore
    /// A closing control asks first; the surface owns that dialog.
    var onConfirm: (HerdrControlAction, HerdrControlRequest) -> Void = { _, _ in }
    @Environment(\.horizontalSizeClass) private var horizontal
    /// A phone on its side has room across and none down: there the keys
    /// ride in the bar itself, so the mirror keeps its rows (lab, HERDR-4).
    @Environment(\.verticalSizeClass) private var vertical

    var body: some View {
        VStack(spacing: 0) {
            // HERDR-4: the keys get their own rows above the bar everywhere,
            // with the key presets after them. One row when it fits; on a
            // phone, two — the fixed keys whole on the first (^C and ^D used
            // to be cut off, HERDR-3-08), the rest and the presets on the
            // second, which scrolls with a visible indicator when it must.
            // HERDR-8: on a phone held upright the keys fold behind one
            // Keys toggle in the bar, so the mirror gets the room.
            if vertical != .compact, !foldsKeys || store.keysOpen {
            ViewThatFits(in: .horizontal) {
                keyRow(HerdrKeyCap.row, presets: store.presetKeys, compact: false)
                VStack(spacing: 0) {
                    keyRow(Array(HerdrKeyCap.row.prefix(HerdrKeyCap.firstRow)), presets: [], compact: true)
                    // VERIFY-1: the second row shows every key. It shares the
                    // width out (^L and ^Z sat past the edge behind a
                    // sideways swipe); only an operator's long preset list
                    // still scrolls, with its indicator showing.
                    let second = Array(HerdrKeyCap.row.dropFirst(HerdrKeyCap.firstRow))
                    ViewThatFits(in: .horizontal) {
                        keyRow(second, presets: store.presetKeys, compact: true)
                        fillingKeyRow(second, presets: store.presetKeys)
                        scrollingKeyRow(second, presets: store.presetKeys)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OmodachiTheme.barBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(OmodachiTheme.border)
                    .frame(height: NativeBarMetrics.edgeRule).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Strings.herdrKeys)
            .accessibilityIdentifier("herdr-keys")
            }
            bar
        }
        // A tick under the finger for every key that went out.
        .sensoryFeedback(.selection, trigger: store.keyTicks)
    }

    private func keyRow(_ caps: [HerdrKeyCap], presets: [HerdrOperatorRowsDTO.Key], compact: Bool) -> some View {
        HStack(spacing: OmodachiTheme.space("xs")) {
            keyCaps(caps, compact: compact)
            presetCaps(presets, compact: compact)
        }
        .padding(.horizontal, OmodachiTheme.space("xs"))
        .frame(height: NativeBarMetrics.hit)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func fillingKeyRow(_ caps: [HerdrKeyCap], presets: [HerdrOperatorRowsDTO.Key]) -> some View {
        HStack(spacing: OmodachiTheme.space("xs")) {
            keyCaps(caps, compact: true, fills: true)
            presetCaps(presets, compact: true, fills: true)
        }
        .padding(.horizontal, OmodachiTheme.space("xs"))
        .frame(height: NativeBarMetrics.hit)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-keys-second")
    }

    private func scrollingKeyRow(_ caps: [HerdrKeyCap], presets: [HerdrOperatorRowsDTO.Key]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: OmodachiTheme.space("xs")) {
                keyCaps(caps, compact: true)
                presetCaps(presets, compact: true)
            }
            .padding(.horizontal, OmodachiTheme.space("xs"))
            .frame(height: NativeBarMetrics.hit)
        }
        // The affordance: the indicator stays visible and flashes on arrival,
        // so a row that runs past the edge says so.
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(onAppear: true)
        .accessibilityIdentifier("herdr-keys-second")
    }

    @ViewBuilder private func keyCaps(_ caps: [HerdrKeyCap], compact: Bool, fills: Bool = false) -> some View {
        ForEach(caps) { cap in
            KeyCap(face: cap.face, repeats: cap.repeats, compact: compact, fills: fills) { store.send(key: cap) }
                .accessibilityLabel(Strings.herdrKeySend(Self.spoken(cap)))
                .accessibilityIdentifier("herdr-key-\(cap.id)")
        }
    }

    /// The key presets (core's rows, or the operator's `keys.toml`), after a
    /// thin rule. A `danger` preset asks for a second tap.
    @ViewBuilder private func presetCaps(_ presets: [HerdrOperatorRowsDTO.Key], compact: Bool, fills: Bool = false) -> some View {
        if !presets.isEmpty {
            Rectangle().fill(OmodachiTheme.border).frame(width: NativeBarMetrics.edgeRule, height: 20)
                .accessibilityHidden(true)
            ForEach(presets) { preset in
                let armed = store.isArmed("key:" + preset.label) // non-copy
                KeyCap(face: HerdrPresetFace.face(preset) + (armed ? "?" : ""), compact: compact, fills: fills) {
                    store.send(preset: preset)
                }
                .accessibilityLabel(Strings.herdrKeySend(preset.label))
                .accessibilityIdentifier("herdr-preset-\(preset.label)")
            }
        }
    }

    private var bar: some View {
        // AGENT-UI-2 (Leo): no Panel toggle here any more. It was our mark,
        // which reads as an agent's face, and it did what the bar's own logo
        // does - the logo is on screen in every layout this bar is in.
        HStack(spacing: 0) {
            typeToggle
                .padding(.leading, OmodachiTheme.space("xs"))
                .padding(.trailing, OmodachiTheme.space("xs"))
            quickToggle
                .padding(.trailing, OmodachiTheme.space("xs"))
            if foldsKeys {
                keysToggle
                    .padding(.trailing, OmodachiTheme.space("xs"))
            }

            // HERDR-4: the harness segment — the agent's own /model /effort
            // /compact /resume — sits on the bar where there is room; on a
            // phone it is at the top of the Quick dock.
            if vertical == .compact {
                scrollingKeyRow(HerdrKeyCap.row, presets: store.presetKeys)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Strings.herdrKeys)
                    .accessibilityIdentifier("herdr-keys")
            } else {
                if horizontal != .compact, !store.operatorRows.harness.isEmpty {
                    harnessSegment
                }
                if !togglesFill { Spacer(minLength: 0) }
            }

            if horizontal != .compact {
                Text(modeLabel)
                    .font(OmodachiTheme.font("caption"))
                    .foregroundStyle(store.typing ? OmodachiTheme.accent : OmodachiTheme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, OmodachiTheme.space("md"))
                    .accessibilityIdentifier("herdr-mode")
            }

            moreMenu
        }
        .frame(height: NativeBarMetrics.hit)
        .frame(maxWidth: .infinity)
        .background(OmodachiTheme.barBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(OmodachiTheme.border)
                .frame(height: NativeBarMetrics.edgeRule).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-control-bar")
    }

    private var typeToggle: some View {
        Tap(selected: store.typing, bordered: true, fill: OmodachiTheme.normalFill, action: store.toggleTyping) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                Glyph(Icon.keyboard)
                Text(Strings.herdrType).font(OmodachiTheme.font("body-small"))
            }
            .padding(.horizontal, OmodachiTheme.space("md"))
            .frame(maxWidth: togglesFill ? .infinity : nil, minHeight: OmodachiTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .frame(minHeight: NativeBarMetrics.hit)
        .accessibilityHint(Strings.herdrTypeHint)
        .accessibilityAddTraits(store.typing ? [.isSelected] : [])
        .accessibilityIdentifier("herdr-type")
    }

    /// A phone held upright: the keys rows are behind the Keys toggle.
    private var foldsKeys: Bool { horizontal == .compact && vertical != .compact }
    /// AGENT-UI-2: there, Type, Quick and Keys share the bar up to More -
    /// the room the Panel toggle had is theirs.
    private var togglesFill: Bool { foldsKeys }

    private var keysToggle: some View {
        Tap(selected: store.keysOpen, bordered: true, fill: OmodachiTheme.normalFill, action: store.toggleKeys) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                Glyph(symbol: "command")
                Text(Strings.herdrKeys).font(OmodachiTheme.font("body-small"))
            }
            .padding(.horizontal, OmodachiTheme.space("md"))
            .frame(maxWidth: togglesFill ? .infinity : nil, minHeight: OmodachiTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .frame(minHeight: NativeBarMetrics.hit)
        .accessibilityHint(Strings.herdrKeysHint)
        .accessibilityAddTraits(store.keysOpen ? [.isSelected] : [])
        .accessibilityIdentifier("herdr-keys-toggle")
    }

    private var quickToggle: some View {
        Tap(selected: store.quickOpen, bordered: true, fill: OmodachiTheme.normalFill, action: store.toggleQuick) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                Glyph(symbol: "text.bubble")
                Text(Strings.herdrQuick).font(OmodachiTheme.font("body-small"))
            }
            .padding(.horizontal, OmodachiTheme.space("md"))
            .frame(maxWidth: togglesFill ? .infinity : nil, minHeight: OmodachiTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .frame(minHeight: NativeBarMetrics.hit)
        .accessibilityHint(Strings.herdrQuickHint)
        .accessibilityAddTraits(store.quickOpen ? [.isSelected] : [])
        .accessibilityIdentifier("herdr-quick")
    }

    private var harnessSegment: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OmodachiTheme.space("xs")) {
                ForEach(store.operatorRows.harness) { row in
                    let armed = store.isArmed("harness:" + row.command) // non-copy
                    TextTap(armed ? Strings.herdrTapAgain : HerdrHarnessWords.title(row), role: armed ? .yellow : .accent,
                            selected: armed, bordered: true,
                            minimumHeight: OmodachiTheme.controlHeight) { store.send(harness: row) }
                        .frame(minHeight: NativeBarMetrics.hit)
                        .accessibilityHint(Strings.herdrHarnessHint(row.command))
                        .accessibilityIdentifier("herdr-bar-harness-\(row.harnessID ?? row.command)")
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.herdrQuickHarness)
    }

    private var moreMenu: some View {
        Menu {
            // HERDR-10: the pane's screen as text, in one tap.
            LabelledMenuItem(title: Strings.herdrCopyOutput, detail: nil, symbol: "doc.on.doc", destructive: false) {
                store.copyOutput()
            }
            .accessibilityIdentifier("herdr-menu-copyOutput")
            ForEach(HerdrControlAction.menu) { action in
                item(action)
            }
        } label: {
            HStack(spacing: OmodachiTheme.space("sm")) {
                Glyph(symbol: "ellipsis.circle")
                Text(Strings.herdrMore).font(OmodachiTheme.font("body-small"))
            }
            .padding(.horizontal, OmodachiTheme.space("md"))
            .frame(minWidth: NativeBarMetrics.hit, minHeight: NativeBarMetrics.hit)
            .contentShape(Rectangle())
        }
        // Top to bottom as listed, wherever the menu opens.
        .menuOrder(.fixed)
        .accessibilityLabel(Strings.herdrMore)
        .accessibilityIdentifier("herdr-more")
    }

    @ViewBuilder private func item(_ action: HerdrControlAction) -> some View {
        let request = HerdrControlMapper.request(action, layout: store.layout, selected: store.selected)
        let reason: String? = if case .unsupported(let text) = request { text } else { nil }
        LabelledMenuItem(title: action.title, detail: reason, symbol: action.symbol,
                         destructive: action.destructive && reason == nil) {
            // An item that cannot act says why when it is tapped, in the
            // notice row, instead of being a dead grey line.
            if action.confirms, reason == nil { onConfirm(action, request) }
            else { store.perform(request, confirmed: true) }
        }
        .accessibilityIdentifier("herdr-menu-\(action.rawValue)")
    }

    private var modeLabel: String {
        if store.typing { return Strings.herdrModeTyping }
        switch store.connection {
        case .observing: return Strings.herdrModeObserve
        case .connecting: return "…"
        case .retrying(let attempt): return Strings.herdrModeRetry(Format.count(attempt))
        case .unavailable: return Strings.herdrModeOffline
        case .idle: return "—"
        }
    }

    /// What VoiceOver says for a key cap: its name in the reader's language.
    static func spoken(_ cap: HerdrKeyCap) -> String {
        switch cap.name {
        case .escape: Strings.herdrKeyEscape
        case .tab: Strings.herdrKeyTab
        case .shiftTab: Strings.herdrKeyShiftTab
        case .enter: Strings.herdrKeyEnter
        case .space: Strings.herdrKeySpace
        case .up: Strings.herdrKeyUp
        case .down: Strings.herdrKeyDown
        case .left: Strings.herdrKeyLeft
        case .right: Strings.herdrKeyRight
        case .backspace: Strings.herdrKeyBackspace
        case .ctrlC: Strings.herdrKeyCtrlC
        case .ctrlD: Strings.herdrKeyCtrlD
        case .digit: cap.face
        }
    }
}

/// HERDR-3. Everything between the terminal and the bar: Type's strip (with
/// its Stop), what the last send did, and the composer.
///
/// While Type is on the composer steps aside: keys already go straight to the
/// pane, and two inputs at once would be one too many.
struct HerdrInputArea: View {
    @ObservedObject var store: HerdrStore
    var keyboardUp = false
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    var body: some View {
        VStack(spacing: 0) {
            if store.typing {
                strip(Strings.herdrTypeStrip(paneName), identifier: "herdr-type-strip",
                      stopIdentifier: "herdr-type-stop") { store.stopTyping() }
            }
            if store.quickOpen, store.selected != nil {
                HerdrQuickDock(store: store)
            }
            // HERDR-9: the pane's own choices, as buttons, right above the box.
            // A phone on its side with the keyboard up has a row or two of
            // height left: those go to the mirror's newest rows, and the
            // choices come back with the keyboard put away.
            if let choices = store.choices, store.selected != nil, !(keyboardUp && vertical == .compact) {
                HerdrChoicesStrip(store: store, choices: choices)
            }
            sendStateRow
            if store.selected != nil, !store.typing {
                Rectangle().fill(OmodachiTheme.border)
                    .frame(height: NativeBarMetrics.edgeRule).accessibilityHidden(true)
                // ATTACH-1: what goes with the next Send; core types the paths.
                HerdrAttachmentChips(store: store)
                composer
                    .padding(.top, OmodachiTheme.space(horizontal == .compact ? "sm" : "lg"))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(OmodachiTheme.background)
    }

    /// HERDR-4: the pane as a person names it, never Herdr's id.
    private var paneName: String { store.selectedPaneName }

    /// HERDR-9: the keyboard's return key sends; an empty box hands its keys
    /// to the pane. HERDR-8: on a phone it is one line until it is tapped.
    private var composer: some View {
        HerdrComposer(store: store, compactIdle: horizontal == .compact) {
            AttachButton(tray: store.attachments, identifier: "herdr-attach")
        }
    }

    private func strip(_ text: String, identifier: String, stopIdentifier: String,
                       stop: @escaping () -> Void) -> some View {
        HStack(spacing: OmodachiTheme.space("md")) {
            Glyph(Icon.keyboard).foregroundStyle(OmodachiTheme.accent)
            Text(text)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.text)
                .lineLimit(3)
                .accessibilityIdentifier(identifier)
            Spacer(minLength: 0)
            TextTap(Strings.herdrStop, bordered: true, action: stop)
                .accessibilityIdentifier(stopIdentifier)
        }
        .padding(.leading, OmodachiTheme.rowPaddingX)
        .padding(.trailing, OmodachiTheme.space("md"))
        .frame(minHeight: NativeBarMetrics.hit)
        .background(OmodachiTheme.selectedFill)
        .overlay(alignment: .top) {
            Rectangle().fill(OmodachiTheme.accent).frame(height: 2).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var sendStateRow: some View {
        switch store.sendState {
        case .idle:
            EmptyView()
        case .sending:
            stateLine(Strings.herdrSending, role: .muted, dismissible: false)
        case .sent:
            stateLine(Strings.herdrSent, role: .green, dismissible: false)
        case .sentLight:
            // HERDR-4: a short reply proved only by its line — no ✓.
            stateLine(Strings.herdrSentLight, role: .foreground, dismissible: true)
        case .notSubmitted(let reason):
            stateLine(Strings.herdrNotSubmitted(ReasonText.message(reason, domain: .herdr)), role: .yellow,
                      dismissible: true)
        case .failed(let message):
            stateLine(message, role: .red, dismissible: true)
        }
    }

    private func stateLine(_ text: String, role: ThemeColorRole, dismissible: Bool) -> some View {
        HStack(spacing: OmodachiTheme.space("md")) {
            Text(text)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.current.color(role))
                .lineLimit(3)
                .accessibilityIdentifier("herdr-send-state")
            Spacer(minLength: 0)
            if dismissible {
                Tap(action: store.dismissSendState) { Glyph(symbol: "xmark") }
                    .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                    .accessibilityLabel(Strings.actionDismiss)
            }
        }
        .padding(.leading, OmodachiTheme.panelPadding)
        .frame(minHeight: 32)
    }
}

/// HERDR-4. A preset's face: what ships reads like the keys row's own caps
/// (`^U`), an operator's row keeps the words it was given.
enum HerdrPresetFace {
    static func face(_ preset: HerdrOperatorRowsDTO.Key) -> String {
        guard !preset.isOperator, preset.keys.count == 1 else { return preset.label }
        let key = preset.keys[0].lowercased()
        guard key.hasPrefix("ctrl+"), key.count == 6 else { return preset.label }
        return "^" + key.suffix(1).uppercased()
    }
}

/// ATTACH-1: the tray's chips, redrawn whenever the tray changes (the store
/// itself does not publish the tray's own changes).
private struct HerdrAttachmentChips: View {
    @ObservedObject var store: HerdrStore
    var body: some View { HerdrTrayChips(tray: store.attachments) }
}

private struct HerdrTrayChips: View {
    @ObservedObject var tray: AttachmentTray
    var body: some View { AttachmentChipStrip(tray: tray, identifier: "herdr-chips") }
}
