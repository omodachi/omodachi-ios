import XCTest

/// AGENT-UI-2 — "选择模型的哪里我们分成两行吧 模型和effort 一行全是折叠". On a
/// phone the header's model control put the model and the effort on one line
/// in 120 points, so a real codex thread (`gpt-6.1-sol` · `xhigh`) read as
/// "gpt-…" and nothing else. Model and effort are now two lines, in the header
/// and in the picker, in portrait and on its side, with Plan mode's chip and
/// the usage meters beside them (`--agent-plan-fixture --agent-models-fixture`).
@MainActor
final class AGENTUI2UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 300
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            app?.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        try await super.tearDown()
    }

    private func launch(_ language: String, _ locale: String) {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--agent-plan-fixture", "--agent-models-fixture",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 10))
        app.buttons["open-agent"].tap()
        let hint = element("hint-dismiss")
        if hint.waitForExistence(timeout: 2) { hint.tap() }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The screen's own picture: after a rotation `app.screenshot()` is a
    /// portrait image drawn sideways (ARCH1AcceptanceTests).
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func rotate(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        sleep(2)
    }

    /// The control is whole on the screen, at least 44 high, wide enough for
    /// `gpt-6.1-sol` on a line of its own, and says the model and the effort.
    private func checkTwoLines(_ moment: String) {
        let control = element("agent-model-control")
        XCTAssertTrue(control.waitForExistence(timeout: 15), moment)
        XCTAssertTrue(control.label.contains("gpt-6.1-sol"), "\(moment): \(control.label)")
        XCTAssertTrue(control.label.contains("xhigh"), "\(moment): \(control.label)")
        let frame = control.frame
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame), "\(moment): the model control \(frame) is off the screen")
        XCTAssertTrue(control.isHittable, "\(moment): the model control cannot be tapped")
        XCTAssertGreaterThanOrEqual(frame.height, 44, "\(moment): the hit area is under 44")
        // 11 mono characters at the phone's 11 pt step, and the padding.
        XCTAssertGreaterThanOrEqual(frame.width, 88, "\(moment): the model control is \(frame.width) wide")
        let identity = element("agent-identity")
        XCTAssertTrue(identity.exists, "\(moment): the identity is gone")
        XCTAssertTrue(identity.label.contains("default"), "\(moment): \(identity.label)")
    }

    private func type(_ words: String) {
        let composer = element("agent-chat-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText(words)
        let send = element("agent-send")
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    private func run(_ language: String, _ locale: String, tag: String) {
        launch(language, locale)
        checkTwoLines("\(tag) header")
        capture("agent-ui2-\(tag)-header-portrait")

        // Plan mode's chip shares the header (typed as AGENTPLAN1UITests does).
        type("/plan")
        let chip = element("agent-plan-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "\(tag): no Plan chip")
        app.swipeDown()
        sleep(1)
        checkTwoLines("\(tag) plan portrait")
        capture("agent-ui2-\(tag)-plan-portrait")
        rotate(.landscapeLeft)
        checkTwoLines("\(tag) plan landscape")
        capture("agent-ui2-\(tag)-plan-landscape")
        chip.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: chip)
        waitForExpectations(timeout: 10)
        checkTwoLines("\(tag) header landscape")
        capture("agent-ui2-\(tag)-header-landscape")

        element("agent-model-control").tap()
        let row = element("agent-effort-gpt-5.6-sol-codex-max-xhigh")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(tag): the picker has no rows")
        capture("agent-ui2-\(tag)-picker-landscape")
        rotate(.portrait)
        // Turning the phone draws the panel again, list closed.
        let picker = element("agent-model-picker")
        if !picker.exists { element("agent-model-control").tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(tag): the picker has no rows in portrait")
        capture("agent-ui2-\(tag)-picker-portrait")
        // The control is its own way back (UX-4 §4).
        for _ in 0..<3 where picker.exists {
            element("agent-model-control").tap()
            _ = element("agent-chat-composer").waitForExistence(timeout: 3)
        }
        XCTAssertFalse(picker.exists, "\(tag): the model control did not put the list away")
    }

    func testModelAndEffortReadInFullEnglish() {
        run("en", "en_US", tag: "en")
    }

    func testModelAndEffortReadInFullChinese() {
        run("zh-Hans", "zh_CN", tag: "zh")
    }

    // MARK: - Herdr's bar (Leo: the Panel toggle left of Type looked like an
    // agent face and did what the bar's own logo does)

    /// Without the toggle, the menu is the bar's logo away in every layout the
    /// Herdr panel has: upright, on its side, typing (keyboard up).
    func testTheMenuIsTheBarsLogoAwayFromHerdrInEveryLayout() {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "--herdr-agents-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-control-bar"].firstMatch.waitForExistence(timeout: 10))
        let hint = element("hint-dismiss")
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        let logo = app.buttons["open-panel"]

        func reachable(_ moment: String) {
            XCTAssertTrue(logo.waitForExistence(timeout: 5), "\(moment): no bar logo")
            XCTAssertTrue(logo.isHittable, "\(moment): the bar logo cannot be tapped")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(logo.frame), "\(moment): the logo \(logo.frame) is off the screen")
        }
        reachable("upright")
        capture("agent-ui2-herdr-bar-portrait")
        rotate(.landscapeLeft)
        reachable("on its side")
        capture("agent-ui2-herdr-bar-landscape")
        // Typing: Type on, and the keyboard itself (the pane's composer).
        let type = element("herdr-type")
        XCTAssertTrue(type.waitForExistence(timeout: 5))
        type.tap()
        let field = element("herdr-composer")
        if field.waitForExistence(timeout: 5) { field.tap() }
        // A simulator with a hardware keyboard attached shows none on screen;
        // the bar is then checked with the composer focused all the same.
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        sleep(1)
        reachable("on its side, typing")
        capture("agent-ui2-herdr-bar-landscape-typing")
        rotate(.portrait)
        if !app.keyboards.firstMatch.exists, field.exists { field.tap(); sleep(1) }
        reachable("upright, typing")
        capture("agent-ui2-herdr-bar-portrait-typing")
        logo.tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10), "the logo did not open the menu")
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-control-bar"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(element("herdr-panel").exists, "the Panel toggle is still in Herdr's bar")
    }
}
