import XCTest

/// MERGE-1's acceptance run: the merged `ux-1` (UX-1 + PAIR-3 + INPUT-1 +
/// INPUT-2) against the real `omarchy` host, from the two simulators the spec
/// names. Disabled without `OMODACHI_UX1_ACCEPTANCE`, the same way
/// `OperatorRemoteTests` is: these drive a real machine.
///
/// Every host-visible action prints a `MERGE1` marker with a wall-clock epoch
/// so a host-side poller can be correlated against it afterwards; the dwell
/// after each one is what gives that poller a sample.
@MainActor final class MERGE1AcceptanceTests: XCTestCase {
    /// The two simulators MERGE-1 names, and nothing else. `D0AF9C40`,
    /// `D4730803` and `67633048` belong to other runs and are refused here.
    private let authorizedDevices = ["BD431ECD-4DC6-4EE8-8183-7B0AA3B313EA",
                                     "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"]

    private func mark(_ text: String) {
        print("MERGE1 \(text) epoch=\(Date().timeIntervalSince1970)")
    }

    private func application(_ extra: [String] = []) throws -> XCUIApplication {
        #if OMODACHI_UX1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("MERGE-1 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1800
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        return app
        #else
        throw XCTSkip("MERGE-1 acceptance is disabled; build with OMODACHI_UX1_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        mark("screenshot \(name)")
    }

    /// A deadline, not an iteration count. The inherited helper spent its
    /// budget on iterations rather than on time, so an element that flickered
    /// on and off early burned the whole wait in a few seconds; this one waits
    /// the seconds it was asked for whatever the element does in between.
    private func appears(_ element: XCUIElement, seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return element.exists
    }

    /// A-46: the microphone appears only inside a composer. On the Panel that
    /// composer is the search field, so "no top-level microphone row" is the
    /// assertion that every microphone on screen sits inside it.
    private func assertMicrophoneIsOnlyAComposerControl(_ app: XCUIApplication) {
        let mics = app.descendants(matching: .any).matching(identifier: "voice-button")
        let search = app.textFields["panel-search"].firstMatch
        guard mics.count > 0 else { return }
        XCTAssertTrue(search.exists, "A-46: a microphone is on screen with no composer around it")
        let composer = search.frame.insetBy(dx: -220, dy: -14)
        for index in 0..<mics.count {
            let mic = mics.element(boundBy: index)
            XCTAssertTrue(composer.intersects(mic.frame),
                          "A-46: microphone \(mic.frame) is outside the composer row \(search.frame)")
        }
    }

    /// The edge pan is the only native entry into the Remote overlay (A-40).
    private func summonOverlay(_ app: XCUIApplication, _ window: XCUIElement) {
        guard !app.buttons["remote-keyboard"].isHittable else { return }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
        Thread.sleep(forTimeInterval: 2)
    }

    private func isRegular(_ app: XCUIApplication) -> Bool {
        app.windows.element(boundBy: 0).frame.width >= 700
    }

    // MARK: - a. pairing

    /// 4a. The host list, the tap on `omarchy`, and the claim that PAIR-3's
    /// single `pair approve` is supposed to complete with streaming included.
    func testAPairWithTheRealHost() throws {
        let app = try application()
        if app.otherElements["home-panel"].waitForExistence(timeout: 8) {
            if app.buttons["panel-pin-remote"].exists && app.buttons["panel-pin-remote"].isEnabled {
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
        capture("a1-host-list", app)
        mark("tap host row")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pair-card").firstMatch
            .waitForExistence(timeout: 30), "the waiting card never appeared")
        capture("a2-pair-waiting", app)
        var authorized = false
        for _ in 0..<180 where !authorized {
            authorized = app.buttons["panel-pin-remote"].exists && app.buttons["panel-pin-remote"].isEnabled
            if !authorized { Thread.sleep(forTimeInterval: 2) }
        }
        capture("a3-paired-panel", app)
        XCTAssertTrue(authorized, "the claim never completed — approve it on the host")
    }

    // MARK: - b. the left column never goes away

    /// 4b. Remote entry, Settings and the notifications group, each opened in
    /// turn, with the Panel column asserted present on a regular width and a
    /// screenshot taken of every one.
    func testBSecondaryPagesKeepThePanel() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 10)
        capture("b0-panel", app)
        let regular = isRegular(app)

        // Remote entry.
        app.buttons["panel-pin-remote"].tap()
        let entry = app.descendants(matching: .any).matching(identifier: "remote-entry-page").firstMatch
        XCTAssertTrue(appears(entry, seconds: 20), "the Remote entry never opened")
        Thread.sleep(forTimeInterval: 2)
        capture("b1-remote-entry", app)
        if regular {
            XCTAssertTrue(app.otherElements["home-panel"].exists,
                          "A-44: the left Panel column disappeared behind the Remote entry")
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "panel-topbar").count, 1,
                       "A-47: exactly one native bar")
        // Item 2b: the two cards fit their column.
        let page = entry.frame
        for kind in ["extend", "takeover"] {
            let card = app.descendants(matching: .any).matching(identifier: "remote-card-\(kind)").firstMatch
            if card.exists {
                XCTAssertTrue(page.insetBy(dx: -1, dy: -1).contains(card.frame),
                              "item 2b: the \(kind) card bleeds its page: card \(card.frame) page \(page)")
            }
        }
        if app.buttons["remote-entry-close"].exists { app.buttons["remote-entry-close"].tap() }
        Thread.sleep(forTimeInterval: 2)

