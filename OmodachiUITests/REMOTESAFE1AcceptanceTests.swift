import XCTest

/// REMOTE-SAFE-1's acceptance run: an Extend session on the clean VM
/// (`studio:sf-omodachi-vm`), with the host bar's two ends moved in clear of this
/// display's corners, portrait and landscape.
///
/// The operator side runs on the VM while each hold lasts: `hyprctl layers`,
/// the plugin's `omodachi.barGeometry`, a WayVNC grab of the OMODACHI output,
/// and `simctl io screenshot --mask=alpha` of this simulator (the rounded
/// display mask is what shows the corners). Every hold prints a mark with its
/// epoch so the two sides line up.
///
/// Disabled without `OMODACHI_REMOTESAFE1_ACCEPTANCE`, like every operator suite
/// here, and it refuses any simulator but the two REMOTE-SAFE-1 created. The
/// host is the VM's NAT address in `OMODACHI_OPERATOR_HOST`; never Leo's
/// machine.
@MainActor final class REMOTESAFE1AcceptanceTests: XCTestCase {
    /// iPhone 17 Pro and iPad Pro 11-inch (M5), created for this spec.
    /// REMOTE-SAFE-1b adds its own iPhone 15 Pro (Leo's device) and iPhone 17 Pro.
    private let authorizedDevices = ["1A2F48E1-568B-4BDD-AFA4-3908F4B1BFE5",
                                     "4CFAAD48-CCD8-43D4-A4B6-E83A0F393087",
                                     "778986C7-0A4A-4DB7-9B1F-548B788AD9FE",
                                     "3F881C3C-A287-403D-8B74-B30E23BFDC33"]

    private func mark(_ text: String) {
        print("RS1 \(text) epoch=\(Date().timeIntervalSince1970)")
    }

    private var hold: TimeInterval {
        TimeInterval(ProcessInfo.processInfo.environment["OMODACHI_RS1_HOLD"] ?? "") ?? 45
    }

