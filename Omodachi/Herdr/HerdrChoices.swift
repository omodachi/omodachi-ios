// lint:host-words — the words codex, Claude Code and a shell print on their screens.
import Foundation

/// HERDR-9: the choices a pane is asking for, read off the same screen the
/// mirror shows, so a phone answers them with a tap instead of Type.
///
/// Leo, approving codex from an iPhone: he had to turn on Type, type `y`,
/// could not see that it arrived, and Type stayed on afterwards. Collie
/// (AltanS/collie, MIT) lifts a terminal dialog into buttons; this is the same
/// idea, adapted to one strip above the composer and to the agents Omodachi
/// meets. Ported and adapted from Collie `25468b0`:
/// `web/src/lib/harness/codex/approval.ts` and `codex/ask.ts` (codex's
/// approval and question cards, their footers and wrapped labels),
/// `claude/prompt-select.ts` and `claude/markers.ts` (`classifyFooter`: the
/// footer decides digit-then-Enter vs digit alone; free-text rows are never
/// buttons; a pointed, unnumbered list is walked with the arrows), and
/// `harness/menu-hints.ts` (`pointerWalk`).
///
/// What makes a screen a menu here — the shape, never the words alone, so an
/// ordinary numbered list in an answer or a build log is not one:
///
/// * a **hint footer** (`Press enter to confirm or esc to cancel`, `Enter to
///   select · Esc to cancel`, `enter select · esc back`, `Esc to cancel · Tab
///   to amend`) among the last rows, with nothing but more hints under it;
/// * directly above it, a **contiguous run of options** numbered one apart;
/// * **one** of them carrying the selection marker (`›` or `❯`).
///
/// A `(y/n)` / `[Y/n]` question on the last row is the other shape.
///
/// What a tap sends is what that TUI takes: the option's digit when it is
/// numbered (codex confirms on the digit; Claude's "Enter to select" lists
/// take the digit then Enter), the arrows from the marked row plus Enter when
/// it is not (or past 9); `y` / `n` and Enter for a yes-or-no question.
struct HerdrChoice: Equatable, Sendable, Identifiable {
    var id: Int { index }
    /// Its place in the strip, top to bottom, as on the pane.
    let index: Int
    /// The option's own words, its keyboard hint (`(y)`, `(esc)`) left off.
    let label: String
    /// What the option says after its name (codex's model picker, Claude's
    /// descriptions), when it says anything.
    let detail: String?
    /// Herdr key names, in order (`pane.send_keys`).
    let keys: [String]
    /// The pane's selection marker is on this row.
    let highlighted: Bool
    /// "don't ask again", "for this session": a choice that outlives this
    /// question. Shown as it is, never as the main one.
    let lasting: Bool
    /// The number the pane gives it, when it gives one.
    let number: Int?
    /// HERDR-10: codex's "None of the above" on a question card. A tap walks
    /// the marker to it and opens the card's notes box (Tab), and the
    /// composer takes the note: Return sends it and submits the answer. Its
    /// digit would submit "None of the above" with nothing said.
    var opensNote = false
}

struct HerdrChoices: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Options the pane lists.
        case menu
        /// A `(y/n)` question.
        case yesNo
    }

    let kind: Kind
    /// The question above the options, when one could be read.
    let question: String?
    let options: [HerdrChoice]
    /// The footer offers Esc to cancel or go back.
    let escape: Bool
    /// The region's text, rows joined. A tap compares it with a fresh read:
    /// a different dialog in the same shape is not the one that was seen.
    let signature: String
}

enum HerdrChoiceReader {
    /// The rows of a grid as text, right-trimmed.
    static func rows(_ grid: HerdrGrid) -> [String] {
        grid.rows.map { row in trimEnd(row.map(\.text).joined()) }
    }

    /// The choices at the bottom of `rows`, or nil.
    static func read(_ rows: [String], cursorRow: Int? = nil) -> HerdrChoices? {
        let texts = rows.map(trimEnd)
        guard let end = texts.lastIndex(where: { !isBlank($0) }) else { return nil }
        if let menu = menu(texts, end: end) { return menu }
        return yesNo(texts, end: end, cursorRow: cursorRow)
    }

