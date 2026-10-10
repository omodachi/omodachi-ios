import XCTest

/// HERDR-6, hermetic (the demo, no host): "New workspace…" is in the More
/// menu, and a small "+" ends the workspaces. The demo changes no session, so
/// both say so in the notice row instead of opening the card (the card itself
/// is proven against the real host, HERDR-6 report §4).
@MainActor
final class HERDR6UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func launchIntoHerdr(_ app: XCUIApplication) {
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-composer"].firstMatch.waitForExistence(timeout: 10))
    }

    func testTheMoreMenuOffersANewWorkspace() {
        let app = XCUIApplication()
        launchIntoHerdr(app)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        any["herdr-more"].firstMatch.tap()
        let item = any["herdr-menu-newWorkspace"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(any["herdr-menu-newTab"].firstMatch.exists)
        item.tap()
        XCTAssertTrue(any["herdr-notice"].firstMatch.waitForExistence(timeout: 5), "the demo says what it would do")
        XCTAssertFalse(any["herdr-new-workspace"].firstMatch.exists)
    }

    func testAPlusEndsTheWorkspaces() {
        let app = XCUIApplication()
        launchIntoHerdr(app)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let plus = any["herdr-workspace-new"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        XCTAssertEqual(plus.label, "New workspace…")
        // It comes after every workspace on screen.
        let workspaces = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'herdr-workspace-w'"))
        for index in 0..<workspaces.count {
            let frame = workspaces.element(boundBy: index).frame
            XCTAssertTrue(plus.frame.minX >= frame.maxX - 1 || plus.frame.minY >= frame.maxY - 1, "after \(index)")
        }
    }
}
