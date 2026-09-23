import XCTest

/// MENU-1's acceptance walk: the ten top-level rows of the real host's menu,
/// photographed one row at a time so the glyph column can be put beside the
/// host's own rendering of the same code points.
///
/// Disabled without `OMODACHI_MENU1_ACCEPTANCE`, and it refuses any simulator
/// the spec did not name — these drive a machine somebody else is using.
@MainActor final class MENU1AcceptanceTests: XCTestCase {
    /// The two MENU-1 names, and nothing else.
    private let authorizedDevices = ["BD431ECD-4DC6-4EE8-8183-7B0AA3B313EA",
                                     "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"]

    /// The host's own root menu, in the host's own order
    /// (`/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc`).
    private let topLevel = ["apps", "learn", "trigger", "style", "setup",
                            "install", "remove", "update", "about", "system", "omodachi"]

    private func application() throws -> XCUIApplication {
        #if OMODACHI_MENU1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("MENU-1 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 600
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("MENU-1 acceptance is disabled; build with OMODACHI_MENU1_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ screenshot: XCUIScreenshot) {
        let shot = XCTAttachment(screenshot: screenshot)
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

    /// One-time: the real pairing handshake, approved on the host with
    /// `omodachi-host pair approve <id>`.
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

    /// The comparison itself. Each row is photographed on its own, so the
    /// 36-wide glyph box can be cut out at a known place instead of guessed at
    /// from a full-screen shot.
    func testBTheTopLevelGlyphs() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60),
                      "MENU-1 needs a paired host; run testAPairWithTheRealHost first")
        // The menu rows arrive with the catalog, not with the launch.
        XCTAssertTrue(appears(app.descendants(matching: .any)["menu-system"], seconds: 60),
                      "the host's catalog never reached the panel")
        Thread.sleep(forTimeInterval: 2)
        capture("menu1-panel", XCUIScreen.main.screenshot())
        for identifier in topLevel {
            let row = app.descendants(matching: .any)["menu-\(identifier)"]
            XCTAssertTrue(row.exists, "the host publishes \(identifier) at the root")
            guard row.exists else { continue }
            capture("menu1-row-\(identifier)", row.screenshot())
        }
    }

    /// The other half of §2: `apps.*` rows carry an XDG icon *name*, so the
    /// glyph column used to be a stack of anonymous circles (UX-1 §6.4). It is
    /// one generic application window now.
    func testCTheAppsSubmenu() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60))
        let apps = app.descendants(matching: .any)["menu-apps"]
        XCTAssertTrue(appears(apps, seconds: 60), "the host's catalog never reached the panel")
        apps.tap()
        Thread.sleep(forTimeInterval: 3)
        capture("menu1-apps-submenu", XCUIScreen.main.screenshot())
    }
}
