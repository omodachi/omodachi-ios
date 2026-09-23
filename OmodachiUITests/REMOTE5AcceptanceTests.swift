import XCTest

/// REMOTE-5's host run: a simulator that was created and paired minutes ago
/// reaches a Sunshine first frame, and so does a VNC one, and so does the same
/// device after a reinstall (the adoption path Leo's iPad takes).
///
/// GEST-1 §6b reported "no first frame" twice on a freshly paired simulator.
/// That run waited on `remote-edge-strip`, which MERGE-1's A-40 deleted from
/// the product, so this suite waits on the picture's own name
/// (`remote-live-picture`) **and** records whether the strip exists, so the two
/// readings can never be confused again.
///
/// Disabled without `OMODACHI_REMOTE5_ACCEPTANCE`. It refuses any simulator
/// whose name this spec did not choose, and it opens a Remote session on a
/// machine somebody else uses: run it only with `omodachi-host remote status`
/// showing `null`.
@MainActor final class REMOTE5AcceptanceTests: XCTestCase {
    /// The throwaway simulators this spec creates carry this prefix in their
    /// name; nothing else is touched. A udid list would have to be edited for
    /// every run, and an edited allow-list is how another spec's device gets
    /// installed into by accident.
    private let namePrefix = "omodachi-remote5"

    private var expectedHost: String {
        ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOST"] ?? "192.168.1.10"
    }
    /// `sunshine`, `vnc`, or `auto` (the host's default, which is Sunshine).
    private var backend: String {
        ProcessInfo.processInfo.environment["OMODACHI_REMOTE5_BACKEND"] ?? "auto"
    }
    /// Which run of the five this is, so the markers can be told apart.
    private var runLabel: String {
        ProcessInfo.processInfo.environment["OMODACHI_REMOTE5_RUN"] ?? "0"
    }

    private func mark(_ text: String) {
        print("REMOTE5 run=\(runLabel) backend=\(backend) \(text) epoch=\(Date().timeIntervalSince1970)")
    }

