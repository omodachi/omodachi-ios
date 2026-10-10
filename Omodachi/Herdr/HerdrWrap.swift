import Foundation
import SwiftTerm

/// HERDR-8: the pane's screen as text that fits a phone.
///
/// Leo, looking at Herdr on an iPhone: "手机完全是不可用的，无论是 fit 还是
/// actual". A 200-column pane fitted to a phone is 9-point type in a strip,
/// and at its own size it is a small window onto the grid. The geometry is the
/// person at the desk's (the PTY is never resized, attached or zoomed — Collie
/// ADR 0008 and its amendment, and this app's own rule since HERDR-3), so the
/// phone does what Collie does with the same input: Herdr's observe stream is
/// already the *rendered* screen, so its rows are drawn as styled text at the
/// App's normal terminal size and soft-wrapped to the width the phone has.
///
/// This file is the part that decides, and nothing in it draws: it reads the
/// grid SwiftTerm holds (`HerdrGrid`) and turns it into blocks
/// (`HerdrWrap.layout`). `HerdrWrapView` draws them.
///
/// * A **text** row wraps. Rows an app hard-wrapped at the pane's width are
///   joined back into one line first (`reflow`), so a sentence does not break
///   where the desk's terminal ended; a row the terminal itself wrapped is
///   joined without a space, which also repairs a long URL cut at the edge.
///   Which rows the terminal wrapped is its own flag when the grid has one
///   (`HerdrGrid.wrapped`); Herdr's frames place every row by position and
///   carry none, so there it is read from the cells (`join`).
/// * A **rule** (a run of `─`) is cut to the width instead of wrapping into a
///   wall of dashes.
/// * A **framed** row (`│ … │`, an input box) keeps its left edge and drops
///   the right one, which would otherwise land on a line of its own.
/// * A **wide** block — a table drawn with box characters, or columns lined up
///   with spaces — is kept as it is and pans sideways on its own (Collie).
/// * An indented block (codex's logo sits 84 columns in) is moved left as one
///   piece, keeping its own shape.
///
/// A full-screen program (vim, htop, less) is a picture, not a transcript:
/// `fullScreen` says so, and the mirror shows the grid instead with a note.
/// Herdr's frames never switch to the alternate screen (they are repaints of
/// Herdr's own render), so that is read from what is on the screen.
struct HerdrCellStyle: Hashable, Sendable {
    enum Color: Hashable, Sendable {
        case standard
        case ansi(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    var foreground: Color = .standard
    var background: Color = .standard
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
    var strike = false

    static let plain = HerdrCellStyle()

    init() {}

    init(_ attribute: Attribute) {
        foreground = Self.color(attribute.fg)
        background = Self.color(attribute.bg)
        let style = attribute.style
        bold = style.contains(.bold)
        dim = style.contains(.dim)
        italic = style.contains(.italic)
        underline = style.contains(.underline)
        inverse = style.contains(.inverse)
        strike = style.contains(.crossedOut)
    }

    private static func color(_ value: Attribute.Color) -> Color {
        switch value {
        case .ansi256(let code): .ansi(code)
        case .trueColor(let red, let green, let blue): .rgb(red, green, blue)
        case .defaultColor, .defaultInvertedColor: .standard
        }
    }

    /// The colour this cell's background is painted, inverse included.
    var paintedBackground: Color { inverse ? (foreground == .standard ? .ansi(255) : foreground) : background }
}

/// One cell of the grid: what is drawn there (empty for the second half of a
/// wide character), how, and the link the program marked on it (OSC 8).
struct HerdrCell: Equatable, Sendable {
    var text: String
    var style: HerdrCellStyle = .plain
    var link: String?

