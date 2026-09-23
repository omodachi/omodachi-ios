import XCTest

/// HERDR-2 §1: the Herdr panel against the real `omarchy` host, from the two
/// simulators the spec names. Disabled without `OMODACHI_HERDR2_ACCEPTANCE`.
@MainActor final class HERDR2AcceptanceTests: XCTestCase {
    private let authorizedDevices = ["BD431ECD-4DC6-4EE8-8183-7B0AA3B313EA",
                                     "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"]

    private var isPhone: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"
    }

    private func application(_ extra: [String] = []) throws -> XCUIApplication {
        #if OMODACHI_HERDR2_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("HERDR-2 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        return app
        #else
        throw XCTSkip("HERDR-2 acceptance is disabled; build with OMODACHI_HERDR2_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func appears(_ element: XCUIElement, seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return element.exists
    }

    private func dump(_ label: String, _ app: XCUIApplication) {
        print("=== AX \(label) ===")
        print(app.debugDescription)
        print("=== /AX \(label) ===")
    }

    func testAPairWithTheRealHost() throws {
        let app = try application()
        let gate = app.otherElements["onboarding-gate"]
        if !gate.waitForExistence(timeout: 10) { return }
        let manual = app.buttons["connect-add-manual"]
        if manual.waitForExistence(timeout: 10) {
            manual.tap()
            let field = app.textFields["connect-manual-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOST"] ?? "192.168.1.10")
            app.buttons["connect-manual-submit"].tap()
        }
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 300),
                      "approve the request on the host with `omodachi-host pair approve <id>`")
    }

    /// §1: enter the Herdr panel, see the grid, and type into the owned session.
    func testBHerdrPanel() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 30))
        if !isPhone { XCUIDevice.shared.orientation = .landscapeLeft; Thread.sleep(forTimeInterval: 2) }
        XCTAssertTrue(app.buttons["open-herdr"].waitForExistence(timeout: 10))
        app.buttons["open-herdr"].tap()
        Thread.sleep(forTimeInterval: 6)
        capture("herdr2-01-entry", app)

        let terminal = app.descendants(matching: .any)["herdr-terminal"]
        print("=== terminal exists: \(terminal.exists) ===")
        print("=== mode: \(app.descendants(matching: .any)["herdr-mode"].label) ===")
        // The surface loads its layout once per appearance. Waiting proves that
        // a connection that came up afterwards never gets it a second reading.
        for step in [10, 20, 30, 45, 60] {
            Thread.sleep(forTimeInterval: 10)
            print("=== after \(step)s · connection: \(app.descendants(matching: .any)["bar-connection"].value as? String ?? "?") · mode: \(app.descendants(matching: .any)["herdr-mode"].label) · terminal: \(terminal.exists) ===")
            if terminal.exists { break }
        }
        capture("herdr2-01b-after-waiting", app)
        if !terminal.exists {
            // Leave the panel and come back: `appear()` is the only other
            // caller of `refreshLayout()`, so this is the whole difference.
            app.buttons["open-herdr"].tap()
            Thread.sleep(forTimeInterval: 2)
            app.buttons["open-herdr"].tap()
            Thread.sleep(forTimeInterval: 6)
            print("=== after re-entry · mode: \(app.descendants(matching: .any)["herdr-mode"].label) · terminal: \(terminal.exists) ===")
            dump("herdr-after-reentry", app)
            capture("herdr2-01c-after-reentry", app)
        }
        if terminal.exists {
            terminal.tap()
            Thread.sleep(forTimeInterval: 4)
            print("=== mode after tap: \(app.descendants(matching: .any)["herdr-mode"].label) ===")
            app.typeText("echo omodachi-herdr2\n")
            Thread.sleep(forTimeInterval: 4)
            capture("herdr2-02-typed", app)
        }
    }
    /// §1's reproduction: enter Herdr *before* the host connection finishes.
    ///
    /// The surface reads the layout once per appearance. If that one read lands
    /// while `companionConnected` is still false it fails, and nothing asks
    /// again: `herdr.layout.changed` only fires when the projection actually
    /// moves, so a quiet session never nudges it back.
    func testCEnterBeforeTheHostConnection() throws {
        let app = try application()
        if !isPhone { XCUIDevice.shared.orientation = .landscapeLeft }
        // No waiting for `home-panel`: the entry exists from the first frame,
        // and that is exactly what a user taps.
        XCTAssertTrue(app.buttons["open-herdr"].waitForExistence(timeout: 20))
        app.buttons["open-herdr"].tap()
        let terminal = app.descendants(matching: .any)["herdr-terminal"]
        let connection = app.descendants(matching: .any)["bar-connection"]
        let mode = app.descendants(matching: .any)["herdr-mode"]
        var seen: [String] = []
        for step in 0..<12 {
            let line = "t+\(step * 5)s connection=\(connection.value as? String ?? "?") mode=\(mode.label) terminal=\(terminal.exists)"
            print("=== \(line) ===")
            seen.append(line)
            if terminal.exists { break }
            Thread.sleep(forTimeInterval: 5)
        }
        capture("herdr2-03-entered-while-connecting", app)
        if !terminal.exists {
            print("=== NEVER RECOVERED while on the surface ===")
            app.buttons["open-herdr"].tap()
            Thread.sleep(forTimeInterval: 2)
            app.buttons["open-herdr"].tap()
            Thread.sleep(forTimeInterval: 8)
            print("=== after leaving and re-entering: mode=\(mode.label) terminal=\(terminal.exists) ===")
            capture("herdr2-04-after-reentry", app)
        }
        XCTAssertTrue(terminal.exists, "the surface never got a layout: \(seen.joined(separator: " | "))")
    }
    /// §2's acceptance: the dropdown lists every session on the host, entering
    /// the core-made probe session switches the grid and the stream to it, and
    /// coming back lands on `omodachi` again.
    ///
    /// Leo's own `default` session is listed and read, and that is all: this
    /// test never selects it and never sends it a keystroke.
    func testDTheSessionDropdown() throws {
        let app = try application()
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 40))
        if !isPhone { XCUIDevice.shared.orientation = .landscapeLeft; Thread.sleep(forTimeInterval: 2) }
        app.buttons["open-herdr"].tap()
        let terminal = app.descendants(matching: .any)["herdr-terminal"]
        XCTAssertTrue(appears(terminal, seconds: 60), "no layout on entry")
        let switcher = app.descendants(matching: .any)["herdr-session-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        print("=== switcher value: \(switcher.value as? String ?? "?") ===")
        capture("herdr2-05-session-bar", app)

        switcher.tap()
        Thread.sleep(forTimeInterval: 2)
        dump("session-menu", app)
        capture("herdr2-06-session-menu", app)
        for name in ["omodachi", "default", "herdr2-probe"] {
            XCTAssertTrue(app.descendants(matching: .any)["herdr-session-\(name)"].exists,
                          "\(name) is not in the dropdown")
        }
        // The probe session is core-made and is the only one this test enters.
        app.descendants(matching: .any)["herdr-session-herdr2-probe"].tap()
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(appears(terminal, seconds: 60), "the probe session never drew")
        print("=== after switch: \(switcher.value as? String ?? "?") ===")
        XCTAssertEqual(switcher.value as? String, "herdr2-probe")
        terminal.tap()
        Thread.sleep(forTimeInterval: 4)
        app.typeText("echo omodachi-herdr2\n")
        Thread.sleep(forTimeInterval: 4)
        capture("herdr2-07-probe-session", app)
        dump("probe-session", app)

        switcher.tap()
        Thread.sleep(forTimeInterval: 2)
        app.descendants(matching: .any)["herdr-session-omodachi"].tap()
        Thread.sleep(forTimeInterval: 8)
        XCTAssertEqual(switcher.value as? String, "omodachi")
        XCTAssertTrue(appears(terminal, seconds: 60), "coming back never drew")
        capture("herdr2-08-back-to-omodachi", app)
    }
}
