import SwiftUI

/// SETTINGS-LAYOUT-1. The one shape of a row in Settings ⑥ and its sub-pages.
///
/// Before it there were six: a stacked "label over control" row whose doc said
/// it went side by side on a wide column (it never did — ARCH-1 added the
/// `narrow` flag and only ever used it to cap the control's width), a switch
/// row, a name/value line with the name *smaller* than its value, the menu's
/// `Row`, onboarding's `EntryRow`, and two hand-built ones. Leo: "some are
/// side by side and some are stacked, with no visible reason". The rule is now
/// one, and it is the arrangement a row asks for, never the device:
///
/// * `.beside` — a switch, a short value, a single action. Title left, the
///   thing on the right, on every width.
/// * `.fitting` — a choice (a segmented control, a slider) or a value of no
///   fixed length. Beside the title when the control fits there at its own
///   natural width; otherwise under the title, left-aligned with it. Measured
///   by `ViewThatFits`, so it is the column that decides.
/// * `.under` — a long value: a fingerprint, an id, a URL. Always under.
///
/// Whatever the arrangement, a detail line sits under the title (never beside
/// it), the title is `subtitle` in the text colour, the detail `body-small`
/// in the tertiary colour, and every row has the same insets.
enum SettingArrangement {
    case beside, fitting, under
}

/// What a row's leading glyph is, when it has one: one of the app's own icons,
/// or a host glyph code point with its SF fallback.
enum SettingGlyph {
    case icon((symbol: String, nerd: String))
    case host(glyph: String, fallbackSymbol: GlyphFallback)
}

/// The type and spacing every Settings row shares, in one place.
@MainActor enum SettingMetrics {
    static var titleFont: Font { OmodachiTheme.font("subtitle") }
    static var detailFont: Font { OmodachiTheme.bodyFont("body-small") }
    static var valueFont: Font { OmodachiTheme.font("subtitle") }
    static var verticalPadding: CGFloat { OmodachiTheme.space("md") }
    /// Between the title column and what sits beside it, or under it.
    static var gap: CGFloat { OmodachiTheme.space("lg") }
    /// A choice under its title on a wide column stops here (A-56).
    static let underControlWidth: CGFloat = 420
    static let glyphBox: CGFloat = 28
}

extension VerticalAlignment {
    /// The title's own line: what a switch or a value centres on when it sits
    /// beside a title that has a detail line under it.
    private enum SettingTitleLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let settingTitleLine = VerticalAlignment(SettingTitleLine.self)
}

