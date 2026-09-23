import XCTest

/// CORE-2 §1, the whole credential lifecycle with the TTL turned down.
///
/// The host is a throwaway `omodachid` on this Mac (`--demo --listen 127.0.0.1
/// --port 8399 --credential-ttl 600 --credential-grace 120`, its own secret,
/// registry and certificate), reached through the list's manual add - so no
/// real machine's credential registry is touched and nothing is advertised on
/// the LAN. The operator approves each pairing request on that daemon's own
/// socket and revokes the device there between two launches. Compiled only
/// with `OMODACHI_CORE2_ACCEPTANCE`, and it refuses any simulator but its own.
@MainActor final class CORE2AcceptanceTests: XCTestCase {
    private let authorizedDevices = ["0540F469-6D4D-4BD8-A7FC-DDCFE2AB2391"]
    private let address = "127.0.0.1:8399"

    private func application() throws -> XCUIApplication {
        #if OMODACHI_CORE2_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("CORE-2 refuses any simulator it did not create (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("CORE-2 acceptance is disabled; build with OMODACHI_CORE2_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String) {
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

    /// Manual add → one request → the operator approves → the Panel.
    private func pairByAddress(_ app: XCUIApplication, shot: String) {
        let add = app.descendants(matching: .any)["connect-add-manual"]
        XCTAssertTrue(add.waitForExistence(timeout: 30), "the list offers a manual add")
        add.tap()
        let field = app.textFields["connect-manual-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(address)
        app.descendants(matching: .any)["connect-manual-submit"].tap()
        // PAIR-4: a credential this device still holds and the host still
        // honours is adopted with no request at all, straight into the Panel.
        let waiting = app.descendants(matching: .any)["pair-waiting"]
        XCTAssertTrue(waitUntil(seconds: 30) { waiting.exists || app.buttons["open-agent"].exists },
                      "neither the waiting card nor the Panel appeared")
        capture(shot)
        XCTAssertTrue(waitUntil(seconds: 300) { app.buttons["open-agent"].exists },
                      "the pairing claim never completed")
        settle()
    }

    /// The directory record and the profile are UserDefaults; a runner that
    /// kills the app the instant the Panel appears can beat their write to
    /// disk (the first run of this suite did). Going to the background flushes
    /// them, the way a person switching apps would.
    private func settle() {
        Thread.sleep(forTimeInterval: 3)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
    }

    // MARK: - 0. pair

    func testPairWithTheShortLivedDaemon() throws {
        let app = try application()
        if app.buttons["open-agent"].waitForExistence(timeout: 15) { return }
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30))
        pairByAddress(app, shot: "core2-0-waiting")
    }

    // MARK: - 1. renewal

    /// The credential is inside its "last week" from the moment it is issued
    /// (a 600 s life against the 7-day window), so a launch renews it. The
    /// person sees the Panel and nothing else; the host's log and `devices
    /// list` are the evidence (the report has both).
    func testALaunchRenewsTheCredentialSilently() throws {
        let app = try application()
        XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 30),
                      "a live credential opens the Panel")
        XCTAssertFalse(app.otherElements["onboarding-gate"].exists)
        // Leave time for the launch pass (probe, then GET + POST) to land.
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(app.buttons["open-agent"].exists, "nothing about a renewal takes the Panel away")
    }

    // MARK: - 2. expiry

    /// The operator kept the app closed for longer than the credential's life.
    /// The launch probe gets `401 credential_expired`; the list says so, and one
    /// more approval brings the device back.
    func testAnExpiredCredentialFallsBackToOneApproval() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 60),
                      "an expired credential is not a Panel to sit in")
        let line = app.descendants(matching: .any)["connect-credential-stale"]
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        let text = line.staticTexts.allElementsBoundByIndex.map(\.label).joined() + line.label
        XCTAssertTrue(text.contains("过期"), "the line says the credential expired: \(text)")
        XCTAssertTrue(text.contains("批准一次"), "and that one approval brings it back: \(text)")
        capture("core2-2-expired-list")
        pairByAddress(app, shot: "core2-2-repair-waiting")
        capture("core2-2-repaired")
    }

    // MARK: - 3. revoke

    /// The operator revoked the device on the daemon between two launches. The
    /// list says it was taken back on the computer - not "expired", and not an
    /// offer to renew.
    func testARevokedCredentialSaysItWasTakenBack() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 60))
        let line = app.descendants(matching: .any)["connect-credential-stale"]
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        let text = line.staticTexts.allElementsBoundByIndex.map(\.label).joined() + line.label
        XCTAssertTrue(text.contains("撤销"), "the line says the device was revoked: \(text)")
        XCTAssertFalse(text.contains("过期"), "a revoke is not an expiry: \(text)")
        XCTAssertFalse(app.buttons["open-agent"].exists)
        capture("core2-3-revoked-list")
    }
}
