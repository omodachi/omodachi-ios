import XCTest

/// Disabled in ordinary builds. These drive the real `omarchy` host from the
/// one authorized simulator and are compiled only with OMODACHI_OPERATOR_REMOTE.
/// The host record arrives in the launch environment
/// (TEST_RUNNER_OMODACHI_DEV_HOST); no key material is ever committed or
/// written into a screenshot. PAIR-2 removed the invitation seed: pairing here
/// is the real handshake, with nothing typed and nothing bootstrapped.
@MainActor final class OperatorRemoteTests: XCTestCase {
    /// The simulators an operator run is allowed to touch. Each one is here
    /// because a spec named it: `D0AF9C40` by SPEC-E2/E3, `E737AB77` by
    /// PAIR-2 §4.1, which needs a device that has never paired. Anything else -
    /// "whatever simulator happens to be booted" - is still refused.
    private let authorizedDevices = ["D0AF9C40-994A-46AA-BF15-159FB94B6718",
                                     "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"]
    /// The profile the operator is allowed to attach to, by the name the app
    /// stores. A run that imports the development record gets `192.168.1.10`;
    /// a run on a device paired for real through discovery gets whatever the
    /// host advertised — `omarchy` — so PAIR-3, which streams from a genuinely
    /// paired device rather than an imported one, names it. The guard is still
    /// "one explicitly named host", never "whatever profile is loaded".
    private var expectedHost: String {
        ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOST"] ?? "192.168.1.10"
    }