    /// HERDR-10: codex's question card has its notes box open (the strip's
    /// "None of the above" opens it): the bottom hint reads "tab or esc to
    /// clear notes". What the composer sends then is the note.
    static func notesOpen(_ rows: [String]) -> Bool {
        let texts = rows.map(trimEnd)
        guard let end = texts.lastIndex(where: { !isBlank($0) }) else { return false }
        return texts[max(0, end - 2)...end].contains(where: notesFocused)
    }

    // MARK: - Menus

    /// How many non-blank rows at the bottom may hold the footer: a question
    /// card puts `esc to interrupt` on a row of its own under it.
    private static let footerReach = 3
    /// Rows between the last option and the footer (a blank, a hint line).
    private static let footerGap = 3
    /// How far up an option run may reach.
    private static let optionReach = 40
    private static let questionReach = 12

    private static func menu(_ texts: [String], end: Int) -> HerdrChoices? {
        // The footer: one of the last few non-blank rows. Any rows under it
        // must be hints too, never content.
        var footer = -1
        var seen = 0
        var index = end
        while index >= 0, seen < footerReach {
            let text = texts[index]
            if isBlank(text) { index -= 1; continue }
            if notesFocused(text) { return nil }
            if isFooter(text) { footer = index; break }
            guard isTrailingHint(text) else { break }
            seen += 1
            index -= 1
        }
        guard footer > 0 else { return footerless(texts, end: end) }
        let footerText = texts[footer].lowercased()
        // Above the footer: at most a few blank or hint rows, then options.
        var bottom = footer - 1
        var gap = 0
        while bottom >= 0, gap < footerGap, optionRow(texts[bottom]) == nil, !isPointedPlain(texts[bottom]) {
            guard isBlank(texts[bottom]) || isScrollMark(texts[bottom]) || isHintLine(texts[bottom]) else { break }
            bottom -= 1
            gap += 1
        }
        guard bottom >= 0 else { return nil }
        if optionRow(texts[bottom]) != nil || isContinuation(texts, bottom),
           let menu = numbered(texts, bottom: bottom, footer: footer, footerText: footerText) {
            return menu
        }
        return pointed(texts, bottom: bottom, footer: footer, footerText: footerText)
    }

    private struct OptionRow {
        var row: Int
        let number: Int
        let pointed: Bool
        let column: Int
        var text: String
    }

    /// Claude's WebFetch permission prints no footer: its own question
    /// ("Do you want to …?") over `1. Yes` … `N. No`, the last option on the
    /// last row, the marker on one of them (Collie `namesPermissionDialog`).
    private static func footerless(_ texts: [String], end: Int) -> HerdrChoices? {
        guard let menu = numbered(texts, bottom: end, footer: end, footerText: "") else { return nil }
        guard let first = menu.options.first, let last = menu.options.last,
              first.label.lowercased().hasPrefix("yes"), last.label.lowercased().hasPrefix("no"),
              let question = menu.question, question.hasPrefix("Do you want to"), question.hasSuffix("?") else { return nil } // non-copy: Claude's words
        return menu
    }

