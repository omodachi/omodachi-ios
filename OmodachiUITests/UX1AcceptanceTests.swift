import XCTest

/// UX-1's acceptance run against the real `omarchy` host, from the two
/// simulators the spec names. Disabled without `OMODACHI_UX1_ACCEPTANCE`, the
/// same way `OperatorRemoteTests` is: these drive a real machine.
///
/// Screenshots are XCTAttachments, exported from the `.xcresult` afterwards.
@MainActor final class UX1AcceptanceTests: XCTestCase {
    private let authorizedDevices = ["BD431ECD-4DC6-4EE8-8183-7B0AA3B313EA",
                                     "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"]

    private func application(_ extra: [String] = []) throws -> XCUIApplication {
        #if OMODACHI_UX1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("UX-1 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 600
        // Every capture is portrait unless the test says otherwise: a
        // screenshot taken while the simulator is still rotating is clipped.
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        return app
        #else
        throw XCTSkip("UX-1 acceptance is disabled; build with OMODACHI_UX1_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A one-off structural check that also prints the tree when it fails, so
    /// a duplicate render is visible rather than showing up as "multiple
    /// matching elements" inside some other assertion.
    private func assertSingle(_ identifier: String, _ app: XCUIApplication) {
        let count = app.descendants(matching: .any).matching(identifier: identifier).count
        XCTAssertLessThanOrEqual(count, 1, "\(identifier) is on screen \(count) times\n\(app.debugDescription)")
    }

    /// MERGE-1: a deadline, not an iteration count. Written as a `where`
    /// clause this spent its budget on iterations, so an element that flickered
    /// early burned a 150-second wait in twenty — which is how UX-1's stream
    /// case reported "no first frame" 29 seconds after asking for 150.
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
        // The simulator may already hold a profile with no credential — the
        // Panel is then on screen and the host list is reached the way a user
        // reaches it, through Settings (N-19/N-26).
        if app.otherElements["home-panel"].waitForExistence(timeout: 8) {
            if app.buttons["panel-pin-remote"].isEnabled {
                throw XCTSkip("this simulator is already paired and authorized")
            }
            app.buttons["open-setup"].tap()
            let find = app.buttons["settings-find-hosts"].firstMatch
            XCTAssertTrue(find.waitForExistence(timeout: 20), "Settings never opened")
            find.tap()
        }
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 20))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no _omodachi._tcp instance was discovered")
        capture("00-discovery", app)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pair-card").firstMatch
            .waitForExistence(timeout: 30), "the waiting card never appeared")
        capture("01-pair-waiting", app)
        // The claim poll runs every 2s; the operator approves in parallel.
        var authorized = false
        for _ in 0..<150 where !authorized {
            authorized = app.buttons["panel-pin-remote"].exists && app.buttons["panel-pin-remote"].isEnabled
            if !authorized { Thread.sleep(forTimeInterval: 2) }
        }
        capture("02-paired-panel", app)
        XCTAssertTrue(authorized, "the claim never completed — approve it on the host")
    }

    /// Items 5 and 8: the Panel and the Keybindings list on a real host theme,
    /// with the real catalog's glyphs in them.
    func testBPanelAndKeybindings() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        // Let the theme, fonts and catalog land before measuring readability.
        Thread.sleep(forTimeInterval: 12)
        assertSingle("panel-segments", app)
        assertSingle("home-panel", app)
        capture("10-panel", app)

        // Item 8: the `apps` branch is where every XDG icon name lives.
        let apps = app.buttons["menu-apps"]
        if appears(apps, seconds: 20) {
            apps.tap()
            Thread.sleep(forTimeInterval: 3)
            capture("11-apps-glyphs", app)
            // Back to the Panel root.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 1)
        } else {
            capture("11-apps-glyphs-missing", app)
        }

        let keybindings = app.buttons["panel-segment-keybindings"]
        if appears(keybindings, seconds: 10) { keybindings.tap() }
        Thread.sleep(forTimeInterval: 4)
        capture("12-keybindings", app)
    }

    /// Item 4: the notifications group is collapsed, counts, and deletes.
    func testCNotifications() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 8)
        let group = app.descendants(matching: .any).matching(identifier: "panel-notifications").firstMatch
        XCTAssertTrue(appears(group, seconds: 20), "the notifications group never appeared")
        // A-45 remembers the choice, so a run that already opened the group
        // starts open. Put it back first, which is also the assertion that the
        // collapsed state is a real state with a count on it.
        if app.buttons["panel-notifications-clear"].exists {
            app.buttons["panel-notifications-toggle"].tap()
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertFalse(app.buttons["panel-notifications-clear"].exists,
                       "清除全部 only exists while the group is open")
        XCTAssertTrue(app.staticTexts["panel-notifications-unread"].exists,
                      "A-45: a collapsed group shows the unread count")
        capture("20-notifications-collapsed", app)
        app.buttons["panel-notifications-toggle"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["panel-notifications-clear"].waitForExistence(timeout: 5),
                      "A-45: 清除全部 is in the group header")
        // A-45: every row carries its own delete, history rows included.
        let deletes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'notification-delete-'"))
        XCTAssertGreaterThan(deletes.count, 0, "A-45: each row has a delete at its end")
        capture("21-notifications-expanded", app)
    }

    /// Items 2 and 7: a secondary page is the right column on an iPad and the
    /// Panel stays on screen; the native bar never goes away.
    func testDSecondaryPagesKeepThePanelAndTheBar() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 6)
        app.buttons["open-setup"].tap()
        Thread.sleep(forTimeInterval: 2)
        // A-44 on a regular width: both are on screen at once.
        let regular = app.windows.element(boundBy: 0).frame.width >= 700
        if regular {
            XCTAssertTrue(app.otherElements["home-panel"].exists,
                          "A-44: the left column never disappears on an iPad")
        }
        // A-47: the bar is there whatever is on screen.
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "panel-topbar").count, 1,
                       "A-47: exactly one native bar, on every surface but Remote")
        assertSingle("panel-segments", app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings-screen").count, 1,
                       "exactly one Settings page is on screen")
        capture("30-settings", app)

        // A-42: the touch mode is a preference now, not a Remote toolbar button.
        let touch = app.descendants(matching: .any).matching(identifier: "settings-remote-touch-mode").firstMatch
        XCTAssertTrue(appears(touch, seconds: 10), "A-42: 触控方式 belongs in Settings › Remote")
        capture("31-settings-touch-mode", app)
        if app.buttons["settings-close"].exists { app.buttons["settings-close"].tap() }
    }

    /// Items 1, 2b, A: Remote's entry page beside the Panel, then the picture
    /// with no chrome and the keyboard toggled from the overlay.
    func testERemoteEntryStreamAndKeyboard() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 8)
        app.buttons["panel-pin-remote"].tap()
        let entry = app.descendants(matching: .any).matching(identifier: "remote-entry-page").firstMatch
        XCTAssertTrue(appears(entry, seconds: 20), "A-44: the Remote entry is a page beside the Panel")
        Thread.sleep(forTimeInterval: 2)
        // Item 2b: the cards, side by side, sized to content, inside their border.
        capture("40-remote-entry", app)
        XCTAssertTrue(app.otherElements["home-panel"].exists || !isRegular(app),
                      "A-44: the Panel is still the left column while Remote's entry is open")

        guard ProcessInfo.processInfo.environment["OMODACHI_UX1_STREAM"] == "1" else {
            throw XCTSkip("stream phase is opt-in; the host allows one session at a time")
        }
        let start = app.buttons["remote-start-extend"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isHittable, "the start button is not reachable: \(start.frame)")
        start.tap()
        Thread.sleep(forTimeInterval: 4)
        capture("40b-after-start", app)
        // A-40: there is no strip any more, so a frame is the absence of the
        // setup card rather than the presence of a strip.
        let hint = app.descendants(matching: .any).matching(identifier: "remote-touch-hint").firstMatch
        if !appears(hint, seconds: 150) {
            capture("41x-no-frame", app)
            let message = app.staticTexts["remote-message"].firstMatch
            XCTFail("no first frame arrived from the host: \(message.exists ? message.label : "no message on screen")")
        }
        Thread.sleep(forTimeInterval: 5)
        capture("41-remote-no-chrome", app)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "remote-edge-strip").firstMatch.exists,
                       "A-40: Remote draws no native strip")

        // A-43 from the overlay. The edge pan summons it; the button toggles
        // the soft keyboard.
        let window = app.windows.element(boundBy: 0)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
        let keyboard = app.buttons["remote-keyboard"]
        XCTAssertTrue(appears(keyboard, seconds: 15), "the Remote overlay never opened")
        capture("42-remote-overlay", app)
        keyboard.tap()
        Thread.sleep(forTimeInterval: 3)
        capture("43-remote-keyboard", app)
        XCTAssertTrue(app.keyboards.count > 0, "A-43: the overlay button raises the soft keyboard")
        keyboard.tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(app.keyboards.count, 0, "A-43: the same button puts it away")

        // A-41: the session ends from the Panel's pinned row, nowhere else.
        app.buttons["panel-pin-remote"].tap()
        XCTAssertTrue(app.buttons["panel-pin-remote-end-confirm"].waitForExistence(timeout: 10),
                      "A-41/N-14: one tap asks, the second ends")
        capture("44-remote-end-confirm", app)
        app.buttons["panel-pin-remote-end-confirm"].tap()
        Thread.sleep(forTimeInterval: 6)
    }

    private func isRegular(_ app: XCUIApplication) -> Bool {
        app.windows.element(boundBy: 0).frame.width >= 700
    }
}
