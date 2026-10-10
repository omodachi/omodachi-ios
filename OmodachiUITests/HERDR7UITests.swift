import XCTest

/// HERDR-7, hermetic (the demo with `--herdr-agents-fixture`, no host): Herdr
/// shows which pane runs an agent and what it is doing with a still marker
/// and words — the animated face stays in the Agent panel and on the bar.
/// Every agent row says its agent and its state to VoiceOver, the one that is
/// waiting says so in words, and a shell row says neither.
@MainActor
final class HERDR7UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func launch(_ language: String = "en", locale: String = "en_US") -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "--herdr-agents-fixture",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-pane-w1:p4"].firstMatch.waitForExistence(timeout: 10), "the fixture's four panes")
        return app
    }

    func testAgentRowsSayTheirAgentAndStateAndAShellRowDoesNot() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let waiting = any["herdr-pane-w1:p1"].firstMatch.label
        XCTAssertTrue(waiting.contains("codex"), waiting)
        XCTAssertTrue(waiting.contains("Waiting for you"), waiting)
        let working = any["herdr-pane-w1:p3"].firstMatch.label
        XCTAssertTrue(working.contains("claude") && working.contains("Working"), working)
        let done = any["herdr-pane-w1:p4"].firstMatch.label
        XCTAssertTrue(done.contains("codex") && done.contains("Done"), done)
        let shell = any["herdr-pane-w1:p2"].firstMatch.label
        for word in ["Waiting for you", "Working", "Done", "Idle"] {
            XCTAssertFalse(shell.contains(word), "a shell pane has no agent state: \(shell)")
        }
        XCTAssertTrue(any["herdr-waiting"].firstMatch.exists, "waiting is said in words on the row")
        attach(app, "HERDR-7-en")
    }

    /// The Chinese walk, for the screenshots and the words.
    func testChineseRowsSayTheStateInChinese() {
        let app = launch("zh-Hans", locale: "zh_CN")
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["herdr-pane-w1:p1"].firstMatch.label.contains("在等你"))
        XCTAssertTrue(any["herdr-pane-w1:p3"].firstMatch.label.contains("在干活"))
        attach(app, "HERDR-7-zh")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + "-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
        shot.lifetime = .keepAlways
        add(shot)
    }
}
