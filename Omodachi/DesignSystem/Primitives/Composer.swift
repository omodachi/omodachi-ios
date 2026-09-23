import SwiftUI

/// The Agent panel's input: a growing text area and the row of actions under it.
///
/// N-35 (rev 5): **no microphone.** Leo — "先不考虑麦克风，这部分有点复杂了". What
/// was here reached the host's voxtype through core's uplink, and that path has
/// a resource model to settle first (`voice.md`'s `MicrophoneArbiter`: passthrough
/// and dictation are two uses of one microphone, and the second claimant gets
/// `audio_input_busy`). The uplink code is still in the app; nothing calls it.
///
/// The actions are supplied by the caller because what they are depends on what
/// the turn is doing — Send, or Steer and Interrupt, or Run for a slash command
/// — and that is the Agent panel's knowledge, not this primitive's.
struct Composer<Actions: View>: View {
    let placeholder: String
    @Binding var text: String
    var identifier = "composer"
    /// `true` while the surface is refusing input (no identity yet, a turn that
    /// cannot take a steer). The field is still readable; it just cannot be
    /// typed into, and A-65 wants that stated rather than only drawn.
    var enabled = true
    @ViewBuilder var actions: () -> Actions

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: OmodachiTheme.space("lg")) {
                // A-16: it grows with what is typed, up to six lines, and then
                // scrolls. A field rather than an editor, because the app has
                // one text control shape and this is it.
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .font(OmodachiTheme.bodyFont("title"))
                    .foregroundStyle(OmodachiTheme.text)
                    .focused($focused)
                    .accessibilityIdentifier(identifier)
                    .padding(OmodachiTheme.space("xxl"))
                    // A-01. The box a finger aims at is 44 whatever the type
                    // step does, and all 44 of it belongs to the field.
                    .frame(minHeight: NativeBarMetrics.hit)
                    .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder,
                                                      lineWidth: OmodachiTheme.controlBorderWidth)
                        .allowsHitTesting(false))
                    .textEntryHitArea($focused, enabled: enabled)
                    .disabled(!enabled)
                actions()
            }
            .padding(.horizontal, OmodachiTheme.panelPadding)
            .padding(.bottom, OmodachiTheme.space("xxl"))
        }
        .accessibilityElement(children: .contain)
    }

    /// The Shell closes the keyboard when a panel goes away, the same way a
    /// `Field` does.
    func resignFocus() { focused = false }
}

/// One action in a composer's row: 28 tall like every other control, inside the
/// 44 a finger needs (A-01).
struct ComposerAction: View {
    let title: String
    var enabled = true
    var identifier: String
    let action: () -> Void

    var body: some View {
        Tap(bordered: true, enabled: enabled, action: action) {
            Text(title)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.text)
                .padding(.horizontal, OmodachiTheme.space("xl"))
                .frame(height: OmodachiTheme.controlHeight)
                .frame(minWidth: 60, minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }
}