/// A title and, under it, its detail line. The detail never widens the row: it
/// takes the width the title column is given and wraps in it, so a long
/// explanation can never be what pushes a control under its title.
struct SettingTitle: View {
    let title: String
    var detail: String?
    /// `<row identifier>-title`, so a test can measure where the title is.
    var identifier: String?
    var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("label-gap")) {
            Text(title)
                .font(SettingMetrics.titleFont)
                .foregroundStyle(enabled ? OmodachiTheme.text : OmodachiTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(.settingTitleLine) { $0[VerticalAlignment.center] }
                .modifier(TitleIdentifier(identifier: identifier))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(SettingMetrics.detailFont)
                    .foregroundStyle(OmodachiTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TitleIdentifier: ViewModifier {
    let identifier: String?
    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier("\(identifier)-title") } else { content }
    }
}

/// One Settings row: an optional leading glyph, the title (and detail), and
/// the trailing thing in the arrangement the row asks for.
struct SettingLine<Trailing: View>: View {
    let title: String
    var detail: String?
    var arrangement: SettingArrangement = .beside
    var leading: SettingGlyph?
    /// Names the title `<identifier>-title`; the trailing control keeps its own.
    var identifier: String?
    var enabled = true
    /// `false` for a row placed inside something that already has the insets
    /// (a card, or a caller that pads it — `SquareToggleRow`'s callers).
    var inset = true
    /// `false` where the narrow column would only waste the width (A-56).
    var narrow = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .settingTitleLine, spacing: SettingMetrics.gap) {
            if let leading { glyph(leading) }
            switch arrangement {
            case .beside: beside
            case .under: under
            case .fitting:
                ViewThatFits(in: .horizontal) {
                    beside
                    under
                }
            }
        }
        .padding(.horizontal, inset ? OmodachiTheme.rowPaddingX : 0)
        .padding(.vertical, SettingMetrics.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: RowHeight.line, alignment: .leading)
    }

    /// The trailing thing at its natural width, which is also what
    /// `ViewThatFits` measures against the column.
    private var beside: some View {
        HStack(alignment: .settingTitleLine, spacing: SettingMetrics.gap) {
            SettingTitle(title: title, detail: detail, identifier: identifier, enabled: enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
                .fixedSize()
                // The title's line centres on the control's first row: the
                // whole of a switch or a single control (44 high), the top
                // row of a taller one, the middle of a line of text.
                .alignmentGuide(.settingTitleLine) { min($0.height / 2, RowHeight.line / 2) }
        }
    }

    private var under: some View {
        VStack(alignment: .leading, spacing: SettingMetrics.gap) {
            SettingTitle(title: title, detail: detail, identifier: identifier, enabled: enabled)
            trailing()
                .frame(maxWidth: narrow ? .infinity : SettingMetrics.underControlWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func glyph(_ glyph: SettingGlyph) -> some View {
        Group {
            switch glyph {
            case .icon(let icon): Glyph(icon)
            case .host(let code, let fallback): HostGlyphView(glyph: code, fallbackSymbol: fallback, size: 16)
            }
        }
        .foregroundStyle(enabled ? OmodachiTheme.text : OmodachiTheme.muted)
        .frame(width: SettingMetrics.glyphBox)
        .alignmentGuide(.settingTitleLine) { $0[VerticalAlignment.center] }
        .accessibilityHidden(true)
    }
}

extension SettingLine where Trailing == EmptyView {
    /// A row that only says something: a title and its detail.
    init(title: String, detail: String? = nil, leading: SettingGlyph? = nil, identifier: String? = nil) {
        self.init(title: title, detail: detail, arrangement: .beside, leading: leading,
                  identifier: identifier, trailing: { EmptyView() })
    }
}

/// A name and what it is set to. Short values sit beside the name when they
/// fit (`.fitting`); a fingerprint, an id or a URL asks for `.under`, where it
/// may take two lines and can be selected.
struct SettingValue: View {
    let name: String
    let value: String
    var identifier: String?
    var arrangement: SettingArrangement = .fitting
    /// UX-4 §2. A value that is *wrong* rather than merely informational —
    /// the host's fingerprint when it is not this device's.
    var wrong = false

    var body: some View {
        SettingLine(title: name, arrangement: arrangement, identifier: identifier, narrow: true) {
            Text(verbatim: value)
                .font(SettingMetrics.valueFont)
                .foregroundStyle(wrong ? OmodachiTheme.danger : OmodachiTheme.secondaryText)
                .lineLimit(arrangement == .under ? 2 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier ?? "value-\(name)")
        }
    }
}

/// A single action: the row is the button, a chevron (or the caller's glyph)
/// on the right says it leads somewhere.
///
/// A-65: the title is the label and the detail the value, unless the caller
/// says the value is something else (`value:`) or sets its own afterwards.
struct SettingAction: View {
    let title: String
    var detail: String?
    var leading: SettingGlyph?
    var trailing: (symbol: String, nerd: String) = Icon.chevronRight
    var selected = false
    var identifier: String
    var value: String?
    let action: () -> Void

    var body: some View {
        Tap(selected: selected, action: action) {
            SettingLine(title: title, detail: detail, leading: leading) {
                Glyph(trailing, step: "icon-small")
                    .foregroundStyle(OmodachiTheme.accent)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .modifier(OptionalValue(value: value))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }

    private struct OptionalValue: ViewModifier {
        let value: String?
        func body(content: Content) -> some View {
            if let value { content.accessibilityValue(value) } else { content }
        }
    }
}