    static let blank = HerdrCell(text: " ")
}

/// The screen, row by row, at the pane's own width — what SwiftTerm holds
/// after a frame — and where the cursor is when it is showing.
struct HerdrGrid: Equatable, Sendable {
    var cols: Int
    var rows: [[HerdrCell]]
    var cursor: (x: Int, y: Int)?
    /// REL2-POLISH-2: per row, whether the terminal itself wrapped the row
    /// before onto it (SwiftTerm's `BufferLine.isWrapped`). `nil` when the
    /// grid's source places every row itself — Herdr's frames move the cursor
    /// to each row before writing it, so the terminal never wraps one and the
    /// flag would say "no" about rows the desk's terminal did wrap.
    var wrapped: [Bool]?

    static func == (lhs: HerdrGrid, rhs: HerdrGrid) -> Bool {
        lhs.cols == rhs.cols && lhs.rows == rhs.rows && lhs.cursor?.x == rhs.cursor?.x && lhs.cursor?.y == rhs.cursor?.y
            && lhs.wrapped == rhs.wrapped
    }

    /// Read the visible screen out of SwiftTerm. `wrapFlags`: the bytes were
    /// text the terminal laid out itself (the demo's screens), so its wrap
    /// flags are real and are read too.
    static func read(_ terminal: Terminal, cursorVisible: Bool, wrapFlags: Bool = false) -> HerdrGrid {
        let cols = terminal.cols
        var rows: [[HerdrCell]] = []
        var wrapped: [Bool] = []
        rows.reserveCapacity(terminal.rows)
        for y in 0..<terminal.rows {
            wrapped.append(terminal.getLine(row: y)?.isWrapped ?? false)
            guard let line = terminal.getLine(row: y) else { rows.append(Array(repeating: .blank, count: cols)); continue }
            var cells: [HerdrCell] = []
            cells.reserveCapacity(cols)
            for x in 0..<min(cols, line.count) {
                let data = line[x]
                var text = String(terminal.getCharacter(for: data))
                if text == "\0" || text.isEmpty {
                    // The second half of a wide character is a zero-width
                    // placeholder; a never-written cell is a space.
                    text = x > 0 && line[x - 1].width == 2 ? "" : " "
                }
                var link: String?
                if data.hasPayload {
                    link = terminal.link(at: .buffer(Position(col: x, row: y)), mode: .explicitOnly)
                }
                cells.append(HerdrCell(text: text, style: HerdrCellStyle(data.attribute), link: link))
            }
            while cells.count < cols { cells.append(.blank) }
            rows.append(cells)
        }
        let location = terminal.getCursorLocation()
        let cursor = cursorVisible && location.y >= 0 && location.y < rows.count ? (location.x, location.y) : nil
        return HerdrGrid(cols: cols, rows: rows, cursor: cursor, wrapped: wrapFlags ? wrapped : nil)
    }
}

/// A piece of one line, all in one style.
struct HerdrRun: Equatable, Sendable {
    var text: String
    var style: HerdrCellStyle
    var link: String?
    var cursor = false
}

/// What the wrap view draws, top to bottom.
enum HerdrWrapBlock: Equatable, Sendable {
    /// One logical line, soft-wrapped to the width. `indent` is how far its
    /// continuation lines hang in, in columns.
    case text([HerdrRun], indent: Int)
    /// A line that is cut at the width, never wrapped (a rule).
    case rule([HerdrRun])
    /// Rows kept exactly as they are, panned sideways together.
    case wide([[HerdrRun]])
    /// An empty line.
    case blank
}

struct HerdrWrapResult: Equatable, Sendable {
    var blocks: [HerdrWrapBlock]
    /// A full-screen program: the grid says more than wrapped text would.
    var fullScreen: Bool
}

enum HerdrWrap {
    /// Box drawing (`U+2500…U+257F`) and the block elements around it.
    static func isBoxCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return false }
        return (0x2500...0x259F).contains(scalar.value)
    }

