import XCTest

/// REMOTE-4's acceptance run against the real `omarchy` host: with a session
/// live, the host reconfigures its own displays — a plain `hyprctl reload`,
/// which re-applies the catch-all monitor rule in `~/.config/hypr/monitors.lua`
/// to every output including this session's — and the App stays on the picture.
///
/// Leo, 2026-09-22, in a takeover: he changed the display scale from the
/// official Omarchy Display panel, Remote disconnected, and the App was back on
/// panel ① with the session gone. It had not crashed; it had treated a backend
/// that stopped as a session that had ended. What this run proves is the
/// negative: the entry page never comes back.
///
/// Disabled without `OMODACHI_REMOTE4_ACCEPTANCE`, like every other operator
/// suite here: it drives a real machine somebody else is using. The operator
/// issues the reload over ssh while this holds the session up.
@MainActor final class REMOTE4AcceptanceTests: XCTestCase {
    /// The one simulator that holds a pairing with the real host.
    private let authorizedDevices = ["D0AF9C40-994A-46AA-BF15-159FB94B6718"]

    private func mark(_ text: String) {
        print("REMOTE4 \(text) epoch=\(Date().timeIntervalSince1970)")
    }

    private func application() throws -> XCUIApplication {
        #if OMODACHI_REMOTE4_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("REMOTE-4 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("REMOTE-4 acceptance is disabled; build with OMODACHI_REMOTE4_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        mark("screenshot \(name)")
    }

    private func appears(_ element: XCUIElement, seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.exists
    }

    func testAHostReconfigureLeavesThePictureWhereItIs() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.otherElements["remote-entry-page"].waitForExistence(timeout: 10))
        mark("start extend")
        app.buttons["remote-start-extend"].tap()

        let picture = app.otherElements["remote-live-picture"]
        guard appears(picture, seconds: 120) else {
            capture("remote4-00-no-frame", app)
            throw XCTSkip("no first frame from the host")
        }
        Thread.sleep(forTimeInterval: 3)
        mark("picture up — issue `hyprctl reload` on the host now")
        capture("remote4-01-picture-before-reload", app)

        // The operator's reload lands somewhere in here. Watch for 90 s and
        // fail on the one thing that must not happen: the entry page coming
        // back, which is what "Remote 掉了，回到了 ①" was.
        let entry = app.otherElements["remote-entry-page"]
        let home = app.otherElements["home-panel"]
        let deadline = Date().addingTimeInterval(90)
        var sawBanner = false
        while Date() < deadline {
            XCTAssertFalse(entry.exists, "REMOTE-4: the session was ended and the App went back to ②")
            XCTAssertFalse(home.exists, "REMOTE-4: the session was ended and the App went back to ①")
            if app.otherElements["remote-reconnect-banner"].exists, !sawBanner {
                sawBanner = true
                capture("remote4-02-host-reconfiguring", app)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        mark("survived, banner=\(sawBanner)")
        XCTAssertTrue(picture.exists, "and the picture is still what the user is looking at")
        capture("remote4-03-picture-after-reload", app)

        // End it the way a user does, so the host is not left holding an output.
        if appears(app.otherElements["remote-panel-overlay"], seconds: 5),
           app.buttons["open-remote"].waitForExistence(timeout: 5) {
            app.buttons["open-remote"].tap()
        }
        if app.otherElements["remote-session-card"].waitForExistence(timeout: 10) {
            app.buttons["remote-end"].tap()
            if app.buttons["remote-end-confirm"].waitForExistence(timeout: 5) {
                app.buttons["remote-end-confirm"].tap()
            }
        } else {
            mark("no session card; leaving the session to its TTL")
        }
        _ = appears(home, seconds: 60)
        mark("done")
    }
}
