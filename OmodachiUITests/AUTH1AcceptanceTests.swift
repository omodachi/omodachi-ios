import XCTest

/// AUTH-1 §"主机验收", against the real `omarchy`, on the one simulator this
/// spec was given. Compiled only with `OMODACHI_AUTH1_ACCEPTANCE`, the same way
/// PAIR-5's and ARCH-1's are.
///
/// This is an operator test: it drives the app and waits, while the person
/// running it does the three things only the computer and the simulator host
/// can do —
///
///   * `omodachi-host pair approve <id>` for the real handshake,
///   * `xcrun simctl spawn <udid> /usr/bin/notifyutil -p
///     com.apple.BiometricKit_Sim.fingerTouch.match` for the Face ID,
///   * `pkexec` (or `sudo`) on the computer to raise the actual PAM prompt.
///
/// Nothing is seeded and nothing is faked: the key is a real keychain key
/// under `.biometryCurrentSet`, the signature is a real P-256 signature, and
/// what proves it is that the host's PAM stack lets the operator through.
@MainActor final class AUTH1AcceptanceTests: XCTestCase {
    /// The spec's simulator, and nothing else. The ones other specs are using
    /// are deliberately not in this list.
    private let authorizedDevices = ["D0AF9C40-994A-46AA-BF15-159FB94B6718"]

    private func application(_ extra: [String] = []) throws -> XCUIApplication {
        #if OMODACHI_AUTH1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("AUTH-1 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1200
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        return app
        #else
        throw XCTSkip("AUTH-1 acceptance is disabled; build with OMODACHI_AUTH1_ACCEPTANCE")
        #endif
    }

    private func waitUntil(seconds: Int, _ condition: () -> Bool) -> Bool {
        for _ in 0..<(seconds * 2) {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func pairIfNeeded(_ app: XCUIApplication) {
        guard !app.buttons["open-setup"].waitForExistence(timeout: 20) else { return }
        guard app.otherElements["onboarding-gate"].waitForExistence(timeout: 20) else { return }
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 90), "no _omodachi._tcp instance was discovered")
        row.tap()
        XCTAssertTrue(waitUntil(seconds: 300) { app.buttons["open-setup"].exists },
                      "the operator never approved the pairing on the computer")
    }

    private func openSettings(_ app: XCUIApplication) {
        if app.descendants(matching: .any)["settings-screen"].exists { return }
        let entry = app.buttons["open-setup"]
        XCTAssertTrue(entry.waitForExistence(timeout: 60), "the settings entry never appeared")
        entry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-screen"].waitForExistence(timeout: 30),
                      "panel ⑥ never opened")
    }

    // MARK: - one run, because it is one key

    /// Register, then answer a real host prompt — in a single launch.
    ///
    /// These were two test methods once, and that was wrong: each method is its
    /// own install, and an install is a new app container. The key registered
    /// by one run is not necessarily the key the next run can sign with, and
    /// the host then holds a public half whose private half nothing can reach.
    /// One launch, one key, both halves of the story.
    func testRegisterThenApproveARealHostPrompt() throws {
        let app = try application()
        pairIfNeeded(app)
        openSettings(app)

        // 1 — the device's own switch. Turning it on raises the system
        // biometric sheet; the operator injects a match.
        let toggle = app.descendants(matching: .any)["settings-approval-toggle"]
        XCTAssertTrue(waitUntil(seconds: 60) {
            app.swipeUp()
            return toggle.exists && toggle.isHittable
        }, "the approval switch is not on panel ⑥")
        let key = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings-approval-key-'")).firstMatch
        // Always start from off, whatever the last run left behind. Tapping a
        // switch that is already on unregisters the key — which is correct
        // behaviour and a very effective way to test the wrong thing.
        if key.exists {
            toggle.tap()
            XCTAssertTrue(waitUntil(seconds: 60) { !key.exists }, "turning it off did not unregister")
        }
        capture("auth1-settings-before")
        toggle.tap()
        if !waitUntil(seconds: 150, { key.exists }) {
            app.swipeUp()
            let error = app.descendants(matching: .any)["settings-approval-error"]
            let text = error.exists ? error.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / ")
                                    : "(no error row on screen)"
            capture("auth1-settings-failed")
            XCTFail("no key was registered: \(text)")
            return
        }
        capture("auth1-settings-registered")

        // 2 — the operator raises a real password prompt on the computer. The
        // 26-high row appears over whatever panel is up, the biometric follows,
        // and the row clears itself once the host has its answer.
        let toast = app.descendants(matching: .any)["remote-toast"]
        XCTAssertTrue(waitUntil(seconds: 300) { toast.exists },
                      "the host prompt never reached this device")
        capture("auth1-approval-row")
        XCTAssertTrue(waitUntil(seconds: 180) { !toast.exists }, "the row never cleared")
        capture("auth1-after")
    }
}
