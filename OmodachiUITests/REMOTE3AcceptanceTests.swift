import XCTest

/// REMOTE-3's acceptance run against the real `omarchy` host: with a session
/// live and the overlay summoned from the host, the Omodachi logo on *our* bar
/// is the second half of A-59's toggle — the overlay goes away and the picture
/// is back, ready for input (INPUT-2).
///
/// Disabled without `OMODACHI_REMOTE3_ACCEPTANCE`, the same way every other
/// operator suite here is: it drives a real machine somebody else is using.
/// The operator sends the summon (`omodachi-host panel-summon --view overview`)
/// while this holds the session up, and watches the host's evdev / `hyprctl
/// activewindow` for the tap this test puts on the picture afterwards.
@MainActor final class REMOTE3AcceptanceTests: XCTestCase {
    /// The one simulator REMOTE-3 names. The others belong to other runs.
    private let authorizedDevices = ["D0AF9C40-994A-46AA-BF15-159FB94B6718"]

    private func mark(_ text: String) {
        print("REMOTE3 \(text) epoch=\(Date().timeIntervalSince1970)")
    }

    private func application() throws -> XCUIApplication {
        #if OMODACHI_REMOTE3_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("REMOTE-3 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        // Set, never inherited: the overlay's geometry is orientation's to
        // decide, and REMOTE-2 §9 lost a run to a Panel laid out off-screen.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("REMOTE-3 acceptance is disabled; build with OMODACHI_REMOTE3_ACCEPTANCE")
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
            Thread.sleep(forTimeInterval: 1)
        }
        return element.exists
    }

    private func disappears(_ element: XCUIElement, seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !element.exists
    }

    /// The whole of Leo's report, in order: session up, summon from the host,
    /// tap our logo, picture back, and a tap that the host can see.
    func testTheLogoOnOurBarPutsThePictureBack() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.otherElements["remote-entry-page"].waitForExistence(timeout: 10))
        mark("start extend")
        app.buttons["remote-start-extend"].tap()

        let picture = app.otherElements["remote-live-picture"]
        guard appears(picture, seconds: 120) else {
            capture("remote3-00-no-frame", app)
            throw XCTSkip("no first frame from the host")
        }
        Thread.sleep(forTimeInterval: 3)
        mark("picture up")

        let overlay = app.otherElements["remote-panel-overlay"]
        XCTAssertFalse(overlay.exists, "A-58: nothing of ours is on the picture yet")
        XCTAssertTrue(appears(overlay, seconds: 180),
                      "summon panel ① from the host: `omodachi-host panel-summon --view overview`")
        Thread.sleep(forTimeInterval: 2)
        capture("remote3-01-overlay-summoned", app)

        // The fix. The logo is panel ①'s entry and ① is what is up, so this is
        // the tap-again of A-55 — which under Remote means the picture (A-59).
        let logo = app.buttons["open-panel"]
        XCTAssertTrue(logo.waitForExistence(timeout: 10) && logo.isHittable,
                      "the bar in the overlay carries the logo")
        mark("tap logo")
        logo.tap()
        XCTAssertTrue(disappears(overlay, seconds: 5), "REMOTE-3: the overlay is gone")
        XCTAssertTrue(picture.exists, "and the picture is what is left")
        Thread.sleep(forTimeInterval: 1)
        capture("remote3-02-picture-back", app)

        // INPUT-2: the gate reopens with the overlay's dismissal, so this tap
        // is a real one on the host. The operator reads it off evdev or off a
        // `hyprctl activewindow` that changes.
        mark("tap the picture")
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 3)
        mark("tap the picture done")

        // A-57: the session ends where it always ends, from ②'s card — and to
        // get back to the card the overlay has to come back, because this test
        // just proved there is no chrome left on the picture. The operator
        // sends one more summon; without it the session is left to its TTL
        // rather than failing a run that has already made its point.
        if appears(overlay, seconds: 120), app.buttons["open-remote"].waitForExistence(timeout: 10) {
            app.buttons["open-remote"].tap()
            if app.otherElements["remote-session-card"].waitForExistence(timeout: 10) {
                app.buttons["remote-end"].tap()
                if app.buttons["remote-end-confirm"].waitForExistence(timeout: 5) {
                    app.buttons["remote-end-confirm"].tap()
                }
            } else {
                mark("the session card never appeared; leaving the session to its TTL")
            }
        } else {
            mark("no second summon (`panel-summon --view overview`); leaving the session to its TTL")
        }
        _ = appears(app.otherElements["home-panel"], seconds: 60)
        mark("done")
    }
}
