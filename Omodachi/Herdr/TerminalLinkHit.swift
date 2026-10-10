import SwiftTerm
import UIKit

/// LINKS-1 §1–2: what is under a finger on a terminal — the Herdr mirror, the
/// SSH panel.
///
/// A link the program marked (OSC 8 — codex marks every web address it
/// prints, and the mark survives Herdr's observe stream, ATTACH-2 §1.5) wins.
/// Otherwise the row is read as text — joined with the rows it wraps onto —
/// and `LinkDetector` finds the address or path under the tapped column: codex
/// never marks a path, so a path is only ever recognised this way.
@MainActor enum TerminalLinkHit {
    /// `point` is in the terminal view's own (content) coordinates — what
    /// `UIGestureRecognizer.location(in: terminalView)` gives.
    static func target(in view: TerminalView, at point: CGPoint, bareNames: Bool) -> LinkTarget? {
        let terminal = view.getTerminal()
        let optimal = view.getOptimalFrameSize()
        let cols = terminal.cols, rows = terminal.rows
        guard cols > 0, rows > 0, optimal.width > 0, optimal.height > 0, point.x >= 0, point.y >= 0 else { return nil }
        let cellWidth = optimal.width / CGFloat(cols), cellHeight = optimal.height / CGFloat(rows)
        let col = Int(point.x / cellWidth), row = Int(point.y / cellHeight)
        guard col < cols else { return nil }
        if let explicit = terminal.link(at: .buffer(Position(col: col, row: row)), mode: .explicitOnly),
           let target = LinkTarget.classify(explicit) {
            return target
        }
        guard let text = text(around: row, column: col, in: terminal) else { return nil }
        guard let match = LinkDetector.link(in: text.value, at: text.offset, bareNames: bareNames) else { return nil }
        return LinkTarget.classify(match.text)
    }

    /// The logical line around buffer row `row` — the row and the rows it is
    /// wrapped with — and the character offset of column `col` in it.
    static func text(around row: Int, column col: Int, in terminal: Terminal) -> (value: String, offset: Int)? {
        let top = terminal.buffer.totalLinesTrimmed
        func line(_ index: Int) -> BufferLine? { index < 0 ? nil : terminal.getScrollInvariantLine(row: index + top) }
        guard line(row) != nil else { return nil }
        var first = row
        while first > row - 8, let current = line(first), current.isWrapped, line(first - 1) != nil { first -= 1 }
        var last = row
        while last < row + 8, let next = line(last + 1), next.isWrapped { last += 1 }
        let cols = terminal.cols
        var cells: [Character] = []
        var tapped = 0
        for index in first...last {
            guard let current = line(index) else { break }
            for column in 0..<min(cols, current.count) {
                if index == row && column == col { tapped = cells.count }
                let character = current[column].getCharacter()
                cells.append(character == "\0" ? " " : character)
            }
        }
        // Counted in the joined string's characters, which a combining mark
        // in the next cell can merge with the one before it.
        let offset = String(cells[..<min(tapped, cells.count)]).count
        return (String(cells), offset)
    }
}