    /// A numbered menu: `› 1. Yes, proceed (y)`, `  2. …`, wrapped labels and
    /// description rows under them.
    private static func numbered(_ texts: [String], bottom: Int, footer: Int, footerText: String) -> HerdrChoices? {
        var options: [OptionRow] = []
        var pending: [String] = []
        var sawScroll = false
        var row = bottom
        var floor = max(0, bottom - optionReach)
        while row >= floor {
            let text = texts[row]
            if let option = optionRow(text) {
                var value = option
                value.row = row
                value.text = ([option.text] + pending).joined(separator: "\n")
                pending = []
                options.insert(value, at: 0)
                row -= 1
                continue
            }
            if isScrollMark(text) { sawScroll = true; row -= 1; continue }
            if isRule(text), !options.isEmpty || !pending.isEmpty { row -= 1; continue }
            // A row indented past the digits belongs to the option above it:
            // a wrapped label or its description.
            if !isBlank(text), indent(text) >= 4, optionRow(text) == nil {
                pending.insert(text, at: 0)
                row -= 1
                floor = max(0, floor - 1)
                continue
            }
            break
        }
        // Rows under the last option with no option above them (a wrapped
        // label cut from its row) are not a menu we can read; rows left over
        // above the first option are the dialog's own text.
        guard options.count >= 2, options.last.map({ $0.row }) ?? 0 >= bottom - 8 else { return nil }
        let top = row
        for (offset, option) in options.enumerated() where option.number != options[0].number + offset { return nil }
        guard options.count <= 30 else { return nil }
        // A menu that does not start at 1 must show it scrolled.
        if options[0].number != 1, !sawScroll, !(top >= 0 && isScrollMark(texts[top])) { return nil }
        // Exactly one selection marker: none is a plain list, two is not one.
        let pointedRows = options.filter(\.pointed)
        guard pointedRows.count == 1, let pointedAt = options.firstIndex(where: \.pointed) else { return nil }
        // Checkboxes are a multi-select, which a single tap cannot answer.
        guard !options.contains(where: { checkbox(firstLine($0.text)) }) else { return nil }

        let selectThenEnter = footerText.contains("enter to select")
        // HERDR-10: codex's question card says "tab to add notes" on the
        // footer, or on its own row above it when a narrow pane wraps it.
        let hints = texts[min(bottom + 1, footer)...footer].joined(separator: " ").lowercased()
        let notesCard = hints.contains("tab to add notes")
        var choices: [HerdrChoice] = []
        for (offset, option) in options.enumerated() {
            let lines = option.text.components(separatedBy: "\n")
            let head = lines[0].trimmingCharacters(in: .whitespaces)
            // A free-text row is answered by typing into it, not by a key;
            // while the marker is on it the field has the keyboard and every
            // digit would be typed there, so nothing on this menu is a button.
            if freeText(head) || amendField(head, lines: lines, first: offset == 0, last: offset == options.count - 1) {
                if option.pointed { return nil }
                continue
            }
            // codex's picker writes its description after a run of spaces;
            // Claude puts it on the rows under the label.
            let split = head.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var label = split.first ?? head
            var detail = split.dropFirst().joined(separator: " ")
            let more = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !more.isEmpty {
                // A row indented to the label's own column is the label
                // wrapping (codex, Claude permission rows); deeper is detail.
                // Claude's "Enter to select" lists put a description there.
                if detail.isEmpty, !selectThenEnter, Self.wrapsLabel(lines, option: option) {
                    label = Self.joinWrapped([label] + more)
                } else {
                    detail = Self.joinWrapped([detail] + more)
                }
            }
            label = stripShortcut(label)
            let keys: [String]
            let opensNote = notesCard && label.lowercased() == "none of the above" // non-copy: codex's own words
            if opensNote {
                keys = Array(pointerWalk(from: pointedAt, to: offset).dropLast()) + ["Tab"]
            } else if selectThenEnter, option.number <= 9 {
                keys = [String(option.number), "Enter"]
            } else if option.number <= 9 {
                keys = [String(option.number)]
            } else {
                keys = pointerWalk(from: pointedAt, to: offset)
            }
            choices.append(HerdrChoice(index: choices.count, label: label, detail: detail.isEmpty ? nil : detail,
                                       keys: keys, highlighted: option.pointed, lasting: lasting(label),
                                       number: option.number, opensNote: opensNote))
        }
        guard choices.count >= 1 else { return nil }
        let first = options[0].row
        let question = Self.question(texts, above: first)
        let start = max(0, min(question?.row ?? first, first - questionReach))
        return HerdrChoices(kind: .menu, question: question?.text, options: choices,
                            escape: offersEscape(footerText),
                            signature: texts[start...footer].joined(separator: "\n"))
    }

