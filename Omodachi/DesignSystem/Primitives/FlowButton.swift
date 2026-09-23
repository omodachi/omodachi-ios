import SwiftUI

/// The pieces Study 03 §12 and §13 are drawn out of, and nothing else.
///
/// No new row shapes were invented for this screen: the host row is the 58 pt
/// two-line detail row A-19 already uses, with its first line lifted to
/// `heading` because it is the only thing on that screen worth reading (A-32).
/// Empty states are list content, not full-screen illustrations, and each one
/// carries its own exit (A-33).
enum ConnectionParts {
    /// A-32: `Menu.qml` detail height.
    static let rowHeight: CGFloat = 58
    /// A-33 / A-01: the minimum a finger can hit.
    static let actionHeight: CGFloat = 44
}

/// N-20: "paired" is answered by this device's own pin record, never by a TXT
/// field a LAN peer could write.
enum HostPairingState: Equatable, Sendable {
    case new, paired, certificateChanged
    /// PAIR-4 §1: this device is holding a credential for that host but has no
    /// directory record to go with it — the app was reinstalled, or an older
    /// build wrote the record under a different key. One tap asks the host
    /// whether the credential is still good and settles it either way.
    case unconfirmed

    var label: String {
        switch self {
        case .new: Strings.hostPairingNew
        case .paired: Strings.hostPairingPaired
        case .unconfirmed: Strings.hostPairingUnconfirmed
        case .certificateChanged: Strings.hostPairingCertChanged
        }
    }
}

/// One row in the host list: a discovered instance or one the user typed.
struct HostCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The last six of `host_id`. It survives certificate rotation, which is
    /// what makes it the right way to tell two machines with the same name
    /// apart (A-32); the Bonjour `fp` prefix is only a list label.
    let hostIDSuffix: String?
    let address: String
    let url: URL
    var pairing: HostPairingState
    /// PAIR-2 §3.3: this host answered `/health` with `pairing.mode == invite`.
    /// It changes one word on one chip; it is not a pairing state of its own.
    var invitationOnly = false

    /// PAIR-4 §4. The one key this row's credential, pin and directory record
    /// are all stored under. A URL that cannot be an account at all keeps its
    /// own string so the row still has a stable identity; nothing will be
    /// found under it, which is exactly what a bad address deserves.
    var account: String { HostAccount.derive(url) ?? url.absoluteString }

    /// The chip on the trailing edge. An unpaired host that has been locked to
    /// invitations says so here rather than letting the user find out by
    /// tapping it and reading a refusal.
    var statusLabel: String {
        pairing == .new && invitationOnly ? Strings.hostPairingInviteNeeded : pairing.label
    }

    var secondLine: String {
        guard let hostIDSuffix, !hostIDSuffix.isEmpty else { return address }
        return "…\(hostIDSuffix) · \(address)"
    }

    init(id: String, name: String, hostIDSuffix: String?, address: String, url: URL,
         pairing: HostPairingState = .new) {
        self.id = id
        self.name = name
        self.hostIDSuffix = hostIDSuffix
        self.address = address
        self.url = url
        self.pairing = pairing
    }

    init?(discovered host: DiscoveredHost) {
        guard let url = host.preferredURL else { return nil }
        let address = [url.host, url.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
        self.init(id: host.id, name: host.displayName,
                  hostIDSuffix: host.hostID.map { String($0.suffix(6)) },
                  address: address, url: url)
    }

    /// A-34: the user knows their machine is called `omarchy`, or an address.
    /// They do not know 8099 and should not be asked to assemble a URL.
    static func manual(_ input: String, defaultPort: Int = 8099) -> HostCandidate? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 255 else { return nil }
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var port = defaultPort
        // An IPv6 literal is full of colons, so only `[addr]:port` is a port.
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let value = Int(rest.dropFirst()) { port = value }
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") {
            // Exactly one colon is `host:port`. Two or more is an IPv6 literal,
            // which only carries a port inside brackets.
            guard let value = Int(text[text.index(after: colon)...]) else { return nil }
            port = value
            text = String(text[..<colon])
        }
        guard (1...65535).contains(port), !text.isEmpty,
              !text.contains(where: { $0.isWhitespace }),
              !text.contains("/"), !text.contains("@"), !text.contains("?"), !text.contains("#"),
              let url = DiscoveredHost.url(host: text, port: port) else { return nil }
        return HostCandidate(id: url.absoluteString, name: text, hostIDSuffix: nil,
                             address: "\(text):\(port)", url: url)
    }
}

