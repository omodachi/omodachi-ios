import SwiftTerm
import XCTest
@testable import Omodachi

/// HERDR-8: the mirror on a phone. Real frames from Herdr's observe stream on
/// the host (herdr 0.8.2, a 200×55 pane in the test session `h8-test`, the
/// model's name redacted) go through SwiftTerm exactly as the App feeds them,
/// and `HerdrWrap` turns the grid into text that fits a phone.
final class HERDR8Tests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let sink = Sink()

    /// One captured `terminal.frame`, fed into a 200×55 grid.
    private func grid(_ name: String, cursorVisible: Bool = true) throws -> HerdrGrid {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "herdr8-" + name, withExtension: "json"))
        let message = try HerdrStreamDecoder.decode(Data(contentsOf: url))
        guard case .frame(let frame) = message else { throw XCTSkip("not a frame") }
        XCTAssertEqual(frame.width, 200)
        XCTAssertTrue(frame.full)
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: frame.width ?? 200, rows: frame.height ?? 55,
                                                                         scrollback: 0))
        terminal.feed(byteArray: frame.bytes)
        return HerdrGrid.read(terminal, cursorVisible: cursorVisible)
    }

    /// The blocks as plain lines: what a person reads, before TextKit wraps it.
    private func lines(_ result: HerdrWrapResult) -> [String] {
        result.blocks.map { block in
            switch block {
            case .text(let runs, _): runs.map(\.text).joined()
            case .rule(let runs): "RULE " + runs.map(\.text).joined()
            case .wide(let rows): "WIDE " + rows.map { $0.map(\.text).joined() }.joined(separator: "\n")
            case .blank: ""
            }
        }
    }

    private func wideBlocks(_ result: HerdrWrapResult) -> [[[HerdrRun]]] {
        result.blocks.compactMap { if case .wide(let rows) = $0 { rows } else { nil } }
    }

    /// codex hard-wraps its answer at the desk's 200 columns; on a phone the
    /// sentence is one line again, its list items stay items, and the long
    /// address is whole.
    func testCodexsAnswerIsReflowedIntoLinesAPhoneCanWrap() throws {
        let result = HerdrWrap.layout(try grid("codex-answer"), width: 44, agent: true)
        XCTAssertFalse(result.fullScreen)
        let text = lines(result)
        let paragraph = try XCTUnwrap(text.first { $0.hasPrefix("• This tiny uptime checker") })
        XCTAssertTrue(paragraph.hasSuffix("easy to interpret."), "the desk's line break is gone: \(paragraph)")
        XCTAssertTrue(paragraph.contains("handle slow responses"), "joined with one space")
        XCTAssertEqual(text.filter { $0.hasPrefix("  • ") }.count, 4, "four list items, four lines")
        let prompt = try XCTUnwrap(text.first { $0.hasPrefix("› Without running") })
        XCTAssertTrue(prompt.contains("one-line explanations, then a link"), "the prompt is one line too")
        XCTAssertTrue(text.contains { $0.contains("(https://example.com/docs/uptime/configuration#retries-and-backoff-ceiling)") })
        XCTAssertFalse(text.contains { $0.hasPrefix("RULE") || $0.hasPrefix("WIDE") })
        XCTAssertEqual(text.last, "  ← for agents · ? for shortcuts", "the bottom of the screen is the bottom of the text")
        // Blank rows collapse to one.
        XCTAssertFalse(zip(text, text.dropFirst()).contains { $0.isEmpty && $1.isEmpty })
    }

    /// The logo 84 columns in moves left as one piece, keeping its shape.
    func testAnIndentedPictureMovesLeftWhole() throws {
        let full = try grid("codex-welcome")
        let result = HerdrWrap.layout(full, width: 44, agent: true)
        let art = lines(result).filter { $0.contains("⣿") }
        XCTAssertGreaterThan(art.count, 10)
        let leads = art.map { $0.prefix { $0 == " " }.count }
        XCTAssertLessThanOrEqual(leads.min() ?? 99, 2)
        // The same relative shape as on the desk.
        let deskLeads = full.rows.compactMap { row -> Int? in
            let text = row.map(\.text).joined()
            guard text.contains("⣿") else { return nil }
            return text.prefix { $0 == " " }.count
        }
        XCTAssertEqual(leads.map { $0 - (leads.min() ?? 0) }, deskLeads.map { $0 - (deskLeads.min() ?? 0) })
    }

    /// claude's splash: the drawing pans as one block, the rules are cut to
    /// the width, the menu is text.
    func testClaudesSplashKeepsTheDrawingAndCutsTheRules() throws {
        let result = HerdrWrap.layout(try grid("claude-onboarding"), width: 44, agent: true)
        XCTAssertLessThanOrEqual(wideBlocks(result).count, 1, "one picture, not shards")
        let rules = result.blocks.compactMap { if case .rule(let runs) = $0 { runs.map(\.text).joined() } else { nil } }
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.allSatisfy { $0.count <= 44 }, "a rule never wraps into a wall")
        let text = lines(result)
        XCTAssertTrue(text.contains(" Choose the text style that looks best with your terminal"))
        XCTAssertTrue(text.contains(" ❯ ✔ Dark mode"))
    }

    /// A build log: the line the desk's terminal wrapped is one line again (so
    /// the address in it is whole), the prompt and its cursor end the text.
    func testABuildLogJoinsTheTerminalsOwnWrapAndEndsAtThePrompt() throws {
        let result = HerdrWrap.layout(try grid("build-log"), width: 44, agent: false)
        XCTAssertFalse(result.fullScreen)
        let text = lines(result)
        let ld = try XCTUnwrap(text.first { $0.hasPrefix("/usr/bin/ld:") })
        XCTAssertTrue(ld.hasSuffix("(see https://example.com/docs/uptime/build-troubleshooting#undefined-reference-to-x509)"), ld)
        XCTAssertEqual(text.filter { $0.contains("cc -O2") }.count, 10)
        XCTAssertTrue(text.last?.hasPrefix("~/h8test ❯") == true)
        guard case .text(let runs, _) = try XCTUnwrap(result.blocks.last) else { return XCTFail("the prompt is text") }
        XCTAssertTrue(runs.contains(where: \.cursor), "the cursor is shown where it is")
        // Colours survive: the step counter is green, FAILED is red.
        let all = result.blocks.flatMap { block -> [HerdrRun] in if case .text(let runs, _) = block { runs } else { [] } }
        XCTAssertTrue(all.contains { $0.text.contains("[ 1/12]") && $0.style.foreground == .ansi(2) })
        XCTAssertTrue(all.contains { $0.text.contains("FAILED:") && $0.style.foreground == .ansi(1) && $0.style.bold })
    }

    /// A table wider than the phone keeps its columns and pans on its own.
    func testAWideTablePansAsOneBlock() throws {
        let result = HerdrWrap.layout(try grid("wide-table"), width: 44, agent: false)
        let wide = wideBlocks(result)
        XCTAssertEqual(wide.count, 1)
        let rows = try XCTUnwrap(wide.first).map { $0.map(\.text).joined() }
        XCTAssertTrue(rows.first?.hasPrefix("┌───") == true)
        XCTAssertTrue(rows.contains { $0.hasPrefix("│ svc-11-uptime-checker │ ap-south-1 │") }, "columns intact")
        XCTAssertTrue(rows.contains { $0.hasPrefix("svc-04-uptime-checker  ap-south-1") }, "the space-aligned table too")
        XCTAssertEqual(lines(result).first, "~/h8test ❯ python3 .tools/table.py", "the command above it is text")
    }

    /// vim fills the screen and draws a status bar: a picture, so the mirror
    /// shows the grid. An agent's screen never counts as one.
    func testVimIsAFullScreenProgram() throws {
        let vim = try grid("vim")
        XCTAssertTrue(HerdrWrap.layout(vim, width: 44, agent: false).fullScreen)
        XCTAssertFalse(HerdrWrap.layout(vim, width: 44, agent: true).fullScreen)
        for name in ["build-log", "wide-table"] {
            XCTAssertFalse(HerdrWrap.layout(try grid(name), width: 44, agent: false).fullScreen, name)
        }
        // vim's own `~` filler and ruler, and less's prompt, on their own.
        func screen(_ rows: [String]) -> [[HerdrCell]] { rows.map { $0.map { HerdrCell(text: String($0)) } } }
        XCTAssertTrue(HerdrWrap.looksFullScreen(screen(["hello", "~", "~", "~", ""]), cols: 20))
        XCTAssertTrue(HerdrWrap.looksFullScreen(screen(["a", "\"x\" 3L, 20B      1,1   All"]), cols: 40))
        XCTAssertTrue(HerdrWrap.looksFullScreen(screen(["a", "(END)"]), cols: 20))
        XCTAssertFalse(HerdrWrap.looksFullScreen(screen(["$ ls", "a  b  c", "$ "]), cols: 20))
    }

    /// A narrower phone (or a wider one) changes where rules are cut and what
    /// counts as wide, never the text.
    func testTheWidthOnlyMovesTheCuts() throws {
        let narrow = HerdrWrap.layout(try grid("codex-answer"), width: 30, agent: true)
        let wide = HerdrWrap.layout(try grid("codex-answer"), width: 80, agent: true)
        XCTAssertEqual(lines(narrow), lines(wide))
    }

    // MARK: - Modes

    @MainActor func testModesCycleAndAreRememberedPerKind() {
        // An iPad: Fit → Actual → Wrap → Fit.
        XCTAssertEqual(HerdrMirrorMode.wrap.next(phone: false), .fit)
        XCTAssertEqual(HerdrMirrorMode.fit.next(phone: false), .actual)
        XCTAssertEqual(HerdrMirrorMode.actual.next(phone: false), .wrap)
        // HERDR-12: an iPhone, Wrap ↔ Fit; Actual size is not on its way.
        XCTAssertEqual(HerdrMirrorMode.wrap.next(phone: true), .fit)
        XCTAssertEqual(HerdrMirrorMode.fit.next(phone: true), .wrap)
        XCTAssertEqual(HerdrMirrorMode.actual.next(phone: true), .wrap)
        let suite = "herdr8-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let phone = HerdrMirrorPreference(defaults: defaults, phone: true)
        let pad = HerdrMirrorPreference(defaults: defaults, phone: false)
        XCTAssertEqual(phone.mode(agent: nil), .wrap, "an iPhone starts on Wrap")
        XCTAssertEqual(pad.mode(agent: "codex"), .fit, "an iPad keeps the grid")
        phone.remember(.fit, agent: "codex")
        XCTAssertEqual(phone.mode(agent: "codex"), .fit)
        XCTAssertEqual(phone.mode(agent: "claude"), .wrap, "another kind keeps its own")
        XCTAssertEqual(phone.mode(agent: nil), .wrap, "a shell is its own kind")
        // HERDR-12: Actual size remembered on a phone from before opens on Fit;
        // the same choice on an iPad stays.
        phone.remember(.actual, agent: "claude")
        XCTAssertEqual(phone.mode(agent: "claude"), .fit, "a phone has no Actual size any more")
        XCTAssertEqual(pad.mode(agent: "claude"), .actual, "an iPad keeps it")
    }

    func testDumpForTheReport() throws {
        for (name, agent) in [("codex-answer", true), ("codex-welcome", true), ("claude-onboarding", true),
                              ("build-log", false), ("wide-table", false), ("vim", false)] {
            let result = HerdrWrap.layout(try grid(name), width: 44, agent: agent)
            print("=== \(name) fullScreen=\(result.fullScreen)")
            for line in lines(result) { print("| " + line) }
        }
    }
}
