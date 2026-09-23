import SwiftUI

/// A-57. While something is running, its panel says what is running — not what
/// you could start.
///
/// Study 04's card is four lines and a row of buttons: mode, backend and what
/// was negotiated, how long it has been up, and **where ending it will take
/// you** (N-32's `returnTo`, written out rather than promised). The row of
/// buttons wraps on a narrow column (A-56 rev 4b), because 349 points cannot
/// hold "回到画面" beside a two-step confirmation.
struct SessionCard<Actions: View>: View {
    /// "扩展屏幕 · 进行中".
    let title: String
    /// The chip at the end of the title line: "已连接".
    var status: String?
    var statusRole: ThemeColorRole = .green
    /// The name/value lines, in order.
    let lines: [(String, String)]
    /// A-56: below `PanelMeasure.narrowColumn` the buttons stack.
    var narrow = false
    var identifier = "session-card"
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OmodachiTheme.space("lg")) {
                Text(title)
                    .font(OmodachiTheme.font("title"))
                    .foregroundStyle(OmodachiTheme.text)
                    .lineLimit(1)
                if let status {
                    StateChip(text: status, kind: statusRole == .green ? .paired : .new)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.top, OmodachiTheme.rowPaddingX)

            ForEach(lines, id: \.0) { line in
                HStack(alignment: .firstTextBaseline, spacing: OmodachiTheme.space("lg")) {
                    Text(line.0)
                        .font(OmodachiTheme.font("body-small"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .frame(width: 88, alignment: .leading)
                    Text(line.1)
                        .font(OmodachiTheme.font("body-small"))
                        .foregroundStyle(OmodachiTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .padding(.top, OmodachiTheme.space("md"))
                .accessibilityElement(children: .combine)
            }

            if narrow {
                VStack(spacing: OmodachiTheme.space("lg")) { actions() }
                    .padding(OmodachiTheme.rowPaddingX)
            } else {
                HStack(spacing: OmodachiTheme.space("lg")) { actions() }
                    .padding(OmodachiTheme.rowPaddingX)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmodachiTheme.background)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.accent, lineWidth: OmodachiTheme.popupBorderWidth))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
