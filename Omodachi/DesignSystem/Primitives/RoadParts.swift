import SwiftUI

/// TAIL-3b. The pieces of the Tailscale first screen, the Wi-Fi road and the
/// road line, drawn from the same tokens as the rest of the connection flow
/// (`ConnectionParts`). Nothing here decides anything; it draws what it is given.

/// The computer's name, with Paste inside the same box (S01–S03, L03).
///
/// Paste is the system's `PasteButton`: reading the pasteboard from a tap on
/// it needs no "Allow Paste" question, where `UIPasteboard` from an ordinary
/// button asks every time. Its title is the system's own, in the system's
/// language.
struct NameField: View {
    /// What a MagicDNS name looks like, as the field's placeholder. Not a
    /// word to translate: it is the shape of the thing to paste.
    static let example = "omarchy.tail…ts.net"
    @Binding var text: String
    var placeholder = NameField.example
    var focused: FocusState<Bool>.Binding
    var fieldIdentifier = "connect-ts-field"
    var pasteIdentifier = "connect-ts-paste"
    var onSubmit: () -> Void = {}
    let onPaste: (String?) -> Void

    var body: some View {
        HStack(spacing: 0) {
            TextField(placeholder, text: $text)
                .font(OmodachiTheme.font(size: 16))
                .foregroundStyle(OmodachiTheme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(onSubmit)
                .focused(focused)
                .accessibilityIdentifier(fieldIdentifier)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: ConnectionParts.actionHeight)
                .textEntryHitArea(focused)
            Rectangle().fill(OmodachiTheme.accent).frame(width: OmodachiTheme.controlBorderWidth)
            PasteButton(payloadType: String.self) { values in
                Task { @MainActor in onPaste(values.first) }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.roundedRectangle(radius: 0))
            .tint(OmodachiTheme.selectedFill)
            .foregroundStyle(OmodachiTheme.accent)
            .padding(.horizontal, 6)
            .accessibilityIdentifier(pasteIdentifier)
        }
        .overlay(Rectangle().stroke(OmodachiTheme.accent, lineWidth: OmodachiTheme.controlBorderWidth)
            .allowsHitTesting(false))
        .padding(.horizontal, 12)
    }
}

/// One short line with a mark: ✓ fine, ! needs doing, → what will happen.
struct StatusLine: View {
    enum Kind { case ok, warn, next, error }
    let text: String
    var kind: Kind = .ok
    var identifier = "status-line"

    private var mark: String {
        switch kind {
        case .ok: "\u{2713}"
        case .warn, .error: "!"
        case .next: "\u{2192}"
        }
    }
    private var color: Color {
        switch kind {
        case .ok, .next: OmodachiTheme.success
        case .warn: OmodachiTheme.warning
        case .error: OmodachiTheme.danger
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: mark).font(OmodachiTheme.font(size: 12)).foregroundStyle(color)
            Text(text)
                .font(OmodachiTheme.bodyFont(size: 12))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// A numbered step (S01 "First time with Tailscale?", S03 "Where is the name").
struct NumberedStep: View {
    let number: Int
    let text: String
    var linkTitle: String?
    var linkIdentifier = "step-link"
    var onLink: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(OmodachiTheme.font(size: 11))
                .foregroundStyle(OmodachiTheme.secondaryText)
                .frame(width: 20, height: 20)
                .overlay(Rectangle().stroke(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(OmodachiTheme.bodyFont(size: 13))
                    .foregroundStyle(OmodachiTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let linkTitle, let onLink {
                    LinkLine(title: linkTitle, identifier: linkIdentifier, action: onLink)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// An accent text link with a chevron: "Where is the name? ›".
struct LinkLine: View {
    let title: String
    var identifier = "link-line"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(OmodachiTheme.bodyFont(size: 13))
                Text(verbatim: "\u{203A}").font(OmodachiTheme.font(size: 13))
            }
            .foregroundStyle(OmodachiTheme.accent)
            .frame(minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// A full-width row that leads somewhere else: "I don't use Tailscale",
/// "Explore the demo", "Use Tailscale for this computer".
struct EntryRow: View {
    let glyph: String
    let fallbackSymbol: GlyphFallback
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Tap(action: action) {
            HStack(spacing: 10) {
                HostGlyphView(glyph: glyph, fallbackSymbol: fallbackSymbol, size: 16)
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(OmodachiTheme.font(size: 13))
                        .foregroundStyle(OmodachiTheme.text)
                    Text(detail)
                        .font(OmodachiTheme.font(size: 11))
                        .foregroundStyle(OmodachiTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HostGlyphView(glyph: "\u{f054}", fallbackSymbol: "chevron.right", size: 11)
                    .foregroundStyle(OmodachiTheme.accent)
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.vertical, 6)
            .frame(minHeight: ConnectionParts.actionHeight)
            .contentShape(Rectangle())
        }
    }
}

/// A problem with a title, a sentence and its exits, behind a warning edge
/// (E01 / E02 in panel ①).
struct NoticeBlock<Actions: View>: View {
    let title: String
    let detail: String
    var identifier = "notice-block"
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(OmodachiTheme.warning).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(OmodachiTheme.bodyFont("subtitle"))
                    .foregroundStyle(OmodachiTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(OmodachiTheme.bodyFont("body-small"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions() }
                    .padding(.top, 4)
            }
            .padding(12)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(OmodachiTheme.normalFill)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// TAIL-3b. A host's road in one coloured word, with what it is dialled at
/// beside it when there is room: blue "Tailscale", yellow "This Wi-Fi only".
struct RoadLine: View {
    let road: HostRoad
    var showsAddress = true
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 6) {
            Text(HostRoadWords.word(road))
                .font(OmodachiTheme.font(size: size))
                .foregroundStyle(road.kind.isTailscale ? OmodachiTheme.accent : OmodachiTheme.warning)
                .fixedSize()
            if showsAddress {
                Text(verbatim: "·").font(OmodachiTheme.font(size: size)).foregroundStyle(OmodachiTheme.dimText)
                Text(verbatim: road.host)
                    .font(OmodachiTheme.font(size: size))
                    .foregroundStyle(OmodachiTheme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HostRoadWords.a11y(road))
    }
}
