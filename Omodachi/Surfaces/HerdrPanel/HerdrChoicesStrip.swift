import SwiftUI

/// HERDR-9. The pane's own choices, as buttons, right above the composer:
/// codex's approval, a selection list, Claude's permission prompt, a `(y/n)`.
///
/// ```
/// ┌──────────────────────────────────────────┐
/// │ The pane is waiting for your answer.  Esc │
/// │ 1  Yes, proceed                        ›  │  ← marked on the pane
/// │ 2  Yes, and don't ask again for …         │  ← dimmer: it outlives this
/// │ 3  No, and tell Codex what to do …        │
/// └──────────────────────────────────────────┘
/// ```
///
/// Each button is the option's own words on one line, in the pane's order;
/// the row the pane has marked carries the marker; a choice that keeps
/// applying ("don't ask again") is drawn dimmer and never as the main one. A
/// tap sends what that program takes (the store reads the screen again first
/// and refuses a question that changed). The strip goes the moment the
/// question leaves the screen, in every mirror mode, because it is read from
/// the same grid. Collie's `prompt-select-block` / `option-button` are the
/// model (AltanS/collie, MIT), redrawn in this app's primitives.
struct HerdrChoicesStrip: View {
    @ObservedObject var store: HerdrStore
    let choices: HerdrChoices
    @Environment(\.horizontalSizeClass) private var horizontal
    /// A phone on its side: one row that scrolls sideways, so the mirror
    /// keeps its few rows (with the keyboard up there are not many).
    @Environment(\.verticalSizeClass) private var vertical

    /// More options than this scroll inside the strip, so a long picker never
    /// pushes the composer off the screen.
    private static let visibleRows: CGFloat = 4.5

    var body: some View {
        Group {
            if vertical == .compact { row } else { column }
        }
        .background(OmodachiTheme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(OmodachiTheme.accent).frame(height: 2).accessibilityHidden(true)
        }
        .disabled(store.choicesAnswered)
        .opacity(store.choicesAnswered ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.herdrChoicesTitle)
        .accessibilityIdentifier("herdr-choices")
    }

