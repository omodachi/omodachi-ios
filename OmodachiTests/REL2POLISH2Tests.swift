import SwiftTerm
import XCTest
@testable import Omodachi

/// REL2-POLISH-2 §1. Wrap joins a row with the next only when the next row
/// really continues it: the terminal's own wrap flag when the grid has one,
/// and otherwise a row that fills the width and is cut mid-word, or an app's
/// word wrap whose next word did not fit.
final class REL2POLISH2Tests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let sink = Sink()

    private func terminal(cols: Int, rows: Int, text: String) -> Terminal {
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: cols, rows: rows, scrollback: 0))
        terminal.feed(text: text)
        return terminal
    }

    /// A grid as Herdr's frames leave it: every row placed, no wrap flags.
    private func placed(_ rows: [String], cols: Int) -> HerdrGrid {
        let cells = rows.map { row -> [HerdrCell] in
            var cells = row.map { HerdrCell(text: String($0)) }
            while cells.count < cols { cells.append(.blank) }
            return cells
        }
        return HerdrGrid(cols: cols, rows: cells, cursor: nil)
    }

    private func lines(_ result: HerdrWrapResult) -> [String] {
        result.blocks.compactMap { block in
            if case .text(let runs, _) = block { runs.map(\.text).joined() } else { nil }
        }
    }

    /// The demo's nvim pane (96 columns): line 1 ends 15 columns short of the
    /// edge, and line 2 is a line of its own - with SwiftTerm's flags (how the
    /// App reads the demo) and without them (how it reads Herdr's frames).
    func testTheDemosFirstLineIsNotJoinedWithTheSecond() throws {
        let demo = try XCTUnwrap(DemoHost.herdr())
        let screen = try XCTUnwrap(demo.screens["w1:p1"])
        let source = terminal(cols: 96, rows: 36, text: screen)
        for flags in [true, false] {
            let grid = HerdrGrid.read(source, cursorVisible: false, wrapFlags: flags)
            XCTAssertEqual(grid.wrapped == nil, !flags)
            let text = lines(HerdrWrap.layout(grid, width: 40, agent: true))
            XCTAssertTrue(text[0].hasSuffix(#"it is given.""""#), "flags \(flags): \(text[0])")
            XCTAssertEqual(text[1], "  2  import sys", "flags \(flags)")
            XCTAssertEqual(text.filter { $0.contains("import") }.count, 3)
        }
    }

    /// A row that fills the pane exactly, then a new line: indented, numbered,
    /// or a prompt. None of them is a continuation.
    func testAFullWidthRowFollowedByANewLineStaysTwoLines() {
        let full = "  1  abcdefghij klmno" // 21 columns
        for next in ["  2  import sys", "❯ ls", "$ ls"] {
            let text = lines(HerdrWrap.layout(placed([full, next], cols: 21), width: 12, agent: true))
            XCTAssertEqual(text, [full, next], next)
        }
    }

    /// The terminal's own soft wrap, both ways the App can see it: flowing
    /// text SwiftTerm wrapped (its flag), and a placed grid whose row fills
    /// the width and is cut mid-word (the build log's long address).
    func testARealSoftWrapIsJoinedWithoutASpace() {
        let address = "see https://example.com/docs/uptime/build-troubleshooting#undefined-reference"
        let flowing = terminal(cols: 30, rows: 6, text: address + "\r\n$ ")
        let flagged = HerdrGrid.read(flowing, cursorVisible: false, wrapFlags: true)
        XCTAssertEqual(flagged.wrapped?.prefix(3), [false, true, true])
        XCTAssertEqual(lines(HerdrWrap.layout(flagged, width: 12, agent: false)).first, address)

        let cut = [String(address.prefix(30)), String(address.dropFirst(30).prefix(30)), String(address.dropFirst(60)), "$ "]
        XCTAssertEqual(lines(HerdrWrap.layout(placed(cut, cols: 30), width: 12, agent: false)).first, address)
    }

    /// With flags, a row is only joined as one word when the terminal says
    /// so: a row that happens to fill the width and ended with a newline is,
    /// at most, an app's word wrap (a space), never one word cut in two.
    func testWithFlagsAFullRowTheTerminalDidNotWrapIsNotOneWord() {
        let source = terminal(cols: 10, rows: 4, text: "abcdefghij\r\nklm")
        let flagged = HerdrGrid.read(source, cursorVisible: false, wrapFlags: true)
        XCTAssertEqual(flagged.wrapped?.prefix(2), [false, false])
        XCTAssertEqual(lines(HerdrWrap.layout(flagged, width: 8, agent: false)), ["abcdefghij klm"])
        let unflagged = HerdrGrid.read(source, cursorVisible: false)
        XCTAssertEqual(lines(HerdrWrap.layout(unflagged, width: 8, agent: false)), ["abcdefghijklm"],
                       "without flags the same cells read as the terminal's own wrap")
    }

    /// An app's word wrap is still undone - its next word did not fit - and
    /// a row whose next word would have fitted is a line of its own.
    func testAnAppsWordWrapJoinsOnlyWhenTheNextWordDidNotFit() {
        let cols = 40
        let wrapped = placed(["  This sentence was wrapped by the app", "  at the edge of the pane."], cols: cols)
        XCTAssertEqual(lines(HerdrWrap.layout(wrapped, width: 20, agent: true)),
                       ["  This sentence was wrapped by the app at the edge of the pane."])
        let separate = placed(["  A line that ends before the edge", "  a new one."], cols: cols)
        XCTAssertEqual(lines(HerdrWrap.layout(separate, width: 20, agent: true)),
                       ["  A line that ends before the edge", "  a new one."])
    }
}
