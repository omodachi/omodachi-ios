import SwiftTerm
import XCTest
@testable import Omodachi

/// HERDR-9: the choices strip reads a pane's dialog off the same screen the
/// mirror shows.
///
/// Two kinds of real captures:
/// * codex 0.160 frames from the host (herdr 0.8.2 `terminal.frame`, a 200×55
///   pane in the throwaway session `h9-test`, model names replaced with
///   same-length stand-ins), fed through SwiftTerm the way the App feeds them;
/// * Claude Code and older codex panes from Collie's test corpus
///   (AltanS/collie `25468b0`, `web/src/fixtures/panes/`, MIT — see
///   docs/THIRD-PARTY.md), which are Herdr `pane.read` captures. Claude is
///   never run on the test host (HERDR-8's onboarding incident).
final class HERDR9ChoicesTests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let sink = Sink()

    // MARK: - Fixtures

    /// A Collie pane capture as the rows a screen shows (SGR dropped).
    private func collie(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "collie--" + name, withExtension: "txt"),
                                "missing fixture \(name)")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let plain = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        return plain.components(separatedBy: "\n").map(HerdrChoiceReader.trimEnd)
    }

    /// A host `terminal.frame` through SwiftTerm, read back as rows.
    private func host(_ name: String) throws -> (rows: [String], cursor: Int?) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "herdr9-" + name, withExtension: "json"),
                                "missing frame \(name)")
        let message = try HerdrStreamDecoder.decode(Data(contentsOf: url))
        guard case .frame(let frame) = message else { throw XCTSkip("not a frame") }
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: frame.width ?? 200, rows: frame.height ?? 55,
                                                                         scrollback: 0))
        terminal.feed(byteArray: frame.bytes)
        let grid = HerdrGrid.read(terminal, cursorVisible: true)
        return (HerdrChoiceReader.rows(grid), grid.cursor?.y)
    }

    private func labels(_ choices: HerdrChoices?) -> [String] { choices?.options.map(\.label) ?? [] }
    private func keys(_ choices: HerdrChoices?) -> [[String]] { choices?.options.map(\.keys) ?? [] }

    // MARK: - codex 0.160 on the host

    func testCodexsCommandApprovalBecomesItsThreeChoices() throws {
        let frame = try host("codex-approval-exec")
        let choices = try XCTUnwrap(HerdrChoiceReader.read(frame.rows))
        XCTAssertEqual(choices.kind, .menu)
        XCTAssertEqual(labels(choices), ["Yes, proceed",
                                         "Yes, and don't ask again for commands that start with `printf hi > hello.txt`",
                                         "No, and tell Codex what to do differently"])
        XCTAssertEqual(choices.signature.components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespaces),
                       "Press enter to confirm or esc to cancel")
        XCTAssertEqual(keys(choices), [["1"], ["2"], ["3"]], "codex confirms on the digit (probed: 3 declined)")
        XCTAssertEqual(choices.options.map(\.highlighted), [true, false, false])
        XCTAssertEqual(choices.options.map(\.lasting), [false, true, false], "don't ask again is never the main one")
        XCTAssertTrue(choices.escape, "the footer offers esc to cancel")
        XCTAssertEqual(choices.question, "Would you like to run the following command?")
        XCTAssertTrue(choices.signature.contains("$ printf hi > hello.txt"), "the command is part of what was seen")
    }

    func testCodexsPatchApprovalBecomesItsChoices() throws {
        let choices = try XCTUnwrap(HerdrChoiceReader.read(try host("codex-approval-patch").rows))
        XCTAssertEqual(labels(choices), ["Yes, proceed", "Yes, and don't ask again for these files",
                                         "No, and tell Codex what to do differently"])
        XCTAssertEqual(keys(choices), [["1"], ["2"], ["3"]])
        XCTAssertEqual(choices.options.map(\.lasting), [false, true, false])
        XCTAssertTrue(choices.signature.contains("Destination:"))
    }

    func testCodexsNetworkApprovalBecomesItsChoices() throws {
        let choices = try XCTUnwrap(HerdrChoiceReader.read(try host("codex-approval-network").rows))
        XCTAssertEqual(labels(choices).first, "Yes, proceed")
        XCTAssertEqual(labels(choices).last, "No, and tell Codex what to do differently")
        XCTAssertTrue(choices.signature.contains("curl"))
    }

    func testCodexsModelPickerIsWalkedWithTheArrowsPastNine() throws {
        let choices = try XCTUnwrap(HerdrChoiceReader.read(try host("codex-model-picker").rows))
        let numbers = choices.options.compactMap(\.number)
        XCTAssertEqual(numbers.first, 4, "the list is scrolled; it starts where the screen does")
        XCTAssertEqual(numbers.last, 11)
        XCTAssertEqual(choices.options.last?.highlighted, true)
        // A one-digit row still goes by its digit; 10 is one Up from 11.
        XCTAssertEqual(choices.options.first?.keys, ["4"])
        XCTAssertEqual(choices.options.first(where: { $0.number == 10 })?.keys, ["Up", "Enter"])
        XCTAssertEqual(choices.options.last?.keys, ["Enter"])
        XCTAssertTrue(choices.escape, "esc back")
        XCTAssertNotNil(choices.options.first?.detail, "codex's description column is the detail")
    }

    func testAMovedHighlightIsADifferentScreen() throws {
        let before = try XCTUnwrap(HerdrChoiceReader.read(try host("codex-model-picker").rows))
        let after = try XCTUnwrap(HerdrChoiceReader.read(try host("codex-model-picker-moved").rows))
        XCTAssertNotEqual(before.signature, after.signature, "a tap aimed at the old highlight is refused")
        XCTAssertEqual(after.options.first(where: { $0.number == 11 })?.keys, ["Down", "Enter"])
    }

    func testCodexsQuestionCardOnTheHost() throws {
        let fruit = try XCTUnwrap(HerdrChoiceReader.read(try host("codex-ask-fruit").rows))
        XCTAssertEqual(fruit.options.map(\.label), ["Apple", "Pear", "None of the above"])
        XCTAssertEqual(fruit.options.map(\.keys), [["1"], ["2"], ["Down", "Down", "Tab"]],
                       "probed on the host: 2 answered Pear; HERDR-10: None of the above opens the note")
        XCTAssertEqual(fruit.question, "Pick a fruit?")
        XCTAssertFalse(fruit.escape, "esc interrupts the conversation there")
    }

    func testCodexsPermissionsPicker() throws {
        let picker = try XCTUnwrap(HerdrChoiceReader.read(try host("codex-permissions").rows))
        XCTAssertEqual(picker.options.map(\.label), ["Ask for approval", "Approve for me", "Full Access"])
        XCTAssertEqual(picker.options.map(\.highlighted), [true, false, false])
        XCTAssertTrue(picker.escape, "esc back")
    }

    func testAShellsYesOrNoOnTheHost() throws {
        let frame = try host("shell-yes-no")
        let question = try XCTUnwrap(HerdrChoiceReader.read(frame.rows, cursorRow: frame.cursor))
        XCTAssertEqual(question.kind, .yesNo)
        XCTAssertEqual(question.options.map(\.keys), [["y", "Enter"], ["n", "Enter"]], "probed: n and Enter answered n")
        XCTAssertEqual(question.options.map(\.highlighted), [false, true])
    }

    // MARK: - codex, never a menu

    func testCodexsIdleDraftAndAnswerAreNotMenus() throws {
        for name in ["codex-idle", "codex-draft", "codex-numbered-answer", "codex-slash-popup", "codex-reconnecting"] {
            let frame = try host(name)
            XCTAssertNil(HerdrChoiceReader.read(frame.rows, cursorRow: frame.cursor), name)
        }
    }

    func testANumberedListInCodexsAnswerIsNotAMenu() throws {
        let frame = try host("codex-numbered-answer")
        XCTAssertTrue(frame.rows.contains { $0.contains("1. It defines a function named greet.") },
                      "the answer really is a numbered list")
        XCTAssertNil(HerdrChoiceReader.read(frame.rows))
    }

    // MARK: - Collie's codex captures

    func testCollieCodexCapturesStillRead() throws {
        let exec = HerdrChoiceReader.read(try collie("codex--approval-exec"))
        XCTAssertEqual(keys(exec), [["1"], ["2"], ["3"]])
        let wrapped = try XCTUnwrap(HerdrChoiceReader.read(try collie("codex--v0156-approval-exec-wrapped-50")))
        XCTAssertEqual(wrapped.options.count, 3)
        XCTAssertEqual(wrapped.options[2].label, "No, and tell Codex what to do differently",
                       "a wrapped label is one label, its (esc) hint left off")
        XCTAssertTrue(wrapped.options[1].label.hasSuffix("start with `touch narrow-approval-test.txt`"))
        XCTAssertEqual(keys(HerdrChoiceReader.read(try collie("codex--v0156-approval-exec-2opt"))), [["1"], ["2"]])
        XCTAssertEqual(labels(HerdrChoiceReader.read(try collie("codex--v0156-approval-patch"))).count, 3)
    }

    func testCodexsQuestionCardAnswersOnTheDigit() throws {
        let fruit = try XCTUnwrap(HerdrChoiceReader.read(try collie("codex--ask-fruit")))
        XCTAssertEqual(labels(fruit), ["Apple (Recommended)", "Pear", "None of the above"])
        // HERDR-10: "None of the above" opens the notes box (walk + Tab) for
        // the composer; the other options answer on their digit.
        XCTAssertEqual(keys(fruit), [["1"], ["2"], ["Down", "Down", "Tab"]], "a digit answers and submits (Collie, probed)")
        XCTAssertEqual(fruit.options[0].detail, "Choose a crisp, sweet apple.")
        XCTAssertFalse(fruit.escape, "esc interrupts the whole conversation: never a button")
        XCTAssertNotNil(HerdrChoiceReader.read(try collie("codex--ask-wizard-q1")))
        // Notes open: a digit would type into the box.
        XCTAssertNil(HerdrChoiceReader.read(try collie("codex--ask-notes-focused")))
    }

    func testCollieCodexIdleScreensAreNotMenus() throws {
        for name in ["codex--fresh-idle", "codex--working", "codex--draft"] {
            XCTAssertNil(HerdrChoiceReader.read(try collie(name)), name)
        }
    }

    // MARK: - Claude Code (Collie's corpus)

    func testClaudesPermissionPromptAnswersOnTheDigit() throws {
        let bash = try XCTUnwrap(HerdrChoiceReader.read(try collie("claude--permission-bash")))
        XCTAssertEqual(labels(bash), ["Yes", "Yes, and don’t ask again for: mkfifo fixture-fifo *", "No"])
        XCTAssertEqual(keys(bash), [["1"], ["2"], ["3"]])
        XCTAssertEqual(bash.options.map(\.lasting), [false, true, false])
        XCTAssertTrue(bash.escape)
        XCTAssertEqual(bash.question, "Do you want to proceed?")
        let edit = try XCTUnwrap(HerdrChoiceReader.read(try collie("claude--permission-edit")))
        XCTAssertEqual(labels(edit), ["Yes", "Yes, allow all edits during this session", "No"])
        XCTAssertEqual(edit.options.map(\.lasting), [false, true, false])
        for name in ["claude-lab--permission-bash--w82", "claude-lab--permission-write--w82"] {
            XCTAssertEqual(HerdrChoiceReader.read(try collie(name))?.options.first?.keys, ["1"], name)
        }
    }

    func testANarrowClaudePermissionRejoinsItsWrappedLabels() throws {
        let narrow = try XCTUnwrap(HerdrChoiceReader.read(try collie("claude-lab--permission-bash--w40")))
        XCTAssertEqual(narrow.options.count, 4)
        XCTAssertEqual(narrow.options[1].label, "Yes, and always allow access to /tmp/claude-lab/project from this project")
    }

    func testClaudesWebFetchPermissionWithoutAFooter() throws {
        let fetch = try XCTUnwrap(HerdrChoiceReader.read(try collie("claude-lab--permission-webfetch--w82")))
        XCTAssertEqual(labels(fetch), ["Yes", "Yes, and don't ask again for example.com",
                                       "No, and tell Claude what to do differently"])
        XCTAssertFalse(fetch.escape, "no footer offers it")
    }

    func testClaudesQuestionTakesTheDigitThenEnterAndSkipsTheTextField() throws {
        let select = try XCTUnwrap(HerdrChoiceReader.read(try collie("claude--select-menu")))
        XCTAssertEqual(labels(select), ["Red", "Green", "Blue", "Chat about this"],
                       "\"Type something.\" is typed into, never tapped")
        XCTAssertEqual(keys(select), [["1", "Enter"], ["2", "Enter"], ["3", "Enter"], ["5", "Enter"]])
        XCTAssertEqual(select.options[0].detail, "A warm, high-energy theme with red as the primary accent color.")
        XCTAssertEqual(HerdrChoiceReader.read(try collie("claude--wizard-q1"))?.options.first?.keys, ["1", "Enter"])
    }

    func testClaudesModelPickerAndPlanApproval() throws {
        let model = try XCTUnwrap(HerdrChoiceReader.read(try collie("claude-lab--menu-model-picker--w82")))
        XCTAssertEqual(model.options.count, 5)
        XCTAssertEqual(model.options[3].highlighted, true)
        XCTAssertEqual(model.options[0].label, "Default (recommended)")
        let plan = try XCTUnwrap(HerdrChoiceReader.read(try collie("claude--plan-approval")))
        XCTAssertEqual(labels(plan), ["Yes, and use auto mode", "Yes, manually approve edits",
                                      "No, refine with Ultraplan on Claude Code on the web"])
        XCTAssertEqual(keys(plan), [["1"], ["2"], ["3"]])
    }

    func testClaudesTrustPromptNumberedAndPointed() throws {
        let numbered = try XCTUnwrap(HerdrChoiceReader.read(try collie("claude--trust-prompt")))
        XCTAssertEqual(labels(numbered), ["Yes, I trust this folder", "No, exit"])
        let pointed = try XCTUnwrap(HerdrChoiceReader.read(try collie("claude--trust-prompt-unnumbered")))
        XCTAssertEqual(labels(pointed), ["No, exit", "Yes, I trust this folder"])
        XCTAssertEqual(keys(pointed), [["Enter"], ["Down", "Enter"]], "no digit on screen: the arrows and Enter")
        XCTAssertNil(pointed.options[0].number)
    }

    func testClaudeScreensThatAreNotMenus() throws {
        for name in ["claude--done", "claude--working", "claude--fresh-idle",
                     "claude-lab--transcript-dialog-lookalike--w82", // a menu's words, printed in an answer
                     "claude--select-multiselect-single", // checkboxes: one tap cannot answer
                     "claude--v2283-permission-amend-focused"] { // the note field has the keyboard
            XCTAssertNil(HerdrChoiceReader.read(try collie(name)), name)
        }
    }

    // MARK: - Yes or no

    func testAYesOrNoQuestionOnTheLastRow() throws {
        let apt = try XCTUnwrap(HerdrChoiceReader.read(["$ sudo apt upgrade", "Need to get 2 MB.",
                                                         "Do you want to continue? [Y/n] "], cursorRow: 2))
        XCTAssertEqual(apt.kind, .yesNo)
        XCTAssertEqual(keys(apt), [["y", "Enter"], ["n", "Enter"]])
        XCTAssertEqual(apt.options.map(\.highlighted), [true, false], "the capital is the default")
        let ssh = try XCTUnwrap(HerdrChoiceReader.read([
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? "]))
        XCTAssertEqual(keys(ssh), [["y", "e", "s", "Enter"], ["n", "o", "Enter"]])
        XCTAssertEqual(HerdrChoiceReader.read(["Overwrite? (y/N)"])?.options.map(\.highlighted), [false, true])
        // Not on the cursor's row, or not the last thing on screen: not a question.
        XCTAssertNil(HerdrChoiceReader.read(["Continue? [Y/n]", "$ "], cursorRow: 1))
        XCTAssertNil(HerdrChoiceReader.read(["Continue? [Y/n]", "$ echo"]))
        XCTAssertNil(HerdrChoiceReader.read(["Continue? [Y/n] y", "done"]))
    }

    // MARK: - Ordinary output

    func testABuildLogAndAPlainNumberedListAreNotMenus() throws {
        XCTAssertNil(HerdrChoiceReader.read([
            "[1/3] cc -c main.c", "[2/3] cc -c util.c", "[3/3] ld -o app", "FAILED: app",
            "ninja: build stopped: subcommand failed.", "$ "]))
        XCTAssertNil(HerdrChoiceReader.read([
            "Steps:", "  1. Build", "  2. Test", "  3. Ship", "", "Press enter to continue"]),
            "no selection marker: a list, not a menu")
        XCTAssertNil(HerdrChoiceReader.read([
            "› 1. Build", "› 2. Test", "", "Press enter to confirm"]), "two markers")
        XCTAssertNil(HerdrChoiceReader.read([
            "› 1. Build", "  2. Test", "", "Press enter to confirm", "", "$ ls", "README.md"]),
            "output after the footer")
        XCTAssertNil(HerdrChoiceReader.read([
            "› 3. Build", "  4. Test", "", "Press enter to confirm"]), "starts past 1 without a scroll mark")
    }

    func testTheShortcutHintIsLeftOffALabel() {
        XCTAssertEqual(HerdrChoiceReader.stripShortcut("Yes, proceed (y)"), "Yes, proceed")
        XCTAssertEqual(HerdrChoiceReader.stripShortcut("No (esc)"), "No")
        XCTAssertEqual(HerdrChoiceReader.stripShortcut("Allow all (shift+tab)"), "Allow all")
        XCTAssertEqual(HerdrChoiceReader.stripShortcut("Apple (Recommended)"), "Apple (Recommended)")
        XCTAssertEqual(HerdrChoiceReader.pointerWalk(from: 2, to: 0), ["Up", "Up", "Enter"])
        XCTAssertEqual(HerdrChoiceReader.pointerWalk(from: 0, to: 0), ["Enter"])
    }
}

/// HERDR-8's captures, read again by HERDR-9: none of them is a question.
final class HERDR9NegativeFramesTests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let sink = Sink()

    func testHERDR8sFramesAreNotMenus() throws {
        for name in ["build-log", "codex-answer", "codex-welcome", "claude-onboarding", "vim", "wide-table"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "herdr8-" + name, withExtension: "json"))
            let message = try HerdrStreamDecoder.decode(Data(contentsOf: url))
            guard case .frame(let frame) = message else { continue }
            let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: frame.width ?? 200,
                                                                             rows: frame.height ?? 55, scrollback: 0))
            terminal.feed(byteArray: frame.bytes)
            let grid = HerdrGrid.read(terminal, cursorVisible: true)
            XCTAssertNil(HerdrChoiceReader.read(HerdrChoiceReader.rows(grid), cursorRow: grid.cursor?.y), name)
        }
    }
}
