import SwiftUI

/// A-63 and review item 14: one progress row and one error row, shared by every
/// panel.
///
/// Before ARCH-1 each surface wrote its own: the SSH surface had a paragraph,
/// Herdr had "Herdr available · default agent not attached", Agent had a
/// permanent `Starting… / Ready / Working…` line, and Remote had three more.
/// N-33 deleted the ones that said nothing; these two are what is left, and
/// they are the same two everywhere.
///
/// The rules they carry:
///
/// * **Entering a panel starts the thing.** There is no "connect" button and no
///   question. While it is starting there is one 26-high row, and when it is
///   started the row goes away — success is the content appearing, never a
///   sentence saying "connected".
/// * **A failure takes the screen.** One sentence of Chinese saying what went
///   wrong, the host's own code in brackets for copying, and at least one
///   button that is a next step (N-24).
/// * D-15: the busy indicator turns only while something really is in flight.

/// The 26-high starting row. `steps` are the words, in order, with the one in
/// flight marked; `detail` is whatever the host has said so far.
struct ProgressRow: View {
    let title: String
    var detail: String?
    /// D-15. False draws the same row without the spinner, for a step that is
    /// waiting on the user rather than on the wire.
    var busy = true
    var identifier = "progress-row"

    var body: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            if busy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(OmodachiTheme.accent)
                    .accessibilityHidden(true)
            } else {
                Glyph(Icon.working, step: "caption")
                    .foregroundStyle(OmodachiTheme.secondaryText)
            }
            Text(title)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.text)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(verbatim: "·").foregroundStyle(OmodachiTheme.dimText)
                Text(detail)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
        .accessibilityIdentifier(identifier)
    }
}

/// The one failure block. A sentence, the host's code in brackets, and the
/// buttons that are the next step.
///
/// Review item 14: `SessionStore`'s SSH paragraph, Herdr's own wording and
/// Agent's third variant are all this now, so a user who has read one has read
/// them all.
struct InlineError<Actions: View>: View {
    /// One sentence, in Chinese, saying what happened.
    let message: String
    /// The host's own enum, e.g. `agent_backend_missing`. Drawn in brackets and
    /// in the mono face: it is there to be copied into a search, not read.
    var code: String?
    var identifier = "inline-error"
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("lg")) {
            HStack(alignment: .firstTextBaseline, spacing: OmodachiTheme.space("lg")) {
                Glyph(Icon.warning, step: "icon-small")
                    .foregroundStyle(OmodachiTheme.danger)
                Text(message)
                    .font(OmodachiTheme.bodyFont("subtitle"))
                    .foregroundStyle(OmodachiTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let code, !code.isEmpty {
                Text(verbatim: "(\(code))")
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.tertiaryText)
                    .textSelection(.enabled)
            }
            HStack(spacing: OmodachiTheme.space("lg")) { actions() }
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.vertical, OmodachiTheme.space("xxl"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

extension InlineError where Actions == EmptyView {
    init(message: String, code: String? = nil, identifier: String = "inline-error") {
        self.init(message: message, code: code, identifier: identifier, actions: { EmptyView() })
    }
}

/// The empty state, which is not an error: there is nothing here *yet*, and the
/// second line says what would put something here (A-33).
struct EmptyState: View {
    let title: String
    var detail: String?
    var identifier = "empty-state"

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            Text(title)
                .font(OmodachiTheme.bodyFont("subtitle"))
                .foregroundStyle(OmodachiTheme.secondaryText)
            if let detail {
                Text(detail)
                    .font(OmodachiTheme.bodyFont("body-small"))
                    .foregroundStyle(OmodachiTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.vertical, 22)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
