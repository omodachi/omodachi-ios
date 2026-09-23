import XCTest

/// GEST-1's host run: one picture gesture, on a real session, proved by the
/// host's own `activeworkspace` moving on the output the session owns.
///
/// **A three-finger swipe cannot be synthesized on this runtime.** XCUITest
/// refuses to compute coordinates for a multi-finger gesture and the
/// simulator's HID injection serialises the touches (REMOTE-2, UX-2 §0). So the
/// app is launched with `--remote-operator-gesture=<name>` and replays that
/// gesture into the **real** arbiter three seconds after the first frame:
/// the state machine, N-37's registration check, the alias, the host request
/// and the 26-high row are all the product path. What the replay stands in for
/// is the finger, and only the finger — which is why the report also carries a
/// checklist for Leo's own iPad.
///
/// Disabled without `OMODACHI_GEST1_ACCEPTANCE`, and it refuses any simulator
/// the spec did not name. It opens a Remote session on a machine somebody else
/// is using: run it only with `omodachi-host remote status` showing `null`.
@MainActor final class GEST1AcceptanceTests: XCTestCase {
    /// The one simulator this spec names. UX-2 and INPUT-2 used the same one.
    ///
    /// The 2026-09-22 run added a second, throwaway iPad's udid here for the
    /// length of the run and took it out again: pairing a fresh device with the
    /// real host is cleaner than resetting the keychain of a simulator Leo also
    /// uses, and the throwaway was deleted and its host credential revoked when
    /// the run ended. Do the same rather than widening this list.
    private let authorizedDevices = ["D0AF9C40-994A-46AA-BF15-159FB94B6718"]

    private var expectedHost: String {
        ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOST"] ?? "192.168.1.10"
    }
    /// `workspace_next` / `workspace_previous` / `scratchpad` / `full_screen`.
    private var gesture: String {
        ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_GESTURE"] ?? "workspace_next"
    }

    private func mark(_ text: String) { print("GEST1 \(text) epoch=\(Date().timeIntervalSince1970)") }

    private func application() throws -> XCUIApplication {
        #if OMODACHI_GEST1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("GEST-1 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        let app = XCUIApplication()
        app.launchArguments = ["--remote-operator", "--remote-operator-phase=stream",
                               "--remote-operator-host=\(expectedHost)",
                               "--remote-operator-gesture=\(gesture)"]
        if let value = ProcessInfo.processInfo.environment["OMODACHI_DEV_HOST"] {
            app.launchEnvironment["OMODACHI_DEV_HOST"] = value
        }
        app.launch()
        return app
        #else
        throw XCTSkip("GEST-1 acceptance is disabled; build with OMODACHI_GEST1_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func appears(_ element: XCUIElement, seconds: Int) -> Bool {
        for _ in 0..<(seconds / 3) {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 3)
        }
        return element.exists
    }

    /// The precondition, not the point: this device has to hold a real pairing
    /// before it can hold a session. One tap, then the operator approves on the
    /// host (`omodachi-host pair approve`) exactly as a person would.
    func testAPairWithTheRealHost() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 15))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no _omodachi._tcp instance was discovered")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pair-card")
                      .firstMatch.waitForExistence(timeout: 30), "the waiting card never appeared")
        mark("waiting-for-approval")
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 240), "the claim never completed")
        mark("paired")
    }

    /// §1 / §3 on a live session: the gesture resolves to its row, the row runs
    /// on the host, and the 26-high row says what the host answered.
    func testBPictureGestureRunsTheRowItIsAnAliasOf() throws {
        let app = try application()
        if !app.buttons["remote-start-extend"].waitForExistence(timeout: 10) {
            XCTAssertTrue(app.buttons["open-remote"].waitForExistence(timeout: 20), "no way into Remote")
            app.buttons["open-remote"].tap()
        }
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 20))
        // Extend, never takeover: the host's own screen is somebody's desk.
        app.buttons["remote-start-extend"].tap()
        // PAIR-3: a device that has just been paired with core still has no
        // streaming certificate with the fork, and the host refuses before it
        // touches anything. The app starts that pairing itself; this waits for
        // it and then asks for the session again. A device that already holds
        // a certificate never comes through here.
        let pairing = app.staticTexts["sunshine-pairing-status"]
        if appears(pairing, seconds: 30) {
            mark("sunshine-pairing \(pairing.label)")
            let done = NSPredicate { _, _ in !app.buttons["remote-pair"].exists }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: done, object: nil)], timeout: 240)
            mark("sunshine-paired")
            if app.buttons["remote-start-extend"].waitForExistence(timeout: 20) {
                app.buttons["remote-start-extend"].tap()
            }
        }
        // REMOTE-5. This waited on `remote-edge-strip`, which MERGE-1's A-40
        // had already deleted from the product — so the 2026-09-22 run reported
        // "no first frame" twice against a host that was streaming throughout
        // (GEST-1 §6b, REMOTE-5 report). `remote-live-picture` is the picture's
        // own name and exists for exactly as long as the stream does.
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        XCTAssertTrue(appears(picture, seconds: 150), "no first frame")
        mark("first-frame gesture=\(gesture)")
        // The replay fires three seconds after the first frame; the row is up
        // for two seconds after the host settles it.
        let toast = app.descendants(matching: .any).matching(identifier: "panel-toast").firstMatch
        XCTAssertTrue(appears(toast, seconds: 30), "the gesture produced no 26-high row")
        mark("toast label=\(toast.label)")
        capture("GEST-1-gesture-toast", app)
        // Four endings, one release (N-32). Ending it here rather than leaving
        // it for the host's TTL is the difference between a spec run and a
        // stuck session on somebody's machine.
        // REMOTE-5: A-57's two-step is `remote-end` / `remote-end-confirm` on
        // the session card. `remote-session-end` is nothing, and a tap on
        // nothing left the host holding the output for a whole TTL.
        let end = app.buttons["remote-end"].firstMatch
        if end.waitForExistence(timeout: 5) {
            end.tap()
            if app.buttons["remote-end-confirm"].waitForExistence(timeout: 5) {
                app.buttons["remote-end-confirm"].tap()
            }
        }
        mark("released")
    }

    /// §4: settings ⑥ names every gesture and what it resolved to, including
    /// the ones the host has no row for.
    func testCSettingsNamesEveryGestureAndItsRow() throws {
        let app = try application()
        // REMOTE-5: the bar's own name for ⑤ is `open-setup` (BarView's
        // `identifier(for:)`); neither of the two names this reached for has
        // existed for several specs.
        let settings = app.buttons["open-setup"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "no way into settings")
        settings.tap()
        for raw in 2...5 {
            let row = app.descendants(matching: .any).matching(identifier: "settings-gesture-\(raw)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "gesture row \(raw) is missing")
        }
        capture("GEST-1-settings-gestures", app)
    }
}
