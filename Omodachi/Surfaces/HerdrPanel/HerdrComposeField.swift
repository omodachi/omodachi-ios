import SwiftUI
import UIKit

/// HERDR-9. Herdr's composer: the box under the mirror, with REMOTE-INPUT-2b's
/// rule (Leo likes it there, and Herdr should feel the same):
///
/// * words in the box: the keyboard's return key (labelled Send) and a
///   hardware Return send them and press Enter; the box clears;
/// * the box empty: ⌫ (held, it repeats), Return, the arrows, Tab and Esc go
///   straight to the pane — so the text already on codex's input line is
///   deleted without Type, and a dialog's Enter is one key away.
///
/// There is no Send button any more. On an iPhone it took a fifth of the
/// box's width to do what the return key already does; chips with no words
/// still send, because their markers are words in the box.
///
/// A `UITextView`, because what this needs is UIKit's: `deleteBackward` on an
/// empty field (a SwiftUI field reports no change for it) and a hardware
/// keyboard's presses — the same reason Remote's field is one.
struct HerdrComposer<Leading: View>: View {
    @ObservedObject var store: HerdrStore
    /// HERDR-8: on a phone the box is one line until it is tapped.
    var compactIdle = false
    @ViewBuilder var leading: () -> Leading
    @State private var height: CGFloat = NativeBarMetrics.hit
    @State private var focused = false
    /// HERDR-10: the box shows something - the draft, or letters an input
    /// method is still composing (pinyin), which are not the draft yet.
    @State private var showsText = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            leading()
            ZStack(alignment: .topLeading) {
                HerdrComposeField(store: store, height: $height, focused: $focused, showsText: $showsText,
                                  maxLines: idle ? 1 : 6)
                    .frame(height: idle ? NativeBarMetrics.hit : height)
                // HERDR-10: never under pinyin being composed (Leo's
                // "zai gei wo yi ge wen" over "Write to this pane").
                if store.draft.isEmpty, !showsText {
                    Text(Strings.herdrComposerPlaceholder)
                        .font(OmodachiTheme.bodyFont("title"))
                        .foregroundStyle(OmodachiTheme.muted)
                        .lineLimit(1)
                        .padding(.leading, HerdrComposeField.inset.left + 5)
                        .padding(.top, HerdrComposeField.inset.top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        // AGENT-UI-1: a filled box, like the Agent's.
        .textEntrySurface(focused: focused)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth)
            .allowsHitTesting(false))
        .padding(.horizontal, OmodachiTheme.panelPadding)
        .padding(.bottom, OmodachiTheme.space(compactIdle ? "sm" : "xxl"))
        .accessibilityElement(children: .contain)
    }

    private var idle: Bool { compactIdle && !focused }
}

struct HerdrComposeField: UIViewRepresentable {
    @ObservedObject var store: HerdrStore
    @Binding var height: CGFloat
    @Binding var focused: Bool
    var showsText: Binding<Bool> = .constant(false)
    var maxLines: CGFloat = 6

    static let inset = UIEdgeInsets(top: 11, left: 8, bottom: 11, right: 8)