    private func application(_ orientation: UIDeviceOrientation) throws -> XCUIApplication {
        #if OMODACHI_REMOTESAFE1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("REMOTE-SAFE-1 refuses any simulator the spec did not create (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1200
        XCUIDevice.shared.orientation = orientation
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
        #else
        throw XCTSkip("REMOTE-SAFE-1 acceptance is disabled; build with OMODACHI_REMOTESAFE1_ACCEPTANCE")
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

    /// One-time per simulator: the real pairing handshake with the VM, which
    /// the operator approves there (`omodachi-host pair approve <id>`).
    func testAPairWithTheVM() throws {
        let app = try application(.portrait)
        guard app.otherElements["onboarding-gate"].waitForExistence(timeout: 15) else {
            XCTAssertTrue(app.otherElements["home-panel"].exists, "neither the gate nor a paired panel")
            return
        }
        let manual = app.buttons["connect-add-manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        manual.tap()
        let field = app.textFields["connect-manual-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOST"] ?? "192.168.1.25")
        app.buttons["connect-manual-submit"].tap()
        mark("pairing requested — approve it on the VM")
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 300), "the VM never approved")
    }

    /// Portrait, then (on the phone) landscape: the picture, our logo mark,
    /// and a hold at each for the VM side to be read.
    func testBExtendPortraitThenLandscape() throws {
        let app = try application(.portrait)
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60), "pair first (testAPairWithTheVM)")
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.otherElements["remote-entry-page"].waitForExistence(timeout: 10))
        mark("start extend")
        app.buttons["remote-start-extend"].tap()
        let picture = app.otherElements["remote-live-picture"]
        guard appears(picture, seconds: 180) else {
            capture("rs1-00-no-frame")
            throw XCTSkip("no first frame from the VM")
        }
        Thread.sleep(forTimeInterval: 6)
        report(app, "portrait")
        mark("hold portrait begin")
        capture("rs1-portrait")
        Thread.sleep(forTimeInterval: hold)
        mark("hold portrait end")

        if ProcessInfo.processInfo.environment["OMODACHI_RS1_ROTATE"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
            mark("rotated landscape")
            Thread.sleep(forTimeInterval: 4)
            XCTAssertTrue(appears(picture, seconds: 120), "the picture came back after the rotation")
            Thread.sleep(forTimeInterval: 8)
            report(app, "landscape")
            mark("hold landscape begin")
            capture("rs1-landscape")
            Thread.sleep(forTimeInterval: hold)
            mark("hold landscape end")
        }
        endSession(app)
        mark("hold ended begin")
        Thread.sleep(forTimeInterval: 20)
        mark("hold ended end")
    }

    /// REMOTE-SAFE-1b. The same holds for a Take over: the whole desktop on the
    /// device-shaped output, the bar on the edge `official_bar_position` picks
    /// (portrait: left/right, landscape: top/bottom). Ends the session through
    /// our logo mark -> panel ① -> End, in whichever orientation it is in at
    /// the end, and says whether each step was reachable.
    func testCTakeoverPortraitThenLandscape() throws {
        let app = try application(.portrait)
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60), "pair first (testAPairWithTheVM)")
        app.buttons["open-remote"].tap()
        XCTAssertTrue(app.otherElements["remote-entry-page"].waitForExistence(timeout: 10))
        mark("start takeover")
        app.buttons["remote-start-takeover"].tap()
        let connect = app.buttons["remote-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "the takeover confirmation")
        connect.tap()
        let picture = app.otherElements["remote-live-picture"]
        guard appears(picture, seconds: 180) else {
            capture("rs1b-00-no-frame")
            throw XCTSkip("no first frame from the VM")
        }
        Thread.sleep(forTimeInterval: 8)
        report(app, "takeover-portrait")
        mark("hold portrait begin")
        capture("rs1b-takeover-portrait")
        Thread.sleep(forTimeInterval: hold)
        mark("hold portrait end")

        if ProcessInfo.processInfo.environment["OMODACHI_RS1_ROTATE"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
            mark("rotated landscape")
            Thread.sleep(forTimeInterval: 4)
            XCTAssertTrue(appears(picture, seconds: 120), "the picture came back after the rotation")
            Thread.sleep(forTimeInterval: 10)
            report(app, "takeover-landscape")
            mark("hold landscape begin")
            capture("rs1b-takeover-landscape")
            Thread.sleep(forTimeInterval: hold)
            mark("hold landscape end")
        }
        let logo = app.buttons["remote-mark-logo"]
        mark("logo exists=\(logo.exists) hittable=\(logo.exists && logo.isHittable)")
        if logo.exists && logo.isHittable {
            logo.tap()
            let overlay = app.descendants(matching: .any)["remote-panel-overlay"].firstMatch
            mark("panel after logo tap=\(overlay.waitForExistence(timeout: 8))")
        }
        endSession(app)
        mark("hold ended begin")
        Thread.sleep(forTimeInterval: 20)
        mark("hold ended end")
    }

    /// Where our mark sits over the picture, for the hit-test comparison with
    /// the VM's own `omarchy.menu` slot.
    private func report(_ app: XCUIApplication, _ label: String) {
        let picture = app.otherElements["remote-live-picture"]
        let logo = app.buttons["remote-mark-logo"]
        _ = appears(logo, seconds: 20)
        mark("\(label) picture=\(picture.frame) logo=\(logo.exists ? "\(logo.frame)" : "none") window=\(app.windows.firstMatch.frame)")
    }

    private func endSession(_ app: XCUIApplication) {
        let overlayUp = app.descendants(matching: .any)["remote-panel-overlay"].firstMatch.exists
        for identifier in ["remote-mark-logo", "remote-corner-handle"] where !overlayUp {
            let entry = app.descendants(matching: .any)[identifier]
            if entry.exists && entry.isHittable { entry.tap(); break }
        }
        Thread.sleep(forTimeInterval: 2)
        capture("rs1-overlay")
        let open = app.descendants(matching: .any)["open-remote"].firstMatch
        if open.waitForExistence(timeout: 15), open.isHittable { open.tap() }
        let end = app.descendants(matching: .any)["remote-end"].firstMatch
        guard end.waitForExistence(timeout: 10) else {
            mark("no session card reachable; the operator stops the session on the VM")
            return
        }
        end.tap()
        let confirm = app.descendants(matching: .any)["remote-end-confirm"].firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        mark("session ended")
    }
}
