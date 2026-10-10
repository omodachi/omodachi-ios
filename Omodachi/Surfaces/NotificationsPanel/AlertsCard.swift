import SwiftUI

/// NOTIFY-2. The app's own alerts, beside Odomo's card at the top of ⑦.
///
/// It says honestly what this device will do: banners on, quiet (Notification
/// Centre only — what the Agent panel used to ask for without asking), off, or
/// turned off in iOS Settings. "Turn on alerts" asks iOS the real question,
/// with banners and sound; after a refusal iOS will not ask again, so the same
/// place opens Settings instead. With banners on it is one quiet line, plus
/// the honest limit: a closed app or a locked phone is Odomo's. NOTIFY-1 adds
/// what an approval alert can do, and two switches: "Alert me even when I'm
/// at the computer" and "Tell me when an agent finishes", both off.
struct AlertsCard: View {
    @ObservedObject var attention: AttentionNotifier
    /// Settings ⑥ draws the same thing as a row; ⑦ as a card.
    var compact = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch attention.permission {
        case .unknown:
            EmptyView()
        case .authorized:
            VStack(alignment: .leading, spacing: 4) {
                header(state: Strings.alertsStateOn)
                sentence(Strings.alertsOn(DeviceWord.current), color: OmodachiTheme.secondaryText)
                    .accessibilityIdentifier("alerts-state-on")
                sentence(Strings.alertsLocked(DeviceWord.current, Strings.odomoName), color: OmodachiTheme.tertiaryText)
                // NOTIFY-1: deciding on the alert, quiet at the desk, finished.
                sentence(Strings.alertsActions(DeviceWord.current), color: OmodachiTheme.tertiaryText)
                    .accessibilityIdentifier("alerts-actions")
                SquareToggleRow(title: Strings.alertsAtDesk, identifier: "alerts-at-desk",
                                detail: Strings.alertsAtDeskDetail, isOn: $attention.alertAtDesk)
                SquareToggleRow(title: Strings.alertsFinished, identifier: "alerts-finished",
                                detail: Strings.alertsFinishedDetail, isOn: $attention.finishedAlerts)
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.vertical, compact ? 6 : OmodachiTheme.space("lg"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(compact ? "settings-alerts" : "notifications-alerts-card")
        case .notDetermined, .provisional, .denied:
            HStack(spacing: 0) {
                Rectangle().fill(OmodachiTheme.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    header(state: attention.permission == .provisional ? Strings.alertsStateQuiet : Strings.alertsStateOff)
                    sentence(explanation, color: OmodachiTheme.secondaryText)
                        .accessibilityIdentifier("alerts-state")
                    FlowButton(title: attention.permission == .denied ? Strings.alertsOpenSettings : Strings.alertsTurnOn) {
                        Task { await attention.turnOn { openURL($0) } }
                    }
                    .frame(maxWidth: 220)
                    .padding(.top, 4)
                    .accessibilityIdentifier("alerts-turn-on")
                }
                .padding(12)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(OmodachiTheme.normalFill)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(compact ? "settings-alerts" : "notifications-alerts-card")
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.vertical, compact ? 6 : OmodachiTheme.space("lg"))
        }
    }

    private var explanation: String {
        switch attention.permission {
        case .provisional: Strings.alertsQuiet
        case .denied: Strings.alertsDenied(DeviceWord.current)
        default: Strings.alertsOff(DeviceWord.current)
        }
    }

    private func header(state: String) -> some View {
        HStack(spacing: 8) {
            Text(Strings.alertsTitle(DeviceWord.current))
                .font(OmodachiTheme.bodyFont("subtitle"))
                .foregroundStyle(OmodachiTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(state)
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(attention.permission == .authorized ? OmodachiTheme.accent : OmodachiTheme.muted)
                .accessibilityIdentifier("alerts-state-word")
        }
    }

    private func sentence(_ text: String, color: Color) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont("body-small"))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