    init(store: HerdrStore, height: Binding<CGFloat>, focused: Binding<Bool>,
         showsText: Binding<Bool> = .constant(false), maxLines: CGFloat = 6) {
        self.store = store
        self._height = height
        self._focused = focused
        self.showsText = showsText
        self.maxLines = maxLines
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> HerdrComposeTextView {
        let view = HerdrComposeTextView(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = Self.inset
        view.font = UIFont.systemFont(ofSize: OmodachiTheme.fontSize("title"))
        view.textColor = UIColor(OmodachiTheme.text)
        view.tintColor = UIColor(OmodachiTheme.accent)
        view.isScrollEnabled = true
        view.keyboardDismissMode = .none
        view.accessibilityIdentifier = "herdr-composer"
        view.accessibilityLabel = Strings.herdrComposerPlaceholder
        view.accessibilityHint = Strings.herdrComposerFieldHint
        view.passKey = { [weak coordinator = context.coordinator] key in coordinator?.parent.store.passKey(key) }
        view.text = store.draft
        context.coordinator.focusRequestsSeen = store.composerFocusRequests
        return view
    }

    func updateUIView(_ view: HerdrComposeTextView, context: Context) {
        context.coordinator.parent = self
        // Never over marked text: a pinyin composition is the input
        // method's, not the draft's.
        if view.markedTextRange == nil, view.text != store.draft { view.text = store.draft }
        view.textColor = UIColor(OmodachiTheme.text)
        context.coordinator.notePresence(view)
        context.coordinator.measure(view)
        // HERDR-10: the strip opened a question card's notes box; the note
        // is written here.
        if store.composerFocusRequests != context.coordinator.focusRequestsSeen {
            context.coordinator.focusRequestsSeen = store.composerFocusRequests
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
    }

    static func dismantleUIView(_ view: HerdrComposeTextView, coordinator: Coordinator) {
        view.resignFirstResponder()
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HerdrComposeField
        var focusRequestsSeen = 0

        init(_ parent: HerdrComposeField) { self.parent = parent }

        /// Whether anything is in the box, marked (composing) text included.
        func notePresence(_ view: UITextView) {
            let shows = !view.text.isEmpty
            if parent.showsText.wrappedValue != shows {
                let binding = parent.showsText
                DispatchQueue.main.async { binding.wrappedValue = shows }
            }
        }

        func measure(_ view: UITextView) {
            guard let font = view.font, view.bounds.width > 0 else { return }
            let fitted = view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
            let inset = HerdrComposeField.inset
            let ceiling = ceil(font.lineHeight * parent.maxLines + inset.top + inset.bottom)
            let next = min(max(NativeBarMetrics.hit, ceil(fitted)), ceiling)
            if abs(next - parent.height) > 0.5 {
                DispatchQueue.main.async { [parent] in parent.height = next }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            // While pinyin is being composed the marked letters are not the
            // draft yet.
            if textView.markedTextRange == nil, parent.store.draft != textView.text {
                parent.store.draft = textView.text
            }
            notePresence(textView)
            measure(textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // HERDR-10: Return while pinyin is being composed takes the
            // candidate as it stands; it neither sends nor breaks the line.
            if text == "\n", textView.markedTextRange != nil {
                textView.unmarkText()
                return false
            }
            guard text == "\n", textView.markedTextRange == nil,
                  !(textView as? HerdrComposeTextView).map(\.insertingLineBreak).unwrapped else { return true }
            // Return, typed: an empty box passes it to the pane; words are
            // sent, and core presses Enter once it has seen them arrive.
            if textView.text.isEmpty {
                parent.store.passKey("Enter") // non-copy: a Herdr key name
            } else {
                parent.store.sendDraft()
            }
            return false
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused { parent.focused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.focused = false }
        }
    }
}

private extension Optional where Wrapped == Bool {
    var unwrapped: Bool { self ?? false }
}

/// The composer's text view: the whole iOS input method (pinyin candidates,
/// predictions, dictation, paste), smart quotes and dashes off (what is typed
/// goes to a terminal), and the keys an empty box hands to the pane.
final class HerdrComposeTextView: UITextView {
    /// A key for the pane, in Herdr's names.
    var passKey: ((String) -> Void)?
    /// ⇧⏎ is putting a line break in on purpose; it is not a send.
    private(set) var insertingLineBreak = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        autocorrectionType = .yes
        spellCheckingType = .yes
        autocapitalizationType = .sentences
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardType = .default
        returnKeyType = .send
        // Return on an empty box is a key for the pane: never dimmed.
        enablesReturnKeyAutomatically = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") } // non-copy

    /// ⌫ on an empty box is ⌫ on the pane — and holding it repeats, because
    /// the keyboard calls this again for every repeat.
    override func deleteBackward() {
        if text.isEmpty, markedTextRange == nil {
            passKey?("Backspace") // non-copy: a Herdr key name
            return
        }
        super.deleteBackward()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var local = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { local.insert(press); continue }
            let usage = UInt16(truncatingIfNeeded: key.keyCode.rawValue)
            // ⇧⏎ in a box with words is a line break, not a send.
            if usage == HerdrComposePassthrough.returnKey, key.modifierFlags.contains(.shift), !text.isEmpty,
               markedTextRange == nil {
                insertingLineBreak = true
                insertText(String(UnicodeScalar(10)))
                insertingLineBreak = false
                continue
            }
            let flags = key.modifierFlags
            if let name = HerdrComposePassthrough.key(usage: usage, shift: flags.contains(.shift),
                                                      control: flags.contains(.control),
                                                      alternate: flags.contains(.alternate),
                                                      command: flags.contains(.command),
                                                      empty: text.isEmpty, composing: markedTextRange != nil) {
                passKey?(name)
            } else {
                local.insert(press)
            }
        }
        if !local.isEmpty { super.pressesBegan(local, with: event) }
    }
}
