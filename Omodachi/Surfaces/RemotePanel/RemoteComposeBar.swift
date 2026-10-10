import RemoteInputCore
import SwiftUI
import UIKit

/// REMOTE-INPUT-2. The keyboard's top row in Remote: type in the App, send to
/// the computer.
///
/// ```
/// ┌ Remote picture (size never changes) ┐
/// ├─────────────────────────────────────┤
/// │ [ 你好，帮我看下…               I ] │  the field (one line, grows to 4)
/// │ esc ⇥ ← ↓ ↑ → ^C               ⌨ Keys │  keys row and Keys mode
/// ├─────────────────────────────────────┤
/// │  iOS candidates / predictions        │
/// │  iOS keyboard                        │
/// └─────────────────────────────────────┘
/// ```
///
/// It is an overlay: it sits on the keyboard's top edge over the picture and
/// moves nothing under it, so the host is never asked to re-plan its output
/// (A-61). It looks like the Herdr composer ("Write to this pane"): the same
/// box and the same one-line state under it.
///
/// REMOTE-INPUT-2b (Leo): there is no Send button and no "Enter after". The
/// keyboard's own return key — labelled Send — and a hardware Return type the
/// words and press Return, the way Enter does on the computer. The one small
/// button inside the field's trailing edge (an I-beam) puts the words in
/// without Return.
struct RemoteComposeBar: View {
    @ObservedObject var controller: RemoteSessionController
    @ObservedObject var composer: RemoteComposer
    @Environment(\.horizontalSizeClass) private var horizontal
    @State private var fieldHeight: CGFloat = NativeBarMetrics.hit

