import XCTest

/// LITE-1c: Settings › this computer › "Get notifications with Odomo" opens
/// Odomo in the Safari view over the app, whose Share sheet offers "Add to
/// Home Screen" (iOS 26 and 27: added as a standalone web app). The host is
/// the PAIR-5 offline fixture, so nothing answers; the Odomo address comes
/// from `--odomo-url`, a loopback port nothing needs to listen on.
@MainActor final class LITE1cOdomoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 120
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    func testTheOdomoRowOpensTheSafariViewOverTheApp() {
        let odomo = ProcessInfo.processInfo.environment["OMODACHI_ODOMO_URL"] ?? "http://127.0.0.1:18099/odomo/"
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--pair5-offline", "--odomo-url=\(odomo)",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["open-setup"].waitForExistence(timeout: 30))
        app.buttons["open-setup"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["host-road-sentence"].waitForExistence(timeout: 5))
        let entry = app.descendants(matching: .any)["host-odomo"]
        let deadline = Date().addingTimeInterval(10)
        while !entry.isHittable, Date() < deadline { app.swipeUp() }
        XCTAssertTrue(entry.isHittable)
        XCTAssertTrue(entry.label.contains("Odomo"), entry.label)
        capture("lite1c-odomo-row")
        entry.tap()
        // The Safari view's own controls: Share is where "Add to Home Screen" is.
        XCTAssertTrue(app.buttons["ShareButton"].waitForExistence(timeout: 15), "the Safari view is up")
        // Odomo itself only answers where a host (or the demo daemon) is
        // listening; the page is for the screenshot, not the assertion.
        _ = app.webViews.staticTexts.firstMatch.waitForExistence(timeout: 10)
        capture("lite1c-odomo-safari-view")
        // The Safari view's own Close, top leading (not the toolbar's Stop).
        let close = app.buttons.matching(identifier: "Close").allElementsBoundByIndex
            .filter { $0.isHittable }.min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(close, "the Safari view has its Close")
        if let close { close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let back = app.descendants(matching: .any)["host-odomo"].waitForExistence(timeout: 10)
        capture("lite1c-odomo-after-close")
        XCTAssertTrue(back, "closing it is back where it was")
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