        // Settings.
        app.buttons["open-setup"].tap()
        Thread.sleep(forTimeInterval: 3)
        if regular {
            XCTAssertTrue(app.otherElements["home-panel"].exists,
                          "A-44: the left Panel column disappeared behind Settings")
        } else {
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings-screen").count, 1,
                           "A-44 on compact: Settings is one pushed page")
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "panel-topbar").count, 1,
                       "A-47: exactly one native bar over Settings")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "settings-screen").count, 1,
                       "exactly one Settings page is on screen")
        capture("b2-settings", app)
        // A-42: the touch mode is a preference, and acceptance needs it on
        // direct touch — a touchpad-mode tap lands wherever the host cursor is.
        let touch = app.descendants(matching: .any).matching(identifier: "settings-remote-touch-mode").firstMatch
        XCTAssertTrue(appears(touch, seconds: 10), "A-42: 触控方式 belongs in Settings › Remote")
        capture("b3-settings-touch-mode", app)
        if app.buttons["settings-close"].exists { app.buttons["settings-close"].tap() }
        Thread.sleep(forTimeInterval: 2)

        // Notifications.
        let group = app.descendants(matching: .any).matching(identifier: "panel-notifications").firstMatch
        XCTAssertTrue(appears(group, seconds: 20), "the notifications group never appeared")
        if app.buttons["panel-notifications-clear"].exists {
            app.buttons["panel-notifications-toggle"].tap()
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertFalse(app.buttons["panel-notifications-clear"].exists,
                       "A-45: 清除全部 only exists while the group is open")
        XCTAssertTrue(app.staticTexts["panel-notifications-unread"].exists,
                      "A-45: a collapsed group shows the unread count")
        capture("b4-notifications-collapsed", app)
        app.buttons["panel-notifications-toggle"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["panel-notifications-clear"].waitForExistence(timeout: 5),
                      "A-45: 清除全部 is in the group header")
        let deletes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'notification-delete-'"))
        XCTAssertGreaterThan(deletes.count, 0, "A-45: each row has a delete at its end")
        if regular {
            XCTAssertTrue(app.otherElements["home-panel"].exists,
                          "A-44: the left Panel column disappeared behind the notifications")
        }
        capture("b5-notifications-expanded", app)
        // A-46. The microphone is allowed exactly where the rule puts it — in a
        // composer — so the assertion is that it is inside the Panel's search
        // field, not that it is absent. DND is in the notifications group
        // header, which means it is only on screen while the group is open.
        assertMicrophoneIsOnlyAComposerControl(app)
        let dnd = app.buttons["panel-dnd"].firstMatch
        let toggle = app.buttons["panel-notifications-toggle"].firstMatch
        XCTAssertTrue(dnd.exists && toggle.exists,
                      "A-46: DND belongs in the notifications group header")
        // "In the group header, not a top-level row" is a geometric claim: the
        // DND control shares the header's line with the group's own toggle.
        XCTAssertTrue(dnd.frame.midY > toggle.frame.minY - 4 && dnd.frame.midY < toggle.frame.maxY + 4,
                      "A-46: DND is a top-level row, not a group-header control: dnd \(dnd.frame) header \(toggle.frame)")
    }

    // MARK: - c/d/e. the picture

    /// 4c/4d/4e. Start an extend session, reach the first frame, then: no
    /// strip, the keyboard from a three-finger tap and from the overlay
    /// button, three keybindings run from the overlay, one real pointer tap on
    /// the host bar, and the end from the Panel's pinned row.
    func testCStreamKeyboardKeybindingsAndEnd() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 10)
        app.buttons["panel-pin-remote"].tap()
        let entry = app.descendants(matching: .any).matching(identifier: "remote-entry-page").firstMatch
        XCTAssertTrue(appears(entry, seconds: 20), "the Remote entry never opened")
        Thread.sleep(forTimeInterval: 2)

        let start = app.buttons["remote-start-extend"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isHittable, "the start button is not reachable: \(start.frame)")
        mark("start extend")
        start.tap()
        Thread.sleep(forTimeInterval: 5)
        capture("c0-after-start", app)

        // PAIR-3 is supposed to make this branch unreachable: one `pair
        // approve` already authorized the streaming certificate. If the host
        // still wants a separate media pairing, take it — and say so.
        // A-40 left no visible chrome to wait on; `remote-live-picture` is the
        // picture's own name and is up for as long as the stream is.
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        var sawMediaPairing = false
        if app.buttons["remote-pair"].exists {
            sawMediaPairing = true
            mark("media_pairing_required — taking the Sunshine pairing path")
            capture("c0b-media-pairing-required", app)
            app.buttons["remote-pair"].tap()
            Thread.sleep(forTimeInterval: 20)
            capture("c0c-media-pairing-status", app)
            if app.buttons["remote-start-extend"].exists { app.buttons["remote-start-extend"].tap() }
        }
        if !appears(picture, seconds: 210) {
            capture("c1x-no-frame", app)
            let message = app.staticTexts["remote-message"].firstMatch
            let status = app.staticTexts["remote-status"].firstMatch
            XCTFail("""
                no first frame arrived from the host \
                (media pairing branch taken: \(sawMediaPairing)); \
                message=\(message.exists ? message.label : "none") \
                status=\(status.exists ? status.label : "none")
                """)
            return
        }
        mark("first frame")
        Thread.sleep(forTimeInterval: 6)
        capture("c1-remote-no-chrome", app)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "remote-edge-strip").firstMatch.exists,
                       "A-40: Remote draws no native strip")

        let window = app.windows.element(boundBy: 0)

        // A-43, button half. The button's contract is "put the keyboard on the
        // picture", so it also closes the overlay — the picture cannot take
        // first responder underneath it — and the want is honoured on the next
        // latched geometry, which is a wait, not an instant.
        summonOverlay(app, window)
        let keyboard = app.buttons["remote-keyboard"]
        XCTAssertTrue(appears(keyboard, seconds: 15), "the Remote overlay never opened")
        capture("d2-remote-overlay", app)
        mark("overlay keyboard button (raise)")
        keyboard.tap()
        var raised = false
        for _ in 0..<20 where !raised {
            Thread.sleep(forTimeInterval: 1)
            raised = app.keyboards.count > 0
        }
        capture("d3-overlay-keyboard", app)
        XCTAssertTrue(raised, "A-43: the overlay button raises the soft keyboard")
        mark("overlay keyboard button raised=\(raised)")
        if raised {
            summonOverlay(app, window)
            if appears(keyboard, seconds: 10) {
                mark("overlay keyboard button (dismiss)")
                keyboard.tap()
                Thread.sleep(forTimeInterval: 4)
                XCTAssertEqual(app.keyboards.count, 0, "A-43: the same button puts it away")
            }
        }

        // Item B: three keybindings run from the overlay's Keybindings list,
        // with a dwell after each one so the host poller gets a sample.
        summonOverlay(app, window)
        let keybindings = app.buttons["panel-segment-keybindings"]
        if appears(keybindings, seconds: 10) { keybindings.tap() }
        Thread.sleep(forTimeInterval: 4)
        capture("d4-overlay-keybindings", app)
        for label in ["Omarchy menu", "Terminal", "Switch to workspace 3"] {
            let search = app.textFields["shortcut-search"].firstMatch
            if search.exists {
                search.tap()
                Thread.sleep(forTimeInterval: 1)
                if let existing = search.value as? String, !existing.isEmpty {
                    search.press(forDuration: 1.1)
                    if app.menuItems["Select All"].waitForExistence(timeout: 3) {
                        app.menuItems["Select All"].tap()
                    }
                }
                search.typeText(label)
                Thread.sleep(forTimeInterval: 3)
            }
            var row = app.buttons[label].firstMatch
            if !appears(row, seconds: 8), app.buttons["shortcut-covered-toggle"].exists {
                // Rows the app's own GUI replaces are folded away by default
                // (`ShortcutGUIMap`); "Omarchy menu" is one of them because the
                // bar's Omodachi button is its GUI. Unfold before concluding
                // the row is missing.
                mark("keybinding \(label) is GUI-covered; unfolding")
                app.buttons["shortcut-covered-toggle"].tap()
                Thread.sleep(forTimeInterval: 3)
                row = app.buttons[label].firstMatch
            }
            guard appears(row, seconds: 8) else {
                mark("keybinding \(label) NOT FOUND")
                capture("d5x-\(label.replacingOccurrences(of: " ", with: "-"))-missing", app)
                XCTFail("item B: the keybinding row '\(label)' is not in the overlay list")
                continue
            }
            mark("keybinding tap \(label) enabled=\(row.isEnabled)")
            row.tap()
            Thread.sleep(forTimeInterval: 14)
            let result = app.descendants(matching: .any).matching(identifier: "shortcut-result").firstMatch
            mark("keybinding result \(label): \(result.exists ? result.label : "<no notice>")")
            capture("d5-keybinding-\(label.replacingOccurrences(of: " ", with: "-"))", app)
            XCTAssertTrue(row.isEnabled, "item B: '\(label)' is on screen but not executable")
        }

        // Close the overlay and put one real pointer tap on the host's bar.
        // A-42's default is direct touch, which is the only mode this run is
        // allowed to use: a touchpad-mode tap lands wherever the host cursor is.
        if app.buttons["panel-collapse"].exists { app.buttons["panel-collapse"].tap() }
        Thread.sleep(forTimeInterval: 4)
        let clock = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.012))
        mark("pointer tap host bar clock")
        clock.tap()
        Thread.sleep(forTimeInterval: 14)
        capture("d6-pointer-tap-bar", app)
        mark("pointer tap host bar clock (again, to dismiss)")
        clock.tap()
        Thread.sleep(forTimeInterval: 8)

        // A-41: the session ends from the Panel's pinned row and nowhere else.
        summonOverlay(app, window)
        let panelSegment = app.buttons["panel-segment-panel"]
        if appears(panelSegment, seconds: 10) { panelSegment.tap() }
        Thread.sleep(forTimeInterval: 3)
        let pin = app.buttons["panel-pin-remote"].firstMatch
        XCTAssertTrue(appears(pin, seconds: 15), "A-41: the pinned Remote row is not in the overlay")
        capture("e1-panel-end-row", app)
        pin.tap()
        XCTAssertTrue(app.buttons["panel-pin-remote-end-confirm"].waitForExistence(timeout: 10),
                      "A-41/N-14: one tap asks, the second ends")
        capture("e2-end-confirm", app)
        mark("end remote")
        app.buttons["panel-pin-remote-end-confirm"].tap()
        Thread.sleep(forTimeInterval: 12)
        capture("e3-after-end", app)
    }

    // MARK: - f. the phone

    /// 4f. On a compact width the Remote entry is a pushed page, the
    /// notifications are collapsed and deletable, and the Panel's top level
    /// carries neither a microphone nor a DND row.
    func testFiPhoneSecondaryPagesArePushed() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 10)
        XCTAssertFalse(isRegular(app), "this case is the compact width; run it on the iPhone")
        capture("f0-iphone-panel", app)

        app.buttons["panel-pin-remote"].tap()
        let entry = app.descendants(matching: .any).matching(identifier: "remote-entry-page").firstMatch
        XCTAssertTrue(appears(entry, seconds: 20), "the Remote entry never opened")
        Thread.sleep(forTimeInterval: 3)
        capture("f1-iphone-remote-entry-push", app)
        // A-44 on compact: one page, pushed, with the bar still on it, and the
        // Panel is *not* beside it.
        XCTAssertFalse(app.otherElements["home-panel"].exists,
                       "A-44: on compact the secondary content is a pushed page, not a column")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "panel-topbar").count, 1,
                       "A-47: the native bar is still there on a pushed page")
        if app.buttons["remote-entry-close"].exists { app.buttons["remote-entry-close"].tap() }
        else if app.navigationBars.buttons.count > 0 { app.navigationBars.buttons.element(boundBy: 0).tap() }
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 15),
                      "A-44: back from a pushed page is the Panel")

        let group = app.descendants(matching: .any).matching(identifier: "panel-notifications").firstMatch
        XCTAssertTrue(appears(group, seconds: 20), "the notifications group never appeared")
        if app.buttons["panel-notifications-clear"].exists {
            app.buttons["panel-notifications-toggle"].tap()
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertFalse(app.buttons["panel-notifications-clear"].exists,
                       "A-45: 清除全部 only exists while the group is open")
        XCTAssertTrue(app.staticTexts["panel-notifications-unread"].exists,
                      "A-45: a collapsed group shows the unread count")
        capture("f2-iphone-notifications-collapsed", app)
        app.buttons["panel-notifications-toggle"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["panel-notifications-clear"].waitForExistence(timeout: 5),
                      "A-45: 清除全部 is in the group header")
        let deletes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'notification-delete-'"))
        XCTAssertGreaterThan(deletes.count, 0, "A-45: each row has a delete at its end")
        capture("f3-iphone-notifications-expanded", app)
        // A-45: a row really goes away when its delete is tapped. The visible
        // count is not the assertion — the group shows a fixed window with "N
        // earlier" under it, so deleting one pulls the next one up and the
        // count stays put. The assertion is that *this* row is gone.
        let doomed = deletes.element(boundBy: 0).identifier
        XCTAssertFalse(doomed.isEmpty, "A-45: the delete control carries its row's id")
        deletes.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.buttons[doomed].exists, "A-45: \(doomed) is still on screen after its delete")
        capture("f4-iphone-notification-deleted", app)
        // A-46.
        assertMicrophoneIsOnlyAComposerControl(app)
    }

    /// 4d, gesture half. XCUITest on iOS 26.5 cannot synthesize a multi-touch
    /// tap onto this app: `tap(withNumberOfTaps:numberOfTouches:)` answers
    /// "unable to compute coordinates for gesture after 5 attempts, final
    /// visible/unoccluded frame was {{0, 0}, {834, 1210}}" for the window, for
    /// the picture element and for the application element alike, and simctl /
    /// axe HID injection is broken on the same runtime. The case is kept, and
    /// kept runnable, so the first harness that can drive three fingers proves
    /// A-43's gesture half without anyone re-deriving the steps.
    func testGThreeFingerKeyboardGesture() throws {
        guard ProcessInfo.processInfo.environment["OMODACHI_MERGE1_THREE_FINGER"] == "1" else {
            throw XCTSkip("three-finger tap is opt-in: XCUITest cannot synthesize it on iOS 26.5")
        }
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 10)
        app.buttons["panel-pin-remote"].tap()
        let start = app.buttons["remote-start-extend"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        XCTAssertTrue(appears(picture, seconds: 210), "no first frame")
        Thread.sleep(forTimeInterval: 6)
        mark("three-finger tap (raise)")
        picture.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        Thread.sleep(forTimeInterval: 4)
        capture("d7-three-finger-keyboard", app)
        XCTAssertTrue(app.keyboards.count > 0, "A-43: a three-finger tap raises the soft keyboard")
        mark("three-finger tap (dismiss)")
        picture.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(app.keyboards.count, 0, "A-43: the same gesture puts it away")
        app.buttons["panel-pin-remote"].tap()
        if app.buttons["panel-pin-remote-end-confirm"].waitForExistence(timeout: 10) {
            app.buttons["panel-pin-remote-end-confirm"].tap()
        }
        Thread.sleep(forTimeInterval: 10)
    }


    /// 4d/4e, tightened. `testC` walks the whole path and takes four minutes,
    /// by which time the session is gone (§ the heartbeat finding), so the
    /// keybinding that reached the host did so with the picture already dead.
    /// This case does the one thing that has to be true with a *live* session:
    /// first frame, overlay, one keybinding, and the end from the Panel's row.
    func testHKeybindingAndEndWithALiveSession() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 8)
        app.buttons["panel-pin-remote"].tap()
        let start = app.buttons["remote-start-extend"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        mark("start extend")
        start.tap()
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        XCTAssertTrue(appears(picture, seconds: 210), "no first frame arrived from the host")
        mark("first frame")
        Thread.sleep(forTimeInterval: 4)

        let window = app.windows.element(boundBy: 0)
        summonOverlay(app, window)
        let keybindings = app.buttons["panel-segment-keybindings"]
        XCTAssertTrue(appears(keybindings, seconds: 10), "the overlay never opened")
        keybindings.tap()
        Thread.sleep(forTimeInterval: 3)
        let search = app.textFields["shortcut-search"].firstMatch
        if search.exists { search.tap(); Thread.sleep(forTimeInterval: 1); search.typeText("Terminal") }
        Thread.sleep(forTimeInterval: 3)
        let row = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(appears(row, seconds: 10), "item B: no Terminal row in the overlay")
        mark("keybinding tap Terminal enabled=\(row.isEnabled)")
        row.tap()
        Thread.sleep(forTimeInterval: 10)
        let result = app.descendants(matching: .any).matching(identifier: "shortcut-result").firstMatch
        mark("keybinding result Terminal: \(result.exists ? result.label : "<no notice>")")
        capture("h1-keybinding-terminal-live", app)

        // A-41: end from the Panel's pinned Remote row, two-step, nowhere else.
        let panelSegment = app.buttons["panel-segment-panel"]
        if appears(panelSegment, seconds: 10) { panelSegment.tap() }
        Thread.sleep(forTimeInterval: 3)
        let pin = app.buttons["panel-pin-remote"].firstMatch
        XCTAssertTrue(appears(pin, seconds: 15), "A-41: the pinned Remote row is not in the overlay")
        capture("h2-panel-end-row", app)
        pin.tap()
        XCTAssertTrue(app.buttons["panel-pin-remote-end-confirm"].waitForExistence(timeout: 10),
                      "A-41/N-14: one tap asks, the second ends")
        capture("h3-end-confirm", app)
        mark("end remote")
        app.buttons["panel-pin-remote-end-confirm"].tap()
        Thread.sleep(forTimeInterval: 12)
        capture("h4-after-end", app)
        mark("ended")
    }

}
