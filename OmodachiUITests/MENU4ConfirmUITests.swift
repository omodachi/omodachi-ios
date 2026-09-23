import XCTest

/// MENU-4 / Study 04 A-68, on the local demo host (`--ui-testing`): a row the
/// host marks `confirm` asks for a second tap in the row itself. Nothing here
/// reaches a real machine; the demo's `System › Lock` carries the mark.
@MainActor
final class MENU4ConfirmUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 120
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            app.launch()
            XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 15))
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    private func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)["menu-\(id)"].firstMatch }

    private func reveal(_ element: XCUIElement) {
        let scroller = app.scrollViews.firstMatch
        for _ in 0..<12 where !(element.exists && element.isHittable) { scroller.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.waitForExistence(timeout: 5) && element.isHittable, "\(element) never came on screen")
    }

    private func openLock() -> XCUIElement {
        let system = row("system")
        reveal(system)
        system.tap()
        let lock = row("system.lock")
        reveal(lock)
        return lock
    }

    private var toast: XCUIElement { app.descendants(matching: .any).matching(identifier: "panel-toast").firstMatch }

    func testTheFirstTapAsksAndTheSecondSends() {
        let lock = openLock()
        lock.tap()
        let armed = app.descendants(matching: .any)["menu-confirm-system.lock"].firstMatch
        XCTAssertTrue(armed.waitForExistence(timeout: 2), "the first tap arms the row")
        XCTAssertEqual(armed.label, "再点一次执行")
        XCTAssertFalse(toast.exists, "the first tap sends nothing")
        capture("menu4-armed")
        lock.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "the second tap sends it")
        XCTAssertTrue(toast.label.contains("Lock"), toast.label)
        XCTAssertFalse(armed.exists)
    }

    func testTheQuestionGoesAwayOnItsOwnAfterTwoSeconds() {
        let lock = openLock()
        lock.tap()
        let armed = app.descendants(matching: .any)["menu-confirm-system.lock"].firstMatch
        XCTAssertTrue(armed.waitForExistence(timeout: 2))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: armed)
        wait(for: [gone], timeout: 4)
        lock.tap()
        XCTAssertTrue(armed.waitForExistence(timeout: 2), "after the window a tap is a first tap again")
        XCTAssertFalse(toast.exists)
    }

    func testARowWithoutTheMarkIsSentOnTheFirstTap() {
        let trigger = row("trigger")
        reveal(trigger)
        trigger.tap()
        let nightlight = row("trigger.toggle.nightlight")
        reveal(nightlight)
        nightlight.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["menu-confirm-trigger.toggle.nightlight"].exists)
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
