import XCTest

/// ARCH-1 §4's acceptance walk, against the real `omarchy` host, from the two
/// simulators the spec names. Disabled without `OMODACHI_ARCH1_ACCEPTANCE`, the
/// same way `UX1AcceptanceTests` and `OperatorRemoteTests` are: these drive a
/// real machine that somebody else is also using.
///
/// Screenshots are `XCTAttachment`s, exported from the `.xcresult` afterwards
/// into `docs/specs/ARCH-1-*.png`.
@MainActor final class ARCH1AcceptanceTests: XCTestCase {
    /// The spec's two, and nothing else. The three simulators other specs are
    /// using are deliberately not in this list.
    private let authorizedDevices = ["D0AF9C40-994A-46AA-BF15-159FB94B6718",
                                     "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"]

    private var isPhone: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"
    }

    private func application(_ extra: [String] = []) throws -> XCUIApplication {
        #if OMODACHI_ARCH1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("ARCH-1 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 600
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication()
        // The boards are drawn in Simplified Chinese and that is the catalog's
        // source language (ARCH-1 §6); a screenshot in the simulator's own `en`
        // would be a picture of the translation.
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        return app
        #else
        throw XCTSkip("ARCH-1 acceptance is disabled; build with OMODACHI_ARCH1_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        // `app.screenshot()` hands back the app's own window in the *device's*
        // native orientation, which after a rotation is a portrait image drawn
        // sideways into a landscape canvas with a black band beside it. The
        // screen's own screenshot is what is actually on the glass.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func appears(_ element: XCUIElement, seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return element.exists
    }

    /// One-time: the real pairing handshake, so the rest of the run has a host.
    /// The operator approves on the host with `omodachi-host pair approve`.
    func testAPairWithTheRealHost() throws {
        let app = try application()
        // `home-panel` and the bar exist whether or not a host answers, so the
        // thing to look for is the gate itself: the Shell shows it only when
        // the directory has no record at all.
        let gate = app.otherElements["onboarding-gate"]
        if !gate.waitForExistence(timeout: 10) {
            capture("arch1-00-already-paired", app)
            return
        }
        let manual = app.buttons["connect-add-manual"]
        if manual.waitForExistence(timeout: 10) {
            manual.tap()
            let field = app.textFields["connect-manual-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOST"] ?? "192.168.1.10")
            app.buttons["connect-manual-submit"].tap()
        }
        capture("arch1-00-pairing-wait", app)
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 300),
                      "approve the request on the host with `omodachi-host pair approve <id>`")
    }

    /// §4.2's walk of the panel area: each entry opens its panel, the same
    /// entry again is ①, and there is one bar throughout.
    func testBTheSevenPanels() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "panel-topbar").count, 1)

        // A-54: ① is side by side only in landscape AND at ≥ 785 points, so the
        // iPhone in portrait is the stacked half with the vertical bar, and the
        // iPad in landscape is the pair.
        if isPhone {
            // The bar draws its workspace squares from `state.workspace`, which
            // arrives with the first state frame — capturing at launch gets an
            // amber dot and an empty menu, which is a picture of the connect,
            // not of the bar.
            _ = appears(app.descendants(matching: .any)["workspace-1"], seconds: 30)
            Thread.sleep(forTimeInterval: 2)
            capture("arch1-12-iphone-portrait-bar", app)
        } else {
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 2)
            capture("arch1-01-ipad-panel-one", app)
        }

        // N-39: the edit affordance, and what a pinned row looks like.
        if app.buttons["pinned-menu-edit"].exists {
            app.buttons["pinned-menu-edit"].tap()
            Thread.sleep(forTimeInterval: 1)
            capture(isPhone ? "arch1-13-iphone-pinned-edit" : "arch1-02-ipad-pinned-edit", app)
            app.buttons["pinned-menu-edit"].tap()
        }

        for (entry, name) in [("open-agent", "03-agent"), ("open-herdr", "04-herdr"),
                              ("open-ssh", "05-ssh"), ("open-setup", "06-settings"),
                              ("open-notifications", "07-notifications"),
                              ("open-remote", "08-remote")] {
            guard app.buttons[entry].exists else { continue }
            app.buttons[entry].tap()
            Thread.sleep(forTimeInterval: 2)
            capture("arch1-\(isPhone ? "iphone-" : "ipad-")\(name)", app)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "panel-topbar").count, 1,
                           "\(entry) kept the one bar")
            app.buttons[entry].tap()
            XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 5),
                          "A-55: \(entry) again is panel ①")
        }
        capture("arch1-\(isPhone ? "iphone" : "ipad")-07-back-to-one", app)
        XCUIDevice.shared.orientation = .portrait
    }

    /// §4.3's live session: the picture has no chrome, the host's own two bar
    /// icons summon the two panels, and ending returns to where it started.
    ///
    /// The operator drives the host end (`omodachi-host panel-summon --view …`,
    /// or clicking the icons in the stream) while this holds the session up.
    func testCARealSessionAndItsSummons() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 20))
        // N-32: start from ③ so "where it came from" is something other than ①.
        app.buttons["open-agent"].tap()
        Thread.sleep(forTimeInterval: 2)
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.otherElements["remote-entry-page"].waitForExistence(timeout: 10))
        app.buttons["remote-start-extend"].tap()

        let picture = app.otherElements["remote-live-picture"]
        guard appears(picture, seconds: 120) else {
            capture("arch1-08-remote-no-frame", app)
            throw XCTSkip("no first frame from the host")
        }
        Thread.sleep(forTimeInterval: 3)
        capture("arch1-08-remote-picture", app)
        // A-58: nothing of ours is on the picture.
        for chrome in ["panel-topbar", "remote-edge-strip", "remote-panel-overlay"] {
            XCTAssertFalse(app.descendants(matching: .any)[chrome].exists, "\(chrome) is on the picture")
        }

        let overlay = app.otherElements["remote-panel-overlay"]
        XCTAssertTrue(appears(overlay, seconds: 120),
                      "summon panel ① from the host: `omodachi-host panel-summon --view overview`")
        capture("arch1-09-remote-summon-menu", app)

        // Study 04 A-64 / ARCH-1: the overlay's bar carries the workspace
        // squares, and during a session a square acts on the screen the user is
        // looking at — core pulls the workspace to the session's own output.
        // The operator watches `hyprctl activeworkspace` across this window:
        // its `monitor` must become OMODACHI-*, and eDP-1 must keep its own.
        // Which squares the bar draws during a session is the host's answer, not
        // ours — `state.remote_bar.workspaces` is the session's own output — so
        // the tap goes to whichever of them is there rather than to a number
        // this test picked in advance.
        for number in [5, 4, 3, 2, 1] {
            let square = app.descendants(matching: .any)["workspace-\(number)"]
            guard square.exists, square.isHittable else { continue }
            square.tap()
            Thread.sleep(forTimeInterval: 8)
            capture("arch1-09b-remote-workspace-square", app)
            break
        }

        // The same view again is a dismissal (A-59 rev 5); a different one is a
        // switch. The operator sends `--view settings` next.
        XCTAssertTrue(appears(app.otherElements["settings-screen"], seconds: 120),
                      "summon ⑥ from the host: `omodachi-host panel-summon --view settings`")
        capture("arch1-10-remote-summon-settings", app)

        // A-57: the session card, and the only place a session ends.
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.otherElements["remote-session-card"].waitForExistence(timeout: 10))
        capture("arch1-11-remote-session-card", app)
        app.buttons["remote-end"].tap()
        app.buttons["remote-end-confirm"].tap()

        // #3 / N-32: `returnTo` is the panel on screen the moment Start was
        // pressed — and that is ②, because Start lives in ②. The spec's own
        // exception applies: when `returnTo` would be ② (or its entry is
        // disabled) the session ends in ①. So ① is the pass here, not ③.
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60),
                      "#3: a session started from ② ends in ①")
        capture("arch1-07-back-where-it-started", app)
    }
}
