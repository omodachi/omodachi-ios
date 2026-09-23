import XCTest

/// STREAM-1's host run: one real Sunshine session walked through the presets
/// in place, and one held on `自动` while the operator shapes the link.
///
/// The host is the witness: the operator samples `omodachi-host remote status`
/// (profile fps / bitrate / codec, `quality.preset`, and a session id that must
/// not change) while this drives the App. The walk itself is the product path
/// — `setStreamChoice`, the resize, the re-dial — started by
/// `--remote-operator-stream` because ⑥ cannot be reached from inside the
/// picture without a gesture the simulator cannot make.
///
/// Disabled without `OMODACHI_STREAM1_ACCEPTANCE`, and it refuses any
/// simulator other than the one named in `OMODACHI_STREAM1_DEVICE` (a
/// throwaway the run creates, pairs, revokes and deletes). Run it only with
/// `remote status` showing `null`: it opens a session on somebody's machine.
@MainActor final class STREAM1AcceptanceTests: XCTestCase {
    private var expectedHost: String {
        ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOST"] ?? "192.168.1.10"
    }

    private func mark(_ text: String) { print("STREAM1 \(text) epoch=\(Date().timeIntervalSince1970)") }

    private func application(stream: String? = nil) throws -> XCUIApplication {
        #if OMODACHI_STREAM1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
        let named = ProcessInfo.processInfo.environment["OMODACHI_STREAM1_DEVICE"]
        guard let device, let named, device == named else {
            throw XCTSkip("STREAM-1 refuses any simulator it was not handed (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1800
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        let app = XCUIApplication()
        app.launchArguments = ["--remote-operator", "--remote-operator-phase=stream",
                               "--remote-operator-host=\(expectedHost)"]
        if let stream { app.launchArguments.append("--remote-operator-stream=\(stream)") }
        app.launch()
        return app
        #else
        throw XCTSkip("STREAM-1 acceptance is disabled; build with OMODACHI_STREAM1_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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

    func testAPairWithTheRealHost() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 15))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no _omodachi._tcp instance was discovered")
        row.tap()
        mark("waiting-for-approval")
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 240), "the claim never completed")
        mark("paired")
    }

    /// Opens Remote, starts an extend Sunshine session, walks the Sunshine
    /// certificate pairing if the fork does not know this device yet.
    @discardableResult
    private func startSession(_ app: XCUIApplication) -> Bool {
        if !app.buttons["remote-start-extend"].waitForExistence(timeout: 10) {
            XCTAssertTrue(app.buttons["open-remote"].waitForExistence(timeout: 30), "no way into Remote")
            app.buttons["open-remote"].tap()
        }
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 20))
        app.buttons["remote-start-extend"].tap()
        mark("start extend")
        let pairing = app.staticTexts["sunshine-pairing-status"]
        if appears(pairing, seconds: 20) {
            mark("sunshine-pairing \(pairing.label)")
            let done = NSPredicate { _, _ in !app.buttons["remote-pair"].exists }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: done, object: nil)], timeout: 240)
            mark("sunshine-paired")
            if app.buttons["remote-start-extend"].waitForExistence(timeout: 20) {
                app.buttons["remote-start-extend"].tap()
            }
        }
        let picture = app.descendants(matching: .any).matching(identifier: "remote-live-picture").firstMatch
        let arrived = appears(picture, seconds: 150)
        mark("first-frame arrived=\(arrived)")
        return arrived
    }

    private func end(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 28)
        app.activate()
        mark("released")
    }

    /// The three rows and the text variant on one session, 25 s each. A
    /// capture 18 s into each row, after the re-dial has settled.
    func testBThePresetWalkIsOneSession() throws {
        let rows = ["performance", "balanced", "quality", "custom@30/30000"]
        let app = try application(stream: rows.map { "\($0):25" }.joined(separator: ","))
        guard startSession(app) else { return XCTFail("no first frame") }
        let started = Date()
        for (index, row) in rows.enumerated() {
            let due = started.addingTimeInterval(TimeInterval(index * 25 + 18))
            Thread.sleep(forTimeInterval: max(0, due.timeIntervalSinceNow))
            capture("stream1-\(index + 1)-\(row.replacingOccurrences(of: "/", with: "x"))")
        }
        Thread.sleep(forTimeInterval: 10)
        end(app)
    }

    /// `自动` held for as long as the operator needs to shape the link and
    /// watch it step (OMODACHI_STREAM1_HOLD seconds, default 240).
    func testCAutoFollowsTheLink() throws {
        let hold = Int(ProcessInfo.processInfo.environment["OMODACHI_STREAM1_HOLD"] ?? "") ?? 240
        let app = try application(stream: "auto:\(hold + 60)")
        guard startSession(app) else { return XCTFail("no first frame") }
        mark("auto holding \(hold)s")
        Thread.sleep(forTimeInterval: TimeInterval(hold))
        capture("stream1-auto-after-hold")
        end(app)
    }
}
