import XCTest

/// MENU-3's acceptance walk: the Install and Remove submenus as the real host
/// now evaluates them, photographed once and listed row by row so they can be
/// put beside what the host's own menu shows.
///
/// Disabled without `OMODACHI_MENU3_ACCEPTANCE`. It refuses every simulator
/// except the one named in `OMODACHI_MENU3_DEVICE` (passed to the runner as
/// `TEST_RUNNER_OMODACHI_MENU3_DEVICE`): MENU-3 creates its own simulator and
/// deletes it afterwards, so there is no fixed udid to write down here.
@MainActor final class MENU3AcceptanceTests: XCTestCase {
    private func application() throws -> XCUIApplication {
        #if OMODACHI_MENU3_ACCEPTANCE
        let environment = ProcessInfo.processInfo.environment
        let device = environment["SIMULATOR_UDID"]
        guard let device, let allowed = environment["OMODACHI_MENU3_DEVICE"], device == allowed else {
            throw XCTSkip("MENU-3 runs only on the simulator it created (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 600
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("MENU-3 acceptance is disabled; build with OMODACHI_MENU3_ACCEPTANCE")
        #endif
    }

    private func appears(_ element: XCUIElement, seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return element.exists
    }

    private func attach(_ name: String, text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    /// The branches to open, parent first: every group under Install and
    /// Remove whose rows MENU-3 changed (the toolchains, the gaming and service
    /// rows, Remove › Security), in the host's own order.
    private let branches = ["install", "install.service", "install.gaming", "install.development",
                            "install.development.javascript", "install.development.php",
                            "install.development.elixir",
                            "remove", "remove.gaming", "remove.security", "remove.development",
                            "remove.development.javascript", "remove.development.php",
                            "remove.development.elixir"]

    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["menu-\(id)"]
    }

    /// Scroll until `element` is on screen, or give up after a bounded number of swipes.
    private func reveal(_ element: XCUIElement, in menu: XCUIElement) -> Bool {
        for _ in 0..<30 {
            if element.exists && element.isHittable { return true }
            menu.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    /// Both submenus opened, the rows the panel drew listed with whether each
    /// reads `不可用`, and one picture of each submenu.
    func testBInstallAndRemove() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60),
                      "MENU-3 needs a paired host; run testAPairWithTheRealHost first")
        XCTAssertTrue(appears(row(app, "system"), seconds: 60), "the host's catalog never reached the panel")
        let scroller = app.scrollViews.firstMatch
        for id in branches {
            let branch = row(app, id)
            if id == "remove" {
                // Install's picture first, with Development open, then on.
                for _ in 0..<40 where !(row(app, "install.development").exists && row(app, "install.development").isHittable) {
                    scroller.swipeDown(velocity: .slow)
                }
                capture("menu3-install", app)
            }
            guard reveal(branch, in: scroller) else {
                XCTFail("\(id) never came on screen")
                continue
            }
            branch.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        for _ in 0..<40 where !(row(app, "remove.development").exists && row(app, "remove.development").isHittable) {
            scroller.swipeDown(velocity: .slow)
        }
        capture("menu3-remove", app)
        // The row list: from the top, a screen at a time, every identifier the
        // panel drew under Install or Remove.
        for _ in 0..<80 { scroller.swipeDown(velocity: .fast) ; if row(app, "apps").isHittable { break } }
        var seen: [String: String] = [:]
        var order: [String] = []
        var still = 0
        while still < 3 {
            let before = seen.count
            let rows = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH 'menu-install' OR identifier BEGINSWITH 'menu-remove'"))
            for index in 0..<rows.count {
                let element = rows.element(boundBy: index)
                let id = String(element.identifier.dropFirst(5))
                guard seen[id] == nil else { continue }
                // `不可用` is the trailing text beside the row, not inside the
                // row's own accessibility element, so it is matched by line.
                let frame = element.frame
                let marks = app.staticTexts.matching(NSPredicate(format: "label == '不可用'"))
                var greyed = false
                for mark in 0..<marks.count where abs(marks.element(boundBy: mark).frame.midY - frame.midY) < 4 {
                    greyed = true
                }
                seen[id] = greyed ? "不可用" : "ok"
                order.append("\(id)\t\(element.label)\t\(seen[id]!)")
            }
            still = seen.count == before ? still + 1 : 0
            scroller.swipeUp(velocity: .slow)
        }
        attach("menu3-install-remove-rows", text: order.joined(separator: "\n"))
        // Not asserted to be zero: a row can also be grey because core has no
        // route adapter for its action, which MENU-3 does not change. The
        // report sorts the list by the host's own readiness reason.
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
