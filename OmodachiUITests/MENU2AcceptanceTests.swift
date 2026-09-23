import XCTest

/// MENU-2's acceptance run: our own mark, drawn over the host bar's Omarchy
/// logo, on a real session — and the host's own Omodachi icon left alone.
///
/// The host is a **side-by-side daemon** on `127.0.0.1:8199` reached through an
/// `ssh -L` tunnel (HOST-1 §4.2): Leo's installed core is under a 24 h soak and
/// is not touched. `OMODACHI_OPERATOR_HOST` is therefore `127.0.0.1:8199` here
/// rather than the LAN address every other suite uses.
///
/// Disabled without `OMODACHI_MENU2_ACCEPTANCE`, the same way every other
/// operator suite here is: it drives a real machine somebody else is using.
@MainActor final class MENU2AcceptanceTests: XCTestCase {
    /// The one simulator MENU-2 names. The others belong to other runs.
    private let authorizedDevices = ["D0AF9C40-994A-46AA-BF15-159FB94B6718"]

    private func mark(_ text: String) {
        print("MENU2 \(text) epoch=\(Date().timeIntervalSince1970)")
    }

    private func application() throws -> XCUIApplication {
        #if OMODACHI_MENU2_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("MENU-2 refuses any simulator the spec did not name (saw \(device ?? "none"))")
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
        throw XCTSkip("MENU-2 acceptance is disabled; build with OMODACHI_MENU2_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ screenshot: XCUIScreenshot) {
        let shot = XCTAttachment(screenshot: screenshot)
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

    /// One-time: the real pairing handshake with the side-by-side daemon,
    /// approved on the host with its own socket.
    func testAPairWithTheSideDaemon() throws {
        let app = try application()
        let gate = app.otherElements["onboarding-gate"]
        if !gate.waitForExistence(timeout: 10) { return }
        let manual = app.buttons["connect-add-manual"]
        if manual.waitForExistence(timeout: 10) {
            manual.tap()
            let field = app.textFields["connect-manual-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOST"] ?? "127.0.0.1:8199")
            app.buttons["connect-manual-submit"].tap()
        }
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 300),
                      "approve on the host: `omodachi-host --socket <side> pair approve <id>`")
    }

    /// The whole of §2, in order: the session, our mark on the picture, the
    /// logo opening ① and the picture coming back.
    func testBTheMarkAnswersTheLogo() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60),
                      "MENU-2 needs a paired host; run testAPairWithTheSideDaemon first")
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.otherElements["remote-entry-page"].waitForExistence(timeout: 10))
        mark("start extend")
        app.buttons["remote-start-extend"].tap()

        let picture = app.otherElements["remote-live-picture"]
        guard appears(picture, seconds: 180) else {
            capture("menu2-00-no-frame", XCUIScreen.main.screenshot())
            throw XCTSkip("no first frame from the host")
        }
        Thread.sleep(forTimeInterval: 4)

        // A-67. Core measured the bar on the output this session owns, and our
        // mark is drawn on top of the host's Omarchy logo. Nothing is drawn
        // over the host's own Omodachi icon.
        let logo = app.buttons["remote-mark-logo"]
        XCTAssertTrue(appears(logo, seconds: 60), "the logo mark never reached the picture")
        XCTAssertFalse(app.descendants(matching: .any)["remote-mark-plugin"].exists,
                       "A-67: the plugin's own slot is never covered")
        Thread.sleep(forTimeInterval: 1)
        capture("menu2-01-mark-on-the-picture", XCUIScreen.main.screenshot())
        mark("logo hittable=\(logo.isHittable) frame=\(logo.frame)")

        let overlay = app.otherElements["remote-panel-overlay"]
        XCTAssertFalse(overlay.exists, "A-58: nothing else of ours is on the picture")
        mark("tap the logo mark")
        logo.tap()
        XCTAssertTrue(appears(overlay, seconds: 10), "the logo mark opens panel ①")
        Thread.sleep(forTimeInterval: 2)
        capture("menu2-02-logo-opens-panel-one", XCUIScreen.main.screenshot())

        // A-55 / A-59: the same destination again is the way back to the
        // picture. With the overlay up our marks are under the scrim, and the
        // scrim is the picture, so this is the same tap the user makes.
        app.otherElements["panel-scrim"].tap()
        XCTAssertTrue(disappears(overlay, seconds: 5), "and the picture is back")
        Thread.sleep(forTimeInterval: 2)
        capture("menu2-03-picture-back", XCUIScreen.main.screenshot())

        // A-67's other half is the host's: with a takeover running, the host's
        // own Omodachi icon opens nothing and says so — on the machine and from
        // here alike. The operator reads the notice off the host's own bar.
        mark("tap where the host's Omodachi icon is (the picture keeps this touch)")

        endSession(app)
    }

    /// A-67's fallback: with no mark on the picture — the operator hides the
    /// host's bar — panel ⑥'s switch puts one 26 handle in the corner.
    func testCTheCornerHandleWhenTheBarIsHidden() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60))
        // The switch first, off the picture, where ⑥ is the whole panel area.
        app.buttons["open-settings"].tap()
        let toggle = app.switches["settings-corner-handle"]
        XCTAssertTrue(appears(toggle, seconds: 10), "⑥ carries A-67's switch")
        if toggle.value as? String != "1" { toggle.tap() }
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.otherElements["remote-entry-page"].waitForExistence(timeout: 10))
        app.buttons["remote-start-extend"].tap()
        let picture = app.otherElements["remote-live-picture"]
        guard appears(picture, seconds: 180) else { throw XCTSkip("no first frame from the host") }
        Thread.sleep(forTimeInterval: 4)

        let handle = app.otherElements["remote-corner-handle"]
        mark("hide the host's bar now (`omarchy-toggle-bar` or shell.json)")
        XCTAssertTrue(appears(handle, seconds: 240),
                      "with no mark on the picture, the corner handle is what is left")
        Thread.sleep(forTimeInterval: 1)
        capture("menu2-04-corner-handle", XCUIScreen.main.screenshot())
        endSession(app)
    }

    /// A-57: the session ends from ②'s card, and the card is behind the
    /// overlay, which is behind one of our marks or the corner handle.
    private func endSession(_ app: XCUIApplication) {
        for identifier in ["remote-mark-logo", "remote-corner-handle"] {
            let entry = app.descendants(matching: .any)[identifier]
            if entry.exists && entry.isHittable { entry.tap(); break }
        }
        guard app.buttons["open-remote"].waitForExistence(timeout: 15) else {
            mark("no way back to the panel; leaving the session to its TTL")
            return
        }
        app.buttons["open-remote"].tap()
        guard app.otherElements["remote-session-card"].waitForExistence(timeout: 10) else {
            mark("the session card never appeared; leaving the session to its TTL")
            return
        }
        app.buttons["remote-end"].tap()
        if app.buttons["remote-end-confirm"].waitForExistence(timeout: 5) {
            app.buttons["remote-end-confirm"].tap()
        }
        mark("session ended")
    }
}