    /// The characters a horizontal rule is made of, corners and tees included.
    static let ruleCharacters: Set<String> = [
        "─", "━", "═", "╌", "╍", "┄", "┅", "┈", "┉", "╴", "╶", "╸", "╺", "▔", "▁", "-", "=", "_", // non-copy: drawing characters
        "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "╔", "╗", "╚", "╝", "╠", "╣", "╦", "╩", "╬", // non-copy: drawing characters
        "┏", "┓", "┗", "┛", "┣", "┫", "┳", "┻", "╋", "╞", "╡", "╪", // non-copy: drawing characters
    ]
    static let horizontalCharacters: Set<String> = ["─", "━", "═", "╌", "╍", "┄", "┅", "┈", "┉", "▔", "▁", "-", "=", "_"] // non-copy: drawing characters
    static let verticalBars: Set<String> = ["│", "┃", "║", "▏", "▕", "▎", "▌", "▐", "|"] // non-copy: drawing characters
    /// Tees and crosses: a rule with one of these is a table's border.
    static let tableJoints: Set<String> = ["┬", "┴", "┼", "╦", "╩", "╬", "┳", "┻", "╋", "╪", "├", "┤", "╠", "╣"] // non-copy: drawing characters
    /// How a list item starts; its continuation lines hang in past it.
    static let markers: Set<String> = ["•", "◦", "▪", "‣", "-", "*", "+", "›", "❯", ">", "└", "⎿", "⏺", "●", "○", "✔", "✗", "✓", "✘"] // non-copy: drawing characters

    private struct Row {
        var cells: [HerdrCell]
        /// Leading blank cells.
        var lead: Int
        /// One past the last written cell (0 for a blank row).
        var end: Int
        var cursorX: Int?
        /// The terminal wrapped the row before onto this one: `nil` when the
        /// grid has no flags to say.
        var continued: Bool?
        var kind: Kind
        enum Kind { case blank, text, rule, framed, wide }

        var isBlank: Bool { kind == .blank }
        var length: Int { max(0, end - lead) }
    }

    /// The grid as blocks for a mirror `width` columns wide. `agent`: the pane
    /// runs an agent, whose screen is a transcript even when it fills the
    /// grid, so it is never treated as a full-screen program.
    static func layout(_ grid: HerdrGrid, width: Int, agent: Bool) -> HerdrWrapResult {
        let width = max(8, width)
        var rows = grid.rows.enumerated().map { index, cells in
            var row = classify(cells, cursorX: grid.cursor?.y == index ? grid.cursor?.x : nil, cols: grid.cols, width: width)
            if let flags = grid.wrapped { row.continued = index < flags.count && flags[index] }
            return row
        }
        let fullScreen = !agent && looksFullScreen(rows.map(\.cells), cols: grid.cols)
        markWide(&rows, width: width)
        dedent(&rows, width: width)
        // Blank rows at the top and after the last written row (or the
        // cursor) are the screen's unused space, not content.
        let first = rows.firstIndex { !$0.isBlank } ?? rows.count
        let last = rows.lastIndex { !$0.isBlank } ?? -1
        guard first <= last else { return HerdrWrapResult(blocks: [], fullScreen: fullScreen) }
        var blocks: [HerdrWrapBlock] = []
        var index = first
        var previousBlank = false
        while index <= last {
            let row = rows[index]
            switch row.kind {
            case .blank:
                if !previousBlank { blocks.append(.blank) }
                previousBlank = true
                index += 1
                continue
            case .wide:
                var block: [[HerdrRun]] = []
                while index <= last, rows[index].kind == .wide {
                    block.append(runs(rows[index].cells, from: 0, to: rows[index].end, cursorX: rows[index].cursorX))
                    index += 1
                }
                blocks.append(.wide(block))
            case .rule:
                let end = min(row.end, row.lead + width - 1)
                blocks.append(.rule(runs(row.cells, from: 0, to: end, cursorX: row.cursorX)))
                index += 1
            case .text, .framed:
                var line = runs(row.cells, from: 0, to: row.end, cursorX: row.cursorX)
                let indent = hangingIndent(row)
                var current = row
                // Join the rows an app (or the terminal) wrapped at the
                // desk's width back into the line they were.
                while index + 1 <= last, let joint = join(current, rows[index + 1], cols: grid.cols) {
                    let next = rows[index + 1]
                    let start = joint == .direct ? 0 : next.lead
                    if joint == .space { line.append(HerdrRun(text: " ", style: .plain)) }
                    line += runs(next.cells, from: start, to: next.end, cursorX: next.cursorX)
                    current = next
                    index += 1
                }
                blocks.append(.text(merged(line), indent: min(indent, width / 2)))
                index += 1
            }
            previousBlank = false
        }
        return HerdrWrapResult(blocks: blocks, fullScreen: fullScreen)
    }

