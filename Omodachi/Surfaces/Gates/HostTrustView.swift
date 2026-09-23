import SwiftUI

/// One name/value line, in the app's own shape rather than `LabeledContent`'s.
private struct LabelledLine: View {
    let name: String
    let value: String

    var body: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            Text(name)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.secondaryText)
            Spacer(minLength: OmodachiTheme.space("lg"))
            Text(value)
                .font(OmodachiTheme.font("subtitle"))
                .foregroundStyle(OmodachiTheme.text)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .frame(minHeight: NativeBarMetrics.hit)
    }
}

struct HostTrustView: View {
    let challenge: SSHHostKeyChallenge
    /// The host and its port: an address, not a sentence.
    private var endpoint: String { "\(challenge.host):\(challenge.port)" }
    let accept: () -> Void
    let reject: () -> Void
    /// UX-1 item 9. This was a stock `Form` of `Section`s and `LabeledContent`
    /// rows inside a `NavigationStack` — grouped grey cards with rounded
    /// corners and a system tint, in the middle of an app that is flat,
    /// zero-radius and bordered throughout. It is built from the same parts as
    /// every other page now.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Strings.gateSshHostKey)
                .font(OmodachiTheme.font("heading"))
                .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .frame(height: NativeBarMetrics.hit)
            FlowRule()
            GroupLabel(text: Strings.gateSshHostKeyNew)
            LabelledLine(name: Strings.gateSshHostKeyHost, value: endpoint)
            LabelledLine(name: Strings.gateSshHostKeyAlgorithm, value: challenge.algorithm)
            Text(challenge.fingerprintSHA256)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .padding(.vertical, OmodachiTheme.space("md"))
                .accessibilityIdentifier("host-key-fingerprint")
            Text(Strings.gateSshHostKeyDetail)
                .font(OmodachiTheme.bodyFont("body-small"))
                .foregroundStyle(OmodachiTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .padding(.bottom, OmodachiTheme.space("xxl"))
            FlowRule()
            HStack(spacing: OmodachiTheme.space("lg")) {
                FlowButton(title: Strings.gateSshHostKeyTrust, action: accept)
                    .accessibilityIdentifier("trust-host-key")
                FlowButton(title: Strings.gateSshHostKeyReject, kind: .ghost, action: reject)
                    .accessibilityIdentifier("reject-host-key")
            }
            .padding(OmodachiTheme.rowPaddingX)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmodachiTheme.background)
        .presentationDetents([.medium, .large])
        .presentationBackground(OmodachiTheme.background)
    }
}

