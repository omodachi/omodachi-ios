import XCTest

/// REMOTE-6's acceptance run against the real `omarchy` host.
///
/// Two things are being proven, and the host operator samples
/// `omodachi-host remote status` alongside both of them:
///
/// 1. A VNC session now gets the device's own pixels. WayVNC opens at the
///    compositor's logical size and corrects itself to the output's buffer
///    pixels one update in, and the picture has to follow that flip rather
///    than end the session on it (SPEC-E3 §3, REMOTE-4's re-dial).
/// 2. Leo, 2026-09-22: after a VNC session, going back to Sunshine in ⑥ did
///    not come back to the high-resolution profile. This drives that exact
///    sequence from the entry screen, three times, so the operator's sampler
///    has a profile for every session in the chain.
///
/// Disabled without `OMODACHI_REMOTE6_ACCEPTANCE`. It drives a real machine.
@MainActor final class REMOTE6AcceptanceTests: XCTestCase {
    /// The simulators this spec paired with the real host. Anything else —
    /// "whatever simulator happens to be booted" — is refused.
    private let authorizedDevices = ["B0E3D355-3EFB-414B-AFBE-CCCCD891A779"]

    private func mark(_ text: String) {
        print("REMOTE6 \(text) epoch=\(Date().timeIntervalSince1970)")
    }

    private func application() throws -> XCUIApplication {
        #if OMODACHI_REMOTE6_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("REMOTE-6 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1800
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("REMOTE-6 acceptance is disabled; build with OMODACHI_REMOTE6_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
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
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.exists
    }

    // MARK: - the two flows a user actually performs

    /// `extend` by default. A takeover blanks the operator's own physical
    /// screen for the length of the session, so it is asked for explicitly
    /// rather than run five times in a row on somebody's desk.
    private var mode: String {
        ProcessInfo.processInfo.environment["OMODACHI_REMOTE6_MODE"] ?? "extend"
    }

    /// Opens ⑥, chooses a backend and starts a session in `mode`. Answers
    /// whether a picture arrived.
    @discardableResult
    private func startSession(_ app: XCUIApplication, backend: String) -> Bool {
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 60), "no panel ①")
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.otherElements["remote-entry-page"].waitForExistence(timeout: 20), "no entry page")
        if !app.buttons[backend].exists, app.buttons["remote-advanced"].exists {
            app.buttons["remote-advanced"].tap()
        }
        let choice = app.buttons[backend]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "no \(backend) segment in ⑥")
        choice.tap()
        mark("chose \(backend)")
        app.buttons["remote-start-\(mode)"].tap()
        mark("start \(mode) backend=\(backend)")
        let arrived = appears(app.otherElements["remote-live-picture"], seconds: 150)
        mark("picture backend=\(backend) arrived=\(arrived)")
        return arrived
    }

    /// Ends the session the way REMOTE-2 §1 says a user ends one without
    /// touching anything: the app goes to the background and stays there past
    /// its 20 s grace, and the controller releases the session itself. The
    /// Panel's pinned row is the other way (A-41) and is covered by MERGE-1;
    /// this suite is about the picture, and this path needs no chrome.
    private func endSession(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 28)
        app.activate()
        _ = appears(app.otherElements["home-panel"], seconds: 60)
        Thread.sleep(forTimeInterval: 2)
        mark("ended")
    }

    /// §1. Five VNC sessions in a row, each one reaching a real frame. The
    /// operator's sampler records the profile and the app's own
    /// `remote.framebuffer` trace records both of WayVNC's sizes.
    func testVNCReachesItsFirstFrameFiveTimes() throws {
        let app = try application()
        var arrived = 0
        for attempt in 1...5 {
            mark("vnc attempt \(attempt)")
            if startSession(app, backend: "VNC") {
                arrived += 1
                Thread.sleep(forTimeInterval: 4)
                if attempt == 1 { capture("remote6-01-vnc-native-pixels", app) }
            } else {
                capture("remote6-vnc-no-frame-\(attempt)", app)
            }
            endSession(app)
            Thread.sleep(forTimeInterval: 3)
        }
        mark("vnc first frames \(arrived)/5")
        XCTAssertEqual(arrived, 5, "every VNC session reached a frame")
    }

    /// §3. Leo's sequence: VNC, then back to Sunshine in ⑥, three times over.
    /// Nothing is asserted about resolution here — the host is the only honest
    /// witness to that, and the operator samples it — but every session is
    /// driven from the entry screen exactly as a user drives it.
    func testGoingBackToSunshineAfterVNCThreeTimes() throws {
        let app = try application()
        var reached: [String: Int] = [:]
        for round in 1...3 {
            for backend in ["VNC", "Sunshine"] {
                mark("round \(round) backend \(backend)")
                if startSession(app, backend: backend) {
                    reached[backend, default: 0] += 1
                    Thread.sleep(forTimeInterval: 6)
                    if round == 1, backend == "Sunshine" {
                        capture("remote6-02-sunshine-after-vnc", app)
                    }
                }
                mark("settled round \(round) backend \(backend)")
                endSession(app)
                Thread.sleep(forTimeInterval: 3)
            }
        }
        mark("reached vnc=\(reached["VNC"] ?? 0) sunshine=\(reached["Sunshine"] ?? 0)")
        XCTAssertEqual(reached["VNC"] ?? 0, 3)
    }
}
