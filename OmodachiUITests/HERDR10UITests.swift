import XCTest

/// HERDR-10, hermetic (the demo with `--herdr-choices-fixture
/// --herdr-cjk-fixture`, no host): codex in `w1:p1` asks two Chinese
/// questions on a 94×39 pane - the real frames from the host. On a phone
/// the composer typed into used to cut the grid to about half the pane, which
/// garbled the Chinese and lost the strip; the grid stays 94×39 now, the strip
/// answers both questions, and "None of the above" takes a note from the
/// composer. Copy works on the grid (a long press) and from the More menu.
@MainActor
final class HERDR10UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func launch(_ language: String = "en", locale: String = "en_US") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "--herdr-choices-fixture", "--herdr-cjk-fixture"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-composer"].firstMatch.waitForExistence(timeout: 10))
        if any["hint-dismiss"].firstMatch.exists { any["hint-dismiss"].firstMatch.tap() }
        return app
    }

    private func sent(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["herdr-fixture-sent"].firstMatch.label
    }

    private func waitForSent(_ app: XCUIApplication, _ line: String, timeout: TimeInterval = 5) -> Bool {
        let element = app.descendants(matching: .any)["herdr-fixture-sent"].firstMatch
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", line),
                                                    object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + "-" + (phone ? "iphone" : "ipad") // non-copy
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Step the mirror with its chip until it says `words`.
    private func mode(_ app: XCUIApplication, _ words: [String]) {
        let chip = app.descendants(matching: .any)["herdr-zoom"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        for _ in 0..<4 where !words.contains(where: { chip.label.contains($0) }) {
            chip.tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    private let style = ["具体例子 (Recommended)", "核心原理", "实际操作", "None of the above"]

    func testTheChineseCardKeepsItsGridAndItsStripWhileTheComposerIsTyped() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["herdr-choices"].firstMatch.waitForExistence(timeout: 10), "codex's Chinese card is a strip")
        XCTAssertEqual((0..<4).map { any["herdr-choice-\($0)"].firstMatch.label }, style)
        mode(app, ["Fit"])
        let composer = any["herdr-composer"].firstMatch
        composer.tap()
        composer.typeText("好的我看一下")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(sent(app).contains("grid 94x39"), "every update of the panel leaves the grid alone: \(sent(app))")
        XCTAssertTrue(any["herdr-choices"].firstMatch.exists, "and the strip stays")
        attach(app, "HERDR-10-fit-typed")
        // HERDR-12: Actual size is the iPad's; the phone's other mode is Wrap.
        mode(app, [phone ? "Wrap" : "Actual"])
        XCTAssertTrue(sent(app).contains("grid 94x39"))
        attach(app, phone ? "HERDR-10-wrap" : "HERDR-10-actual")
    }

    func testBothQuestionsAnsweredWithANoteOnTheSecond() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["herdr-choices"].firstMatch.waitForExistence(timeout: 10))
        any["herdr-choice-1"].firstMatch.tap()
        XCTAssertTrue(waitForSent(app, "w1:p1 keys 2"), sent(app))
        let none = any["herdr-choice-2"].firstMatch
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "None of the above"), object: none)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 5), .completed, "question 2 is on the strip")
        XCTAssertEqual(any["herdr-choice-0"].firstMatch.label, "简短回答")
        attach(app, "HERDR-10-question-2")
        none.tap()
        XCTAssertTrue(waitForSent(app, "w1:p1 keys Down Down Tab"), "the marker walks to it and the notes box opens")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the composer takes the note")
        XCTAssertFalse(any["herdr-choices"].firstMatch.exists, "with the notes box open the strip steps aside")
        attach(app, "HERDR-10-note-open")
        any["herdr-composer"].firstMatch.typeText("都不合适，请用表格对比\n")
        XCTAssertTrue(waitForSent(app, "w1:p1 text 都不合适，请用表格对比"), sent(app))
        XCTAssertTrue(waitForSent(app, "w1:p1 keys Enter"), "Enter submits the answer with its note")
    }

    func testCopyFromTheGridAndFromTheMenu() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["herdr-choices"].firstMatch.waitForExistence(timeout: 10))
        mode(app, ["Fit"])
        let fit = any["herdr-fit"].firstMatch
        fit.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).press(forDuration: 0.8)
        attach(app, "HERDR-10-after-press")
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the edit menu: \(app.menuItems.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(app.menuItems["Select All"].firstMatch.exists)
        attach(app, "HERDR-10-copy-menu")
        copy.tap()
        any["herdr-more"].firstMatch.tap()
        let item = any["herdr-menu-copyOutput"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.staticTexts["Copied what the pane shows now."].firstMatch.waitForExistence(timeout: 5))
    }

    func testChineseInterfaceScreenshots() {
        let app = launch("zh-Hans", locale: "zh_CN")
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["herdr-choices"].firstMatch.waitForExistence(timeout: 10))
        attach(app, "HERDR-10-zh-strip")
        mode(app, ["适应"])
        attach(app, "HERDR-10-zh-fit")
    }
}
