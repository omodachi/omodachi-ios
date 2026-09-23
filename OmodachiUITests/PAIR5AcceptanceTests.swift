import XCTest

/// PAIR-5 §5, against the real `omarchy`, on the one simulator this spec was
/// given. Disabled in ordinary builds; compiled only with
/// `OMODACHI_PAIR5_ACCEPTANCE`, the same way ARCH-1's and AGENT-2's are.
///
/// Nothing here is seeded: the pairing is the real handshake and the operator
/// approves it on the computer with `omodachi-host pair approve`. The three
/// runs are the spec's three, and each is its own invocation because what
/// happens *between* two launches — `devices revoke`, `simctl keychain reset`,
/// `systemctl --user stop omodachid` — is the whole point of the case.
@MainActor final class PAIR5AcceptanceTests: XCTestCase {
    /// The spec's simulator, and nothing else. The four another spec is using
    /// are deliberately not in this list.
    private let authorizedDevices = ["E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"]

    private func application(_ extra: [String] = []) throws -> XCUIApplication {
        #if OMODACHI_PAIR5_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("PAIR-5 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // The boards are drawn in Simplified Chinese, which is the catalog's
        // source language: a screenshot in `en` is a picture of a translation.
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        return app
        #else
        throw XCTSkip("PAIR-5 acceptance is disabled; build with OMODACHI_PAIR5_ACCEPTANCE")
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

    // MARK: - 0. the pairing every case starts from

    /// The real handshake. The operator approves on the computer while this
    /// waits; nothing is typed and nothing is seeded.
    func testPairWithTheRealHost() throws {
        let app = try application()
        if app.buttons["open-agent"].waitForExistence(timeout: 20) {
            return  // already paired: the case under test starts from here
        }
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30),
                      "an unpaired app is the host list and nothing else")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no _omodachi._tcp instance was discovered")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pair-waiting"].waitForExistence(timeout: 30),
                      "the waiting card never appeared")
        capture("pair5-0-waiting", app)
        XCTAssertTrue(waitUntil(seconds: 300) { app.buttons["open-agent"].exists },
                      "the pairing claim never completed")
        XCTAssertTrue(waitUntil(seconds: 60) { !app.descendants(matching: .any)["panel-host-offline"].exists },
                      "a freshly paired host is not offline")
    }

    // MARK: - 1. `omodachi-host devices revoke`

    /// The operator revoked this device between the two launches. The app has a
    /// directory record and a credential and no idea yet; the launch probe gets
    /// the 401 and the app is on the host list, row unpaired, with one line.
    func testARevokedCredentialLandsOnTheHostList() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 60),
                      "a revoked credential is not a Panel to sit in")
        XCTAssertTrue(app.descendants(matching: .any)["connect-credential-stale"].waitForExistence(timeout: 10),
                      "the list says why it is being looked at again")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        XCTAssertTrue(row.label.contains("未配对"), "the row reads 未配对, not 已配对: \(row.label)")
        XCTAssertFalse(app.buttons["open-agent"].exists)
        capture("pair5-1-rejected-list", app)
    }

    /// And the same tap that always pairs, pairs — the cleanup left nothing in
    /// the way. The operator approves the new request on the computer.
    func testTappingTheRowPairsAgain() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pair-waiting"].waitForExistence(timeout: 30),
                      "the waiting card never appeared")
        XCTAssertTrue(waitUntil(seconds: 300) { app.buttons["open-agent"].exists },
                      "the second pairing never completed")
        capture("pair5-2-paired-again", app)
    }

    // MARK: - 2. `simctl keychain reset`

    /// The records are still in the container and the secret is gone. No
    /// request is sent — there is nothing to send — and the app is unpaired.
    func testACredentialThatWasDeletedLandsOnTheHostList() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 60),
                      "a device holding no credential is a device that is not paired")
        XCTAssertTrue(app.descendants(matching: .any)["connect-credential-stale"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["open-agent"].exists)
    }

    // MARK: - 3. `systemctl --user stop omodachid`

    /// The host is off for half a minute. Nothing is deleted, the Panel is
    /// where the app stays, ① carries one offline row — and when the computer
    /// comes back the row goes away on its own.
    func testAnOfflineHostKeepsThePanelAndComesBackOnItsOwn() throws {
        let app = try application()
        XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 60),
                      "an unreachable host is not a revocation")
        XCTAssertTrue(app.descendants(matching: .any)["panel-host-offline"].waitForExistence(timeout: 60),
                      "① says the host is offline, and that row is the only thing it says")
        XCTAssertFalse(app.otherElements["onboarding-gate"].exists)
        capture("pair5-3-offline-panel", app)
        // The operator starts `omodachid` again while this waits.
        XCTAssertTrue(waitUntil(seconds: 180) { !app.descendants(matching: .any)["panel-host-offline"].exists },
                      "the connection never came back by itself")
    }
}
