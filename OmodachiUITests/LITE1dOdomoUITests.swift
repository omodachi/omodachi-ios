import XCTest

/// LITE-1d: Odomo where people look for notifications — a card at the top of
/// Notifications and a row at the top level of Settings. The host is the
/// PAIR-5 offline fixture, so nothing answers; what the host would have said
/// about Odomo comes from launch flags (`--odomo-url`, `--odomo-push-devices`,
/// `--odomo-none`). The live run against a core is in LITE-1d-report.md.
@MainActor final class LITE1dOdomoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 180
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    private func launch(_ odomo: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--pair5-offline"] + odomo + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["open-notifications"].waitForExistence(timeout: 30))
    }

    private var odomoURL: String {
        ProcessInfo.processInfo.environment["OMODACHI_ODOMO_URL"] ?? "http://127.0.0.1:18099/odomo/"
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func settingsRow() -> XCUIElement {
        app.buttons["open-setup"].tap()
        let row = element("settings-odomo")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the row is at the top level of Settings")
        return row
    }

    func testTheCardOpensOdomoInTheAppAndHidePutsItAway() {
        launch(["--odomo-url=\(odomoURL)", "--odomo-push-devices=0"])
        app.buttons["open-notifications"].tap()
        let card = element("notifications-odomo-card")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "offered at the top of Notifications")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'locked'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Add it to the Home Screen'")).firstMatch.exists,
                      "the hint for what to do in it")
        capture("lite1d-card-en")
        element("odomo-card-open").tap()
        // The Safari view's own controls: Share is where "Add to Home Screen" is.
        XCTAssertTrue(app.buttons["ShareButton"].waitForExistence(timeout: 15), "Odomo opens in the Safari view")
        _ = app.webViews.staticTexts.firstMatch.waitForExistence(timeout: 10)
        capture("lite1d-safari-view-en")
        let close = app.buttons.matching(identifier: "Close").allElementsBoundByIndex
            .filter { $0.isHittable }.min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(close, "the Safari view has its Close")
        if let close { close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(card.waitForExistence(timeout: 10), "nothing changed on the computer, so it is still offered")

        element("odomo-card-hide").tap()
        XCTAssertTrue(waitForAbsence(card), "Hide puts it away for this computer")
        XCTAssertTrue(element("odomo-card-hidden").exists, "and says where it went")
        let row = settingsRow()
        XCTAssertEqual(row.value as? String, "Not set up yet.")
        capture("lite1d-settings-off-en")
    }

    func testWithAPhoneGettingOdomoTheCardIsGoneAndSettingsSaysOn() {
        launch(["--odomo-url=\(odomoURL)", "--odomo-push-devices=1"])
        app.buttons["open-notifications"].tap()
        XCTAssertTrue(element("notifications-panel").waitForExistence(timeout: 10))
        XCTAssertFalse(element("notifications-odomo-card").exists)
        let row = settingsRow()
        XCTAssertEqual(row.value as? String, "On for this computer.")
        capture("lite1d-settings-on-en")
    }

    func testWithoutTailscaleTheCardSaysWhyAndLeadsToTheMove() {
        launch(["--odomo-none", "--odomo-push-devices=0"])
        app.buttons["open-notifications"].tap()
        XCTAssertTrue(element("notifications-odomo-card").waitForExistence(timeout: 10), "explained, not hidden")
        XCTAssertTrue(element("odomo-card-none").exists)
        XCTAssertTrue(element("odomo-card-move").exists, "a computer on this Wi-Fi is offered Tailscale")
        capture("lite1d-card-none-en")
        element("odomo-card-move").tap()
        XCTAssertTrue(element("move-tailscale").waitForExistence(timeout: 10), "the move opens in Settings")
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return !element.exists
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
