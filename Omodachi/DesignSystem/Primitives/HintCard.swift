import SwiftUI

/// HERDR-4 §3.4. A one-time hint: one or two warm sentences about what this
/// surface can do, and the one word that puts it away for good. Shown inline
/// (never over the content), accent-ruled on the leading edge like a note.
struct HintCard: View {
    let text: String
    let dismissTitle: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: OmodachiTheme.space("md")) {
            Glyph(symbol: "lightbulb")
                .foregroundStyle(OmodachiTheme.accent)
                .padding(.top, OmodachiTheme.space("xs"))
            Text(text)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextTap(dismissTitle, bordered: true, minimumHeight: OmodachiTheme.controlHeight, action: onDismiss)
                .accessibilityIdentifier("hint-dismiss")
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.vertical, OmodachiTheme.space("md"))
        .background(OmodachiTheme.normalFill)
        .overlay(alignment: .leading) {
            Rectangle().fill(OmodachiTheme.accent).frame(width: 2).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}