    // MARK: - Rows

    private static func classify(_ source: [HerdrCell], cursorX: Int?, cols: Int, width: Int) -> Row {
        var cells = source
        var end = cells.count
        while end > 0, cells[end - 1].text == " " || cells[end - 1].text.isEmpty { end -= 1 }
        if let cursorX, cursorX >= end, cursorX < cells.count { end = cursorX + 1 }
        var lead = 0
        while lead < end, cells[lead].text == " ", cursorX != lead { lead += 1 }
        guard end > 0 else { return Row(cells: cells, lead: 0, end: 0, cursorX: cursorX, kind: cursorX == nil ? .blank : .text) }
        let written = cells[lead..<end].filter { $0.text != " " && !$0.text.isEmpty }.map(\.text)
        let horizontal = written.filter { horizontalCharacters.contains($0) }.count
        if horizontal >= 8, written.allSatisfy({ ruleCharacters.contains($0) }) {
            return Row(cells: cells, lead: lead, end: end, cursorX: cursorX, kind: .rule)
        }
        // `│ text │`: keep the left edge, drop the right one and the padding
        // before it, so the box's content wraps like any other line.
        if let first = written.first, let lastBar = written.last, verticalBars.contains(first), verticalBars.contains(lastBar),
           written.count > 2, written.dropFirst().dropLast().allSatisfy({ !verticalBars.contains($0) }) {
            var right = end - 1
            cells[right] = .blank
            while right > lead + 1, cells[right - 1].text == " " { right -= 1 }
            end = max(lead + 1, right)
            if let cursorX, cursorX >= end { end = min(cells.count, cursorX + 1) }
            return Row(cells: cells, lead: lead, end: end, cursorX: cursorX, kind: .framed)
        }
        return Row(cells: cells, lead: lead, end: end, cursorX: cursorX, kind: .text)
    }