    private func application(phase: String, importHost: Bool) throws -> XCUIApplication {
        #if OMODACHI_OPERATOR_REMOTE
        // The runner does not always inherit SIMULATOR_UDID, so the harness may
        // also name the device explicitly; either way it must be the one
        // authorized device, never "whatever simulator happens to be booted".
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("Operator refuses any simulator other than an explicitly authorized one (saw \(device ?? "no device id"))")
        }
        continueAfterFailure = false
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--remote-operator", "--remote-operator-phase=\(phase)",
                               "--remote-operator-host=\(expectedHost)"]
        // INPUT-2: `hyprctl cursorpos` follows the pointer, not the touchscreen,
        // so the landing measurement asks for the absolute-pointer path.
        if ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_ABSOLUTE_POINTER"] == "1" {
            app.launchArguments.append("--remote-operator-absolute-pointer")
        }
        if importHost { app.launchArguments.append("--import-development-host") }
        if let value = ProcessInfo.processInfo.environment["OMODACHI_DEV_HOST"] {
            app.launchEnvironment["OMODACHI_DEV_HOST"] = value
        }
        app.launch()
        return app
        #else
        throw XCTSkip("Real-host operator is disabled; build explicitly with OMODACHI_OPERATOR_REMOTE")
        #endif
    }

    /// Slow existence poll; `waitForExistence` snapshots every second.
    private func appears(_ element: XCUIElement, seconds: Int) -> Bool {
        for _ in 0..<(seconds / 3) {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 3)
        }
        return element.exists
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// §7.2 — the discovery list, a real pairing claim, and the pinned identity.
    func testDiscoverAndPairRealHost() throws {
        let app = try application(phase: "pair", importHost: false)
        // SPEC-I §12: the list is the first screen; there is no Settings page
        // to go through and no "配对设备" row to find.
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 10))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no _omodachi._tcp instance was discovered")
        capture("discovery-list", app)
        row.tap()
        // PAIR-2: one tap is the whole request. The card that comes up asks for
        // nothing - there is no invitation field on it - and it goes straight
        // to waiting for the computer. (The countdown itself is covered by
        // `ConnectionFlowTests.testOneTapSendsTheRequest…`: SwiftUI folds that
        // Text into its identified row, so it is not separately queryable.)
        let card = app.descendants(matching: .any).matching(identifier: "pair-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the waiting card never appeared")
        XCTAssertFalse(app.secureTextFields["pair-locked-invitation"].exists,
                       "an open host must never show an invitation field")
        let waiting = app.descendants(matching: .any).matching(identifier: "pair-waiting").firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 20),
                      "the card never reached 'waiting for the computer'")
        // §13: the same panel becomes the waiting card, fingerprint and all.
        XCTAssertTrue(app.staticTexts["pair-fingerprint"].waitForExistence(timeout: 20),
                      "the presented certificate was never shown for comparison")
        capture("pairing-card", app)
        // The host operator approves in parallel; the claim poll runs every 2s.
        // A claim lands on the Panel, so the Panel is the assertion.
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 180),
                      "the claim never completed")
        capture("pairing-claimed", app)

        // N-28 / PAIR-2 §4.1: the same one approval already wrote this device's
        // key to authorized_keys, so the terminal opens with nothing typed -
        // no host, no port, no user, and no host-key sheet to confirm.
        // AGENT-2 item 6 / A-63: opening ⑤ is the whole of it; the
        // "open a terminal" page it used to go through is deleted.
        app.buttons["open-ssh"].tap()
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal-emulator").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the terminal surface never opened")
        let state = app.staticTexts["terminal-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 30))
        var connected = false
        for _ in 0..<40 where !connected {
            // I18N-1: this suite is driven on whichever language the operator's
            // device is in, and the state row is a catalog string now.
            connected = ["connected", "已连接"].contains(state.label)
            if !connected { Thread.sleep(forTimeInterval: 1) }
        }
        XCTAssertTrue(connected, "SSH did not connect without input (state: \(state.label))")
        XCTAssertFalse(app.buttons["trust-host-key"].exists,
                       "a paired host must not raise a host-key confirmation")
        capture("pairing-ssh", app)
    }

    /// SPEC-E3 §3.2/§3.3 — a real desktop frame over the WSS bridge, then a
    /// real rotation. There is no SSH on this path any more, so there is no
    /// host-key prompt to confirm.
    func testRemoteDesktopFirstFrameAndRotation() throws {
        let app = try application(phase: "stream", importHost: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        // With --remote-operator-phase=stream the authorized profile opens the
        // Remote surface itself, so no navigation is simulated here.
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 15))
        select(backend: "VNC", app)
        capture("remote-setup", app)
        start(mode: .extend, app)
        // The edge strip only exists once a frame is actually on screen. Poll it
        // slowly: a per-second accessibility snapshot of a live video view is
        // expensive enough to destabilise the runner.
        // REMOTE-5: A-40 deleted the strip, and a wait on a name nothing emits
        // can only time out — which is how GEST-1 §6b read a streaming host as
        // "no first frame". `remote-live-picture` is the picture's own name and
        // is up for exactly as long as the stream is.
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        XCTAssertTrue(appears(picture, seconds: 120), "no first frame arrived from the host: \(situation(app))")
        // The first frame can land while the launch-to-landscape layout is still
        // settling; capture the steady state, not the transition.
        Thread.sleep(forTimeInterval: 4)
        capture("remote-first-frame-landscape", app)

        XCUIDevice.shared.orientation = .portrait
        // The old picture is retained until the new one lands, so wait for the
        // picture to come back rather than for the rotation animation.
        XCTAssertTrue(appears(picture, seconds: 120), "the session never recovered after rotation")
        Thread.sleep(forTimeInterval: 4)
        capture("remote-after-rotation-portrait", app)

        disconnect(app)
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 30),
                      "the session did not return to its entry screen after release")
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    /// SPEC-E3 §3.4/§3.5 — Moonlight pairing finished inside the app, then a
    /// Sunshine session. The host operator approves the device once, in
    /// parallel, with `omodachi-host media-pairing approve …`.
    func testSunshinePairingAndFirstFrame() throws {
        let app = try application(phase: "stream", importHost: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 15))
        select(backend: "Sunshine", app)
        start(mode: .extend, app)
        // Without a paired certificate the host refuses before it touches
        // anything, and the app starts the pairing itself. A device that
        // already holds a streaming certificate must not be sent through it a
        // second time, so this leg is taken only when the app actually asks:
        // pairing is a precondition of the first frame, never a step in it.
        let status = app.staticTexts["sunshine-pairing-status"]
        if appears(status, seconds: 30) {
            capture("sunshine-pairing", app)
            let paired = NSPredicate { _, _ in
                app.staticTexts["sunshine-pairing-status"].label.contains("Sunshine 配对完成")
                    || !app.buttons["remote-pair"].exists
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: paired, object: nil)], timeout: 240),
                           .completed, "the host never approved: \(status.label)")
            capture("sunshine-paired", app)
            if app.buttons["remote-start-extend"].waitForExistence(timeout: 20) {
                select(backend: "Sunshine", app)
                start(mode: .extend, app)
            }
        }
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        XCTAssertTrue(appears(picture, seconds: 150), "no Sunshine frame arrived: \(situation(app))")
        capture("sunshine-first-frame", app)
        disconnect(app)
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 30),
                      "the session did not return to its entry screen after release")
    }

    /// PERF-1 — one Sunshine session held open long enough to measure. The
    /// numbers come out of the app's own `app.omodachi`/`perf` os_log
    /// signal, which the harness streams from the Simulator in parallel; this
    /// case only opens the session, keeps it up and lets go of it again. Mode
    /// and hold time come from the launch arguments so the same case measures
    /// extend and takeover without a second code path.
    func testSunshineStreamPerformanceWindow() throws {
        let app = try application(phase: "stream", importHost: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 15))
        select(backend: "Sunshine", app)
        let mode = ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_MODE"] ?? "extend"
        capture("perf-setup", app)
        start(mode: mode == "takeover" ? .takeover : .extend, app)
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        XCTAssertTrue(appears(picture, seconds: 150), "no Sunshine frame arrived: \(situation(app))")
        let hold = Double(ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOLD"] ?? "") ?? 25
        // Nothing is polled while the window runs: an accessibility snapshot of
        // a live video view is exactly the main-thread cost being measured.
        Thread.sleep(forTimeInterval: hold)
        capture("perf-stream", app)
        disconnect(app)
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 30),
                      "the session did not return to its entry screen after release")
    }

    /// INPUT-1 §验收 — five taps at known fractions of the streamed canvas,
    /// plus one at the host's own bar. The host samples `hyprctl cursorpos` in
    /// parallel; this case only has to put each tap exactly where it says it
    /// does, so it prints the canvas rectangle, the fraction, the screen point
    /// and the epoch of every tap. Nothing is asserted about the cursor here:
    /// the comparison lives in the report, against the host's own readback.
    func testAbsolutePointerLandsOnTheCapturedOutput() throws {
        let app = try application(phase: "stream", importHost: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        // A device paired through the list keeps its own host record, so the
        // operator's auto-open does not fire; the bar's own Remote entry is the
        // same one a person uses.
        if !app.buttons["remote-start-extend"].waitForExistence(timeout: 10) {
            XCTAssertTrue(app.buttons["open-remote"].waitForExistence(timeout: 15), "no way into Remote")
            app.buttons["open-remote"].tap()
        }
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 20))
        select(backend: "Sunshine", app)
        let mode = ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_MODE"] ?? "takeover"
        let choice: RemoteModeChoice = mode == "takeover" ? .takeover : .extend
        start(mode: choice, app)
        // Pairing is a precondition, not a step: one host approval already
        // grants the streaming certificate, so this only re-enters the flow if
        // the app drops back to its entry screen asking for one.
        if app.buttons["remote-pair"].waitForExistence(timeout: 10) {
            app.buttons["remote-pair"].tap()
            _ = app.staticTexts["sunshine-pairing-status"].waitForExistence(timeout: 240)
            if app.buttons["remote-start-extend"].waitForExistence(timeout: 240) {
                select(backend: "Sunshine", app)
                start(mode: choice, app)
            }
        }
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        XCTAssertTrue(appears(picture, seconds: 150), "no Sunshine frame arrived: \(situation(app))")
        // Let the first-frame toast go and the geometry settle before touching.
        Thread.sleep(forTimeInterval: 8)
        // A window for the host to attach to the devices this session created.
        let predwell = Double(ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_PREDWELL"] ?? "") ?? 0
        if predwell > 0 {
            print("OMODACHI-INPUT1 predwell-start \(predwell)s epoch=\(Date().timeIntervalSince1970)")
            Thread.sleep(forTimeInterval: predwell)
            print("OMODACHI-INPUT1 predwell-end epoch=\(Date().timeIntervalSince1970)")
        }
        // REMOTE-5: this used to be "the window minus the strip column". A-40
        // took the strip away, so the picture is no longer a subtraction — it is
        // an element with a rectangle of its own, and that rectangle is what the
        // taps below are placed in.
        let window = app.windows.firstMatch
        let frame = window.frame
        let canvasRect = picture.frame
        print("OMODACHI-INPUT1 mode=\(mode) window=\(frame) picture=\(canvasRect)")
        var targets: [(String, CGFloat, CGFloat)] = [("top-left", 0.05, 0.05), ("top-right", 0.95, 0.05),
                                                     ("bottom-right", 0.95, 0.95), ("bottom-left", 0.05, 0.95),
                                                     ("centre", 0.50, 0.50)]
        // One real target on the host's own bar, given as "fx,fy" so the same
        // case can aim at whatever that bar actually carries.
        if let value = ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_TARGET"] {
            let parts = value.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { targets.append(("host-bar", CGFloat(parts[0]), CGFloat(parts[1]))) }
        }
        for (name, fx, fy) in targets {
            let point = CGPoint(x: canvasRect.minX + canvasRect.width * fx, y: canvasRect.minY + canvasRect.height * fy)
            let dx = (point.x - frame.minX) / frame.width
            let dy = (point.y - frame.minY) / frame.height
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
            print("OMODACHI-INPUT1 tap \(name) fx=\(fx) fy=\(fy) point=\(point) epoch=\(Date().timeIntervalSince1970)")
            Thread.sleep(forTimeInterval: 5)
        }
        // Does any input at all reach the host? The touchpad segment sends
        // relative motion from the same canvas; a drag there is the control.
        let pointerMode = app.descendants(matching: .any).matching(identifier: "remote-pointer-mode").firstMatch
        if pointerMode.exists {
            let touchpad = app.buttons["触摸板"].firstMatch
            if touchpad.exists {
                touchpad.tap()
                print("OMODACHI-INPUT1 touchpad-selected epoch=\(Date().timeIntervalSince1970)")
                Thread.sleep(forTimeInterval: 2)
                let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
                let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7))
                for step in 0..<3 {
                    from.press(forDuration: 0.1, thenDragTo: to)
                    print("OMODACHI-INPUT1 drag \(step) epoch=\(Date().timeIntervalSince1970)")
                    Thread.sleep(forTimeInterval: 2)
                }
                let direct = app.buttons["直接触摸"].firstMatch
                if direct.exists { direct.tap() }
                Thread.sleep(forTimeInterval: 2)
                let centre = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                centre.tap()
                print("OMODACHI-INPUT1 tap centre-again epoch=\(Date().timeIntervalSince1970)")
                Thread.sleep(forTimeInterval: 4)
            }
        }
        // A window in which the host can be interrogated while the stream is up.
        let dwell = Double(ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DWELL"] ?? "") ?? 0
        if dwell > 0 {
            print("OMODACHI-INPUT1 dwell-start \(dwell)s epoch=\(Date().timeIntervalSince1970)")
            Thread.sleep(forTimeInterval: dwell)
        }
        capture("input1-\(mode)-after-taps", app)
        disconnect(app)
        // The release is the host's to finish; if the entry screen is slow the
        // taps above are still the evidence, so this is reported, not fatal.
        if !app.buttons["remote-start-extend"].waitForExistence(timeout: 60) {
            print("OMODACHI-INPUT1 release-did-not-return-to-entry \(situation(app))")
            disconnect(app)
            _ = app.buttons["remote-start-extend"].waitForExistence(timeout: 60)
        }
        print("OMODACHI-INPUT1 done mode=\(mode) epoch=\(Date().timeIntervalSince1970)")
    }

    /// INPUT-2 §验收 — the same five points as INPUT-1, but taken as soon as
    /// the first frame is on screen and without opening any overlay first: the
    /// bug being closed is that input only ever worked after a Panel had been
    /// summoned and dismissed. Then one real target on the host's own bar, a
    /// touchpad drag, and a three-finger tap to raise the software keyboard so
    /// the host's `Keyboard passthrough` node has something to show. Nothing is
    /// asserted about the host here; the host's own readback is the evidence.
    func testInputWorksImmediatelyAfterTheFirstFrameWithoutAnOverlay() throws {
        let app = try application(phase: "stream", importHost: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        if !app.buttons["remote-start-extend"].waitForExistence(timeout: 10) {
            XCTAssertTrue(app.buttons["open-remote"].waitForExistence(timeout: 15), "no way into Remote")
            app.buttons["open-remote"].tap()
        }
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 20))
        select(backend: "Sunshine", app)
        let mode = ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_MODE"] ?? "extend"
        start(mode: mode == "takeover" ? .takeover : .extend, app)
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        XCTAssertTrue(appears(picture, seconds: 150), "no Sunshine frame arrived: \(situation(app))")
        print("OMODACHI-INPUT2 first-frame-visible epoch=\(Date().timeIntervalSince1970)")

        // No settling sleep and no Panel: the first tap goes in as soon as the
        // canvas exists, which is exactly the case that used to be dead.
        let window = app.windows.firstMatch
        let frame = window.frame
        // REMOTE-5: see INPUT-1 above — the canvas is the picture's own frame.
        let canvasRect = picture.frame
        print("OMODACHI-INPUT2 mode=\(mode) window=\(frame) picture=\(canvasRect)")
        func pointer(_ label: String) {
            let button = app.buttons[label].firstMatch
            guard button.exists else { print("OMODACHI-INPUT2 pointer-mode-missing=\(label)"); return }
            print("OMODACHI-INPUT2 pointer-mode=\(label) frame=\(button.frame) hittable=\(button.isHittable) selected-before=\(button.isSelected)")
            button.tap()
            Thread.sleep(forTimeInterval: 2)
            print("OMODACHI-INPUT2 pointer-mode=\(label) selected-after=\(app.buttons[label].firstMatch.isSelected) epoch=\(Date().timeIntervalSince1970)")
        }
        func tap(_ name: String, _ fx: CGFloat, _ fy: CGFloat, settle: TimeInterval = 4) {
            let point = CGPoint(x: canvasRect.minX + canvasRect.width * fx, y: canvasRect.minY + canvasRect.height * fy)
            let dx = (point.x - frame.minX) / frame.width
            let dy = (point.y - frame.minY) / frame.height
            window.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
            print("OMODACHI-INPUT2 tap \(name) fx=\(fx) fy=\(fy) point=\(point) epoch=\(Date().timeIntervalSince1970)")
            Thread.sleep(forTimeInterval: settle)
        }
        // One tap before anything is touched at all: whatever pointer mode the
        // device was left in, an event has to reach the host.
        tap("immediate-centre", 0.50, 0.50, settle: 3)
        // The five absolute points are a direct-touch claim, so say so; the
        // segment is in the strip, not behind an overlay.
        pointer("直接触摸")
        for (name, fx, fy) in [("top-left", 0.05, 0.05), ("top-right", 0.95, 0.05),
                               ("bottom-right", 0.95, 0.95), ("bottom-left", 0.05, 0.95),
                               ("centre", 0.50, 0.50)] as [(String, CGFloat, CGFloat)] {
            tap(name, fx, fy)
        }
        // One real target, given as "fx,fy" so the same case can aim at
        // whatever the host's bar actually carries.
        if let value = ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_TARGET"] {
            let parts = value.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { tap("host-bar", CGFloat(parts[0]), CGFloat(parts[1]), settle: 6) }
        }

        // Relative motion from the same canvas.
        let pointerMode = app.descendants(matching: .any).matching(identifier: "remote-pointer-mode").firstMatch
        if pointerMode.exists, app.buttons["触摸板"].firstMatch.exists {
            pointer("触摸板")
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65))
            for step in 0..<3 {
                from.press(forDuration: 0.1, thenDragTo: to)
                print("OMODACHI-INPUT2 drag \(step) epoch=\(Date().timeIntervalSince1970)")
                Thread.sleep(forTimeInterval: 2)
            }
            pointer("直接触摸")
        }

        // Three fingers on the canvas is the software keyboard, and the text it
        // types is what the host's keyboard node has to show.
        let canvas = app.descendants(matching: .any).matching(identifier: "remote-native-video").firstMatch
        if canvas.exists {
            canvas.tap(withNumberOfTaps: 1, numberOfTouches: 3)
            print("OMODACHI-INPUT2 three-finger-tap epoch=\(Date().timeIntervalSince1970)")
            Thread.sleep(forTimeInterval: 3)
            print("OMODACHI-INPUT2 keyboards=\(app.keyboards.count) frame=\(app.keyboards.firstMatch.exists ? "\(app.keyboards.firstMatch.frame)" : "none")")
            let text = ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_TEXT"] ?? "omodachi"
            // A key the on-screen keyboard can actually be tapped on is the
            // first choice; with the Simulator's hardware keyboard attached the
            // panel is parked off screen, and `typeText` is the same path.
            let sample = app.keys[String(text.first ?? "o")].firstMatch
            if sample.exists, sample.isHittable {
                for character in text where app.keys[String(character)].firstMatch.isHittable {
                    app.keys[String(character)].firstMatch.tap()
                }
                print("OMODACHI-INPUT2 typed-by-key=\(text) epoch=\(Date().timeIntervalSince1970)")
            } else {
                app.typeText(text)
                print("OMODACHI-INPUT2 typed-by-hardware=\(text) epoch=\(Date().timeIntervalSince1970)")
            }
            Thread.sleep(forTimeInterval: 4)
        }
        capture("input2-\(mode)", app)
        let dwell = Double(ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DWELL"] ?? "") ?? 0
        if dwell > 0 {
            print("OMODACHI-INPUT2 dwell-start \(dwell)s epoch=\(Date().timeIntervalSince1970)")
            Thread.sleep(forTimeInterval: dwell)
        }
        disconnect(app)
        if !app.buttons["remote-start-extend"].waitForExistence(timeout: 60) {
            print("OMODACHI-INPUT2 release-did-not-return-to-entry \(situation(app))")
            disconnect(app)
            _ = app.buttons["remote-start-extend"].waitForExistence(timeout: 60)
        }
        print("OMODACHI-INPUT2 done mode=\(mode) epoch=\(Date().timeIntervalSince1970)")
    }

    /// Under Remote the control lives in the 44pt edge strip, which SwiftUI does
    /// not always publish as a `Button`.
    private func disconnect(_ app: XCUIApplication) {
        let button = app.buttons["remote-disconnect"].firstMatch
        let element = button.exists ? button
            : app.descendants(matching: .any).matching(identifier: "remote-disconnect").firstMatch
        element.tap()
    }

    /// The setup sheet is gone once a frame is up, so read it defensively.
    private func situation(_ app: XCUIApplication) -> String {
        let sheet = app.staticTexts.matching(identifier: "remote-status").firstMatch
        let note = app.staticTexts.matching(identifier: "remote-message").firstMatch
        return "\(sheet.exists ? sheet.label : "<no setup sheet>") / \(note.exists ? note.label : "")"
    }

    /// SPEC-I §15: the backend lives under "高级", which has to be opened first.
    private func select(backend: String, _ app: XCUIApplication) {
        let disclosure = app.buttons["remote-advanced"]
        guard disclosure.waitForExistence(timeout: 10) else { return }
        let picker = app.otherElements["remote-backend"]
        if !picker.exists { disclosure.tap() }
        guard picker.waitForExistence(timeout: 5) else { return }
        let option = picker.buttons[backend]
        if option.exists { option.tap() }
    }

    /// The mode is not a picker any more: it is which card you press.
    private func start(mode: RemoteModeChoice, _ app: XCUIApplication) {
        app.buttons["remote-start-\(mode.rawValue)"].tap()
        // Takeover has the one confirmation in the flow (N-25).
        if mode == .takeover, app.buttons["remote-connect"].waitForExistence(timeout: 5) {
            app.buttons["remote-connect"].tap()
        }
    }

    enum RemoteModeChoice: String { case extend, takeover }
}
