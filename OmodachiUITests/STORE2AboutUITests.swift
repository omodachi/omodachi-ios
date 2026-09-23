import XCTest

/// STORE-2 §4. Settings ⑥'s About: version, licence, source and privacy — in
/// the demo, because App Review sees the app without a host.
///
/// Hermetic: `--ui-testing --unpaired` and the demo's fixtures; nothing is
/// opened in Safari (the two link rows are only checked, never tapped).
@MainActor
final class STORE2AboutUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    func testAboutCarriesTheLicenceTheSourceAndThePrivacyPolicyInTheDemo() {
        XCUIDevice.shared.orientation = .portrait
        let app = STORE2About.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)

        STORE2About.openSettingsInTheDemo(app)
        XCTAssertTrue(STORE2About.reveal(any["settings-licence"], in: app), "About has a licence row")
        let version = any["settings-version"].label
        XCTAssertTrue(version.hasPrefix("0.1.0 (") && version.hasSuffix(")"), "release and build: \(version)")
        XCTAssertTrue(any["settings-source-code"].exists)
        XCTAssertEqual(any["settings-source-code"].value as? String, "https://github.com/omodachi/omodachi-ios")
        XCTAssertTrue(any["settings-privacy"].exists)
        XCTAssertEqual(any["settings-privacy"].value as? String, "https://omodachi.app/privacy")

        XCTAssertFalse(any["licence-page"].exists, "the page is closed until asked for")
        any["settings-licence"].tap()
        XCTAssertTrue(any["licence-page"].waitForExistence(timeout: 5))
        XCTAssertTrue(any["licence-component-0"].exists)
        XCTAssertTrue(any["licence-component-0"].label.contains("GPL-3.0"), any["licence-component-0"].label)
        XCTAssertTrue(STORE2About.reveal(any["licence-text"], in: app), "the full text is on the page")
        XCTAssertTrue(any["licence-text-copy"].exists, "and can be copied")
        XCTAssertTrue(any["demo-banner"].exists, "all of it inside the demo")
    }
}

/// STORE-2 §6. The three screenshots the report carries. Compiled only with
/// `OMODACHI_STORE2_SCREENSHOTS` and run through `scripts/build.sh acceptance
/// OMODACHI_STORE2_SCREENSHOTS STORE2ScreenshotTests` on a simulator made for it.
@MainActor
final class STORE2ScreenshotTests: XCTestCase {
    func testAboutLicenceAndTheIconOnTheHomeScreen() throws {
        #if OMODACHI_STORE2_SCREENSHOTS
        continueAfterFailure = true
        executionTimeAllowance = 300
        XCUIDevice.shared.orientation = .portrait
        let app = STORE2About.launch()
        let any = app.descendants(matching: .any)
        STORE2About.openSettingsInTheDemo(app)
        XCTAssertTrue(STORE2About.reveal(any["settings-privacy"], in: app))
        settle()
        capture("STORE-2-01-settings-about")

        any["settings-licence"].tap()
        XCTAssertTrue(any["licence-page"].waitForExistence(timeout: 5))
        // The page's head: the one-sentence why, then the list from
        // THIRD-PARTY.md, the GPL components first.
        XCTAssertTrue(STORE2About.reveal(any["licence-component-6"], in: app))
        settle()
        capture("STORE-2-02-licence")

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Omodachi"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        for _ in 0..<4 where !icon.isHittable {
            springboard.swipeLeft()
            settle(0.8)
        }
        settle(2)
        capture("STORE-2-03-home-screen-icon")
        #else
        throw XCTSkip("STORE-2 screenshots are disabled; build with OMODACHI_STORE2_SCREENSHOTS")
        #endif
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

@MainActor
enum STORE2About {
    static func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    static func openSettingsInTheDemo(_ app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30), "the first screen offers the demo")
        any["demo-enter"].tap()
        XCTAssertTrue(any["demo-banner"].waitForExistence(timeout: 10))
        app.buttons["open-setup"].tap()
        XCTAssertTrue(any["settings-screen"].waitForExistence(timeout: 10))
    }

    /// Scrolls ⑥ until `element` is on screen; a bounded number of swipes.
    static func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<30 {
            if element.exists && element.isHittable { return true }
            app.descendants(matching: .any)["settings-screen"].swipeUp(velocity: .fast)
        }
        return element.exists && element.isHittable
    }
}
