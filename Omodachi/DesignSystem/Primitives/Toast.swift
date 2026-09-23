import SwiftUI

/// A-12. An action's result is a 26-high row inside the Panel, not a dialog and
/// not a desktop notification: the 5s/8s + hover-pause machinery upstairs has
/// no touch equivalent, and a modal would cost a dismissal for something the
/// user is about to do again.
///
/// It reports what the host actually said — `accepted` while the host has only
/// taken the request, then `applied` or `failed` — and never claims a result
/// the host has not confirmed.
struct PanelToast: Equatable, Sendable, Identifiable {
    /// `message` is the host's own sentence with no verdict of its own — the
    /// channel panel ① used to draw as a red error row under the menu even when
    /// nothing had gone wrong (N-33).
    enum Stage: Sendable, Equatable { case accepted, applied, failed, message }
    let id: UUID
    var stage: Stage
    var label: String
    var detail: String?

    init(id: UUID = UUID(), stage: Stage, label: String, detail: String? = nil) {
        self.id = id; self.stage = stage; self.label = label; self.detail = detail
    }

    var role: ThemeColorRole {
        switch stage {
        case .accepted, .message: .muted
        case .applied: .green
        case .failed: .red
        }
    }
    var symbol: String {
        switch stage {
        case .accepted: "ellipsis"
        case .applied: "checkmark"
        case .failed: "exclamationmark"
        case .message: "info.circle"
        }
    }
    /// The word on the trailing edge. A plain message has none: there is no
    /// verdict to print, and "message" is not one.
    var tail: String {
        switch stage {
        case .accepted: "accepted"
        case .applied: "applied"
        case .failed: "failed"
        case .message: ""
        }
    }
}

struct PanelToastView: View {
    let toast: PanelToast

    var body: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            Image(systemName: toast.symbol)
                .font(.system(size: OmodachiTheme.fontSize("caption")))
                .foregroundStyle(OmodachiTheme.current.color(toast.role))
            Text(toast.detail.map { "\(toast.label) · \($0)" } ?? toast.label)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: OmodachiTheme.space("sm"))
            if !toast.tail.isEmpty {
                Text(toast.tail)
                    .foregroundStyle(OmodachiTheme.tertiaryText)
            }
        }
        .font(OmodachiTheme.font("body-small"))
        .foregroundStyle(OmodachiTheme.text)
        .padding(.horizontal, OmodachiTheme.space("xl"))
        .frame(height: 26)
        .background(OmodachiTheme.normalFill)
        .background(OmodachiTheme.background)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
        // `.toast` sits 5 in from the stage edge — half of `general.gaps_out`,
        // the same shell edge distance `Style.qml 359–375` uses.
        .padding(.horizontal, 5)
        .accessibilityIdentifier("panel-toast")
        .accessibilityLabel(toast.tail.isEmpty ? toast.label : Strings.pair(toast.label, toast.tail))
    }
}

/// A-58's one exception, and the only native thing ever drawn on the picture.
///
/// Study 04 rev 5, review item 4: the stream has no native chrome, so a
/// notification, an agent approval or a dropped connection was invisible while
/// a session was up — A-12's toast hangs on a bar that is not there, the
/// approval card lives inside panel ③, and `AgentApprovalNotifier` only raises a
/// local notification when the app is in the *background*, which it is not.
///
/// So: one 26-high row against the picture's bar edge, for exactly three kinds
/// of event. Tapping it summons the panel that event belongs to (⑦ / ③ / ②);
/// ignoring it makes it go away on its own. It never takes input from the
/// stream — `allowsHitTesting` is on the row, not on the picture.
struct RemoteToast: View {
    /// What happened, and therefore which panel this opens.
    enum Kind: Equatable, Sendable {
        /// `notification.posted` → panel ⑦.
        case notification
        /// `agent.approval.requested` → panel ③.
        case approval
        /// The host connection dropped or is retrying → panel ②.
        case connection

        var role: ThemeColorRole {
            switch self {
            case .notification: .accent
            case .approval: .yellow
            case .connection: .red
            }
        }
        var icon: (symbol: String, nerd: String) {
            switch self {
            case .notification: Icon.bell
            case .approval: Icon.warning
            case .connection: Icon.warning
            }
        }
        var tail: String {
            switch self {
            case .notification: Strings.remoteToastNotification
            case .approval: Strings.remoteToastApproval
            case .connection: Strings.remoteToastConnection
            }
        }
    }

    let kind: Kind
    let message: String
    /// The right end: "第 2 次 · 4s", or the tail that says what a tap does.
    var detail: String?
    let action: () -> Void

    var body: some View {
        Tap(action: action) {
            HStack(spacing: OmodachiTheme.space("lg")) {
                Glyph(kind.icon, step: "caption")
                    .foregroundStyle(OmodachiTheme.current.color(kind.role))
                Text(message)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.text)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: OmodachiTheme.space("sm"))
                Text(detail ?? kind.tail)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, OmodachiTheme.space("xl"))
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(OmodachiTheme.background.opacity(0.94))
            .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder,
                                              lineWidth: OmodachiTheme.controlBorderWidth))
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityValue(detail ?? kind.tail)
        .accessibilityIdentifier("remote-toast")
    }
}