    private func application(_ extra: [String] = []) throws -> XCUIApplication {
        #if OMODACHI_REMOTE5_ACCEPTANCE
        let name = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        guard name.hasPrefix(namePrefix) else {
            throw XCTSkip("REMOTE-5 refuses a simulator it did not create (saw \(name.isEmpty ? "none" : name))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1200
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        return app
        #else
        throw XCTSkip("REMOTE-5 acceptance is disabled; build with OMODACHI_REMOTE5_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A deadline, not an iteration count (MERGE-1 §6.2).
    @discardableResult private func appears(_ element: XCUIElement, seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.exists
    }

    // MARK: - a. the pairing this device does not have yet

    func testAPairWithTheRealHost() throws {
        let app = try application()
        if app.otherElements["home-panel"].waitForExistence(timeout: 8) {
            mark("already-paired")
            return
        }
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 20))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 90), "no _omodachi._tcp instance was discovered")
        mark("tap-host-row")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pair-card").firstMatch
            .waitForExistence(timeout: 30), "the waiting card never appeared")
        mark("waiting-for-approval")
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 300),
                      "the claim never completed")
        mark("paired")
    }

    // MARK: - b. the first frame

    /// Open Remote, pick the backend this run is for, start an **extend**
    /// session, and wait for the picture. Every branch prints a marker, so a
    /// run that stops somewhere says where.
    func testBFirstFrame() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 40), "no panel")
        Thread.sleep(forTimeInterval: 6)
        try firstFrame(app)
    }

    // MARK: - c. the adoption path Leo's iPad takes

    /// A reinstall keeps the Keychain and loses `UserDefaults`, so the app comes
    /// up on the gate holding a credential the host still honours. Tapping the
    /// host **adopts** it — no request, no approval — and UX-4's reconcile puts
    /// this install's new SSH key up. Then the session, from a device that was
    /// already paired.
    func testCAdoptThenFirstFrame() throws {
        let app = try application()
        if !app.otherElements["home-panel"].waitForExistence(timeout: 12) {
            XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30),
                          "neither a panel nor a gate")
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 90), "no _omodachi._tcp instance was discovered")
            mark("tap-host-row-for-adoption")
            row.tap()
            XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 180),
                          "the adoption never reached the panel")
            mark("adopted")
        }
        Thread.sleep(forTimeInterval: 6)
        try firstFrame(app)
    }

    private func firstFrame(_ app: XCUIApplication) throws {
        let open = app.buttons["open-remote"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20), "no way into Remote")
        open.tap()
        let entry = app.descendants(matching: .any).matching(identifier: "remote-entry").firstMatch
        XCTAssertTrue(appears(entry, seconds: 30), "the Remote entry never opened")
        Thread.sleep(forTimeInterval: 2)

        if backend != "auto" {
            let advanced = app.buttons["remote-advanced"].firstMatch
            if advanced.waitForExistence(timeout: 10) {
                advanced.tap()
                let title = backend == "vnc" ? "VNC" : "Sunshine"
                let segment = app.buttons[title].firstMatch
                if segment.waitForExistence(timeout: 5) {
                    segment.tap()
                    mark("backend-chosen=\(title)")
                } else {
                    mark("backend-segment-missing=\(title)")
                }
                advanced.tap()
            }
        }

        let start = app.buttons["remote-start-extend"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 20), "no start button")
        mark("start-extend")
        start.tap()

        // The Sunshine certificate leg. A device core has no binding for is
        // refused before the host touches anything; the app starts that pairing
        // itself. Record whether it happened rather than assuming either way.
        let pairingStatus = app.staticTexts["sunshine-pairing-status"].firstMatch
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        var sawPairing = false
        let pairingDeadline = Date().addingTimeInterval(25)
        while Date() < pairingDeadline, !sawPairing, !picture.exists {
            if pairingStatus.exists || app.buttons["remote-pair"].exists { sawPairing = true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if sawPairing {
            mark("sunshine-pairing-seen label=\(pairingStatus.exists ? pairingStatus.label : "-")")
            // The app resumes the session by itself once the pairing lands; the
            // button is only there when it needs a push.
            let settled = Date().addingTimeInterval(240)
            while Date() < settled, !picture.exists {
                if app.buttons["remote-pair"].exists, !pairingStatus.exists {
                    mark("sunshine-pair-button-tap")
                    app.buttons["remote-pair"].tap()
                }
                if app.buttons["remote-start-extend"].exists, !pairingStatus.exists,
                   !app.buttons["remote-pair"].exists {
                    mark("restart-after-pairing")
                    app.buttons["remote-start-extend"].tap()
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }

        let arrived = appears(picture, seconds: 180)
        let strip = app.descendants(matching: .any).matching(identifier: "remote-edge-strip").firstMatch
        mark("first-frame=\(arrived) sawPairing=\(sawPairing) strip-exists=\(strip.exists)")
        if !arrived {
            capture("REMOTE5-no-frame-\(runLabel)", app)
            let message = app.staticTexts["remote-message"].firstMatch
            let banner = app.descendants(matching: .any).matching(identifier: "remote-reconnect-banner").firstMatch
            XCTFail("""
                no first frame (pairing branch: \(sawPairing)); \
                message=\(message.exists ? message.label : "none") \
                banner=\(banner.exists ? "present" : "none")
                """)
        } else if runLabel == "1" {
            Thread.sleep(forTimeInterval: 4)
            capture("REMOTE5-first-frame-\(backend)", app)
        }

        // Four endings, one release: leaving it for the host's TTL is how a
        // spec run turns into a stuck session on somebody's machine.
        endSession(app)
    }

    // MARK: - d. the false negative itself

    /// GEST-1 §6b's own wait, against a session that is streaming.
    ///
    /// This is the counterfactual the report rests on: with the picture up and
    /// the host holding a `ready` Sunshine session, the element GEST-1 waited
    /// 150 seconds for is still not there — because MERGE-1's A-40 deleted it.
    /// The run that reported "no first frame" could not have reported anything
    /// else.
    func testDTheStripGest1WaitedForIsGoneWhileThePictureIsUp() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 40), "no panel")
        Thread.sleep(forTimeInterval: 6)
        let open = app.buttons["open-remote"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20), "no way into Remote")
        open.tap()
        let start = app.buttons["remote-start-extend"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 30), "no start button")
        mark("start-extend")
        start.tap()
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        XCTAssertTrue(appears(picture, seconds: 180), "no first frame")
        mark("first-frame")
        // GEST-1's helper, verbatim: 50 iterations of 3 seconds on the strip.
        let strip = app.descendants(matching: .any).matching(identifier: "remote-edge-strip").firstMatch
        var sawStrip = false
        for _ in 0..<50 {
            if strip.exists { sawStrip = true; break }
            Thread.sleep(forTimeInterval: 3)
        }
        mark("gest1-strip-wait saw=\(sawStrip) picture-still-up=\(picture.exists)")
        XCTAssertFalse(sawStrip, "A-40 deleted the strip; a run waiting for it can only time out")
        XCTAssertTrue(picture.exists, "the picture was up for the whole of GEST-1's wait")
        capture("REMOTE5-picture-during-gest1-wait", app)
        endSession(app)
    }

    /// A-57's two-step where the picture offers it, and the app's own
    /// background release where it does not. Both are product paths; neither
    /// leaves the host holding an output.
    private func endSession(_ app: XCUIApplication) {
        let end = app.buttons["remote-end"].firstMatch
        if !end.exists {
            let mark = app.descendants(matching: .any).matching(identifier: "remote-mark-logo").firstMatch
            if mark.exists, mark.isHittable {
                mark.tap()
                if appears(app.descendants(matching: .any).matching(identifier: "remote-panel-overlay")
                    .firstMatch, seconds: 8), app.buttons["open-remote"].firstMatch.exists {
                    app.buttons["open-remote"].firstMatch.tap()
                }
                _ = appears(end, seconds: 8)
            }
        }
        if end.exists {
            end.tap()
            if app.buttons["remote-end-confirm"].waitForExistence(timeout: 6) {
                app.buttons["remote-end-confirm"].tap()
                mark("released-by-card")
                Thread.sleep(forTimeInterval: 4)
                return
            }
        }
        // The session is released when the app really goes to the background
        // (`backgroundGrace` is 20 s), which is the same `release()` the card
        // calls. Waiting it out here is what keeps the host from holding the
        // output for a whole TTL.
        XCUIDevice.shared.press(.home)
        mark("released-by-background")
        Thread.sleep(forTimeInterval: 30)
    }
}
