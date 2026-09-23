import XCTest

/// REMOTE-2's acceptance run against the real `omarchy` host, from the two
/// simulators the spec names. Disabled without `OMODACHI_UX1_ACCEPTANCE`, the
/// same way `OperatorRemoteTests` and `MERGE1AcceptanceTests` are: these drive
/// a real machine that somebody else is also using.
///
/// Every host-visible action prints a `REMOTE2` marker with a wall-clock epoch
/// so the host poller and the evdev watcher can be lined up against it.
@MainActor final class REMOTE2AcceptanceTests: XCTestCase {
    /// The two simulators REMOTE-2 names, and nothing else. `BD431ECD`,
    /// `D4730803` and `67633048` belong to other runs and are refused here.
    private let authorizedDevices = ["D0AF9C40-994A-46AA-BF15-159FB94B6718",
                                     "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"]

    private func mark(_ text: String) {
        print("REMOTE2 \(text) epoch=\(Date().timeIntervalSince1970)")
    }

    private func application(_ extra: [String] = []) throws -> XCUIApplication {
        #if OMODACHI_UX1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("REMOTE-2 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1800
        // The orientation is set rather than inherited. A run that starts in
        // whatever the last one left behind gets a different overlay geometry,
        // and one of ours came back with the Panel laid out at x = -154 — off
        // the screen, so every control in it existed and none of it could be
        // tapped.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        return app
        #else
        throw XCTSkip("REMOTE-2 acceptance is disabled; build with OMODACHI_UX1_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
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

    /// The edge pan is the only native entry into the Remote overlay (A-40).
    /// One pan is not always enough — the picture has to have taken the gesture
    /// back after whatever closed the overlay — so it is tried up to three
    /// times and the outcome is printed.
    /// `exists` is useless here: a closed overlay is still in the hierarchy at
    /// `.frame(width: 0)`, so every control in it exists — at a negative x,
    /// centred inside a zero-width frame. `isHittable` is the only question
    /// that distinguishes open from closed.
    @discardableResult
    private func overlayIsOpen(_ app: XCUIApplication) -> Bool {
        app.buttons["remote-keyboard"].isHittable
    }

    @discardableResult
    private func summonOverlay(_ app: XCUIApplication, _ window: XCUIElement) -> Bool {
        for attempt in 0..<3 {
            if overlayIsOpen(app) { return true }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
                .press(forDuration: 0.1,
                       thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
            Thread.sleep(forTimeInterval: 3)
            if overlayIsOpen(app) { return true }
            mark("overlay summon attempt \(attempt + 1) did not open it")
        }
        return overlayIsOpen(app)
    }

    /// End the session the way a user does: the Panel's Remote row, two taps
    /// (A-41/N-14). Answers whether it got there.
    @discardableResult
    private func endFromThePanelRow(_ app: XCUIApplication, _ window: XCUIElement) -> Bool {
        summonOverlay(app, window)
        let panelSegment = app.buttons["panel-segment-panel"]
        if panelSegment.isHittable { panelSegment.tap(); Thread.sleep(forTimeInterval: 2) }
        let end = app.buttons["panel-pin-remote"].firstMatch
        guard appears(end, seconds: 10), end.isHittable else {
            mark("panel remote row not reachable; leaving the session to its TTL")
            return false
        }
        // N-14: the first tap asks, and the row is *replaced* by the two
        // confirmation buttons — `panel-pin-remote` is gone by then, so tapping
        // it again finds nothing and the session stays up.
        end.tap()
        Thread.sleep(forTimeInterval: 2)
        let confirm = app.buttons["panel-pin-remote-end-confirm"].firstMatch
        guard appears(confirm, seconds: 8), confirm.isHittable else {
            mark("the end confirmation never appeared; leaving the session to its TTL")
            return false
        }
        mark("end remote (confirm)")
        confirm.tap()
        Thread.sleep(forTimeInterval: 8)
        mark("end remote done")
        return true
    }

    /// From the Panel's pinned Remote row to a picture on screen.
    private func startExtendSession(_ app: XCUIApplication) throws -> XCUIElement {
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 8)
        app.buttons["panel-pin-remote"].tap()
        let entry = app.descendants(matching: .any).matching(identifier: "remote-entry-page").firstMatch
        XCTAssertTrue(appears(entry, seconds: 20), "the Remote entry never opened")
        Thread.sleep(forTimeInterval: 2)
        let start = app.buttons["remote-start-extend"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        mark("start extend")
        start.tap()
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        if !appears(picture, seconds: 210) {
            capture("x-no-frame", app)
            let message = app.staticTexts["remote-message"].firstMatch
            XCTFail("no first frame arrived; message=\(message.exists ? message.label : "none")")
            throw XCTSkip("no frame")
        }
        mark("first frame")
        Thread.sleep(forTimeInterval: 6)
        return picture
    }

    /// Item 1. The overlay stays open for three minutes and the session is still
    /// there afterwards. MERGE-1 §8 had three sessions die one 60 s TTL after
    /// the overlay opened, so the interesting evidence is on the host: the
    /// poller's `sess=` line and the app's own `remote.heartbeat` trace.
    ///
    /// Items 3, 4 and 5 ride the same session, because the host allows one.
    func testAnOpenOverlayKeepsTheSessionAndTheOverlayItselfWorks() throws {
        let app = try application()
        let picture = try startExtendSession(app)
        let window = app.windows.element(boundBy: 0)
        capture("01-first-frame", app)

        // Direct touch, always: a touchpad tap clicks wherever the host cursor
        // already is, which is how an earlier run typed into somebody else's
        // window. The first-frame toast names the mode this session is in.
        let hint = app.staticTexts["remote-touch-hint"].firstMatch
        if hint.exists { mark("touch hint: \(hint.label)") }

        mark("overlay open")
        let keyboard = app.buttons["remote-keyboard"]
        XCTAssertTrue(summonOverlay(app, window), "the Remote overlay never opened")
        capture("02-overlay-open", app)

        // Three minutes, with a marker every 20 s so the host poller lines up.
        let minutes: TimeInterval = TimeInterval(ProcessInfo.processInfo.environment["OMODACHI_REMOTE2_DWELL"] ?? "") ?? 190
        let deadline = Date().addingTimeInterval(minutes)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 20)
            mark("overlay still open picture=\(picture.exists) keyboard_button=\(keyboard.isHittable)")
        }
        mark("overlay dwell done")
        XCTAssertTrue(keyboard.isHittable, "the overlay closed by itself")
        XCTAssertTrue(picture.exists, "the session's picture went away while the overlay was open")
        capture("03-overlay-after-three-minutes", app)

        // Item 3: the keyboard button, both ways.
        mark("keyboard button raise")
        keyboard.tap()
        var raised = false
        for _ in 0..<20 where !raised {
            Thread.sleep(forTimeInterval: 1)
            raised = app.keyboards.count > 0
        }
        mark("keyboard raised=\(raised) keyboards=\(app.keyboards.count)")
        capture("04-keyboard", app)
        XCTAssertTrue(raised, "item 3: the overlay button raises the soft keyboard")
        summonOverlay(app, window)
        if keyboard.isHittable {
            mark("keyboard button dismiss")
            keyboard.tap()
            Thread.sleep(forTimeInterval: 4)
            mark("keyboard after dismiss=\(app.keyboards.count)")
            XCTAssertEqual(app.keyboards.count, 0, "item 3: the same button puts it away")
        }

        // Items 4 and 5: three rows out of the overlay's Keybindings list.
        summonOverlay(app, window)
        let keybindings = app.buttons["panel-segment-keybindings"]
        if keybindings.isHittable { keybindings.tap() }
        Thread.sleep(forTimeInterval: 4)
        // `Omarchy menu` is `omarchy-menu toggle`, and under Remote the overlay
        // is that menu, so running it closes the overlay. It goes last, and the
        // overlay is summoned again before the session is ended.
        for label in ["Terminal", "Switch to workspace 3", "Omarchy menu"] {
            summonOverlay(app, window)
            if keybindings.isHittable { keybindings.tap() }
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
            if !row.isHittable, app.buttons["shortcut-covered-toggle"].isHittable {
                app.buttons["shortcut-covered-toggle"].tap()
                Thread.sleep(forTimeInterval: 2)
                row = app.buttons[label].firstMatch
            }
            guard appears(row, seconds: 8), row.isHittable else {
                mark("row \(label) not found")
                continue
            }
            mark("keybinding tap \(label) enabled=\(row.isEnabled)")
            row.tap()
            Thread.sleep(forTimeInterval: 6)
            let result = app.staticTexts["shortcut-result"].firstMatch
            mark("keybinding result \(label): \(result.exists ? result.label : "no notice")")
            capture("05-keybinding-\(label.replacingOccurrences(of: " ", with: "-"))", app)
        }

        // End it from the Panel's Remote row (A-41/N-14: one tap asks, the
        // second ends), and leave the host as it was found.
        XCTAssertTrue(endFromThePanelRow(app, window), "the session could not be ended from the Panel row")
        capture("06-after-end", app)
    }

    /// Item 2. Five fractions of the picture plus the host bar's clock, in
    /// direct touch — the product's own path, not the operator's absolute
    /// pointer. `hyprctl cursorpos` does not follow a touchscreen, so the
    /// evidence is the `Touch passthrough` device's own normalized coordinates
    /// (the host-side evdev watcher) and what the clock tap does on screen.
    func testDirectTouchLandsWhereItWasAimedAndTheHostBarAnswers() throws {
        let app = try application()
        _ = try startExtendSession(app)
        let window = app.windows.element(boundBy: 0)
        let frame = window.frame
        mark("window=\(frame)")
        let hint = app.staticTexts["remote-touch-hint"].firstMatch
        if hint.exists { mark("touch hint: \(hint.label)") }
        capture("07-direct-touch-before", app)

        // A window for the host watcher to attach to this session's uinput
        // nodes before anything is sent.
        let predwell = Double(ProcessInfo.processInfo.environment["OMODACHI_REMOTE2_PREDWELL"] ?? "") ?? 30
        mark("predwell \(predwell)s")
        Thread.sleep(forTimeInterval: predwell)

        func tap(_ name: String, _ fx: CGFloat, _ fy: CGFloat, settle: TimeInterval = 5) {
            window.coordinate(withNormalizedOffset: CGVector(dx: fx, dy: fy)).tap()
            mark("tap \(name) fx=\(fx) fy=\(fy)")
            Thread.sleep(forTimeInterval: settle)
        }
        for (name, fx, fy) in [("top-left", 0.05, 0.05), ("top-right", 0.95, 0.05),
                               ("bottom-right", 0.95, 0.95), ("bottom-left", 0.05, 0.95),
                               ("centre", 0.50, 0.50)] {
            tap(name, CGFloat(fx), CGFloat(fy))
        }
        // The host's own bar clock, the one target whose effect is visible.
        let target = ProcessInfo.processInfo.environment["OMODACHI_REMOTE2_TARGET"] ?? "0.5,0.012"
        let parts = target.split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 {
            tap("host-bar-clock", CGFloat(parts[0]), CGFloat(parts[1]), settle: 8)
            capture("08-host-bar-clock", app)
            tap("host-bar-clock-again", CGFloat(parts[0]), CGFloat(parts[1]), settle: 6)
        }
        capture("09-direct-touch-after", app)

        // Give the session back.
        XCTAssertTrue(endFromThePanelRow(app, window), "the session could not be ended from the Panel row")
    }

    /// Pairing, when the simulator has been revoked on the host since the last
    /// run. Separate because it needs an operator on the host to approve.
    func testPairWithTheRealHost() throws {
        let app = try application()
        if app.otherElements["home-panel"].waitForExistence(timeout: 8) {
            if app.buttons["panel-pin-remote"].exists && app.buttons["panel-pin-remote"].isEnabled {
                throw XCTSkip("this simulator is already paired and authorized")
            }
            if app.buttons["open-setup"].exists {
                app.buttons["open-setup"].tap()
                let find = app.buttons["settings-find-hosts"].firstMatch
                XCTAssertTrue(find.waitForExistence(timeout: 20), "Settings never opened")
                find.tap()
            }
        }
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 20))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no _omodachi._tcp instance was discovered")
        mark("tap host row")
        row.tap()
        var authorized = false
        for _ in 0..<180 where !authorized {
            authorized = app.buttons["panel-pin-remote"].exists && app.buttons["panel-pin-remote"].isEnabled
            if !authorized { Thread.sleep(forTimeInterval: 2) }
        }
        capture("00-paired", app)
        XCTAssertTrue(authorized, "the host never authorized this device")
    }
}
