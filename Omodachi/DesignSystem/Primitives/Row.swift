import SwiftUI

/// The three row heights this app has, and no fourth.
///
/// They come from the host's own menu: `Menu.qml 99–115` draws an action row at
/// 50 and a detail row (two lines, A-19) at 58, and the shell's `[spacing]`
/// puts a plain list line at 44. Study 01 §01 and A-18 keep all three constant
/// across devices — only the *number* of rows on screen changes — so a surface
/// picks a height by naming what the row is, never by writing a number.
enum RowHeight {
    /// A plain line: a settings value, a group action, a header.
    static let line: CGFloat = NativeBarMetrics.hit
    /// A menu or pinned row: 36 glyph box, one label (`Menu.qml 99–115`).
    static let action: CGFloat = 50
    /// A-19: two lines, the second one at `body-small` and dimmed.
    static let detail: CGFloat = 58
}

/// One tappable row. The glyph column is 36 wide whatever is in it (A-05), the
/// label never wraps, and the trailing slot is for a chevron, a checkmark, a
/// key block or nothing.
///
/// A-65: the row's own words are its accessibility label; its second line is
/// the value. The glyph is hidden, because an icon name read aloud is noise.
struct Row<Trailing: View>: View {
    let title: String
    /// A-19's second line. `nil` makes this a 50-high action row.
    var detail: String?
    var icon: (symbol: String, nerd: String)?
    /// The host's own glyph for this row, when it published one.
    var hostGlyph: String = ""
    var hostIconFont: String = ""
    /// What to draw when the host glyph cannot be drawn.
    var fallbackSymbol: GlyphFallback = "circle"
    var enabled = true
    var selected = false
    /// A-05: 18pt per level plus the 1px rule the study draws at the row's edge.
    var depth = 0
    var identifier: String?
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    private var height: CGFloat { detail == nil ? RowHeight.action : RowHeight.detail }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle().fill(OmodachiTheme.text.opacity(0.25))
                    .frame(width: 1, height: height)
                    .padding(.trailing, 17)
                    .accessibilityHidden(true)
            }
            Tap(selected: selected, enabled: enabled, action: action) { label }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(detail ?? "")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(identifier ?? "row-\(title)")
            trailing()
        }
    }

    private var label: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            glyph
            VStack(alignment: .leading, spacing: OmodachiTheme.space("label-gap")) {
                Text(title)
                    .font(OmodachiTheme.font(detail == nil ? "heading" : "title"))
                    .kerning(-0.2)
                    .foregroundStyle(enabled ? OmodachiTheme.text : OmodachiTheme.muted)
                    .lineLimit(1).truncationMode(.tail)
                if let detail {
                    Text(detail)
                        .font(OmodachiTheme.font("body-small"))
                        .foregroundStyle(OmodachiTheme.tertiaryText)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: OmodachiTheme.space("sm"))
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// `.row .gl` — a 36 box inside the row, whatever it ends up holding.
    @ViewBuilder private var glyph: some View {
        Group {
            if let icon {
                Glyph(icon)
            } else {
                HostGlyphView(glyph: hostGlyph, iconFont: hostIconFont,
                              fallbackSymbol: fallbackSymbol, size: OmodachiTheme.fontSize("icon"))
            }
        }
        .foregroundStyle(enabled ? OmodachiTheme.text : OmodachiTheme.muted)
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }
}

extension Row where Trailing == EmptyView {
    init(title: String, detail: String? = nil, icon: (symbol: String, nerd: String)? = nil,
         hostGlyph: String = "", hostIconFont: String = "", fallbackSymbol: GlyphFallback = "circle",
         enabled: Bool = true, selected: Bool = false, depth: Int = 0,
         identifier: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, icon: icon, hostGlyph: hostGlyph,
                  hostIconFont: hostIconFont, fallbackSymbol: fallbackSymbol,
                  enabled: enabled, selected: selected, depth: depth,
                  identifier: identifier, action: action, trailing: { EmptyView() })
    }
}

/// A 44-high name/value line: what a setting is, and what it is set to.
struct ValueLine: View {
    let name: String
    let value: String
    var identifier: String?
    /// UX-4 §2. A value that is *wrong* rather than merely informational —
    /// the host's fingerprint when it is not this device's. Nothing else in
    /// Settings needs it, and a row that is red for any other reason would
    /// make this one stop meaning anything.
    var wrong = false

    var body: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            Text(name)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.secondaryText)
            Spacer(minLength: OmodachiTheme.space("lg"))
            Text(value)
                .font(OmodachiTheme.font("subtitle"))
                .foregroundStyle(wrong ? OmodachiTheme.danger : OmodachiTheme.text)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier(identifier ?? "value-\(name)")
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .frame(minHeight: RowHeight.line)
    }
}