    /// Box-drawn tables and space-aligned columns wider than the mirror pan
    /// as one block; the rules around a table go with it.
    private static func markWide(_ rows: inout [Row], width: Int) {
        func boxy(_ row: Row) -> Bool {
            guard row.kind == .text || row.kind == .rule else { return false }
            let written = row.cells[row.lead..<row.end].map(\.text)
            let box = written.filter(isBoxCharacter).count
            return row.kind == .rule ? written.contains(where: tableJoints.contains) : box >= 2
        }
        func tabular(_ row: Row) -> Bool {
            guard row.kind == .text else { return false }
            var gaps = 0, run = 0
            for cell in row.cells[row.lead..<row.end] {
                if cell.text == " " { run += 1 } else { if run >= 2 { gaps += 1 }; run = 0 }
            }
            return gaps >= 3
        }
        let candidate = rows.map { ($0.end > width) && (boxy($0) || tabular($0)) }
        for index in rows.indices where candidate[index] {
            // One tabular row on its own is a sentence with spacing, not a
            // table; two in a row (or a box row) is.
            let neighbour = (index > 0 && candidate[index - 1]) || (index + 1 < rows.count && candidate[index + 1])
            if boxy(rows[index]) || neighbour { rows[index].kind = .wide }
        }
        // A few rows (up to three, blank or not) between two wide rows are
        // part of the same picture - a gap inside a drawing, a caption
        // between two tables - and pan with it rather than splitting it.
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .wide else { index += 1; continue }
            var next = index + 1
            while next < rows.count, rows[next].kind == .text || rows[next].kind == .blank { next += 1 }
            if next < rows.count, rows[next].kind == .wide, next - index - 1 <= 3 {
                for gap in (index + 1)..<next { rows[gap].kind = .wide }
            }
            index = next
        }
    }

    /// A block of rows that all start far to the right (a logo, a centred
    /// banner) moves left as one piece, so it keeps its shape on a phone.
    private static func dedent(_ rows: inout [Row], width: Int) {
        var start = 0
        while start < rows.count {
            guard rows[start].kind == .text || rows[start].kind == .framed else { start += 1; continue }
            var end = start
            while end + 1 < rows.count, rows[end + 1].kind == .text || rows[end + 1].kind == .framed { end += 1 }
            let lead = rows[start...end].map(\.lead).min() ?? 0
            if lead >= max(8, width / 3) {
                let shift = lead - 2
                for index in start...end {
                    var row = rows[index]
                    row.cells.removeFirst(shift)
                    row.cells += Array(repeating: HerdrCell.blank, count: shift)
                    row.lead -= shift
                    row.end -= shift
                    row.cursorX = row.cursorX.map { max(0, $0 - shift) }
                    rows[index] = row
                }
            }
            start = end + 1
        }
    }

    /// `tight`: the app wrapped Chinese or Japanese text, which has no
    /// spaces - joined at the next row's indent with none (HERDR-10).
    private enum Joint { case direct, space, tight }

    /// Room an app may leave at the right edge when it wraps its own words
    /// (a margin, or wrapping one short of the edge).
    private static let wrapSlack = 2

    /// Whether `next` continues `row`: the terminal wrapped it (joined as is),
    /// or an app wrapped its words near the edge and the next row carries on
    /// at the same indent (joined with a space).
    ///
    /// REL2-POLISH-2. A terminal wrap is the terminal's own flag when the grid
    /// has one. Without it (Herdr's frames) the row has to fill the width and
    /// break mid-word: the next row carries on at the first column with no
    /// space at the cut — a full-width row followed by an indented one or a
    /// space is a line that ended at the edge. And an app's word wrap only
    /// ever moves a word down because it did not fit: when the next row's
    /// first word would have fitted on this row, the next row is a new line
    /// (nvim's `  1  """…given."""` above `  2  import sys` was joined into
    /// one, the line ending 15 columns short of the edge). Collie never
    /// guesses here at all: it asks Herdr for `recent_unwrapped` when a URL
    /// touches the edge, a read this app does not make (HERDR-8).
    private static func join(_ row: Row, _ next: Row, cols: Int) -> Joint? {
        guard row.kind == .text, next.kind == .text, next.cursorX == nil || next.length > 0 else { return nil }
        if let continued = next.continued {
            if continued { return .direct }
        } else if row.end >= cols, row.lead < cols, next.lead == 0, next.length > 0,
                  row.cells[row.end - 1].text != " ", !startsLine(next) {
            return .direct
        }
        guard row.end >= cols - 16, next.length > 0, next.lead > 0 || row.lead == 0 else { return nil }
        // A list's next item, or a row that starts further left, is a new line.
        if let first = next.cells.dropFirst(next.lead).first, markers.contains(first.text) { return nil }
        let hang = hangingIndent(row)
        guard next.lead == hang || next.lead == row.lead else { return nil }
        if let last = row.cells[row.end - 1].text.first, last.isPunctuation, ".:!?".contains(last),
           next.lead == row.lead, hang == row.lead { return nil }
        // Numbered rows (an editor's line numbers, a numbered list) are lines
        // of their own, however close to the edge the one before ends.
        if numbered(row.cells, from: row.lead), numbered(next.cells, from: next.lead) { return nil }
        if isWide(row.cells, at: row.end - 1), isWide(next.cells, at: next.lead) { return .tight }
        if row.end + 1 + firstWord(next) <= cols - wrapSlack { return nil }
        return .space
    }

    /// The row opens like a line of its own: a list marker or a prompt
    /// (`❯`, `›`, `$ `, `% `, `# `) in its first column.
    private static func startsLine(_ row: Row) -> Bool {
        guard row.lead < row.end else { return false }
        let first = row.cells[row.lead].text
        if markers.contains(first) { return true }
        let second = row.lead + 1 < row.cells.count ? row.cells[row.lead + 1].text : " "
        return ["$", "%", "#"].contains(first) && second == " "
    }

    /// Cells from the row's first written cell to the first blank one.
    private static func firstWord(_ row: Row) -> Int {
        var end = row.lead
        while end < row.end, row.cells[end].text != " " { end += 1 }
        return end - row.lead
    }

    /// The row starts with a number followed by a space, `.` or `)`.
    private static func numbered(_ cells: [HerdrCell], from start: Int) -> Bool {
        var index = start
        while index < cells.count, cells[index].text.count == 1, cells[index].text.first?.isASCII == true,
              cells[index].text.first?.isNumber == true { index += 1 }
        guard index > start, index < cells.count else { return false }
        return [" ", ".", ")"].contains(cells[index].text)
    }

    /// A double-width character starts at `index` (its second cell is the
    /// empty continuation).
    private static func isWide(_ cells: [HerdrCell], at index: Int) -> Bool {
        guard index >= 0, index + 1 < cells.count else { return false }
        return !cells[index].text.isEmpty && cells[index].text != " " && cells[index + 1].text.isEmpty
    }

    /// Where a row's continuation lines line up: past its indent and, for a
    /// list item, past its marker.
    private static func hangingIndent(_ row: Row) -> Int {
        var indent = row.lead
        guard indent < row.end else { return indent }
        if markers.contains(row.cells[indent].text) || verticalBars.contains(row.cells[indent].text) {
            indent += 1
            while indent < row.end, row.cells[indent].text == " " { indent += 1 }
        }
        return indent
    }

    /// Rows joined into one line meet in the middle of what is one run of
    /// text (a URL the terminal cut): put it back together.
    private static func merged(_ line: [HerdrRun]) -> [HerdrRun] {
        var result: [HerdrRun] = []
        for run in line {
            if var last = result.last, !last.cursor, !run.cursor, last.style == run.style, last.link == run.link {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        return result
    }

    private static func runs(_ cells: [HerdrCell], from start: Int, to end: Int, cursorX: Int?) -> [HerdrRun] {
        var result: [HerdrRun] = []
        guard start < end else { return result }
        for x in start..<min(end, cells.count) {
            let cell = cells[x]
            if cell.text.isEmpty { continue }
            let isCursor = x == cursorX
            if var last = result.last, !isCursor, !last.cursor, last.style == cell.style, last.link == cell.link {
                last.text += cell.text
                result[result.count - 1] = last
            } else {
                result.append(HerdrRun(text: cell.text, style: cell.style, link: cell.link, cursor: isCursor))
            }
        }
        return result
    }

    // MARK: - Full-screen programs

    /// vim's `~` filler and ruler, less's prompt, top's header, or a status
    /// bar painted across the bottom of the screen.
    static func looksFullScreen(_ rows: [[HerdrCell]], cols: Int) -> Bool {
        guard !rows.isEmpty, cols > 0 else { return false }
        let texts = rows.map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        if texts.filter({ $0 == "~" }).count >= 3 { return true }
        let tail = texts.suffix(2)
        let ruler = #"\b\d+,\d+(-\d+)?\s+(All|Top|Bot|\d+%)\s*$"#
        if tail.contains(where: { $0.range(of: ruler, options: .regularExpression) != nil }) { return true }
        if let last = texts.last, last == ":" || last.hasSuffix("(END)")
            || last.range(of: #"^lines \d+-\d+"#, options: .regularExpression) != nil { return true }
        if texts.prefix(12).contains(where: { $0.range(of: #"^\s*PID\s+USER\b"#, options: .regularExpression) != nil }) {
            return true
        }
        for row in rows.suffix(2) {
            var counts: [HerdrCellStyle.Color: Int] = [:]
            for cell in row where cell.style.paintedBackground != .standard { counts[cell.style.paintedBackground, default: 0] += 1 }
            let painted = counts.values.reduce(0, +)
            if Double(painted) >= Double(cols) * 0.9 { return true }
        }
        return false
    }
}
