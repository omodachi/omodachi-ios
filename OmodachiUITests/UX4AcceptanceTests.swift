import XCTest

/// UX-4 §2 against the real `omarchy`, on a simulator this round created for
/// itself. Disabled in ordinary builds; compiled only with
/// `OMODACHI_UX4_ACCEPTANCE`, the same way PAIR-5's and ARCH-1's are.
///
/// Nothing is seeded. The pairing is the real handshake, the operator approves
/// it on the computer, and the drift is made the way the real one was made:
/// the host is left holding a key this device does not have. The proof is on
/// the host, in `sshd`'s own journal — `Accepted publickey` with the
/// fingerprint the device is actually carrying.
@MainActor final class UX4AcceptanceTests: XCTestCase {
    /// Only the simulator this round created for itself. It pairs with Leo's
    /// real computer and leaves a device record there, so it must never be one
    /// of the simulators he or another spec is using — and the udid of a
    /// device created per run cannot be written down in advance, so the name
    /// is the allow-list. `scripts/build.sh` creates it, this refuses anything
    /// else, and the round revokes it on the host afterwards.
    private func application(_ extra: [String] = []) throws -> XCUIApplication {
        #if OMODACHI_UX4_ACCEPTANCE
        let name = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        guard name.hasPrefix("omodachi-ux4") else {
            throw XCTSkip("UX-4 pairs with the real host, so it runs only on its own simulator (saw \(name))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // The boards are drawn in Simplified Chinese, which is the catalog's
        // source language: a screenshot in `en` is a picture of a translation.
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        return app
        #else
        throw XCTSkip("UX-4 acceptance is disabled; build with OMODACHI_UX4_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitUntil(seconds: Int, _ condition: () -> Bool) -> Bool {
        for _ in 0..<(seconds * 2) {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    // MARK: - 0 · the pairing everything starts from

    func testPairWithTheRealHost() throws {
        let app = try application()
        if app.buttons["open-agent"].waitForExistence(timeout: 20) { return }
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no _omodachi._tcp instance was discovered")
        row.tap()
        XCTAssertTrue(waitUntil(seconds: 300) { app.buttons["open-agent"].exists },
                      "the pairing claim never completed")
    }

    // MARK: - 1 · the terminal opens on a host holding the wrong key

    /// The operator has left the host holding a key this device does not have,
    /// which is what a reinstall leaves behind. Opening ⑤ is the whole of the
    /// user's part: the dial is refused at `publickey`, the device offers the
    /// key it is actually holding, and dials again.
    func testTheTerminalRepairsADriftedKeyByItself() throws {
        let app = try application()
        XCTAssertTrue(app.buttons["open-ssh"].waitForExistence(timeout: 60),
                      "a paired app opens on the Panel")
        app.buttons["open-ssh"].tap()
        let state = app.descendants(matching: .any)["terminal-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 30), "⑤ never drew a terminal")
        XCTAssertTrue(waitUntil(seconds: 90) { state.label == "已连接" },
                      "the terminal never reached 已连接 (last: \(state.label))")
        capture("ux4-ssh-connected", app)
    }

    // MARK: - 2 · an adopted credential gets its key back

    /// The reinstall itself: the container is gone, the Keychain is not. The
    /// row reads 已配对（待确认）, one tap adopts the credential — and now that
    /// tap also settles the key, so ⑤ opens without a single refused dial.
    func testAnAdoptedCredentialBringsItsKeyWithIt() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 60),
                      "a container with no directory record is the host list")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        XCTAssertTrue(row.label.contains("待确认"), "the row reads 已配对（待确认）: \(row.label)")
        capture("ux4-unconfirmed-row", app)
        row.tap()
        XCTAssertTrue(waitUntil(seconds: 180) { app.buttons["open-ssh"].exists },
                      "the credential was never adopted")
        app.buttons["open-ssh"].tap()
        let state = app.descendants(matching: .any)["terminal-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(seconds: 90) { state.label == "已连接" },
                      "the terminal never reached 已连接 (last: \(state.label))")
        capture("ux4-ssh-after-adoption", app)
    }

    // MARK: - 3 · §4 the model selector folds where it opened

    /// A-55: the entry that opened a thing is the way back out of it. The
    /// picker was the last control in the app with a Done button.
    ///
    /// This lives in the acceptance suite rather than the hermetic one because
    /// `modelControl` is `.disabled(model.identity == nil)`, and the identity
    /// comes from the host's own agent snapshot — with no host there is no
    /// identity, so a hermetic run taps a disabled control and proves nothing.
    func testTheModelControlFoldsTheListItOpened() throws {
        let app = try application()
        XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 60))
        app.buttons["open-agent"].tap()
        let control = app.descendants(matching: .any)["agent-model-control"]
        XCTAssertTrue(control.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(seconds: 60) { control.isEnabled },
                      "the control is enabled once the host names its agent")
        let picker = app.descendants(matching: .any)["agent-model-picker"]
        XCTAssertFalse(picker.exists, "the list starts folded")

        control.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["agent-model-done"].exists,
                       "the Done button is gone")
        capture("ux4-model-picker-open", app)

        control.tap()
        XCTAssertTrue(waitUntil(seconds: 10) { !picker.exists },
                      "tapping the same place folds it again")
        // A toggle, not a one-shot.
        control.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        control.tap()
        XCTAssertTrue(waitUntil(seconds: 10) { !picker.exists })
    }

    // MARK: - 4 · the two fingerprints, side by side

    func testSettingsPrintsBothFingerprints() throws {
        let app = try application()
        XCTAssertTrue(app.buttons["open-setup"].waitForExistence(timeout: 60))
        app.buttons["open-setup"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-screen"].waitForExistence(timeout: 30))
        let local = app.descendants(matching: .any)["settings-diagnostics-key-local"]
        let host = app.descendants(matching: .any)["settings-diagnostics-key-host"]
        XCTAssertTrue(local.waitForExistence(timeout: 30), "⑥ never printed this device's fingerprint")
        XCTAssertTrue(waitUntil(seconds: 30) { host.exists },
                      "⑥ never printed the host's fingerprint")
        XCTAssertEqual(local.label, host.label, "after the repair the two agree")
        // XCUITest finds an element that is scrolled out of view, a camera does
        // not: the diagnostics section is at the bottom of a long page, so the
        // picture has to be taken after scrolling to it.
        for _ in 0..<8 where !local.isHittable {
            app.descendants(matching: .any)["settings-screen"].swipeUp()
        }
        XCTAssertTrue(local.isHittable, "the fingerprint rows never came into view")
        capture("ux4-settings-fingerprints", app)
    }
}
