import SwiftUI

/// HERDR-11 §3. The one connection clock, said in one line over the top of
/// whatever panel is up — an overlay, so nothing under it moves.
///
/// Amber after ~4 s without a word from the computer ("Reconnecting…"), red
/// after ~15 s with the real cause ("This iPhone is offline", "Can't reach
/// omarchy", and in the Herdr panel "Herdr isn't running on omarchy"). Red
/// is a button: Try again reconnects now. Nothing is drawn while the clock
/// says live.
struct ConnectionBanner: View {
    let health: ConnectionHealth
    let message: String?
    var retry: (() -> Void)?

    private var role: ThemeColorRole {
        if case .lost = health { return .red }
        return .yellow
    }

    private var lost: Bool {
        if case .lost = health { return true }
        return false
    }

    var body: some View {
        if health != .live, let message {
            Tap(enabled: lost && retry != nil, action: { retry?() }) {
                HStack(spacing: OmodachiTheme.space("md")) {
                    Circle()
                        .fill(OmodachiTheme.current.color(role))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(OmodachiTheme.font("caption", weight: .semibold))
                        .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if lost, retry != nil {
                        Text(Strings.connectionTryAgain)
                            .font(OmodachiTheme.font("caption"))
                            .foregroundStyle(OmodachiTheme.accent)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, OmodachiTheme.space("lg"))
                .frame(minHeight: 28)
                .background(OmodachiTheme.background.opacity(0.94))
                .overlay(Rectangle().stroke(OmodachiTheme.current.color(role).opacity(0.8),
                                            lineWidth: OmodachiTheme.controlBorderWidth))
                .contentShape(Rectangle())
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
            .accessibilityHint(lost && retry != nil ? Strings.connectionTryAgain : "")
            .accessibilityIdentifier(lost ? "connection-banner-lost" : "connection-banner-trouble")
            .transition(.opacity)
        }
    }
}
