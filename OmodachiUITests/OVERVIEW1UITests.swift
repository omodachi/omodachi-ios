import XCTest

/// OVERVIEW-1, hermetic (the demo with `--herdr-agents-fixture
/// --overview-fixture`, no host): the bar's Herdr entry counts what waits for
/// you; the switcher row ends with the counts and opens the list under it;
/// the list is Needs you / Working / Done, not seen, and one tap goes there —
/// a pane here, or the Agent panel; the session menu says each session's
/// counts; the workspace chip carries its most urgent state and a finished
/// pane its square. iPhone and iPad, upright and on their side.
@MainActor
final class OVERVIEW1UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func launch(_ language: String = "en", locale: String = "en_US",
                        orientation: UIDeviceOrientation = .portrait) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "--herdr-agents-fixture", "--overview-fixture"]
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

    private func value(_ element: XCUIElement) -> String { (element.value as? String) ?? "" }

    /// What the bar, the switcher, the chip and the pane say before anything is opened.
    private func checkTheMarks(_ app: XCUIApplication, needsYou: String, chip: String) {
        let any = app.descendants(matching: .any)
        let herdr = app.buttons["open-herdr"]
        XCTAssertTrue(value(herdr).contains("2"), "two panes wait, in two sessions: \(value(herdr))")
        let open = any["herdr-overview-open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(value(open).contains(needsYou), value(open))
        let workspace = any["herdr-workspace-w1"].firstMatch
        XCTAssertTrue(workspace.exists)
        XCTAssertEqual(value(workspace), chip)
        XCTAssertTrue(any["herdr-unseen-w1:p4"].firstMatch.exists, "the finished pane nobody opened has its square")
        XCTAssertFalse(any["herdr-unseen-w1:p3"].firstMatch.exists, "a working pane has none")
    }

    private func openTheList(_ app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        any["herdr-overview-open"].firstMatch.tap()
        XCTAssertTrue(any["herdr-overview"].firstMatch.waitForExistence(timeout: 5))
    }

    private func walk(_ app: XCUIApplication, _ prefix: String, needsYou: String, chip: String) {
        let any = app.descendants(matching: .any)
        checkTheMarks(app, needsYou: needsYou, chip: chip)
        attach(app, prefix + "-1-marks")
        openTheList(app)
        for section in ["needs_you", "working", "done"] {
            XCTAssertTrue(any["herdr-overview-section-\(section)"].firstMatch.exists, section)
        }
        for row in ["agent", "herdr:omodachi:w1:p1", "herdr:debug:w2:p1", "herdr:omodachi:w1:p3",
                    "herdr:work:w1:p2", "herdr:omodachi:w1:p4"] {
            XCTAssertTrue(any["overview-row-\(row)"].firstMatch.exists, row)
        }
        attach(app, prefix + "-2-list")
        // One tap goes there: a pane in this session…
        any["overview-row-herdr:omodachi:w1:p3"].firstMatch.tap()
        XCTAssertFalse(any["herdr-overview"].firstMatch.waitForExistence(timeout: 1), "the list closes")
        let pane = any["herdr-pane-w1:p3"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        XCTAssertTrue(pane.isSelected, "the pane it named is on screen")
        // …the session menu says what each session holds…
        any["herdr-session-switcher"].firstMatch.tap()
        let debug = any["herdr-session-debug"].firstMatch
        XCTAssertTrue(debug.waitForExistence(timeout: 5))
        attach(app, prefix + "-3-menu")
        any["herdr-session-omodachi"].firstMatch.tap()
        // …and the Agent's row opens the Agent panel.
        openTheList(app)
        any["overview-row-agent"].firstMatch.tap()
        XCTAssertTrue(any["agent-identity"].firstMatch.waitForExistence(timeout: 10), "the Agent panel")
    }

    func testTheListFromTheSwitcherEN() {
        let app = launch()
        walk(app, "overview-en", needsYou: "Needs you 3", chip: "Something needs you")
    }

    func testTheListFromTheSwitcherZH() {
        let app = launch("zh-Hans", locale: "zh_CN")
        walk(app, "overview-zh", needsYou: "等你 3", chip: "有在等你的")
    }

    /// On its side: the switcher keeps the counts, the list opens and scrolls,
    /// and the iPad's grid column carries the same marks.
    func testOnItsSideToo() {
        let app = launch(orientation: .landscapeLeft)
        let any = app.descendants(matching: .any)
        checkTheMarks(app, needsYou: "Needs you 3", chip: "Something needs you")
        openTheList(app)
        XCTAssertTrue(any["overview-row-herdr:omodachi:w1:p4"].firstMatch.exists)
        attach(app, "overview-en-4-landscape")
        any["herdr-overview-close"].firstMatch.tap()
        XCTAssertFalse(any["herdr-overview"].firstMatch.waitForExistence(timeout: 1))
    }

    /// With nothing to say there is nothing: no count on the bar, no summary.
    func testNothingWaitingSaysNothing() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "--herdr-agents-fixture"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-composer"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(any["herdr-overview-open"].firstMatch.exists)
        XCTAssertFalse(value(app.buttons["open-herdr"]).contains("waiting"))
        XCTAssertEqual(value(any["herdr-workspace-w1"].firstMatch), "")
    }
}
