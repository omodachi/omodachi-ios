import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import Omodachi

/// HERDR-9: the store and the composer, with no host in the room. Every
/// write lands in `writeOverride`, so what would have gone to the pane is
/// what the test reads.
@MainActor
final class HERDR9StoreTests: XCTestCase {
    private var home: HomeStore?
    private var sent: [(pane: String, write: HerdrWrite)] = []

    private func store(pane: String? = "w1:p1") -> HerdrStore {
        let defaults = UserDefaults(suiteName: "herdr9-\(UUID().uuidString)")!
        let home = HomeStore(defaults: defaults, clientFactory: { _, _ in HerdrNineNoService() }, autoConnect: false)
        self.home = home
        let store = HerdrStore(home: home)
        store.writeOverride = { [weak self] pane, write in self?.sent.append((pane, write)) }
        if let pane { store.select(pane) }
        store.terminal.getTerminal().resize(cols: 96, rows: 36)
        return store
    }

    private func keys() -> [[String]] {
        sent.compactMap { if case .keys(let keys) = $0.write { keys } else { nil } }
    }

    private func show(_ store: HerdrStore, _ text: String) {
        store.terminal.getTerminal().resetToInitialState()
        store.terminal.feed(byteArray: Array(text.utf8)[...])
    }

    // MARK: - The empty composer hands its keys to the pane

    func testAnEmptyComposerSendsItsKeysStraightToThePane() {
        let store = store()
        XCTAssertTrue(store.composerEmpty)
        store.passKey("Backspace")
        store.passKey("Enter")
        XCTAssertEqual(keys(), [["Backspace"], ["Enter"]])
        XCTAssertEqual(sent.map(\.pane), ["w1:p1", "w1:p1"])
        XCTAssertEqual(store.echo.map(\.face), ["⌫", "↵"], "and it shows that they went")
        store.draft = "hello"
        XCTAssertFalse(store.composerEmpty, "words in the box: its keys edit the words")
    }

