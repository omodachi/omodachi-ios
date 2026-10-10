import SwiftUI

/// LINKS-1 §3. An agent's answer as blocks: headings, paragraphs, lists,
/// quotes, code kept as a block in the host mono, tables kept in their columns.
///
/// Prose is the platform text face at the message step (A-07); machine text —
/// code, tables, paths — is the host's mono. Every link is a `.link` on the
/// text, so a tap goes to the `openURL` the surface installed (`LinkOpener`):
/// a path rides as `omodachi-link://path?t=…` (`LinkCarrier`) and never
/// reaches iOS as a file URL. A picture is its alt text and its path as a link;
/// nothing is fetched (the phone does not view host files). Prose is not
/// `textSelection`-enabled: on iOS 27 that made a link inside a list item
/// swallow its tap; code blocks, which hold no links, stay selectable.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]
    /// The prose step: the Agent panel's message size.
    var step = "title"

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("lg")) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, step: step)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let step: String
    /// AGENT-COLLIE-1: what Find is looking for, marked where it occurs.
    @Environment(\.findHighlight) private var query

    var body: some View {
        switch block {
        case .heading(let level, let inlines):
            Text(FindHighlight.mark(MarkdownInlineText.attributed(inlines, step: step), query))
                .font(OmodachiTheme.bodyFont(level <= 2 ? "heading" : step, weight: level == 1 ? .bold : .semibold))
                .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let inlines):
            Text(FindHighlight.mark(MarkdownInlineText.attributed(inlines, step: step), query))
                .font(OmodachiTheme.bodyFont(step))
                .fixedSize(horizontal: false, vertical: true)
        case .list(let start, let items):
            VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: OmodachiTheme.space("md")) {
                        Text(verbatim: start.map { "\($0 + offset)." } ?? "•")
                            .font(OmodachiTheme.bodyFont(step))
                            .foregroundStyle(OmodachiTheme.secondaryText)
                            .accessibilityHidden(start == nil)
                        MarkdownText(blocks: item, step: step)
                    }
                }
            }
        case .quote(let inner):
            HStack(alignment: .top, spacing: OmodachiTheme.space("xl")) {
                Rectangle().fill(OmodachiTheme.border)
                    .frame(width: OmodachiTheme.popupBorderWidth)
                    .accessibilityHidden(true)
                MarkdownText(blocks: inner, step: step)
                    .foregroundStyle(OmodachiTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            MarkdownCodeBlock(text: text, query: query)
        case .table(let text):
            MarkdownCodeBlock(text: text, query: query)
        case .rule:
            Rectangle().fill(OmodachiTheme.border)
                .frame(height: NativeBarMetrics.edgeRule)
                .accessibilityHidden(true)
        }
    }
}

/// A fenced block: its own lines, never wrapped, scrolled sideways, and
/// selectable — the shape ATTACH-2 found squeezed into one line.
private struct MarkdownCodeBlock: View {
    let text: String
    var query = ""

