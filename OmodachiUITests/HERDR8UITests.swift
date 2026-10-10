import XCTest

/// HERDR-8, hermetic (the demo, no host): on an iPhone the Herdr mirror opens
/// as wrapped text, a double tap goes Wrap → Fit → Wrap (HERDR-12: Actual
/// size is the iPad's) and the choice holds for the next pane of that kind; the keys fold behind one Keys
/// toggle, the hint is short and shows on one visit, and the mirror keeps most
/// of the screen. On an iPad the grid stays the default and the keys stay out.
@MainActor
final class HERDR8UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func launch(_ language: String = "en", locale: String = "en_US", agents: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            + (agents ? ["--herdr-agents-fixture"] : [])
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-zoom"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func label(_ element: XCUIElement, is value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    /// The demo with agents: codex is waiting in w1:p1 (a transcript, so it
    /// wraps), a shell in w1:p2, claude in w1:p3, codex again in w1:p4.
    func testThePhoneWrapsAndADoubleTapCyclesAndIsRemembered() throws {
        let app = launch(agents: true)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let chip = any["herdr-zoom"].firstMatch
        guard phone else {
            XCTAssertEqual(chip.label, "Fit to width", "an iPad keeps the grid")
            XCTAssertTrue(any["herdr-keys"].firstMatch.exists, "an iPad keeps its keys out")
            chip.tap()
            XCTAssertTrue(label(chip, is: "Actual size"))
            chip.tap()
            XCTAssertTrue(label(chip, is: "Wrap"))
            XCTAssertTrue(any["herdr-wrap"].firstMatch.waitForExistence(timeout: 5))
            chip.tap()
            XCTAssertTrue(label(chip, is: "Fit to width"))
            return
        }
        XCTAssertEqual(chip.label, "Wrap")
        let wrap = any["herdr-wrap"].firstMatch
        XCTAssertTrue(wrap.waitForExistence(timeout: 5))
        let text = any["herdr-wrap-text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String ?? "").contains("def main"), "the pane's rows, as text")

        // The mirror keeps most of the screen: the keys are folded away.
        XCTAssertFalse(any["herdr-keys"].firstMatch.exists)
        let window = app.windows.firstMatch.frame
        let share = wrap.frame.height / window.height
        let note = XCTAttachment(string: String(format: "mirror %.0f of %.0f pt = %.1f%%", wrap.frame.height, window.height, share * 100))
        note.name = "HERDR-8-mirror-share"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertGreaterThanOrEqual(share, 0.5, "the mirror keeps most of the height, demo banner and hint included")

        // Keys: one toggle in the bar brings the rows out and puts them away.
        let toggle = any["herdr-keys-toggle"].firstMatch
        XCTAssertTrue(toggle.exists)
        toggle.tap()
        XCTAssertTrue(any["herdr-key-esc"].firstMatch.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertFalse(any["herdr-key-esc"].firstMatch.waitForExistence(timeout: 1))

        // HERDR-12: Wrap → Fit → Wrap, never Actual size on a phone.
        wrap.doubleTap()
        XCTAssertTrue(label(chip, is: "Fit to width"))
        any["herdr-terminal"].firstMatch.doubleTap()
        XCTAssertTrue(label(chip, is: "Wrap"))
        XCTAssertTrue(any["herdr-wrap"].firstMatch.waitForExistence(timeout: 5))

        // Remembered per kind: codex goes to Fit, the other codex pane opens
        // on Fit, claude still on Wrap.
        chip.tap()
        XCTAssertTrue(label(chip, is: "Fit to width"))
        tapPane("w1:p4", in: app)
        XCTAssertTrue(label(chip, is: "Fit to width"), "the next codex pane opens the same way")
        tapPane("w1:p3", in: app)
        XCTAssertTrue(label(chip, is: "Wrap"), "claude is its own kind")
    }

    /// The demo's own first pane is a vim screen: Wrap shows its grid instead
    /// and says why, and Wrap is still one choice away.
    func testAFullScreenProgramFallsBackToTheGridWithANote() throws {
        guard phone else { throw XCTSkip("the phone's default") }
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let chip = any["herdr-zoom"].firstMatch
        XCTAssertEqual(chip.label, "Fit to width")
        XCTAssertTrue(any["herdr-fullscreen-note"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(any["herdr-fullscreen-note"].firstMatch.label, "A full-screen program, shown as its screen")
        // HERDR-12: one tap to Wrap, on purpose; no Actual size on the way.
        chip.tap()
        XCTAssertTrue(label(chip, is: "Wrap"), "Wrap on purpose")
        XCTAssertTrue(any["herdr-wrap"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(any["herdr-fullscreen-note"].firstMatch.exists)
        // A plain shell pane wraps.
        tapPane("w1:p2", in: app)
        XCTAssertTrue(label(chip, is: "Wrap"))
    }

    func testThePhonesHintIsShortAndShowsOnOneVisit() throws {
        guard phone else { throw XCTSkip("the phone's hint") }
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let hint = any["hint-herdr"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        // HERDR-12: the phone's two modes, Actual size not among them.
        let words = "Double-tap the screen to switch between Wrap and Fit to width. Keys holds Esc, the arrows and ^C."
        XCTAssertTrue(any.matching(NSPredicate(format: "label == %@", words)).firstMatch.exists, "the phone's hint")
        XCTAssertFalse(any.matching(NSPredicate(format: "label CONTAINS %@", "Actual size")).firstMatch.exists)
        app.buttons["open-agent"].tap()
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-zoom"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(any["hint-herdr"].firstMatch.waitForExistence(timeout: 2), "one visit, then it is gone")
    }

    /// The screenshots: the demo with agents, English and Chinese.
    func testScreenshots() throws {
        for (language, locale) in [("en", "en_US"), ("zh-Hans", "zh_CN")] {
            let app = launch(language, locale: locale, agents: true)
            let any = app.descendants(matching: .any)
            XCTAssertTrue(any["herdr-pane-w1:p1"].firstMatch.waitForExistence(timeout: 10))
            shot(app, "wrap-\(language)")
            if phone {
                any["herdr-keys-toggle"].firstMatch.tap()
                shot(app, "keys-\(language)")
                any["herdr-keys-toggle"].firstMatch.tap()
            }
            any["herdr-zoom"].firstMatch.tap()
            shot(app, "next-\(language)")
            app.terminate()
        }
    }

    /// The phone's strip scrolls; bring the chip in before tapping it.
    private func tapPane(_ id: String, in app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        let pane = any["herdr-pane-" + id].firstMatch
        var tries = 0
        let width = app.windows.firstMatch.frame.maxX
        while pane.frame.maxX > width - 8, tries < 4 { any["herdr-grid"].firstMatch.swipeLeft(); tries += 1 }
        pane.tap()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "HERDR-8-" + name + "-" + (phone ? "iphone" : "ipad")
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
