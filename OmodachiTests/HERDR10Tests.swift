import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import Omodachi

/// HERDR-10: Chinese broke the mirror on Leo's iPhone, and the question card
/// got no choices strip.
///
/// The frames are real: herdr 0.8.2 `terminal.frame`s from the observe
/// stream on the host - codex 0.160 asking Chinese questions with
/// `request_user_input` (one and two questions, the notes box, "None of the
/// above") and answering in Chinese and in mixed widths, in the throwaway
/// session `h10-test` on a 94×39 pane (Leo's `debug` pane's size) and a
/// 60×29 one, where the descriptions wrap. The model is a scripted stand-in
/// (`h10-scripted`); one frame is read from Leo's own `debug` pane (a codex
/// approval with a Chinese reason). `*.visible.txt` is Herdr's own
/// `pane read --source visible` of the same screen, and the two
/// `herdr10-stream-*.ndjson` are whole observe sessions, increments included.
@MainActor
final class HERDR10Tests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let sink = Sink()
    private var home: HomeStore?

    // MARK: - Fixtures

    private func url(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "herdr10-" + name, withExtension: ext),
                      "missing fixture \(name).\(ext)")
    }

    private func frame(_ name: String) throws -> HerdrFrame {
        let message = try HerdrStreamDecoder.decode(Data(contentsOf: url(name, "json")))
        guard case .frame(let frame) = message else { throw XCTSkip("not a frame") }
        return frame
    }

    private func stream(_ name: String) throws -> [HerdrFrame] {
        let text = try String(contentsOf: url(name, "ndjson"), encoding: .utf8)
        return try text.split(separator: "\n").compactMap { line in
            guard case .frame(let frame) = try HerdrStreamDecoder.decode(Data(line.utf8)) else { return nil }
            return frame
        }
    }

    private func visible(_ name: String) throws -> [String] {
        try String(contentsOf: url(name, "visible.txt"), encoding: .utf8)
            .components(separatedBy: "\n").map(HerdrChoiceReader.trimEnd)
    }

    /// Frames through a headless SwiftTerm at the frames' own size.
    private func terminal(_ frames: [HerdrFrame]) -> Terminal {
        let first = frames[0]
        let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: first.width ?? 80, rows: first.height ?? 24,
                                                                         scrollback: 0))
        for frame in frames { terminal.feed(byteArray: frame.bytes) }
        return terminal
    }

    private func rows(_ terminal: Terminal) -> [String] {
        HerdrChoiceReader.rows(HerdrGrid.read(terminal, cursorVisible: true))
    }

    private func store() -> HerdrStore {
        let defaults = UserDefaults(suiteName: "herdr10-\(UUID().uuidString)")!
        let home = HomeStore(defaults: defaults, clientFactory: { _, _ in HerdrTenNoService() }, autoConnect: false)
        self.home = home
        let store = HerdrStore(home: home)
        store.select("w1:p1")
        return store
    }

    /// The store's mirror laid out the way a phone lays it: a 94-column pane
    /// fitted into a 348-point-wide panel, which draws it at ~0.54×.
    private func phone(_ store: HerdrStore, width: CGFloat = 348, pane: (cols: Int, rows: Int) = (94, 39)) {
        let fit = store.fitView
        fit.frame = CGRect(x: 0, y: 0, width: width, height: 560)
        fit.setPaneSize(pane)
        fit.layoutIfNeeded()
        store.terminal.layoutIfNeeded()
    }

    private func grid(_ store: HerdrStore) -> (cols: Int, rows: Int) {
        (store.terminal.getTerminal().cols, store.terminal.getTerminal().rows)
    }

    // MARK: - Bug 1: the grid stays the pane's size

    /// The cause, measured: on a phone the fit view zooms the terminal below
    /// 1:1, so its `frame` is the scaled size, and setting the faces sized the
    /// grid from that frame. SwiftUI re-applied the faces on every update of
    /// the panel; one update cut a 94×39 pane's grid to 50×21.
    func testAnUpdateOfThePanelLeavesTheGridAtThePanesSize() throws {
        let store = store()
        phone(store)
        XCTAssertLessThan(store.fitView.zoomScale, 1, "a phone draws this pane smaller than 1:1")
        XCTAssertLessThan(store.terminal.frame.width, store.terminal.bounds.width, "so its frame is the scaled size")
        XCTAssertTrue(grid(store) == (94, 39))
        store.feed(try frame("codex-answer-mixed"))
        let painted = rows(store.terminal.getTerminal())
        // What `updateUIView` does on every update: the same revision again
        // and again, then a real theme change.
        for _ in 0..<5 { store.applyAppearance(revision: 7) }
        XCTAssertTrue(grid(store) == (94, 39), "got \(grid(store))")
        XCTAssertEqual(rows(store.terminal.getTerminal()), painted, "and the screen is untouched")
        store.applyAppearance(revision: 8)
        store.fitView.layoutIfNeeded()
        XCTAssertTrue(grid(store) == (94, 39), "a theme change measures at 1:1 too; got \(grid(store))")
        XCTAssertEqual(rows(store.terminal.getTerminal()), painted)
        XCTAssertEqual(store.repaintRequests, 0, "nothing moved, so nothing is asked for again")
    }

    /// The iPad: the same pane fits at 1:1, frame and bounds agree, and the
    /// faces never moved the grid - why Leo's iPad was fine all along.
    func testOnAnIPadThePaneFitsAtOneToOne() throws {
        let store = store()
        phone(store, width: 760)
        XCTAssertEqual(store.fitView.zoomScale, 1, accuracy: 0.0001)
        store.applyAppearance(revision: 1)
        XCTAssertTrue(grid(store) == (94, 39))
    }

    /// Leo's session, replayed: the whole observe stream (codex asking two
    /// Chinese questions, the answers, a Chinese reply, the mixed-width one)
    /// into the phone's mirror, with the panel updating between frames as it
    /// does while codex works. The screen it ends on is the screen a fresh
    /// full frame paints and the screen Herdr itself reads.
    func testThePhonesMirrorEndsOnTheScreenHerdrHas() throws {
        let store = store()
        phone(store)
        for (index, frame) in try stream("stream-94x39").enumerated() {
            store.feed(frame)
            store.applyAppearance(revision: 40 + index % 2)
            store.fitView.layoutIfNeeded()
        }
        XCTAssertTrue(grid(store) == (94, 39), "got \(grid(store))")
        let fresh = rows(terminal([try frame("codex-answer-mixed")]))
        XCTAssertEqual(rows(store.terminal.getTerminal()), fresh)
        let herdr = try visible("codex-answer-mixed")
        for (index, line) in herdr.enumerated() where index < fresh.count {
            XCTAssertEqual(fresh[index], line, "row \(index)")
        }
    }

    /// Whatever moves the grid next time, a frame puts it back: a full frame
    /// is painted at its own size; an increment is not painted onto cells
    /// that moved - the whole screen is asked for again.
    func testAFrameForAnotherSizePutsTheGridBackAndAsksForTheScreen() throws {
        let store = store()
        phone(store)
        store.feed(try frame("codex-ask-one"))
        store.terminal.getTerminal().resize(cols: 50, rows: 21)
        let increments = try stream("stream-94x39").filter { !$0.full }
        store.feed(try XCTUnwrap(increments.first))
        XCTAssertTrue(grid(store) == (94, 39), "got \(grid(store))")
        XCTAssertEqual(store.repaintRequests, 1)
        store.feed(try XCTUnwrap(increments.dropFirst().first))
        XCTAssertEqual(store.repaintRequests, 1, "asked once; increments wait for the full frame")
        store.terminal.getTerminal().resize(cols: 50, rows: 21)
        store.feed(try frame("codex-answer-mixed"))
        XCTAssertTrue(grid(store) == (94, 39))
        XCTAssertEqual(rows(store.terminal.getTerminal()), rows(terminal([try frame("codex-answer-mixed")])))
    }

    // MARK: - Widths: SwiftTerm and Herdr agree on every cell

    /// Every wide character on these screens (CJK, full-width punctuation and
    /// letters, emoji, the box rules of a table) takes the cells Herdr gave
    /// it: the grid read back row by row is Herdr's own text of the screen.
    func testEveryRowIsTheTextHerdrHas() throws {
        for name in ["codex-answer-mixed", "narrow-ask-q1", "narrow-ask-q2", "narrow-answer"] {
            let grid = rows(terminal([try frame(name)]))
            let herdr = try visible(name)
            for (index, line) in herdr.enumerated() where index < grid.count {
                XCTAssertEqual(grid[index], line, "\(name) row \(index)")
            }
        }
    }

    /// The increments alone build the same screen as a full frame: a stream
    /// replayed headless at the pane's size ends where a fresh frame begins.
    func testIncrementsBuildTheSameScreenAsAFullFrame() throws {
        let wide = rows(terminal(try stream("stream-94x39")))
        XCTAssertEqual(wide, rows(terminal([try frame("codex-answer-mixed")])))
        let narrow = rows(terminal(try stream("stream-60x29")))
        XCTAssertEqual(narrow, rows(terminal([try frame("narrow-answer")])))
    }

    /// Herdr places each wide character by absolute position; that is what
    /// made a narrower grid drop them one per row down the left edge.
    func testHerdrPlacesEachWideCharacterByPosition() throws {
        let bytes = String(decoding: try frame("debug-approval-cjk").bytes, as: UTF8.self)
        XCTAssertTrue(bytes.contains("可\u{1B}[11;13H以"), "a cursor move after each wide character")
    }

    // MARK: - Bug 2: codex's Chinese question card gets its strip

    private func choices(_ name: String) throws -> HerdrChoices? {
        let terminal = terminal([try frame(name)])
        let grid = HerdrGrid.read(terminal, cursorVisible: true)
        return HerdrChoiceReader.read(HerdrChoiceReader.rows(grid), cursorRow: grid.cursor?.y)
    }

    private let style = ["具体例子 (Recommended)", "核心原理", "实际操作", "None of the above"]

    func testCodexsChineseQuestionCardBecomesItsChoices() throws {
        let card = try XCTUnwrap(try choices("codex-ask-two-q1"), "Question 1/2 on a 94-column pane")
        XCTAssertEqual(card.options.map(\.label), style)
        XCTAssertEqual(card.options.first?.detail, "先用一个直观例子说明，再总结规律和要点。")
        XCTAssertEqual(card.question, "你更喜欢哪种回答风格？")
        XCTAssertEqual(card.options.map(\.keys), [["1"], ["2"], ["3"], ["Down", "Down", "Down", "Tab"]],
                       "probed on the host: 2 answered question 1 and moved to question 2")
        XCTAssertEqual(card.options.map(\.opensNote), [false, false, false, true])
        XCTAssertEqual(card.options.map(\.highlighted), [true, false, false, false])
        XCTAssertFalse(card.escape, "esc interrupts the turn there")
        // Question 2/2: "enter to submit all", three options.
        let second = try XCTUnwrap(try choices("codex-ask-two-q2"))
        XCTAssertEqual(second.options.map(\.label), ["简短回答", "详细解释", "None of the above"])
        XCTAssertEqual(second.options.map(\.keys), [["1"], ["2"], ["Down", "Down", "Tab"]])
        XCTAssertEqual(second.question, "回答要多详细？")
        XCTAssertNotEqual(card.signature, second.signature, "a tap meant for question 1 never answers question 2")
        // One question, the way Leo's looked.
        XCTAssertEqual(try choices("codex-ask-one")?.options.map(\.label), style)
    }

    /// A 60-column pane wraps each description and the footer: the strip is
    /// the same, the description joined back without a space in the middle
    /// of the Chinese.
    func testANarrowPaneWrapsTheCardAndTheStripIsTheSame() throws {
        let card = try XCTUnwrap(try choices("narrow-ask-q1"))
        XCTAssertEqual(card.options.map(\.label), style)
        XCTAssertEqual(card.options.map(\.detail), ["先用一个直观例子说明，再总结规律和要点。", "先讲清楚概念和原理，再给出简短的例子。",
                                                    "先带你做一遍，边做边解释每一步的作用。",
                                                    "Optionally, add details in notes (tab)"])
        XCTAssertEqual(card.options.last?.keys, ["Down", "Down", "Down", "Tab"],
                       "\"tab to add notes\" is on its own row above the footer here")
        let second = try XCTUnwrap(try choices("narrow-ask-q2"))
        XCTAssertEqual(second.options.map(\.label), ["简短回答", "详细解释", "None of the above"])
        XCTAssertNil(try choices("narrow-answer"), "the answered card and the Chinese reply are no menu")
    }

    func testWithTheNotesBoxOpenTheStripStepsAside() throws {
        XCTAssertNil(try choices("codex-ask-notes-open"), "a digit would be typed into the note")
        XCTAssertNil(try choices("codex-ask-notes-typed"))
    }

    /// Leo's own pane: a codex approval whose reason is Chinese.
    func testAnApprovalWithAChineseReason() throws {
        let approval = try XCTUnwrap(try choices("debug-approval-cjk"))
        XCTAssertEqual(approval.options.count, 3)
        XCTAssertEqual(approval.options.first?.label, "Yes, proceed")
        XCTAssertEqual(approval.options.map(\.keys), [["1"], ["2"], ["3"]])
        XCTAssertEqual(approval.question, "Would you like to run the following command?")
        XCTAssertTrue(approval.options[1].lasting)
    }

    /// "Questions 1/1 answered" on Leo's screen is codex's record of an
    /// answered card in the transcript, not a card waiting: no strip.
    func testChineseAndMixedAnswersAreNoMenu() throws {
        let screen = rows(terminal([try frame("codex-answer-mixed")]))
        XCTAssertTrue(screen.contains("• Questions 1/1 answered"))
        XCTAssertNil(try choices("codex-answer-mixed"))
    }

    /// "None of the above" from the strip: the marker walks to it, the notes
    /// box opens, and the composer takes the keyboard for the note - whose
    /// Return submits the answer (probed on the host: the note arrived as
    /// `user_note`).
    func testNoneOfTheAboveOpensTheNoteInTheComposer() throws {
        let store = store()
        var sent: [HerdrWrite] = []
        store.writeOverride = { _, write in sent.append(write) }
        store.feed(try frame("codex-ask-one"))
        store.refreshChoices(immediately: true)
        let card = try XCTUnwrap(store.choices)
        let none = try XCTUnwrap(card.options.last)
        let before = store.composerFocusRequests
        store.answer(none)
        XCTAssertEqual(sent.compactMap { if case .keys(let keys) = $0 { keys } else { nil } },
                       [["Down", "Down", "Down", "Tab"]])
        XCTAssertEqual(store.composerFocusRequests, before + 1)
        // A plain option does not move the keyboard.
        let other = self.store()
        other.writeOverride = { _, _ in }
        other.feed(try frame("codex-ask-one"))
        other.refreshChoices(immediately: true)
        other.answer(try XCTUnwrap(other.choices?.options.first))
        XCTAssertEqual(other.composerFocusRequests, 0)
    }

    /// With the notes box open, the composer's Return types the note and
    /// presses Enter. Core will not type a *submitted* reply into a pane
    /// whose agent Herdr calls blocked (measured on the host: "Not submitted
    /// - The agent is waiting on a question"), so the note goes as text
    /// without submit, then Enter, which submits the answer with it.
    func testTheNoteIsTypedThenEnterSubmitsIt() throws {
        let store = store()
        var sent: [HerdrWrite] = []
        store.writeOverride = { _, write in sent.append(write) }
        store.feed(try frame("codex-ask-notes-open"))
        store.draft = "都不合适，请用表格对比"
        store.sendDraft()
        XCTAssertEqual(sent, [.text("都不合适，请用表格对比", submit: false), .keys(["Enter"])])
        XCTAssertEqual(store.draft, "")
        // Anywhere else a draft is sent the usual way.
        sent = []
        store.feed(try frame("codex-answer-mixed"))
        store.draft = "继续"
        store.sendDraft()
        XCTAssertEqual(sent, [.text("继续", submit: true)])
    }

    // MARK: - Bug 4: Wrap shows the selected pane, never the last one

    func testAnotherPaneNeverShowsTheLastPanesText() throws {
        func result(_ words: String) -> HerdrWrapResult {
            HerdrWrapResult(blocks: [.text([HerdrRun(text: words, style: .plain)], indent: 0)], fullScreen: false)
        }
        let first = result("收到，你选择了「详细解释」。这是 codex 那个 tab 的文字。")
        let second = result("alex@desk:~$ ls  这是 shell 那个 tab 的文字")
        // The view on its own: a selection holds frames back, and reset()
        // lets go of everything the last pane left.
        let wrap = HerdrWrapView(fontSize: HerdrStore.fontSize)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.addSubview(wrap)
        window.makeKeyAndVisible()
        defer { wrap.removeFromSuperview(); window.isHidden = true }
        wrap.frame = CGRect(x: 0, y: 0, width: 348, height: 560)
        wrap.show(first)
        wrap.layoutIfNeeded()
        let text = try XCTUnwrap(wrap.subviews.flatMap(\.subviews).compactMap { $0 as? UITextView }.first)
        _ = text.becomeFirstResponder()
        text.selectedRange = NSRange(location: 0, length: 4)
        XCTAssertTrue(wrap.holding, "a selection holds frames back")
        wrap.show(second)
        XCTAssertEqual(wrap.shown, first, "held while the selection is up")
        // Leo's case: another tab is chosen with that selection still there.
        wrap.reset()
        XCTAssertNil(wrap.shown, "the old pane's text is gone at once")
        XCTAssertFalse(wrap.holding)
        wrap.show(second)
        XCTAssertEqual(wrap.shown, second)
        // And the store resets its own on every pane switch.
        let store = store()
        store.wrapView.frame = CGRect(x: 0, y: 0, width: 348, height: 560)
        store.wrapView.layoutIfNeeded()
        store.wrapView.show(first)
        XCTAssertEqual(store.wrapView.shown, first)
        store.select("w1:p2")
        XCTAssertNil(store.wrapView.shown)
    }

    // MARK: - Bug 6: select and copy on the grid

    func testALongPressSelectsAWordOnTheGridAndCopiesIt() throws {
        let store = store()
        phone(store)
        store.feed(try frame("codex-answer-mixed"))
        let rows = rows(store.terminal.getTerminal())
        let row = try XCTUnwrap(rows.firstIndex { $0.contains("test two") })
        let col = try XCTUnwrap(rows[row].range(of: "two")).lowerBound.utf16Offset(in: rows[row])
        store.fitView.selectWord(at: Position(col: col, row: row))
        XCTAssertEqual(store.fitView.selectedText, "two")
        store.fitView.copySelection()
        XCTAssertEqual(UIPasteboard.general.string, "two")
        XCTAssertNil(store.fitView.selectedText, "copied, the selection goes")
        store.terminal.selectAll()
        XCTAssertTrue(try XCTUnwrap(store.fitView.selectedText).contains("中文表格内容"))
        store.select("w1:p2")
        XCTAssertNil(store.fitView.selectedText, "another pane, no selection")
    }

    // MARK: - Bug 3: pinyin over the placeholder

    func testPinyinBeingComposedIsNotTheDraftAndReturnTakesTheCandidate() throws {
        let store = store()
        var sent: [HerdrWrite] = []
        store.writeOverride = { _, write in sent.append(write) }
        var height: CGFloat = 44
        var focused = false
        var shows = false
        let field = HerdrComposeField(store: store, height: Binding(get: { height }, set: { height = $0 }),
                                      focused: Binding(get: { focused }, set: { focused = $0 }),
                                      showsText: Binding(get: { shows }, set: { shows = $0 }))
        let coordinator = field.makeCoordinator()
        let view = HerdrComposeTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44), textContainer: nil)
        view.delegate = coordinator
        var passed: [String] = []
        view.passKey = { passed.append($0) }
        view.setMarkedText("zai gei wo", selectedRange: NSRange(location: 10, length: 0))
        coordinator.textViewDidChange(view)
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertEqual(store.draft, "", "marked letters are not the draft yet")
        let expectation = expectation(description: "the box says it shows text")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(shows, "so the placeholder is not drawn under them")
        // Return takes the candidate as it stands: no send, no line break.
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: view.text.count, length: 0),
                                            replacementText: "\n"))
        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(view.text, "zai gei wo")
        // ⌫ edits a composition; it never goes to the pane.
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        view.deleteBackward()
        XCTAssertTrue(passed.isEmpty)
        XCTAssertTrue(sent.isEmpty, "nothing went to the pane: \(sent)")
        XCTAssertTrue(passed.isEmpty)
    }

    // MARK: - Drafts belong to a pane in a session

    /// `w1:p1` is a pane in every session; a draft written in one is not the
    /// other's.
    func testADraftStaysInItsSession() throws {
        func layout(_ session: String) throws -> HerdrLayoutDTO {
            let json = """
            {"session": "\(session)", "revision": 1, "workspaces": [{"id": "w1", "focused": true, "tabs": [
              {"id": "w1:t1", "focused": true, "zoomed": false, "panes": [
                {"id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1", "title": "codex",
                 "focused": true, "zoomed": false, "agent": null, "size": {"cols": 94, "rows": 39}, "revision": 1}]}]}]}
            """
            return try JSONDecoder().decode(HerdrLayoutDTO.self, from: Data(json.utf8))
        }
        let store = store()
        store.apply(try layout("debug"))
        XCTAssertEqual(store.selected, "w1:p1")
        store.draft = "写给 debug 的草稿"
        store.apply(try layout("h10-test"))
        XCTAssertEqual(store.selected, "w1:p1")
        XCTAssertEqual(store.draft, "", "another session's w1:p1 has its own (empty) draft")
        store.apply(try layout("debug"))
        XCTAssertEqual(store.draft, "写给 debug 的草稿")
    }

    // MARK: - Copy output, and a Wrap screen that holds still while read

    func testCopyOutputIsThePanesScreenAsText() throws {
        let store = store()
        store.feed(try frame("narrow-answer"))
        let text = store.outputText()
        XCTAssertTrue(text.contains("收到，你选择了「详细解释」。接下来我会适当增加背景、步骤和注意事项，同时避免重复和无关内容。如果某一步你想跳过，直接告诉我就行。"),
                      "the reply codex wrapped at 60 columns is one line again: \(text)")
        XCTAssertTrue(text.contains("  1. 先确认目标：要解决什么问题？"))
        XCTAssertFalse(text.hasPrefix("\n"))
        store.copyOutput()
        XCTAssertEqual(UIPasteboard.general.string, text)
        XCTAssertEqual(store.notice, Strings.herdrCopyOutputDone)
    }

    func testScrolledUpTheWrapScreenWaitsAndSaysThereIsNewOutput() throws {
        func result(_ count: Int) -> HerdrWrapResult {
            HerdrWrapResult(blocks: (0..<count).map { .text([HerdrRun(text: "第 \($0) 行 line", style: .plain)], indent: 0) },
                            fullScreen: false)
        }
        let wrap = HerdrWrapView(fontSize: HerdrStore.fontSize)
        let mirror = HerdrMirrorView(fit: HerdrFitView(terminal: HerdrTerminalView(frame: .zero)), wrap: wrap)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.addSubview(mirror)
        window.makeKeyAndVisible()
        defer { mirror.removeFromSuperview(); window.isHidden = true }
        mirror.frame = CGRect(x: 0, y: 0, width: 348, height: 300)
        mirror.showsWrap = true
        mirror.layoutIfNeeded()
        var told: [Bool] = []
        let onNew = wrap.onNewOutput
        wrap.onNewOutput = { told.append($0); onNew?($0) }
        wrap.show(result(80))
        XCTAssertFalse(wrap.holding, "at the bottom it follows")
        wrap.layoutIfNeeded()
        XCTAssertGreaterThan(wrap.contentSize.height, 600)
        // The reader drags up: what `contentOffset` hears while tracking.
        wrap.contentOffset = .zero
        wrap.readerMoved()
        XCTAssertTrue(wrap.holding, "scrolled up, the screen holds still")
        wrap.show(result(81))
        XCTAssertEqual(wrap.shown, result(80))
        XCTAssertEqual(told.last, true)
        XCTAssertFalse(mirror.newOutput.isHidden, "New output ↓ shows")
        mirror.newOutput.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(wrap.shown, result(81), "a tap shows the newest")
        XCTAssertFalse(wrap.holding)
        XCTAssertTrue(mirror.newOutput.isHidden)
    }

    /// Wrap joins codex's Chinese paragraph back without a space where codex
    /// broke it at 60 columns (English still gets its space).
    func testWrapJoinsChineseWithoutASpace() throws {
        let grid = HerdrGrid.read(terminal([try frame("narrow-answer")]), cursorVisible: false)
        let lines = HerdrWrap.layout(grid, width: 40, agent: true).blocks.compactMap { block -> String? in
            if case .text(let runs, _) = block { return runs.map(\.text).joined() }
            return nil
        }
        XCTAssertTrue(lines.contains { $0.contains("增加背景、步骤和注意事项，同时避免重复和无关内容。如果某一步你想跳过，直接告诉我就行。") },
                      lines.joined(separator: "\n"))
    }
}

private struct HerdrTenNoService: CompanionServing {
    func connect() async throws { throw CompanionHostError.notConnected }
    func disconnect() async {}
    func fetchState() async throws -> HostStateDTO { throw CompanionHostError.notConnected }
    func fetchSnapshot() async throws -> CompanionSnapshot { throw CompanionHostError.notConnected }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter],
                targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse {
        throw CompanionHostError.notConnected
    }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse {
        throw CompanionHostError.notConnected
    }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
