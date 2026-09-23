import SwiftUI

/// Study 03 §13. Four things and nothing else: which machine, what this one
/// approval grants, what to compare, and how long is left.
///
/// The line "这一次批准授予 · 屏幕 · 终端 · Agent" is the only place a user ever
/// sees the three grants, and it is a promise core keeps: the SSH public key
/// went up with the request and the host writes it in the same Approve (N-28).
/// So there is no second approval after this, no PIN to copy and no SSH host
/// fingerprint to check.
struct PairingCard: View {
    @ObservedObject var flow: ConnectionFlowModel
    @FocusState private var invitationFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch flow.failure {
            case .certificateChanged(let pinned, let observed):
                certificateChanged(pinned: pinned, observed: observed)
            case .expired:
                head
                failure(step: Strings.pairingStepExpired, title: Strings.pairingExpired,
                        detail: Strings.pairingExpiredDetail(hostName))
            case .rejected:
                head
                failure(step: Strings.pairingStepRejected, title: Strings.pairingRejected,
                        detail: Strings.pairingRejectedDetail(hostName))
            case .locked:
                head
                lockedByInvitation
            case .message(let text):
                head
                failure(step: Strings.pairingStepNotDelivered, title: Strings.pairingNotStarted, detail: text)
            case .none:
                head
                waiting
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pair-card")
    }

    private var hostName: String { flow.candidate?.name ?? Strings.pairingThisComputer }

    // MARK: - The head every state shares

    @ViewBuilder private var head: some View {
        Text(Strings.pairingRequesting)
            .font(OmodachiTheme.bodyFont(size: 11))
            .foregroundStyle(OmodachiTheme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.top, 14)
        Text(hostName)
            .font(OmodachiTheme.font(size: 22))
            .foregroundStyle(OmodachiTheme.text)
            .padding(.horizontal, 12)
        Text(flow.candidate?.secondLine ?? "")
            .font(OmodachiTheme.font(size: 11))
            .foregroundStyle(OmodachiTheme.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.top, 4)
        grantLine
    }

