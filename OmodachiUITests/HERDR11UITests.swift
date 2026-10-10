import XCTest

/// HERDR-11, hermetic (the demo with `--herdr11-fixture --herdr-agents-fixture`,
/// no host): the New workspace card starts codex or claude and stars folders
/// (HERDR-12 took the latest-reply card away); the one connection clock says amber and red
/// over every panel, and a mirror nobody has heard from is dimmed with its time.
@MainActor
final class HERDR11UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func launch(_ language: String = "en", locale: String = "en_US", extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "--herdr11-fixture", "--herdr-agents-fixture"] + extra
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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + "-" + (phone ? "iphone" : "ipad") // non-copy
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitForSent(_ app: XCUIApplication, _ line: String, timeout: TimeInterval = 5) -> Bool {
        let element = app.descendants(matching: .any)["herdr-fixture-sent"].firstMatch
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", line),
                                                    object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - §1 Launch and favourites

    /// More → New workspace… (the "+" ends a strip that scrolls on a phone).
    private func openCard(_ app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        any["herdr-more"].firstMatch.tap()
        let item = any["herdr-menu-newWorkspace"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(any["herdr-new-workspace"].firstMatch.waitForExistence(timeout: 5))
    }

    private func newWorkspaceCard(_ app: XCUIApplication, _ prefix: String) {
        let any = app.descendants(matching: .any)
        openCard(app)
        XCTAssertTrue(any["herdr-launch-row"].firstMatch.waitForExistence(timeout: 5), "a HERDR-11 host offers launchers")
        XCTAssertTrue(any["herdr-launch-shell"].firstMatch.exists)
        any["herdr-launch-codex"].firstMatch.tap()
        let create = any["herdr-new-workspace-create"].firstMatch
        XCTAssertTrue(create.isEnabled, "an empty folder is the home folder")
        XCTAssertTrue(any["herdr-folder-favourite-~/code/uptime"].firstMatch.exists, "favourites come first")
        let star = any["herdr-folder-recent-~/Work/notes-star"].firstMatch
        XCTAssertTrue(star.exists)
        star.tap()
        XCTAssertTrue(waitForSent(app, "favourite ~/Work/notes true"))
        XCTAssertTrue(any["herdr-folder-favourite-~/Work/notes"].firstMatch.waitForExistence(timeout: 3))
        attach(app, "\(prefix)-1-card")
        create.tap()
        XCTAssertTrue(waitForSent(app, "create cwd=~ launch=codex"))
        XCTAssertFalse(any["herdr-new-workspace"].firstMatch.exists)
    }

    func testTheCardStartsAnAgentAndStarsAFolderEN() {
        let app = launch()
        defer { app.terminate() }
        newWorkspaceCard(app, "en")
    }

    func testTheCardStartsAnAgentAndStarsAFolderZH() {
        let app = launch("zh-Hans", locale: "zh_CN")
        defer { app.terminate() }
        newWorkspaceCard(app, "zh")
    }

    func testAShellIsStillOneTapAway() {
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        openCard(app)
        XCTAssertTrue(any["herdr-launch-shell"].firstMatch.waitForExistence(timeout: 5))
        any["herdr-launch-shell"].firstMatch.tap()
        let path = any["herdr-new-workspace-path"].firstMatch
        path.tap()
        // Return in the folder field is Create (the keyboard covers the button).
        path.typeText("~/code/uptime\n")
        XCTAssertTrue(waitForSent(app, "create cwd=~/code/uptime launch=-"))
    }

    // MARK: - §3 One honest connection

    private func connection(_ app: XCUIApplication, _ state: String, _ prefix: String) {
        let any = app.descendants(matching: .any)
        let banner = any[state == "trouble" ? "connection-banner-trouble" : "connection-banner-lost"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5), state)
        XCTAssertTrue(any["herdr-mirror-stale"].firstMatch.waitForExistence(timeout: 5), "the mirror says when it was")
        attach(app, "\(prefix)-5-connection-\(state)")
        // The banner lies over every panel, not only Herdr.
        app.buttons["open-panel"].firstMatch.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
    }

    func testTheClockSaysAmberAndRedWithTheCauseEN() {
        for state in ["trouble", "unreachable"] {
            let app = launch(extra: ["--connection-fixture", state])
            connection(app, state, "en")
            app.terminate()
        }
    }

    func testTheClockSaysTheCauseZH() {
        for state in ["offline", "unreachable"] {
            let app = launch("zh-Hans", locale: "zh_CN", extra: ["--connection-fixture", state])
            connection(app, state, "zh")
            app.terminate()
        }
    }
}
