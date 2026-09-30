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

/// STORE-6 §A. What App Review walks through: the demo computer is `desktop`,
/// its rows run and say where, a confirm row asks twice, and every panel has
/// something in it.
@MainActor
final class STORE6DemoUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    func testEveryDemoPanelHasSomethingAndARowRunsOnTheDemoComputer() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["desktop"].firstMatch.waitForExistence(timeout: 5), "the demo computer is `desktop`")
        XCTAssertFalse(app.staticTexts["Unavailable"].exists, "no row in the demo is unavailable")

        any["menu-system"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Unavailable"].exists)
        let lock = any["menu-system.lock"].firstMatch
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        lock.tap()
        XCTAssertTrue(any["menu-confirm-system.lock"].firstMatch.waitForExistence(timeout: 2), "the first tap arms it")
        lock.tap()
        let toast = any["panel-toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertTrue(toast.label.contains("ran on the demo computer"), toast.label)

        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-pane-w1:p2"].firstMatch.waitForExistence(timeout: 10), "Herdr shows the demo's panes")
        app.buttons["open-agent"].tap()
        XCTAssertTrue(any["agent-identity"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "part of the demo"))
            .firstMatch.waitForExistence(timeout: 10), "the Agent conversation says it is the demo's")
        app.buttons["open-notifications"].tap()
        XCTAssertTrue(any["notification-demo-5"].firstMatch.waitForExistence(timeout: 10), "five notifications")
        app.buttons["open-remote"].tap()
        XCTAssertTrue(any["demo-remote-needs-host"].waitForExistence(timeout: 5))
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
        // STORE-6 §C2: every panel of the demo, as evidence for the report.
        continueAfterFailure = true
        executionTimeAllowance = 900
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = pad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        let language = ProcessInfo.processInfo.environment["OMODACHI_SHOT_LANGUAGE"] ?? "en"
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["demo-banner"].waitForExistence(timeout: 10))
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        settle()
        capture("01-panel")

        any["menu-style"].firstMatch.tap()
        settle()
        capture("02-panel-style-open")
        any["menu-style"].firstMatch.tap()

        let lock = any["menu-system.lock"].firstMatch
        lock.tap()
        settle(0.3)
        capture("03-confirm-armed")
        lock.tap()
        settle(0.4)
        capture("04-ran-on-the-demo-computer")

        if app.buttons["panel-segment-keybindings"].exists {
            app.buttons["panel-segment-keybindings"].tap()
            settle()
        }
        let terminal = any["shortcut-demo.shortcut.002"].firstMatch
        if terminal.exists { terminal.tap() }
        settle()
        capture("05-keybindings")
        if app.buttons["panel-segment-menu"].exists { app.buttons["panel-segment-menu"].tap() }

        app.buttons["open-notifications"].tap()
        XCTAssertTrue(any["notifications-panel"].waitForExistence(timeout: 10))
        settle()
        capture("06-notifications")

        app.buttons["open-herdr"].tap()
        settle(2.5)
        capture("07-herdr")

        app.buttons["open-agent"].tap()
        settle(2.5)
        capture("08-agent")

        app.buttons["open-ssh"].tap()
        settle(2.5)
        capture("09-ssh-demo-shell")

        app.buttons["open-remote"].tap()
        XCTAssertTrue(any["demo-remote-needs-host"].waitForExistence(timeout: 10))
        settle()
        capture("10-remote-needs-a-computer")

        app.buttons["open-setup"].tap()
        XCTAssertTrue(any["settings-screen"].waitForExistence(timeout: 10))
        settle()
        capture("11-settings")
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
