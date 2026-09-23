import XCTest

/// STORE-1 §1. The demo, from the unpaired first screen and back.
///
/// Hermetic: `--ui-testing --unpaired` is the host list with nothing stored,
/// and the demo it opens is fixture data with no host behind it.
@MainActor
final class STORE1DemoUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 120
    }

    func testTheDemoIsEnteredFromTheFirstScreenCarriesItsLabelAndLeaves() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30),
                      "an unpaired app opens on the host list")
        let enter = app.descendants(matching: .any)["demo-enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10), "the first screen offers the demo")
        enter.tap()

        let banner = app.descendants(matching: .any)["demo-banner-label"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "the demo says it is one")
        XCTAssertEqual(banner.label, "Demo · not a real computer")
        XCTAssertTrue(app.buttons["open-remote"].exists, "the demo is the Panel with its bar")

        // It stays on top of every panel.
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["demo-remote-needs-host"].waitForExistence(timeout: 5))
        XCTAssertTrue(banner.exists)
        app.buttons["open-notifications"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["notifications-panel"].waitForExistence(timeout: 5))
        XCTAssertTrue(banner.exists)

        app.descendants(matching: .any)["demo-exit"].tap()
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 10),
                      "leaving the demo is the host list again")
        XCTAssertFalse(app.descendants(matching: .any)["demo-banner"].exists)
    }
}

/// STORE-1 §4.5. The App Store screenshots, from the demo and nothing else.
/// Compiled only with `OMODACHI_STORE1_SCREENSHOTS` and run through
/// `scripts/build.sh acceptance OMODACHI_STORE1_SCREENSHOTS STORE1ScreenshotTests`
/// on simulators of the sizes Apple asks for; each shot is a full-screen
/// attachment exported next to the result bundle.
@MainActor
final class STORE1ScreenshotTests: XCTestCase {
    func testStoreScreenshotsFromTheDemo() throws {
        #if OMODACHI_STORE1_SCREENSHOTS
        continueAfterFailure = true
        executionTimeAllowance = 600
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = pad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["demo-banner"].waitForExistence(timeout: 10))
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        settle()
        capture("01-panel-menu")

        if app.buttons["panel-segment-keybindings"].exists {
            app.buttons["panel-segment-keybindings"].tap()
            XCTAssertTrue(app.textFields["shortcut-search"].waitForExistence(timeout: 10))
            settle()
            capture("02-panel-keybindings")
            app.buttons["panel-segment-menu"].tap()
        }

        app.buttons["open-notifications"].tap()
        XCTAssertTrue(any["notifications-panel"].waitForExistence(timeout: 10))
        settle()
        capture("03-notifications")

        app.buttons["open-ssh"].tap()
        settle(2.5)
        capture("04-ssh-demo-shell")

        app.buttons["open-remote"].tap()
        XCTAssertTrue(any["demo-remote-needs-host"].waitForExistence(timeout: 10))
        settle()
        capture("05-remote-needs-a-computer")

        app.buttons["open-setup"].tap()
        XCTAssertTrue(any["settings-screen"].waitForExistence(timeout: 10))
        settle()
        capture("06-settings")
        #else
        throw XCTSkip("STORE-1 screenshots are disabled; build with OMODACHI_STORE1_SCREENSHOTS")
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
