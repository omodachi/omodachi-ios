import SwiftUI
import UIKit

/// UX-3 §2. A block of machine text the person can read and, more to the point,
/// copy.
///
/// Every other row in this app is prose for a person. This one is the opposite:
/// it is the device's own record of what it tried, printed verbatim so it can
/// be pasted into a message. Nothing about it is translated, wrapped or
/// prettified — a trace that has been reflowed is a trace that no longer lines
/// up against the host's journal.
///
/// It scrolls on its own so a long transcript cannot push the rest of ⑥ off
/// screen, and it is capped rather than unbounded for the same reason.
struct DiagnosticBlock: View {
    let title: String
    let text: String
    /// What the copy control says once it has copied. Held briefly, then back.
    let copyTitle: String
    let copiedTitle: String
    let emptyTitle: String
    var identifier: String

    @State private var copied = false

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            HStack(spacing: OmodachiTheme.space("lg")) {
                Text(title)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                Spacer(minLength: OmodachiTheme.space("lg"))
                if !isEmpty {
                    TextTap(copied ? copiedTitle : copyTitle, bordered: true, minimumHeight: 32) {
                        UIPasteboard.general.string = text
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                    .accessibilityIdentifier("\(identifier)-copy")
                }
            }
            if isEmpty {
                Text(emptyTitle)
                    .font(OmodachiTheme.bodyFont("body-small"))
                    .foregroundStyle(OmodachiTheme.tertiaryText)
                    .accessibilityIdentifier(identifier)
            } else {
                ScrollView(.vertical) {
                    Text(verbatim: text)
                        .font(OmodachiTheme.font(size: 11))
                        .foregroundStyle(OmodachiTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(OmodachiTheme.space("md"))
                }
                .frame(maxHeight: 180)
                .background(OmodachiTheme.normalFill)
                .accessibilityIdentifier(identifier)
            }
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.vertical, OmodachiTheme.space("xl"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
