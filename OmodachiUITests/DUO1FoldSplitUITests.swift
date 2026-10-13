import XCTest

/// DUO-1, hermetic (the demo). On an open foldable ① puts the menu and
/// Keybindings one in each half of the screen, divided at the fold. A UI test
/// cannot open a hinge, so `--fold-fixture` makes this simulator read as an
/// open foldable with its fold across the middle of the screen.
@MainActor
final class DUO1FoldSplitUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    private func launch(_ app: XCUIApplication, fold: Bool) {
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (fold ? ["--fold-fixture"] : [])
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
    }

    /// Held wide, both halves are on screen with no segmented control and
    /// meet at the fold. Held tall (the fold runs across), ① is one column
    /// behind the segmented control, as on any phone (Leo, round 2).
    func testHeldWideTheHalvesMeetAtTheFoldHeldTallItIsOneColumn() {
        let app = XCUIApplication()
        launch(app, fold: true)
        let any = app.descendants(matching: .any)
        XCUIDevice.shared.orientation = .landscapeLeft
        let menu = any["menu-half"].firstMatch, keys = any["keybindings-half"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertTrue(keys.waitForExistence(timeout: 10), "held wide: Keybindings is beside the menu")
        XCTAssertFalse(any["panel-segment-keybindings"].exists, "no segmented control when both are shown")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(menu.frame.maxX, window.midX, accuracy: 2, "the menu ends at the fold")
        XCTAssertEqual(keys.frame.minX, window.midX, accuracy: 2, "Keybindings starts at the fold")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(any["panel-segment-keybindings"].waitForExistence(timeout: 10), "held tall: the segments")
        XCTAssertFalse(any["keybindings-half"].exists)
    }

    /// The Keybindings search survives the turn from the split to the
    /// segments and back.
    func testTheSearchSurvivesTheTurn() {
        let app = XCUIApplication()
        launch(app, fold: true)
        let any = app.descendants(matching: .any)
        XCUIDevice.shared.orientation = .landscapeLeft
        let search = any["shortcut-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("show")
        XCUIDevice.shared.orientation = .portrait
        let segment = any["panel-segment-keybindings"].firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        segment.tap()
        XCTAssertTrue(any["shortcut-search"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(any["shortcut-search"].firstMatch.value as? String, "show")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(any["menu-half"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(any["shortcut-search"].firstMatch.value as? String, "show")
    }

    /// Not a foldable: a phone held upright is one column behind the segments, as before.
    func testWithoutAFoldThePhoneIsOneColumn() {
        let app = XCUIApplication()
        launch(app, fold: false)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["panel-segment-keybindings"].waitForExistence(timeout: 10))
        XCTAssertFalse(any["keybindings-half"].exists)
    }
}