    /// Landscape on a phone: every option in one sideways row.
    private var row: some View {
        ScrollView(.horizontal) {
            HStack(spacing: OmodachiTheme.space("xs")) {
                ForEach(choices.options) { choice in
                    let title = choices.kind == .yesNo ? (choice.index == 0 ? Strings.herdrChoicesYes : Strings.herdrChoicesNo)
                        : choice.number.map { "\($0) \(choice.label)" } ?? choice.label
                    Tap(selected: choice.highlighted && !choice.lasting, bordered: true, action: { store.answer(choice) }) {
                        Text(verbatim: title)
                            .font(OmodachiTheme.font("body-small"))
                            .foregroundStyle(choice.lasting ? OmodachiTheme.secondaryText : OmodachiTheme.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 260)
                            .padding(.horizontal, OmodachiTheme.space("md"))
                            .frame(minHeight: OmodachiTheme.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .frame(minHeight: NativeBarMetrics.hit)
                    .accessibilityLabel(choices.kind == .yesNo ? title : choice.label)
                    .accessibilityValue(value(choice))
                    .accessibilityHint(Strings.herdrChoicesHint)
                    .accessibilityIdentifier("herdr-choice-\(choice.index)")
                }
                if choices.escape {
                    TextTap(Strings.herdrKeyEscape, bordered: true, minimumHeight: OmodachiTheme.controlHeight,
                            action: store.answerEscape)
                        .frame(minHeight: NativeBarMetrics.hit)
                        .accessibilityHint(Strings.herdrChoicesEscapeHint)
                        .accessibilityIdentifier("herdr-choices-escape")
                }
            }
            .padding(.horizontal, OmodachiTheme.space("sm"))
        }
        .scrollIndicators(.visible)
        .frame(height: NativeBarMetrics.hit)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch choices.kind {
            case .yesNo:
                yesNo
            case .menu:
                if choices.options.count > Int(Self.visibleRows) {
                    ScrollView { options }
                        .frame(maxHeight: Self.visibleRows * NativeBarMetrics.hit)
                        .scrollIndicators(.visible)
                } else {
                    options
                }
            }
        }
        .padding(.bottom, OmodachiTheme.space("sm"))
    }

    private var header: some View {
        HStack(spacing: OmodachiTheme.space("md")) {
            Text(store.choicesAnswered ? Strings.herdrChoicesAnswered : Strings.herdrChoicesTitle)
                .font(OmodachiTheme.font("caption", weight: .semibold))
                .foregroundStyle(store.choicesAnswered ? OmodachiTheme.secondaryText : OmodachiTheme.accent)
                .lineLimit(1)
                .accessibilityIdentifier("herdr-choices-title")
            Spacer(minLength: 0)
            if choices.escape {
                TextTap(Strings.herdrKeyEscape, step: "caption", bordered: true,
                        minimumHeight: OmodachiTheme.controlHeight, action: store.answerEscape)
                    .frame(minHeight: NativeBarMetrics.hit)
                    .accessibilityHint(Strings.herdrChoicesEscapeHint)
                    .accessibilityIdentifier("herdr-choices-escape")
            }
        }
        .padding(.leading, OmodachiTheme.rowPaddingX)
        .padding(.trailing, OmodachiTheme.space("md"))
        .frame(minHeight: 32)
    }

    private var options: some View {
        VStack(spacing: 0) {
            ForEach(choices.options) { choice in
                optionRow(choice)
            }
        }
    }

    private func optionRow(_ choice: HerdrChoice) -> some View {
        Tap(selected: choice.highlighted && !choice.lasting, action: { store.answer(choice) }) {
            HStack(spacing: OmodachiTheme.space("md")) {
                Text(verbatim: choice.number.map(String.init) ?? "·")
                    .font(OmodachiTheme.font("caption", weight: .semibold))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .frame(minWidth: 18, alignment: .trailing)
                    .accessibilityHidden(true)
                Text(verbatim: choice.label)
                    .font(OmodachiTheme.font("body-small", weight: choice.highlighted && !choice.lasting ? .semibold : .regular))
                    .foregroundStyle(choice.lasting ? OmodachiTheme.secondaryText : OmodachiTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if choice.highlighted {
                    Text(verbatim: "›")
                        .font(OmodachiTheme.font("body", weight: .semibold))
                        .foregroundStyle(choice.lasting ? OmodachiTheme.secondaryText : OmodachiTheme.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(minHeight: NativeBarMetrics.hit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(choice.label)
        .accessibilityValue(value(choice))
        .accessibilityHint(Strings.herdrChoicesHint)
        .accessibilityAddTraits(choice.highlighted ? [.isSelected] : [])
        .accessibilityIdentifier("herdr-choice-\(choice.index)")
    }

    private func value(_ choice: HerdrChoice) -> String {
        var parts: [String] = []
        if choice.highlighted { parts.append(Strings.herdrChoicesSelected) }
        if choice.lasting { parts.append(Strings.herdrChoicesLasting) }
        return parts.joined(separator: " ")
    }

    private var yesNo: some View {
        HStack(spacing: OmodachiTheme.space("md")) {
            ForEach(choices.options) { choice in
                let title = choice.index == 0 ? Strings.herdrChoicesYes : Strings.herdrChoicesNo
                Tap(selected: choice.highlighted, bordered: true, action: { store.answer(choice) }) {
                    Text(title)
                        .font(OmodachiTheme.font("body", weight: .semibold))
                        .foregroundStyle(OmodachiTheme.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: NativeBarMetrics.hit)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel(title)
                    .accessibilityHint(Strings.herdrChoicesHint)
                    .accessibilityValue(choice.highlighted ? Strings.herdrChoicesSelected : "")
                    .accessibilityIdentifier("herdr-choice-\(choice.index)")
            }
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
    }
}

/// HERDR-9. The keys that just went to the pane, for a moment (`y ↵ ⌫`), at
/// the bottom corner of the mirror: so Type, the empty composer's keys and a
/// tapped choice each show that they arrived. It lies over the mirror and
/// moves nothing (Collie's key-queue strip, adapted: there is no queue here,
/// every key is already sent).
struct HerdrKeyEchoStrip: View {
    let echo: [HerdrKeyEcho]
    let spoken: String

    var body: some View {
        if !echo.isEmpty {
            HStack(spacing: OmodachiTheme.space("sm")) {
                ForEach(echo) { key in
                    Text(verbatim: key.face)
                        .font(OmodachiTheme.font("body-small", weight: .semibold))
                        .foregroundStyle(OmodachiTheme.text)
                        .lineLimit(1)
                        .padding(.horizontal, OmodachiTheme.space("sm"))
                        .frame(minHeight: 24)
                        .background(OmodachiTheme.normalFill)
                }
            }
            .padding(OmodachiTheme.space("sm"))
            .background(OmodachiTheme.background.opacity(0.9))
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.herdrEchoLabel(spoken))
            .accessibilityIdentifier("herdr-echo")
        }
    }
}
