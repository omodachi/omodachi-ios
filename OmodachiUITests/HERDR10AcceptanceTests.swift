import XCTest

/// HERDR-10 on the real host, in the throwaway session `h10-test` only (never
/// Leo's sessions): codex asking Chinese questions with `request_user_input`
/// on a 94×39 pane (the size of Leo's own), seen on an iPhone in Wrap, Fit and
/// Actual, with the composer typed into in between (what garbled Leo's
/// mirror); then answered from the strip, "None of the above" with a note
/// from the composer. The same file runs on the batch2 build for the "before"
/// pictures (no strip there: it only looks). Disabled without
/// `OMODACHI_HERDR10_ACCEPTANCE`, and refuses any simulator but the one named
/// in `OMODACHI_H10_DEVICE`. What codex is asked is set up on the host
/// between the steps, in `h10-test`.
@MainActor final class HERDR10AcceptanceTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func application() throws -> XCUIApplication {
        #if OMODACHI_HERDR10_ACCEPTANCE
        let device = environment["SIMULATOR_UDID"] ?? environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, let allowed = environment["OMODACHI_H10_DEVICE"], device == allowed else {
            throw XCTSkip("HERDR-10 refuses any simulator but OMODACHI_H10_DEVICE (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let language = environment["OMODACHI_H10_LANG"] ?? "en"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("HERDR-10 acceptance is disabled; build with OMODACHI_HERDR10_ACCEPTANCE")
        #endif
    }

    private var tag: String { (environment["OMODACHI_H10_TAG"] ?? "run") + "-" + (environment["OMODACHI_H10_LANG"] ?? "en") }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "HERDR-10-" + tag + "-" + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "HERDR-10-" + tag + "-note"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("=== " + text + " ===")
    }

    func testAPairWithTheRealHost() throws {
        let app = try application()
        let gate = app.otherElements["onboarding-gate"]
        if !gate.waitForExistence(timeout: 10) { return }
        let manual = OnboardingNavigation.manualAdd(app)
        if manual.waitForExistence(timeout: 10) {
            manual.tap()
            let field = app.textFields["connect-manual-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(environment["OMODACHI_OPERATOR_HOST"] ?? "omarchy")
            app.buttons["connect-manual-submit"].tap()
        }
        let home = app.otherElements["home-panel"]
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !home.exists { Thread.sleep(forTimeInterval: 2) }
        XCTAssertTrue(home.exists, "approve the request on the host with `omodachi-host pair approve <id> --no-remote`")
    }

    /// Into `h10-test`, on codex's pane (the workspace `w1`).
    @discardableResult private func openCodex(_ app: XCUIApplication) -> Bool {
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 60))
        app.buttons["open-herdr"].tap()
        let switcher = any["herdr-session-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 30))
        // The session is chosen for this device on the host beforehand. The
        // switcher's menu is never touched (HERDR-9 once started one of Leo's
        // sessions from it).
        Thread.sleep(forTimeInterval: 3)
        guard (switcher.value as? String ?? "").contains("h10-test") else {
            capture("wrong-session")
            XCTFail("not on h10-test (\(switcher.value as? String ?? "?")); nothing else is touched")
            return false
        }
        let chip = any["herdr-workspace-w1"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        chip.tap()
        Thread.sleep(forTimeInterval: 5)
        if any["hint-dismiss"].firstMatch.exists { any["hint-dismiss"].firstMatch.tap() }
        return true
    }

    private func mode(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["herdr-zoom"].firstMatch.label
    }

    /// Step the mirror (the chip) until its label is `wanted`'s.
    private func go(_ app: XCUIApplication, to wanted: [String]) {
        let chip = app.descendants(matching: .any)["herdr-zoom"].firstMatch
        for _ in 0..<4 where !wanted.contains(where: { mode(app).contains($0) }) {
            chip.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    private func strip(_ app: XCUIApplication) -> String {
        let any = app.descendants(matching: .any)
        guard any["herdr-choices"].firstMatch.waitForExistence(timeout: 6) else { return "no strip" }
        return "strip: " + (0..<5).compactMap { index -> String? in
            let choice = any["herdr-choice-\(index)"].firstMatch
            return choice.exists ? choice.label : nil
        }.joined(separator: " | ")
    }

    /// codex shows "Question 1/2" in Chinese. The mirror in each mode, the
    /// composer typed into (each letter updates the panel, which is what cut
    /// the grid on the phone), the strip.
    func testBTheQuestionCardInEveryMode() throws {
        let app = try application()
        let any = app.descendants(matching: .any)
        guard openCodex(app) else { return }
        note("opened in \(mode(app)); " + strip(app))
        capture("1-default")
        go(app, to: ["Fit", "适应"])
        capture("2-fit")
        let composer = any["herdr-composer"].firstMatch
        composer.tap()
        Thread.sleep(forTimeInterval: 1)
        composer.typeText("好的我看一下")
        Thread.sleep(forTimeInterval: 3)
        note("fit after typing; " + strip(app))
        capture("3-fit-typed")
        // Put the keyboard away (a tap on the screen) and look again.
        let mirror = [any["herdr-wrap"].firstMatch, any["herdr-fit"].firstMatch].first(where: \.exists)
        mirror?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 2)
        capture("4-fit-keyboard-away")
        // HERDR-12: a phone has no Actual size any more.
        if UIDevice.current.userInterfaceIdiom != .phone {
            go(app, to: ["Actual", "原始"])
            capture("5-actual")
        }
        go(app, to: ["Wrap", "换行"])
        note("wrap; " + strip(app))
        capture("6-wrap")
    }

    /// The card answered from the strip: "核心原理" for question 1, then
    /// "None of the above" for question 2 with a note from the composer.
    func testCAnswerFromTheStripWithANote() throws {
        let app = try application()
        let any = app.descendants(matching: .any)
        guard openCodex(app) else { return }
        let first = strip(app)
        note("question 1: " + first)
        guard first != "no strip" else { capture("no-strip"); return }
        any["herdr-choice-1"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 3)
        let second = strip(app)
        note("question 2: " + second)
        capture("7-question-2")
        let none = (0..<5).map { any["herdr-choice-\($0)"].firstMatch }.last { $0.exists && $0.label.hasPrefix("None of the above") }
        guard let none else { return XCTFail("no None of the above in \(second)") }
        none.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "the composer takes the note")
        Thread.sleep(forTimeInterval: 1.5)
        capture("8-note-open")
        any["herdr-composer"].firstMatch.typeText("都不合适，请用表格对比\n")
        Thread.sleep(forTimeInterval: 6)
        capture("9-answered")
    }

    /// Copy: a long press on the grid (Fit), the edit menu, and the More
    /// menu's Copy output.
    func testDCopy() throws {
        let app = try application()
        let any = app.descendants(matching: .any)
        guard openCodex(app) else { return }
        go(app, to: ["Fit", "适应"])
        let fit = any["herdr-fit"].firstMatch
        fit.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.12)).press(forDuration: 0.8)
        Thread.sleep(forTimeInterval: 1)
        capture("10-copy-menu")
        let copy = app.menuItems.firstMatch
        note("edit menu: " + app.menuItems.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        if copy.exists { copy.tap() }
        Thread.sleep(forTimeInterval: 1)
        let more = any["herdr-more"].firstMatch
        if more.exists {
            more.tap()
            Thread.sleep(forTimeInterval: 1)
            capture("11-more-menu")
            let item = any["herdr-menu-copyOutput"].firstMatch
            if item.exists { item.tap() } else { app.tap() }
            Thread.sleep(forTimeInterval: 1.5)
            capture("12-copied")
        }
    }
}
