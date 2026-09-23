import SwiftUI

/// A-06. The one text field shape: 44 high, zero radius, a bottom rule and
/// nothing else. The desktop's `input-padding-y 7` would be a 21-point target
/// on glass, so the height is the app's, and only the height.
///
/// N-35 (rev 5): **there is no microphone in it.** What it searches is 227
/// keybinding names and 642 catalog rows — short words, which voice does not
/// make faster, and it would cost a permission prompt to find that out.
struct Field: View {
    let placeholder: String
    @Binding var text: String
    var icon: (symbol: String, nerd: String)? = Icon.search
    var identifier: String
    /// Whether this field should take focus when it appears (A-25: `SUPER+K`
    /// lands on the Keybindings search, not merely on the panel).
    var focusOnAppear = false
    var onSubmit: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            if let icon {
                Glyph(icon).foregroundStyle(OmodachiTheme.secondaryText)
            }
            TextField(placeholder, text: $text)
                .font(OmodachiTheme.font("subtitle"))
                .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Tap(action: { text = "" }) {
                    Glyph(Icon.close)
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Strings.menuSearchClear)
                .accessibilityIdentifier("\(identifier)-clear")
            }
        }
        .frame(height: NativeBarMetrics.hit)
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OmodachiTheme.controlBorder)
                .frame(height: OmodachiTheme.controlBorderWidth)
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .allowsHitTesting(false)
        }
        // A-01: the row is 44 high and the field inside it is 22, so without
        // this the top and bottom halves of a search box do nothing.
        .textEntryHitArea($focused)
        .onAppear { if focusOnAppear { focused = true } }
        .onChange(of: focusOnAppear) { _, value in if value { focused = true } }
    }

    /// The Shell closes the keyboard when a panel goes away; a field that kept
    /// first responder would hold it open over the next panel.
    func resignFocus() { focused = false }
}