    func testTheTextViewHandsBackspaceOnAnEmptyBoxToThePane() {
        let view = HerdrComposeTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44), textContainer: nil)
        var passed: [String] = []
        view.passKey = { passed.append($0) }
        view.text = ""
        view.deleteBackward()
        view.deleteBackward() // held: the keyboard calls it again for each repeat
        XCTAssertEqual(passed, ["Backspace", "Backspace"])
        view.text = "ab"
        view.selectedRange = NSRange(location: 2, length: 0)
        view.deleteBackward()
        XCTAssertEqual(view.text, "a", "with words, ⌫ edits them")
        XCTAssertEqual(passed.count, 2)
        XCTAssertEqual(view.returnKeyType, .send)
        XCTAssertFalse(view.enablesReturnKeyAutomatically, "Return on an empty box is a key for the pane")
        XCTAssertEqual(view.smartQuotesType, .no)
    }

    func testReturnOnAnEmptyBoxIsEnterAndWithWordsItSends() {
        let store = store()
        var height: CGFloat = 44
        var focused = false
        let field = HerdrComposeField(store: store, height: Binding(get: { height }, set: { height = $0 }),
                                      focused: Binding(get: { focused }, set: { focused = $0 }))
        let coordinator = field.makeCoordinator()
        let view = HerdrComposeTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 44), textContainer: nil)
        view.text = ""
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "\n"))
        XCTAssertEqual(keys(), [["Enter"]])
        // Words: the draft is sent (core presses Enter once it sees them).
        store.draft = "explain greet.py"
        view.text = "explain greet.py"
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 16, length: 0), replacementText: "\n"))
        let texts = sent.compactMap { if case let .text(text, submit) = $0.write { (text, submit) } else { nil } }
        XCTAssertEqual(texts.first?.0, "explain greet.py")
        XCTAssertEqual(texts.first?.1, true, "sent with Enter")
        // Anything else is typing.
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "a"))
    }

    func testAHardwareKeyboardsKeysPassOnlyFromAnEmptyBox() {
        func key(_ usage: UInt16, shift: Bool = false, control: Bool = false, command: Bool = false,
                 empty: Bool = true, composing: Bool = false) -> String? {
            HerdrComposePassthrough.key(usage: usage, shift: shift, control: control, alternate: false,
                                        command: command, empty: empty, composing: composing)
        }
        XCTAssertEqual(key(HerdrComposePassthrough.backspace), "Backspace")
        XCTAssertEqual(key(HerdrComposePassthrough.returnKey), "Enter")
        XCTAssertEqual(key(HerdrComposePassthrough.tab), "Tab")
        XCTAssertEqual(key(HerdrComposePassthrough.tab, shift: true), "shift+Tab")
        XCTAssertEqual(key(HerdrComposePassthrough.escape), "Escape")
        XCTAssertEqual([0x52, 0x51, 0x50, 0x4F].map { key($0) }, ["Up", "Down", "Left", "Right"])
        XCTAssertEqual(key(0x06, control: true), "ctrl+c", "^C from an empty box interrupts, as at the terminal")
        XCTAssertNil(key(0x06), "a letter is typing")
        XCTAssertNil(key(HerdrComposePassthrough.backspace, empty: false), "with words, ⌫ edits them")
        XCTAssertNil(key(HerdrComposePassthrough.returnKey, composing: true), "pinyin's own Return commits letters")
        XCTAssertNil(key(0x19, command: true), "⌘V is the app's")
    }

    // MARK: - Type

    func testTypeEndsWhenTheScreenIsTappedThePaneChangesOrTheAppLeaves() {
        let store = store()
        store.startTyping()
        XCTAssertTrue(store.typing)
        store.mirrorTapped()
        XCTAssertFalse(store.typing, "a tap on the mirror puts Type's keyboard away, and ends it")
        store.startTyping()
        store.select("w1:p2")
        XCTAssertFalse(store.typing, "another pane")
        store.startTyping()
        store.sceneMovedToBackground()
        XCTAssertFalse(store.typing, "the app going to the background")
        store.startTyping()
        store.toggleTyping()
        XCTAssertFalse(store.typing, "and the button still turns it off")
    }

    func testTypeShowsTheKeysThatWentAndTheyFade() async throws {
        let store = store()
        store.startTyping()
        // y, Return, ⌫ as SwiftTerm hands them over.
        store.send(source: store.terminal, data: [0x79, 0x0d, 0x7f][...])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(keys(), [["y", "Enter", "Backspace"]])
        XCTAssertEqual(store.echo.map(\.face), ["y", "↵", "⌫"])
        XCTAssertEqual(store.echoSpoken, ["y", Strings.herdrKeyEnter, Strings.herdrKeyBackspace].joined(separator: ", "))
        try await Task.sleep(for: HerdrStore.echoLifetime + .milliseconds(300))
        XCTAssertTrue(store.echo.isEmpty, "gone after a moment")
    }

    // MARK: - The keyboard and the mirror

    /// Wrap: the keyboard coming up only makes the view shorter. The text
    /// keeps its wrapping and a reader at the bottom stays at the bottom.
    func testWrapStaysAtTheBottomWhenTheKeyboardTakesHeight() async throws {
        let store = store()
        var text = ""
        for line in 1...80 { text += "line \(line)\r\n" }
        text += "› the input line"
        show(store, text)
        let grid = HerdrGrid.read(store.terminal.getTerminal(), cursorVisible: true)
        let view = HerdrWrapView(fontSize: HerdrStore.fontSize)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 600)
        view.layoutIfNeeded()
        view.show(HerdrWrap.layout(grid, width: view.columns, agent: true))
        view.layoutIfNeeded()
        view.scrollToBottom()
        let columns = view.columns
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 260)
        view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.columns, columns, "the same width, the same wrapping")
        XCTAssertEqual(view.contentOffset.y, max(0, view.contentSize.height - view.bounds.height), accuracy: 1,
                       "the newest rows are in view")
        // Scrolled up to read: it stays put.
        view.setContentOffset(.zero, animated: false)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 600)
        view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.contentOffset.y, max(0, view.contentSize.height - 600), accuracy: 1,
                       "a programmatic scroll is not the reader's; following resumes at the bottom")
    }

    /// Fit: the grid is the pane's own size, so a shorter view changes
    /// nothing in the terminal — no resize — and the bottom rows stay in view.
    func testFitNeverResizesTheGridWhenTheViewGetsShorter() throws {
        let store = store()
        let fit = store.fitView
        fit.frame = CGRect(x: 0, y: 0, width: 356, height: 600)
        fit.setPaneSize((cols: 200, rows: 55))
        fit.layoutIfNeeded()
        store.terminal.layoutIfNeeded()
        let scale = fit.zoomScale
        XCTAssertEqual(store.terminal.getTerminal().cols, 200)
        fit.setContentOffset(CGPoint(x: 0, y: max(0, fit.contentSize.height - 600)), animated: false)
        fit.frame = CGRect(x: 0, y: 0, width: 356, height: 300)
        fit.layoutIfNeeded()
        store.terminal.layoutIfNeeded()
        XCTAssertEqual(store.terminal.getTerminal().cols, 200, "the grid is untouched")
        XCTAssertEqual(store.terminal.getTerminal().rows, 55)
        XCTAssertEqual(fit.zoomScale, scale, accuracy: 0.0001, "Fit keeps its scale")
        XCTAssertEqual(fit.contentOffset.y, max(0, fit.contentSize.height - 300), accuracy: 1,
                       "and the bottom rows stay in view")
    }

    // MARK: - Choices

    private let approval = HerdrChoicesFixture.approval

    func testATapSendsTheChoicesKeysOnceAndWaitsForTheScreen() throws {
        let store = store()
        show(store, approval)
        store.refreshChoices(immediately: true)
        let choices = try XCTUnwrap(store.choices)
        XCTAssertEqual(choices.options.map(\.keys), [["1"], ["2"], ["3"]])
        store.answer(choices.options[0])
        XCTAssertEqual(keys(), [["1"]])
        XCTAssertTrue(store.choicesAnswered)
        store.answer(choices.options[2])
        XCTAssertEqual(keys(), [["1"]], "a second tap at the same question waits for the screen")
        // The screen moves on: the strip goes.
        show(store, HerdrChoicesFixture.approved)
        store.refreshChoices(immediately: true)
        XCTAssertNil(store.choices)
        XCTAssertFalse(store.choicesAnswered)
    }

    func testATapAtAQuestionThatChangedIsRefused() throws {
        let store = store()
        show(store, approval)
        store.refreshChoices(immediately: true)
        let seen = try XCTUnwrap(store.choices)
        // A different command in the same shape arrives before the tap.
        show(store, approval.replacingOccurrences(of: "printf hi > hello.txt", with: "rm -rf build"))
        store.answer(seen.options[0])
        XCTAssertTrue(keys().isEmpty, "nothing is sent at a dialog the person did not see")
        XCTAssertEqual(store.notice, Strings.herdrChoicesChanged)
        XCTAssertNotEqual(store.choices?.signature, seen.signature, "the strip shows the new one")
    }

    func testEscIsOfferedWhenTheFooterOffersIt() throws {
        let store = store()
        show(store, approval)
        store.refreshChoices(immediately: true)
        XCTAssertEqual(store.choices?.escape, true)
        store.answerEscape()
        XCTAssertEqual(keys(), [["Escape"]])
    }

    func testAShellsYesOrNoTakesTheLetterAndEnter() throws {
        let store = store(pane: "w1:p2")
        show(store, HerdrChoicesFixture.question)
        store.refreshChoices(immediately: true)
        let choices = try XCTUnwrap(store.choices)
        XCTAssertEqual(choices.kind, .yesNo)
        XCTAssertEqual(choices.options.map(\.highlighted), [false, true], "[y/N]: No is what Enter alone answers")
        store.answer(choices.options[1])
        XCTAssertEqual(keys(), [["n", "Enter"]])
        XCTAssertEqual(sent.first?.pane, "w1:p2")
    }

    func testAnotherPaneStartsWithNoChoicesAndNoEcho() {
        let store = store()
        show(store, approval)
        store.refreshChoices(immediately: true)
        store.passKey("y")
        XCTAssertNotNil(store.choices)
        XCTAssertFalse(store.echo.isEmpty)
        store.select("w1:p2")
        XCTAssertNil(store.choices)
        XCTAssertTrue(store.echo.isEmpty)
    }

    func testTheFixtureAnswersLikeTheRealPanes() {
        XCTAssertEqual(HerdrChoicesFixture.reaction(pane: "w1:p1", keys: ["1"]), HerdrChoicesFixture.approved)
        XCTAssertEqual(HerdrChoicesFixture.reaction(pane: "w1:p1", keys: ["Escape"]), HerdrChoicesFixture.declined)
        XCTAssertNil(HerdrChoicesFixture.reaction(pane: "w1:p1", keys: ["Backspace"]))
        XCTAssertNotNil(HerdrChoiceReader.read(HerdrChoicesFixture.approval
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .components(separatedBy: "\r\n")))
    }
}

/// A host that is never reached.
private struct HerdrNineNoService: CompanionServing {
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