    /// N-28. One approval, three grants — and it says so before the user asks
    /// anybody to press anything.
    private var grantLine: some View {
        HStack(spacing: 6) {
            HostGlyphView(glyph: "\u{f00c}", fallbackSymbol: "checkmark", size: 12)
                .foregroundStyle(OmodachiTheme.success)
            Text(Strings.pairingGrants)
                .font(OmodachiTheme.font(size: 11))
                .foregroundStyle(OmodachiTheme.secondaryText)
            ForEach([Strings.pairingGrantScreen, Strings.pairingGrantTerminal, Strings.pairingGrantAgent], id: \.self) { item in
                Text(verbatim: "·").font(OmodachiTheme.font(size: 11)).foregroundStyle(OmodachiTheme.dimText)
                Text(item)
                    .font(OmodachiTheme.font(size: 11))
                    .foregroundStyle(OmodachiTheme.text)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .padding(.top, 12)
        .accessibilityIdentifier("pair-grants")
    }

    // MARK: - ① waiting

    @ViewBuilder private var waiting: some View {
        if let fingerprint = flow.fingerprint {
            GroupLabel(text: Strings.pairingFingerprint)
            FingerprintText(fingerprint: fingerprint)
                .accessibilityIdentifier("pair-fingerprint")
            note(Strings.pairingCompareFingerprint)
        } else if flow.probing {
            note(Strings.pairingReadingFingerprint)
        }
        HStack(spacing: 8) {
            Text(Strings.pairingWaiting)
                .font(OmodachiTheme.font(size: 13))
                .foregroundStyle(OmodachiTheme.text)
            Spacer()
            if let expiresAt = flow.expiresAt {
                // D-15's exception: a countdown has a real expiry, so it runs.
                Text(expiresAt, style: .timer)
                    .font(OmodachiTheme.font(size: 13))
                    .foregroundStyle(OmodachiTheme.accent)
                    .monospacedDigit()
                    .accessibilityIdentifier("pair-countdown")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ConnectionParts.actionHeight)
        .background(OmodachiTheme.normalFill)
        .padding(.top, 10)
        .accessibilityIdentifier("pair-waiting")
        note(Strings.pairingApproveOnComputer)
        FlowButton(title: Strings.actionCancel, kind: .ghost) { flow.backToList() }
            .padding(.horizontal, 12)
            .accessibilityIdentifier("pair-cancel")
    }

    // MARK: - The one place an invitation still appears

    /// PAIR-2 §3.2. On the default host this is unreachable: a request needs no
    /// invitation and this card goes straight from "sent" to "approved". It
    /// exists for a host whose owner set `pairing_mode = invite`, and it only
    /// appears after that host has said so — the app never asks first.
    @ViewBuilder private var lockedByInvitation: some View {
        GroupLabel(text: Strings.pairingInviteOnly)
        EmptyBlock(title: Strings.pairingInviteOnlyDetail(hostName),
                   detail: Strings.pairingInviteHow)
        SecureField(Strings.pairingInviteField, text: $flow.lockedInvitation)
            .font(OmodachiTheme.font(size: 14))
            .foregroundStyle(OmodachiTheme.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($invitationFocused)
            .accessibilityIdentifier("pair-locked-invitation")
            .padding(.horizontal, 10)
            .frame(height: ConnectionParts.actionHeight)
            .overlay(Rectangle().stroke(OmodachiTheme.accent, lineWidth: OmodachiTheme.controlBorderWidth)
                .allowsHitTesting(false))
            // A-01: the whole drawn box focuses the field, not just its line.
            .textEntryHitArea($invitationFocused)
            .padding(.horizontal, 12)
        HStack(spacing: 8) {
            FlowButton(title: Strings.pairingRequest, enabled: !flow.running) { flow.submitLockedInvitation() }
                .accessibilityIdentifier("pair-locked-submit")
            FlowButton(title: Strings.pairingOther, kind: .ghost) { flow.backToList() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    // MARK: - ③ ④ the two soft failures

    @ViewBuilder private func failure(step: String, title: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "\u{f00c}") + Text(verbatim: " ") + Text(Strings.pairingDelivered)
                .font(OmodachiTheme.font(size: 11))
                .foregroundStyle(OmodachiTheme.success)
            Text(verbatim: "›").font(OmodachiTheme.font(size: 11)).foregroundStyle(OmodachiTheme.dimText)
            Text(verbatim: "\u{f071} \(step)")
                .font(OmodachiTheme.font(size: 11))
                .foregroundStyle(OmodachiTheme.danger)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .padding(.top, 10)
        Text(title)
            .font(OmodachiTheme.font(size: 22))
            .foregroundStyle(OmodachiTheme.text)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .accessibilityIdentifier("pair-failure-title")
        note(detail)
        HStack(spacing: 8) {
            FlowButton(title: Strings.pairingAgain) { flow.retry() }
                .accessibilityIdentifier("pair-retry")
            FlowButton(title: Strings.pairingOther, kind: .ghost) { flow.backToList() }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - ⑤ the hard one

    /// N-21: no "continue anyway" exists. Trusting is two explicit taps and it
    /// replaces the fingerprint only — `host_id` and the credential do not move,
    /// so nobody has to pair again.
    @ViewBuilder private func certificateChanged(pinned: String, observed: String) -> some View {
        Text(Strings.pairingRefused)
            .font(OmodachiTheme.bodyFont(size: 11))
            .foregroundStyle(OmodachiTheme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.top, 14)
        Text(Strings.pairingCertificateChanged(hostName))
            .font(OmodachiTheme.font(size: 22))
            .foregroundStyle(OmodachiTheme.text)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("pair-certificate-changed")
        GroupLabel(text: Strings.settingsPinnedAt)
        FingerprintText(fingerprint: pinned, color: OmodachiTheme.tertiaryText)
        GroupLabel(text: Strings.settingsPresentedNow)
        FingerprintText(fingerprint: observed, color: OmodachiTheme.danger)
            .accessibilityIdentifier("pair-observed-fingerprint")
        note(Strings.pairingCertificateChangedDetail)
        TwoStepButton(title: Strings.settingsTrustCertificate, confirmTitle: Strings.settingsTrustCertificateConfirm) {
            flow.trustRotatedCertificate()
        }
        .padding(.horizontal, 12)
        .accessibilityIdentifier("pair-trust-certificate")
        FlowButton(title: Strings.actionCancel, kind: .ghost) { flow.backToList() }
            .padding(.horizontal, 12)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont(size: 11))
            .foregroundStyle(OmodachiTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

/// N-14's two-step confirmation, reused: the first tap only changes the button.
struct TwoStepButton: View {
    let title: String
    let confirmTitle: String
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        FlowButton(title: armed ? confirmTitle : title, kind: .danger) {
            if armed { action(); armed = false } else { armed = true }
        }
    }
}