    /// Lines a narrow pane wrapped, joined back: with a space between words,
    /// with none inside Chinese or Japanese text, which has no spaces to
    /// lose (HERDR-10: "再总" + "结规律" is "再总结规律").
    static func joinWrapped(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if let last = result.last, let first = part.first, !(isWide(last) && isWide(first)) {
                result += " "
            }
            result += part
        }
        return result
    }

    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    private static func wrapsLabel(_ lines: [String], option: OptionRow) -> Bool {
        guard lines.count > 1 else { return false }
        // The label starts after `N. `; a continuation at that column wraps it.
        let labelColumn = option.column + String(option.number).count + 2
        return lines.dropFirst().allSatisfy { indent($0) <= labelColumn + 1 }
    }

    /// A pointed, unnumbered list (Claude's folder-trust prompt since 2.1.278,
    /// Collie ADR 0055): one row marked, the others indented past the marker;
    /// a tap walks the marker there with the arrows and presses Enter.
    private static func pointed(_ texts: [String], bottom: Int, footer: Int, footerText: String) -> HerdrChoices? {
        guard footerText.contains("enter") else { return nil }
        var rows: [(row: Int, label: String, pointed: Bool)] = []
        var pointerIndent = -1
        var row = bottom
        while row >= max(0, bottom - 24) {
            let text = texts[row]
            if isBlank(text) { row -= 1; continue }
            guard optionRow(text) == nil else { return nil }
            let pointed = pointerPrefix(text)
            let lead = indent(text)
            if pointerIndent < 0 {
                pointerIndent = pointed ? lead : lead - 2
                guard pointerIndent >= 0 else { return nil }
            }
            if pointed, lead == pointerIndent {
                rows.insert((row, String(text.dropFirst(lead + 1)).trimmingCharacters(in: .whitespaces), true), at: 0)
            } else if !pointed, lead == pointerIndent + 2, lead > 0 {
                rows.insert((row, text.trimmingCharacters(in: .whitespaces), false), at: 0)
            } else {
                break
            }
            row -= 1
        }
        guard rows.count >= 2, rows.filter(\.pointed).count == 1,
              let pointedAt = rows.firstIndex(where: \.pointed) else { return nil }
        let choices = rows.enumerated().map { offset, item in
            HerdrChoice(index: offset, label: stripShortcut(item.label), detail: nil,
                        keys: pointerWalk(from: pointedAt, to: offset), highlighted: item.pointed,
                        lasting: lasting(item.label), number: nil)
        }
        let first = rows[0].row
        let question = Self.question(texts, above: first)
        let start = max(0, min(question?.row ?? first, first - questionReach))
        return HerdrChoices(kind: .menu, question: question?.text, options: choices,
                            escape: offersEscape(footerText),
                            signature: texts[start...footer].joined(separator: "\n"))
    }

    // MARK: - Yes or no

    private static let yesNoPattern = try! NSRegularExpression( // non-copy: a pattern
        pattern: #"[\(\[]\s*(y|Y|yes|Yes|YES)\s*/\s*(n|N|no|No|NO)\s*(?:/.*?)?[\)\]]\s*[:?]?\s*$"#)

    private static func yesNo(_ texts: [String], end: Int, cursorRow: Int?) -> HerdrChoices? {
        let text = texts[end]
        if let cursorRow, cursorRow != end { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = yesNoPattern.firstMatch(in: text, range: range),
              let yesRange = Range(match.range(at: 1), in: text),
              let noRange = Range(match.range(at: 2), in: text) else { return nil }
        let yes = String(text[yesRange]), no = String(text[noRange])
        // `[Y/n]`: the capital is what Enter alone would answer.
        let yesDefault = yes.count == 1 && yes == "Y" && no == "n"
        let noDefault = no.count == 1 && no == "N" && yes == "y"
        func keys(_ word: String) -> [String] { word.lowercased().map(String.init) + ["Enter"] }
        let options = [
            HerdrChoice(index: 0, label: "yes", detail: nil, keys: keys(yes), highlighted: yesDefault, lasting: false, // non-copy: replaced by copy in the strip
                        number: nil),
            HerdrChoice(index: 1, label: "no", detail: nil, keys: keys(no), highlighted: noDefault, lasting: false, // non-copy: replaced by copy in the strip
                        number: nil),
        ]
        let start = max(0, end - 3)
        return HerdrChoices(kind: .yesNo, question: text.trimmingCharacters(in: .whitespaces), options: options,
                            escape: false, signature: texts[start...end].joined(separator: "\n"))
    }

    // MARK: - Row grammar

    private static let markers: Set<Character> = ["›", "❯", "▶", "▸"]

    /// `› 1. Label`, `  2) Label`, `  › 3. Label` (a question card).
    private static func optionRow(_ text: String) -> OptionRow? {
        var characters = Substring(text)
        let lead = characters.prefix { $0 == " " }.count
        characters = characters.dropFirst(lead)
        var pointed = false
        if let first = characters.first, markers.contains(first) {
            pointed = true
            characters = characters.dropFirst()
            characters = characters.drop { $0 == " " }
        }
        let column = text.count - characters.count
        let digits = characters.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(digits.count), let number = Int(digits), number > 0 else { return nil }
        characters = characters.dropFirst(digits.count)
        guard let dot = characters.first, dot == "." || dot == ")" else { return nil }
        characters = characters.dropFirst()
        guard characters.first == " " else { return nil }
        let label = characters.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return OptionRow(row: 0, number: number, pointed: pointed, column: column, text: label)
    }

    private static func pointerPrefix(_ text: String) -> Bool {
        guard let first = text.drop(while: { $0 == " " }).first else { return false }
        return markers.contains(first)
    }

    private static func isPointedPlain(_ text: String) -> Bool { pointerPrefix(text) }

    private static func isContinuation(_ texts: [String], _ row: Int) -> Bool {
        !isBlank(texts[row]) && indent(texts[row]) >= 4
    }

    /// The bottom hint line of a dialog: it names Enter or Esc and what they
    /// do. A transcript's `esc to interrupt` and codex's `? for shortcuts`
    /// are not one.
    static func isFooter(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty, value.count <= 200, optionRow(text) == nil, !pointerPrefix(text) else { return false }
        // Claude's plan approval: its footer names the plan file, not a key.
        if value.contains("ctrl+g to edit") { return true } // non-copy: Claude's footer
        let names = value.contains("enter") || value.contains("esc") || value.contains("⏎") || value.contains("↵")
        let verbs = ["confirm", "select", "submit", "continue", "cancel", "back", "dismiss", "navigate", "amend",
                     "choose", "close"] // non-copy: footer words the TUIs print
        return names && verbs.contains { value.contains($0) }
    }

    /// A hint row allowed under the footer (`esc to interrupt` on its own).
    private static func isTrailingHint(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        return value.count <= 60 && (value.hasPrefix("esc to ") || value.hasPrefix("ctrl+") || value.hasPrefix("tab to "))
    }

    /// A hint line between the options and the footer (Claude's
    /// `shift+tab to approve with this feedback`).
    private static func isHintLine(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard value.count <= 120, value.contains(" to ") else { return false }
        return value.contains("tab") || value.contains("ctrl") || value.contains("←") || value.contains("→")
    }

    /// codex's question card with its notes box open: a digit would type.
    private static func notesFocused(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("tab or esc to clear notes")
    }

    private static func isScrollMark(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard let first = value.first, first == "↑" || first == "↓" else { return false }
        return value.count <= 24
    }

    private static func isRule(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count >= 3 else { return false }
        return value.allSatisfy { "─━═╌┄┈-▔▁".contains($0) }
    }

    private static func checkbox(_ label: String) -> Bool {
        let value = label.trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("[ ]") || value.hasPrefix("[x]") || value.hasPrefix("[X]") || value.hasPrefix("[✔]")
            || value.hasPrefix("[✓]") || value.hasPrefix("☐") || value.hasPrefix("☒")
    }

    /// Claude's "Type something." and "Tell Claude what to change": a field,
    /// typed into, never a button (Collie `isFreeTextLabel`).
    private static func freeText(_ label: String) -> Bool {
        let value = label.lowercased()
        return value.hasPrefix("type something") || value.hasPrefix("tell claude what to change") // non-copy
            || value.hasPrefix("tell codex what to change") // non-copy: words the TUIs print
    }

    /// Claude's permission rows with an amend note open (Tab on Yes or No,
    /// Collie `inputRowAt`): the first row reading "Yes, …" or the last "No,
    /// …" without an `(esc)` key, and the two placeholders. A field, not an
    /// answer.
    private static func amendField(_ head: String, lines: [String], first: Bool, last: Bool) -> Bool {
        let whole = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").lowercased()
        if whole.hasPrefix("yes, and tell claude what to do next") { return true } // non-copy: Claude's placeholder
        if whole.hasPrefix("no, and tell claude what to do differently"), !whole.hasSuffix("(esc)") { return true } // non-copy
        return false
    }

    /// "don't ask again", "always", "for this session": a choice that keeps
    /// answering after this one.
    static func lasting(_ label: String) -> Bool {
        let value = label.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = ["don't ask again", "always", "for this session", "during this session", // non-copy
                     "for this conversation", "in the future", "remember", "every time", "from now on"] // non-copy
        return words.contains { value.contains($0) }
    }

    private static func offersEscape(_ footer: String) -> Bool {
        guard footer.contains("esc") else { return false }
        return ["cancel", "back", "dismiss", "close"].contains { footer.contains($0) } // non-copy: footer words
    }

    /// `Yes, proceed (y)` → `Yes, proceed`: the keyboard hint is for the desk.
    static func stripShortcut(_ label: String) -> String {
        var value = label.trimmingCharacters(in: .whitespaces)
        guard value.hasSuffix(")"), let open = value.lastIndex(of: "(") else { return value }
        let inner = value[value.index(after: open)..<value.index(before: value.endIndex)].lowercased()
        let hint = inner.count == 1 || ["esc", "enter", "tab", "shift+tab"].contains(inner) || inner.hasPrefix("ctrl+")
            || inner.hasPrefix("shift+")
        guard hint else { return value }
        value = String(value[..<open]).trimmingCharacters(in: .whitespaces)
        return value
    }

    /// The arrows from the marked row to `target`, then Enter (Collie
    /// `pointerWalk`), sent as one batch so no half walk is left behind.
    static func pointerWalk(from pointed: Int, to target: Int) -> [String] {
        let steps = target - pointed
        return Array(repeating: steps > 0 ? "Down" : "Up", count: abs(steps)) + ["Enter"]
    }

    /// The dialog's question: the nearest row above the options that ends
    /// in "?" (codex's `Reason:` line is the why, not the question), else
    /// the nearest that asks at all, else the nearest row of text.
    private static func question(_ texts: [String], above first: Int) -> (text: String, row: Int)? {
        var nearest: (String, Int)?
        var asks: (String, Int)?
        var row = first - 1
        while row >= 0, first - row <= questionReach {
            let text = texts[row]
            if isRule(text) { break }
            if !isBlank(text) {
                let value = text.trimmingCharacters(in: .whitespaces)
                if nearest == nil { nearest = (value, row) }
                // HERDR-10: a Chinese question ends in a full-width "？".
                let ends = value.hasSuffix("?") || value.hasSuffix("？")
                if ends, !value.hasPrefix("Reason:") { return (value, row) } // non-copy: codex's label
                if asks == nil, value.contains("?") || value.contains("？") { asks = (value, row) }
            }
            row -= 1
        }
        guard let found = asks ?? nearest else { return nil }
        return (found.0, found.1)
    }

    private static func firstLine(_ text: String) -> String {
        text.components(separatedBy: "\n").first ?? text
    }

    static func indent(_ text: String) -> Int { text.prefix { $0 == " " }.count }

    static func isBlank(_ text: String) -> Bool { text.allSatisfy { $0 == " " } }

    static func trimEnd(_ text: String) -> String {
        var value = Substring(text)
        while let last = value.last, last == " " || last == "\u{0}" { value = value.dropLast() }
        return String(value)
    }
}
