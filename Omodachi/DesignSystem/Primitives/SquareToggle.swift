import SwiftUI

/// The two host controls that are not buttons: the square switch and the small
/// segmented control (D-16, Study 03 §16).
///
/// Both were written inside the Remote entry screen, which is where they were
/// first needed; Settings then used them across a file boundary and the Panel
/// could not use them at all. They are primitives now, so `Toggle` and `Picker`
/// never have to appear (ARCH-1 §1) and every switch in the app is the same
/// square the host draws.

/// D-16: the host's `ToggleSwitch` is a square track with a square knob, not an
/// iOS capsule; rounding only exists where `Style.cornerRadius > 0`, and
/// Omarchy's is 0. The hit area is 44 (A-01); the visual is not enlarged.
struct SquareToggle: View {
    @Binding var isOn: Bool
    /// A-65: a square of colour is not a label. What this switches, in words.
    var label: String = ""
    var identifier: String?

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn ? OmodachiTheme.accent.opacity(0.35) : OmodachiTheme.normalFill)
                    .overlay(Rectangle().stroke(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
                    .frame(width: 42, height: 22)
                Rectangle()
                    .fill(isOn ? OmodachiTheme.accent : OmodachiTheme.muted)
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 3)
            }
            .frame(width: 44, height: ConnectionParts.actionHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isOn)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? Strings.quickOn : Strings.quickOff)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityIdentifier(identifier ?? "square-toggle")
    }
}

struct SquareToggleRow: View {
    let title: String
    var identifier: String?
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(OmodachiTheme.font(size: 13))
                    .foregroundStyle(OmodachiTheme.text)
                if let detail {
                    Text(detail)
                        .font(OmodachiTheme.bodyFont(size: 11))
                        .foregroundStyle(OmodachiTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            SquareToggle(isOn: $isOn, label: title, identifier: identifier)
        }
        .padding(.vertical, 8)
    }
}

/// The 28-high small segmented control Study 03 §16 uses, with a 44 hit area.
struct SegmentedRow<Value: Equatable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { selection = option.1 } label: {
                    Text(option.0)
                        .font(OmodachiTheme.font(size: 12))
                        .foregroundStyle(selection == option.1 ? OmodachiTheme.selectedText : OmodachiTheme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .background(selection == option.1 ? OmodachiTheme.selectedFill : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: ConnectionParts.actionHeight)
            }
        }
        .overlay(Rectangle().stroke(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
    }
}

/// STREAM-1. A stepped value on a line: the system slider (it carries
/// VoiceOver's adjustable action for free) in the host's accent, with the
/// current value printed beside it. The value is snapped to `step` on the way
/// out, so a caller never sees 17 834 kbps.
struct StepSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// What the number beside the track reads, e.g. "20 Mbps".
    let format: (Int) -> String
    var label: String = ""
    var identifier: String?

    var body: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            Slider(value: Binding(get: { Double(value) }, set: { raw in
                let snapped = Int((raw / Double(step)).rounded()) * step
                value = min(range.upperBound, max(range.lowerBound, snapped))
            }), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
            .tint(OmodachiTheme.accent)
            .frame(minHeight: ConnectionParts.actionHeight)
            .accessibilityLabel(label)
            .accessibilityValue(format(value))
            .accessibilityIdentifier(identifier ?? "step-slider")
            Text(verbatim: format(value))
                .font(OmodachiTheme.font(size: 12))
                .foregroundStyle(OmodachiTheme.text)
                .frame(minWidth: 64, alignment: .trailing)
        }
    }
}