// MARK: - Views

/// A-32: 58 pt, two lines, a state chip on the trailing edge.
struct HostRow: View {
    let candidate: HostCandidate
    var trailing: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HostGlyphView(glyph: "\u{f108}", fallbackSymbol: "desktopcomputer", size: 18)
                    .foregroundStyle(candidate.pairing == .new ? OmodachiTheme.dimText : OmodachiTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(OmodachiTheme.font("heading"))
                        .foregroundStyle(OmodachiTheme.text)
                        .lineLimit(1)
                    Text(candidate.secondLine)
                        .font(OmodachiTheme.font(size: 11))
                        .foregroundStyle(OmodachiTheme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                StateChip(text: trailing ?? candidate.statusLabel, kind: candidate.pairing)
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(height: ConnectionParts.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("host-row-\(candidate.id)")
    }
}

struct StateChip: View {
    let text: String
    var kind: HostPairingState = .new

    private var color: Color {
        switch kind {
        case .new: OmodachiTheme.muted
        case .paired: OmodachiTheme.success
        // Not green: nothing has confirmed it yet. Not red either: nothing is
        // wrong, there is just one tap left to make.
        case .unconfirmed: OmodachiTheme.accent
        case .certificateChanged: OmodachiTheme.danger
        }
    }

    var body: some View {
        Text(text)
            .font(OmodachiTheme.font(size: 11))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Rectangle().stroke(color.opacity(0.5), lineWidth: OmodachiTheme.controlBorderWidth))
    }
}

/// A-33: the explanation block inside the list, 22/12 padding, 13 pt body over
/// an 11 pt sub-line at .52.
struct EmptyBlock: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(OmodachiTheme.bodyFont(size: 13))
                .foregroundStyle(OmodachiTheme.text)
            Text(detail)
                .font(OmodachiTheme.bodyFont(size: 11))
                .foregroundStyle(OmodachiTheme.tertiaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 22)
    }
}

struct GroupLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(OmodachiTheme.font(size: 11))
            .foregroundStyle(OmodachiTheme.secondaryText)
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one button shape this flow uses. A ghost variant is the same control
/// without the fill, never a smaller hit area (A-01).
struct FlowButton: View {
    let title: String
    var kind: Kind = .primary
    var enabled = true
    let action: () -> Void

    enum Kind { case primary, secondary, ghost, danger }

    private var foreground: Color {
        switch kind {
        case .primary: OmodachiTheme.selectedText
        case .secondary: OmodachiTheme.text
        case .ghost: OmodachiTheme.muted
        case .danger: OmodachiTheme.danger
        }
    }
    private var fill: Color {
        switch kind {
        case .primary: OmodachiTheme.selectedFill
        case .secondary: OmodachiTheme.normalFill
        case .ghost, .danger: .clear
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OmodachiTheme.font(size: 13))
                .foregroundStyle(enabled ? foreground : OmodachiTheme.dimText)
                .padding(.horizontal, 12)
                .frame(minHeight: ConnectionParts.actionHeight)
                .frame(maxWidth: .infinity)
                .background(fill)
                .overlay(Rectangle().stroke(kind == .danger ? OmodachiTheme.danger.opacity(0.6) : OmodachiTheme.controlBorder,
                                            lineWidth: OmodachiTheme.controlBorderWidth))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A-36: eight hex digits in two groups of four, monospace 18. The other 56 do
/// not go on screen; the question is "are these the same", not "is this right".
struct FingerprintText: View {
    let fingerprint: String
    var color: Color = OmodachiTheme.text

    static func short(_ value: String) -> String {
        let head = value.prefix(8)
        guard head.count == 8 else { return String(head) }
        return "\(head.prefix(4)) \(head.suffix(4))"
    }

    var body: some View {
        Text(Self.short(fingerprint))
            .font(OmodachiTheme.font(size: 18))
            .foregroundStyle(color)
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
    }
}

struct FlowRule: View {
    var body: some View {
        Rectangle()
            .fill(OmodachiTheme.border.opacity(0.35))
            .frame(height: OmodachiTheme.controlBorderWidth)
    }
}
