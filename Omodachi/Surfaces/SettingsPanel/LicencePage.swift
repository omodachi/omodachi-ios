import SwiftUI

/// STORE-2 §4. What `Licence · GPL-3.0` opens, inside ⑥ and under its row.
///
/// Both halves come out of the bundle (`LicenceNotice`): the component list is
/// THIRD-PARTY.md's two tables, and the text is the repository's LICENSE. The
/// text is shown whole and verbatim, in the same scrolling block the
/// diagnostics use, so it can also be copied out.
struct LicencePage: View {
    private let components = LicenceNotice.components()
    private let text = LicenceNotice.licenceText() ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            note(Strings.licenceCombined)
            GroupLabel(text: Strings.licenceComponents)
            note(Strings.licenceComponentsNote)
            if components.isEmpty {
                note(Strings.licenceUnreadable)
            }
            ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: component.name)
                        .font(OmodachiTheme.font("subtitle"))
                        .foregroundStyle(OmodachiTheme.text)
                    Text(verbatim: component.licence)
                        .font(OmodachiTheme.bodyFont("body-small"))
                        .foregroundStyle(OmodachiTheme.tertiaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: RowHeight.line, alignment: .leading)
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("licence-component-\(index)")
            }
            DiagnosticBlock(title: Strings.licenceFullText, text: text,
                            copyTitle: Strings.settingsDiagnosticsCopy,
                            copiedTitle: Strings.settingsDiagnosticsCopied,
                            emptyTitle: Strings.licenceUnreadable,
                            identifier: "licence-text", maxHeight: 420)
        }
        .padding(.bottom, OmodachiTheme.space("xxl"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("licence-page")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont("body-small"))
            .foregroundStyle(OmodachiTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.vertical, OmodachiTheme.space("xl"))
    }
}
