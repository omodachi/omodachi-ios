import XCTest

/// HERDR-9, hermetic (the demo with `--herdr-choices-fixture`, no host): codex
/// is waiting on a command approval in `w1:p1` and a shell asks `[y/N]` in
/// `w1:p2`. The fixture keeps every write in a list (`herdr-fixture-sent`)
/// and answers the way those panes do, so a test can see what a tap sent and
/// that the question left the screen.
@MainActor
final class HERDR9UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func launch(_ language: String = "en", locale: String = "en_US",
                        orientation: UIDeviceOrientation = .portrait) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "--herdr-choices-fixture"]
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

    private func gone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + "-" + (phone ? "iphone" : "ipad") // non-copy
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Choices

    func testTheApprovalIsAnsweredFromTheStripAndTheStripGoes() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let strip = any["herdr-choices"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "codex's approval is a strip of choices")
        let yes = any["herdr-choice-0"].firstMatch
        XCTAssertEqual(yes.label, "Yes, proceed", "VoiceOver reads the option's own words")
        XCTAssertEqual(any["herdr-choice-1"].firstMatch.label,
                       "Yes, and don't ask again for commands that start with `printf hi > hello.txt`")
        XCTAssertEqual(any["herdr-choice-2"].firstMatch.label, "No, and tell Codex what to do differently")
        XCTAssertTrue(any["herdr-choices-escape"].firstMatch.exists, "the footer offers esc")
        // Above the composer, below the mirror.
        XCTAssertLessThanOrEqual(strip.frame.maxY, any["herdr-composer"].firstMatch.frame.minY + 1)
        attach(app, "HERDR-9-strip")
        yes.tap()
        XCTAssertTrue(waitForSent(app, "w1:p1 keys 1"), "the digit codex confirms on: \(sent(app))")
        XCTAssertTrue(gone(strip), "the question left the screen, and the strip with it")
        XCTAssertFalse(sent(app).contains("keys 2"), "one tap, one answer")
        attach(app, "HERDR-9-answered")
    }

    func testTheStripShowsInEveryMirrorMode() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let chip = any["herdr-zoom"].firstMatch
        XCTAssertTrue(any["herdr-choices"].firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            chip.tap()
            XCTAssertTrue(any["herdr-choices"].firstMatch.waitForExistence(timeout: 3), "mode \(chip.label)")
        }
    }

    func testEscDeclinesAndAYesOrNoQuestionTakesTheLetterAndEnter() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["herdr-choices-escape"].firstMatch.waitForExistence(timeout: 10))
        any["herdr-choices-escape"].firstMatch.tap()
        XCTAssertTrue(waitForSent(app, "w1:p1 keys Escape"))
        XCTAssertTrue(gone(any["herdr-choices"].firstMatch))

        any["herdr-pane-w1:p2"].firstMatch.tap()
        let no = any["herdr-choice-1"].firstMatch
        XCTAssertTrue(no.waitForExistence(timeout: 10), "the shell's [y/N] is a Yes / No strip")
        XCTAssertEqual(any["herdr-choice-0"].firstMatch.label, "Yes")
        XCTAssertEqual(no.label, "No")
        attach(app, "HERDR-9-yes-no")
        no.tap()
        XCTAssertTrue(waitForSent(app, "w1:p2 keys n Enter"), sent(app))
        XCTAssertTrue(gone(any["herdr-choices"].firstMatch))
    }

    // MARK: - The empty composer

    func testBackspaceOnTheEmptyComposerReachesThePane() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let composer = any["herdr-composer"].firstMatch
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        let delete = keyboard.keys["delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(any["herdr-echo"].firstMatch.waitForExistence(timeout: 1.4), "it shows that it went")
        attach(app, "HERDR-9-echo")
        XCTAssertTrue(waitForSent(app, "w1:p1 keys Backspace"), "⌫ on an empty box is ⌫ on the pane: \(sent(app))")
        // With words in the box, ⌫ edits them and nothing goes to the pane.
        composer.typeText("ab")
        delete.tap()
        XCTAssertEqual(composer.value as? String, "a")
        XCTAssertEqual(sent(app).components(separatedBy: "Backspace").count - 1, 1, sent(app))
    }

    func testReturnOnTheEmptyComposerIsEnterAndAnswersTheHighlightedRow() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["herdr-choices"].firstMatch.waitForExistence(timeout: 10))
        any["herdr-composer"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        any["herdr-composer"].firstMatch.typeText("\n")
        XCTAssertTrue(waitForSent(app, "w1:p1 keys Enter"), sent(app))
        XCTAssertTrue(gone(any["herdr-choices"].firstMatch), "Enter confirmed the row codex had marked")
    }

    // MARK: - The keyboard and the mirror

    /// With the keyboard up the mirror ends above the composer and the
    /// keyboard: the pane's newest rows are not under the keys.
    func testTheKeyboardDoesNotCoverTheMirrorsNewestRows() {
        for orientation in phone ? [UIDeviceOrientation.portrait, .landscapeLeft] : [.portrait] {
            let app = launch(orientation: orientation)
            let any = app.descendants(matching: .any)
            let composer = any["herdr-composer"].firstMatch
            composer.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 1.0) // the keyboard's own animation
            let mirror = any["herdr-wrap"].firstMatch.exists ? any["herdr-wrap"].firstMatch : any["herdr-fit"].firstMatch
            XCTAssertTrue(mirror.exists)
            XCTAssertLessThanOrEqual(mirror.frame.maxY, keyboard.frame.minY + 1,
                                     "\(orientation.rawValue): the mirror ends above the keyboard")
            XCTAssertLessThanOrEqual(mirror.frame.maxY, composer.frame.minY + 1, "and above the composer")
            let note = XCTAttachment(string: String(format: "mirror %.0f pt tall, keyboard top %.0f, window %.0f",
                                                    mirror.frame.height, keyboard.frame.minY,
                                                    app.windows.firstMatch.frame.height))
            note.name = "HERDR-9-keyboard-mirror-\(orientation.rawValue)"
            note.lifetime = .keepAlways
            add(note)
            // A phone on its side with the keyboard up has the composer and
            // the bar left over it, and in the demo its banner too: the rule
            // there is only that nothing hides under the keys.
            if orientation == .portrait {
                XCTAssertGreaterThan(mirror.frame.height, 60, "with rows left to read")
            }
            attach(app, "HERDR-9-keyboard-up-\(orientation == .portrait ? "portrait" : "landscape")")
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testTheKeysRowCarriesBackspace() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        if phone { any["herdr-keys-toggle"].firstMatch.tap() }
        let key = any["herdr-key-backspace"].firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        XCTAssertTrue(waitForSent(app, "w1:p1 keys Backspace"), sent(app))
    }

    // MARK: - Screenshots, both languages

    func testScreenshotsInChinese() {
        let app = launch("zh-Hans", locale: "zh_CN")
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["herdr-choices"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(any["herdr-choices-title"].firstMatch.label.contains("pane"))
        attach(app, "HERDR-9-strip-zh")
        any["herdr-pane-w1:p2"].firstMatch.tap()
        XCTAssertTrue(any["herdr-choice-1"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(any["herdr-choice-1"].firstMatch.label, "否")
        attach(app, "HERDR-9-yes-no-zh")
    }
}