    init(controller: RemoteSessionController) {
        self.controller = controller
        self.composer = controller.composer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stateLine
            if composer.usesField {
                fieldRow
            } else if !composer.hostSupportsCompose {
                note(Strings.remoteComposeHostTooOld)
            }
            controlsRow
        }
        .background(OmodachiTheme.barBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(OmodachiTheme.border)
                .frame(height: NativeBarMetrics.edgeRule).accessibilityHidden(true)
        }
        // A tick under the finger for every send that landed.
        .sensoryFeedback(.success, trigger: composer.phase) { _, next in next == .sent }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.remoteComposeBar)
        .accessibilityIdentifier("remote-compose-bar")
    }

    // MARK: The field, and "insert only" inside it

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .topLeading) {
                RemoteComposeField(controller: controller, composer: composer, height: $fieldHeight)
                    .frame(height: fieldHeight)
                if composer.draft.isEmpty, !composer.composing {
                    Text(Strings.remoteComposePlaceholder)
                        .font(OmodachiTheme.bodyFont("title"))
                        .foregroundStyle(OmodachiTheme.muted)
                        .lineLimit(1)
                        .padding(.horizontal, RemoteComposeField.inset.left + 5)
                        .padding(.top, RemoteComposeField.inset.top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            insertButton
        }
        // AGENT-UI-1: the same filled box as the Agent's and Herdr's. The bar
        // is only up while the keyboard is, so the box is always the one
        // being typed into.
        .textEntrySurface(focused: true)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder,
                                          lineWidth: OmodachiTheme.controlBorderWidth)
            .allowsHitTesting(false))
        .padding(.horizontal, OmodachiTheme.space("lg"))
        .padding(.top, OmodachiTheme.space("lg"))
    }

    /// Put the words in without pressing Return. Only with words to put.
    private var insertButton: some View {
        Tap(enabled: composer.canSend, action: composer.insert) {
            Glyph(Icon.insertText)
                .foregroundStyle(composer.canSend ? OmodachiTheme.text : OmodachiTheme.muted)
                .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Strings.remoteComposeInsert)
        .accessibilityHint(Strings.remoteComposeInsertHint)
        .accessibilityIdentifier("remote-compose-insert")
    }

    // MARK: Keys and switches

    private var controlsRow: some View {
        HStack(spacing: OmodachiTheme.space("xs")) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OmodachiTheme.space("xs")) {
                    ForEach(RemoteKeyCap.row) { cap in
                        KeyCap(face: cap.face, repeats: cap.repeats, compact: horizontal == .compact) {
                            controller.tapKey(cap)
                        }
                        .accessibilityLabel(Strings.remoteKeySend(cap.spoken))
                        .accessibilityIdentifier("remote-key-\(cap.id)")
                    }
                }
                .padding(.horizontal, OmodachiTheme.space("xs"))
            }
            .frame(height: NativeBarMetrics.hit)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Strings.herdrKeys)
            .accessibilityIdentifier("remote-compose-keys")
            if composer.hostSupportsCompose {
                toggle(Strings.remoteComposeKeysMode, glyph: Icon.keyboard.symbol, on: composer.keysMode,
                       hint: Strings.remoteComposeKeysModeHint, identifier: "remote-compose-keys-mode") {
                    controller.setKeysMode(!composer.keysMode)
                }
            }
        }
        .padding(.trailing, OmodachiTheme.space("xs"))
        .frame(minHeight: NativeBarMetrics.hit)
    }

    /// A named switch like Herdr's Type: a box, a glyph, a word, and the
    /// selected fill when it is on.
    private func toggle(_ title: String, glyph: String, on: Bool, hint: String, identifier: String,
                        action: @escaping () -> Void) -> some View {
        Tap(selected: on, bordered: true, fill: OmodachiTheme.normalFill, action: action) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                Glyph(symbol: glyph)
                Text(title).font(OmodachiTheme.font("body-small")).lineLimit(1)
            }
            .padding(.horizontal, OmodachiTheme.space("md"))
            .frame(minHeight: OmodachiTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .frame(minHeight: NativeBarMetrics.hit)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(on ? Strings.remoteComposeOn : Strings.remoteComposeOff)
        .accessibilityHint(hint)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: What happened

    @ViewBuilder private var stateLine: some View {
        if let overflow = composer.overflow, composer.usesField {
            line(Self.overflowText(overflow), role: .red, identifier: "remote-compose-overflow")
        } else {
            switch composer.phase {
            case .editing:
                EmptyView()
            case .sending:
                line(Strings.remoteComposeSending, role: .muted, identifier: "remote-compose-state")
            case .confirmLines(let lines, let pressReturn):
                HStack(spacing: OmodachiTheme.space("md")) {
                    Text(pressReturn ? Strings.remoteComposeConfirmLinesReturn(Format.count(lines))
                                     : Strings.remoteComposeConfirmLines(Format.count(lines)))
                        .font(OmodachiTheme.font("body-small"))
                        .foregroundStyle(OmodachiTheme.current.color(.yellow))
                        .lineLimit(3)
                        .accessibilityIdentifier("remote-compose-state")
                    Spacer(minLength: 0)
                    TextTap(Strings.remoteComposeSendAnyway, role: .accent, bordered: true) { composer.confirmSend() }
                        .accessibilityIdentifier("remote-compose-confirm")
                    TextTap(Strings.actionCancel, bordered: true) { composer.cancelPending() }
                        .accessibilityIdentifier("remote-compose-cancel")
                }
                .padding(.horizontal, OmodachiTheme.space("lg"))
                .padding(.top, OmodachiTheme.space("sm"))
            case .waiting:
                HStack(spacing: OmodachiTheme.space("md")) {
                    Text(Strings.remoteComposeWaiting)
                        .font(OmodachiTheme.font("body-small"))
                        .foregroundStyle(OmodachiTheme.muted)
                        .lineLimit(2)
                        .accessibilityIdentifier("remote-compose-state")
                    Spacer(minLength: 0)
                    TextTap(Strings.actionCancel, bordered: true) { composer.cancelPending() }
                        .accessibilityIdentifier("remote-compose-cancel")
                }
                .padding(.horizontal, OmodachiTheme.space("lg"))
                .padding(.top, OmodachiTheme.space("sm"))
            case .sent:
                line(Strings.remoteComposeSent, role: .green, identifier: "remote-compose-state")
            case .failed(let words):
                line(words, role: .red, identifier: "remote-compose-state")
            }
        }
    }

    private func line(_ text: String, role: ThemeColorRole, identifier: String) -> some View {
        Text(text)
            .font(OmodachiTheme.font("body-small"))
            .foregroundStyle(OmodachiTheme.current.color(role))
            .lineLimit(3)
            .padding(.horizontal, OmodachiTheme.space("lg"))
            .padding(.top, OmodachiTheme.space("sm"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    private func note(_ text: String) -> some View {
        line(text, role: .muted, identifier: "remote-compose-note")
    }

    static func overflowText(_ overflow: RemoteComposeLimits.Overflow) -> String {
        switch overflow {
        case .characters(let count, let limit):
            Strings.remoteComposeTooLong(Format.count(count), Format.count(limit))
        case .bytes(let count, let limit):
            Strings.remoteComposeTooLongBytes(Format.count(count), Format.count(limit))
        }
    }
}

/// REMOTE-INPUT-2. The field itself: a `UITextView`, because what the bar
/// needs from it is UIKit's — this device's whole input method (pinyin
/// candidates, predictions, autocorrect, spell check, dictation, paste), and
/// the keys an empty field hands to the host (`deleteBackward`, Return, a
/// hardware keyboard's presses), which a SwiftUI field does not expose.
struct RemoteComposeField: UIViewRepresentable {
    @ObservedObject var controller: RemoteSessionController
    @ObservedObject var composer: RemoteComposer
    @Binding var height: CGFloat

    static let inset = UIEdgeInsets(top: 11, left: 8, bottom: 11, right: 8)
    static let maxLines: CGFloat = 4

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> RemoteComposeTextView {
        let view = RemoteComposeTextView(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = Self.inset
        view.font = UIFont.systemFont(ofSize: OmodachiTheme.fontSize("title"))
        view.textColor = UIColor(OmodachiTheme.text)
        view.tintColor = UIColor(OmodachiTheme.accent)
        view.isScrollEnabled = true
        view.keyboardDismissMode = .none
        view.accessibilityIdentifier = "remote-compose-field"
        view.accessibilityLabel = Strings.remoteComposeFieldLabel
        view.accessibilityHint = Strings.remoteComposeFieldHint
        context.coordinator.wire(view)
        view.text = composer.draft
        context.coordinator.seen = (composer.focusRequest, composer.resignRequest)
        if composer.focusRequest > 0 { context.coordinator.focus(view) }
        return view
    }

    func updateUIView(_ view: RemoteComposeTextView, context: Context) {
        context.coordinator.parent = self
        // Never over marked text: a pinyin composition in progress is the
        // input method's, not the draft's.
        if view.markedTextRange == nil, view.text != composer.draft { view.text = composer.draft }
        let coordinator = context.coordinator
        if coordinator.seen.focus != composer.focusRequest {
            coordinator.seen.focus = composer.focusRequest
            coordinator.focus(view)
        }
        if coordinator.seen.resign != composer.resignRequest {
            coordinator.seen.resign = composer.resignRequest
            coordinator.resigning = true
            view.resignFirstResponder()
            coordinator.resigning = false
        }
        coordinator.measure(view)
    }

    static func dismantleUIView(_ view: RemoteComposeTextView, coordinator: Coordinator) {
        coordinator.resigning = true
        view.resignFirstResponder()
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RemoteComposeField
        var seen: (focus: Int, resign: Int) = (0, 0)
        /// We are letting go on purpose (Keys mode, the bar closing).
        var resigning = false

        init(_ parent: RemoteComposeField) { self.parent = parent }

        func wire(_ view: RemoteComposeTextView) {
            view.passKey = { [weak self] usage, down in self?.parent.controller.passKey(usage: usage, down: down) }
            view.passChord = { [weak self] usage, modifiers in
                self?.parent.controller.passChord(usage: usage, modifiers: modifiers)
            }
        }

        func focus(_ view: RemoteComposeTextView) {
            // The view may not be in its window yet on the pass that made it.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil, !view.isFirstResponder else { return }
                view.becomeFirstResponder()
            }
        }

        func measure(_ view: UITextView) {
            guard let font = view.font, view.bounds.width > 0 else { return }
            let fitted = view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
            let line = font.lineHeight
            let ceiling = ceil(line * RemoteComposeField.maxLines + RemoteComposeField.inset.top + RemoteComposeField.inset.bottom)
            let next = min(max(NativeBarMetrics.hit, ceil(fitted)), ceiling)
            if abs(next - parent.height) > 0.5 {
                DispatchQueue.main.async { [parent] in parent.height = next }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            // While pinyin is being composed the marked letters are not the
            // draft yet; the committed characters are.
            let composing = textView.markedTextRange != nil
            if parent.composer.composing != composing { parent.composer.composing = composing }
            guard !composing else { measure(textView); return }
            if parent.composer.draft != textView.text { parent.composer.draft = textView.text }
            measure(textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !parent.composer.isBusy else { return false }
            // Return, typed (not pasted): an empty field passes it through,
            // a field with words sends them. A pinyin composition's own
            // Return commits letters and never arrives here as "\n".
            if text == "\n", textView.markedTextRange == nil {
                if textView.text.isEmpty {
                    parent.controller.passKey(usage: RemoteComposePassthrough.returnKey, down: true)
                    parent.controller.passKey(usage: RemoteComposePassthrough.returnKey, down: false)
                } else if case .confirmLines = parent.composer.phase {
                    parent.composer.confirmSend()
                } else {
                    parent.composer.send()
                }
                return false
            }
            return true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard !resigning else { return }
            parent.controller.composeFieldResigned()
        }
    }
}

/// REMOTE-INPUT-2. The field's text view: full iOS input, with smart quotes,
/// smart dashes and auto-capitals off (what is typed goes to a terminal as
/// often as to a document), and the keys an empty field hands to the host.
final class RemoteComposeTextView: UITextView {
    static let lineBreak = String(UnicodeScalar(10))
    var passKey: ((UInt16, Bool) -> Void)?
    var passChord: ((UInt16, RemoteModifiers) -> Void)?
    /// Hardware keys that went down on the host and must come up there.
    private var heldOnHost: Set<UInt16> = []

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        autocorrectionType = .yes
        spellCheckingType = .yes
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .yes
        keyboardType = .default
        returnKeyType = .send
        // Return on an empty field is a key for the host, so it is never dimmed.
        enablesReturnKeyAutomatically = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // non-copy

    /// Backspace on an empty field is Backspace on the computer.
    override func deleteBackward() {
        if text.isEmpty, markedTextRange == nil {
            passKey?(RemoteComposePassthrough.backspace, true)
            passKey?(RemoteComposePassthrough.backspace, false)
            return
        }
        super.deleteBackward()
    }

    static func modifiers(_ flags: UIKeyModifierFlags) -> RemoteModifiers {
        var value: RemoteModifiers = []
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.alternate) { value.insert(.alt) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.superKey) }
        return value
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var local = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { local.insert(press); continue }
            let usage = UInt16(truncatingIfNeeded: key.keyCode.rawValue)
            let modifiers = Self.modifiers(key.modifierFlags)
            // ⇧⏎ in a field with words is a line break, not a send.
            if usage == RemoteComposePassthrough.returnKey, modifiers == .shift, !text.isEmpty, markedTextRange == nil {
                insertText(Self.lineBreak)
                continue
            }
            switch RemoteComposePassthrough.decide(usage: usage, modifiers: modifiers,
                                                   fieldEmpty: text.isEmpty, composing: markedTextRange != nil) {
            case .local:
                local.insert(press)
            case .hold(let usage):
                heldOnHost.insert(usage)
                passKey?(usage, true)
            case .chord(let usage, let modifiers):
                passChord?(usage, modifiers)
            }
        }
        if !local.isEmpty { super.pressesBegan(local, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(release(presses), with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(release(presses), with: event)
    }

    /// The presses that were the host's come up there; the rest are UIKit's.
    private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        var local = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { local.insert(press); continue }
            let usage = UInt16(truncatingIfNeeded: key.keyCode.rawValue)
            if heldOnHost.remove(usage) != nil { passKey?(usage, false) } else { local.insert(press) }
        }
        return local
    }
}