    var body: some View {
        ScrollView(.horizontal) {
            Text(FindHighlight.mark(AttributedString(text), query))
                .font(OmodachiTheme.font("body"))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(OmodachiTheme.space("xl"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmodachiTheme.normalFill)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
        .accessibilityIdentifier("agent-code-block")
    }
}

/// Inline marks as one `AttributedString`, so a paragraph wraps as a paragraph
/// and its links stay tappable inside it.
@MainActor enum MarkdownInlineText {
    static func attributed(_ inlines: [MarkdownInline], step: String) -> AttributedString {
        var result = AttributedString()
        for node in inlines { result += piece(node, step: step) }
        return result
    }

    private static func piece(_ node: MarkdownInline, step: String) -> AttributedString {
        switch node {
        case .text(let value):
            return AttributedString(value)
        case .lineBreak:
            return AttributedString("\n")
        case .code(let value, let target):
            var code = AttributedString(value)
            code.font = OmodachiTheme.font(step == "title" ? "body" : step)
            code.backgroundColor = OmodachiTheme.normalFill
            if let target, let url = LinkCarrier.url(forRaw: target) {
                code.link = url
                code.foregroundColor = OmodachiTheme.accent
            }
            return code
        case .strong(let inner):
            var value = attributed(inner, step: step)
            value.inlinePresentationIntent = .stronglyEmphasized
            return value
        case .emphasis(let inner):
            var value = attributed(inner, step: step)
            value.inlinePresentationIntent = .emphasized
            return value
        case .link(let inner, let target):
            var value = attributed(inner, step: step)
            if let url = LinkCarrier.url(forRaw: target) {
                value.link = url
                value.foregroundColor = OmodachiTheme.accent
                value.underlineStyle = .single
            }
            return value
        case .image(let alt, let target):
            // The picture's words, then its file — which opens on the computer.
            var value = AttributedString(alt.isEmpty ? "" : alt + " · ")
            var path = AttributedString(target)
            path.font = OmodachiTheme.font(step == "title" ? "body" : step)
            if let url = LinkCarrier.url(forRaw: target) {
                path.link = url
                path.foregroundColor = OmodachiTheme.accent
                path.underlineStyle = .single
            }
            value += path
            return value
        }
    }
}

/// LINKS-1: what a tapped link is doing, or why it could not — one sentence,
/// and "Open on the computer" beside a page the phone could not reach. It sits
/// over whichever panel the link came from, under that panel's header
/// (POLISH-U), so it is opaque: the panel's own ground under the fill.
///
/// The sentence has the whole width and the action goes on the line under it:
/// side by side, a phone left the sentence five lines tall and cut the button
/// to "Open on the co…".
struct LinkNoticeBar: View {
    enum Kind { case working, info, problem }
    let kind: Kind
    let text: String
    var actionTitle: String?
    var action: () -> Void = {}
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: OmodachiTheme.space("lg")) {
                switch kind {
                case .working: ProgressView().controlSize(.small)
                case .info: Glyph(symbol: "info.circle", points: OmodachiTheme.fontSize("caption")) // non-copy: a glyph name
                    .foregroundStyle(OmodachiTheme.secondaryText)
                case .problem: Glyph(Icon.warning, step: "icon-small").foregroundStyle(OmodachiTheme.warning)
                }
                Text(text)
                    .font(OmodachiTheme.bodyFont("subtitle"))
                    .foregroundStyle(OmodachiTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("link-notice-text")
                Tap(action: dismiss) {
                    Glyph(symbol: "xmark", points: OmodachiTheme.fontSize("caption")) // non-copy: a glyph name
                        .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Strings.actionDismiss)
                .accessibilityIdentifier("link-notice-dismiss")
            }
            if let actionTitle {
                TextTap(actionTitle, bordered: true, action: action)
                    .fixedSize()
                    .padding(.bottom, OmodachiTheme.space("lg"))
                    .accessibilityIdentifier("link-notice-open-on-computer")
            }
        }
        .padding(.leading, OmodachiTheme.space("xl"))
        .background(OmodachiTheme.normalFill)
        .background(OmodachiTheme.background)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link-notice")
    }
}

/// POLISH-U: where in a panel the link notice may lie - the top of the content
/// the link was tapped in, never the panel's header or its navigation. A panel
/// marks it with `linkNoticeRegion()`; the Shell reads it (`linkNotice`).
struct LinkNoticeRegionKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Marks this view as the region the link notice lies at the top of.
    func linkNoticeRegion() -> some View {
        anchorPreference(key: LinkNoticeRegionKey.self, value: .bounds) { $0 }
    }
}

// MARK: - AGENT-COLLIE-1: find highlights

private struct FindHighlightKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// The words Find is looking for in the Agent conversation; empty when
    /// Find is closed. Text drawn under it marks every place they occur.
    var findHighlight: String {
        get { self[FindHighlightKey.self] }
        set { self[FindHighlightKey.self] = newValue }
    }
}

/// Marks every case-insensitive occurrence of a query in a text with the
/// accent behind it (Collie `splitHighlight`). A substring, never a pattern.
@MainActor enum FindHighlight {
    static func mark(_ text: AttributedString, _ query: String) -> AttributedString {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }
        var marked = text
        var start = marked.startIndex
        while start < marked.endIndex,
              let found = marked[start...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive,
                                                                       .widthInsensitive]) {
            marked[found].backgroundColor = OmodachiTheme.accent.opacity(0.35)
            guard found.upperBound > start else { break }
            start = found.upperBound
        }
        return marked
    }
    static func mark(_ text: String, _ query: String) -> AttributedString { mark(AttributedString(text), query) }
}
