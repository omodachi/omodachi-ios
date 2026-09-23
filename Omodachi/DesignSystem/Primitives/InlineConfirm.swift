import SwiftUI

/// N-14. A destructive action asks in the row it lives in, and the second tap
/// answers. No dialog: a modal costs a dismissal for something the user is
/// about to do again, and it covers the thing they are deciding about.
///
/// One implementation, used by every destructive place in the app — ending a
/// Remote session (A-57), clearing the notification list (A-45), forgetting a
/// host (N-29) — so the shape of "are you sure" never varies.
struct InlineConfirm: View {
    /// What the row says before it is asked.
    let title: String
    /// What the confirming half says.
    var confirmTitle: String
    var cancelTitle = Strings.actionCancel
    /// The style of the resting state. Ending a session is `secondary` in the
    /// study's session card; forgetting a host is `danger`.
    var kind: FlowButton.Kind = .secondary
    var identifier: String
    let confirm: () -> Void

    @State private var asking = false

    var body: some View {
        Group {
            if asking {
                HStack(spacing: OmodachiTheme.space("lg")) {
                    FlowButton(title: confirmTitle, kind: .danger) {
                        asking = false
                        confirm()
                    }
                    .accessibilityIdentifier("\(identifier)-confirm")
                    FlowButton(title: cancelTitle, kind: .ghost) { asking = false }
                        .accessibilityIdentifier("\(identifier)-cancel")
                }
            } else {
                FlowButton(title: title, kind: kind) { asking = true }
                    .accessibilityIdentifier(identifier)
            }
        }
        // The session can end from four other places (N-32); a row still asking
        // when it does would be asking about something that is already over.
        .onDisappear { asking = false }
    }

    /// Put the question away without answering it. The caller uses this when the
    /// thing being confirmed stopped existing.
    func reset() { }
}

/// MENU-4 / Study 04 A-68. The in-row half of a two-tap host action: the row
/// itself is the button, so all this draws is what the first tap changed —
/// "再点一次执行" and a hairline that runs out with the window. It is the same
/// question N-14 asks, asked where a menu row can ask it: in the row, with no
/// second control to aim at, and gone on its own when the window closes.
struct TapAgainCountdown: View {
    let until: Date
    let window: TimeInterval
    var identifier: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let left = max(0, min(1, until.timeIntervalSince(context.date) / window))
            Text(Strings.menuTapAgain)
                .font(OmodachiTheme.font("body-small", weight: .semibold))
                .foregroundStyle(OmodachiTheme.current.color(.yellow))
                .lineLimit(1)
                .fixedSize()
                .padding(.bottom, 5)
                .overlay(alignment: .bottomTrailing) {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(OmodachiTheme.current.color(.yellow))
                            .frame(width: proxy.size.width * left, height: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
        }
        .padding(.trailing, OmodachiTheme.space("sm"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.menuTapAgain)
        .accessibilityIdentifier(identifier)
    }
}
