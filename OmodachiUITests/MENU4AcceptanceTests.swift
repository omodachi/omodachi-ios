import XCTest

/// MENU-4's acceptance walk against the real host: every submenu the host
/// shows, opened, and every row the panel then draws listed with whether it
/// reads `不可用`. Then one real two-tap row is armed with a single tap and
/// photographed — and never tapped a second time.
///
/// Disabled without `OMODACHI_MENU4_ACCEPTANCE`. It refuses every simulator
/// except the one named in `OMODACHI_MENU4_DEVICE` (passed to the runner as
/// `TEST_RUNNER_OMODACHI_MENU4_DEVICE`); MENU-4 creates that simulator and
/// deletes it afterwards. The submenus to open come from the host's own
/// catalog, in the tree's order, as `TEST_RUNNER_OMODACHI_MENU4_BRANCHES`
/// (comma separated): only rows the host publishes as submenus with visible
/// children, so no tap in the walk can be an invocation.
@MainActor final class MENU4AcceptanceTests: XCTestCase {
    private func application() throws -> XCUIApplication {
        #if OMODACHI_MENU4_ACCEPTANCE
        let environment = ProcessInfo.processInfo.environment
        let device = environment["SIMULATOR_UDID"]
        guard let device, let allowed = environment["OMODACHI_MENU4_DEVICE"], device == allowed else {
            throw XCTSkip("MENU-4 runs only on the simulator it created (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 2400
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("MENU-4 acceptance is disabled; build with OMODACHI_MENU4_ACCEPTANCE")
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

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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

    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["menu-\(id)"].firstMatch
    }

    private func reveal(_ element: XCUIElement, in scroller: XCUIElement) -> Bool {
        for _ in 0..<60 {
            if element.exists && element.isHittable { return true }
            scroller.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    private func top(_ app: XCUIApplication, _ scroller: XCUIElement) {
        for _ in 0..<120 {
            if row(app, "apps").exists && row(app, "apps").isHittable { return }
            scroller.swipeDown(velocity: .fast)
        }
    }

    /// Every submenu open, every row listed with its trailing state.
    func testBEveryRowTheHostShows() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60),
                      "MENU-4 needs a paired host; run testAPairWithTheRealHost first")
        XCTAssertTrue(appears(row(app, "system"), seconds: 60), "the host's catalog never reached the panel")
        let branches = (ProcessInfo.processInfo.environment["OMODACHI_MENU4_BRANCHES"] ?? "")
            .split(separator: ",").map(String.init)
        XCTAssertFalse(branches.isEmpty, "pass the host's submenus in TEST_RUNNER_OMODACHI_MENU4_BRANCHES")
        let scroller = app.scrollViews.firstMatch
        var opened: [String] = []
        for id in branches {
            let branch = row(app, id)
            guard reveal(branch, in: scroller) else {
                XCTFail("\(id) never came on screen")
                continue
            }
            branch.tap()
            opened.append(id)
            Thread.sleep(forTimeInterval: 0.3)
        }
        attach("menu4-opened", text: opened.joined(separator: "\n"))
        top(app, scroller)
        var seen: [String: String] = [:]
        var order: [String] = []
        var still = 0
        while still < 4 {
            let before = seen.count
            let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'menu-'"))
            let marks = app.staticTexts.matching(NSPredicate(format: "label == '不可用'"))
            var greyLines: [CGFloat] = []
            for mark in 0..<marks.count { greyLines.append(marks.element(boundBy: mark).frame.midY) }
            for index in 0..<rows.count {
                let element = rows.element(boundBy: index)
                let identifier = element.identifier
                // Only the tree's rows: `menu-empty`, `menu-half`, `menu-confirm-…` are not rows.
                guard !identifier.hasPrefix("menu-confirm-"), identifier != "menu-empty",
                      identifier != "menu-half" else { continue }
                let id = String(identifier.dropFirst(5))
                guard seen[id] == nil, element.frame.height > 20 else { continue }
                let greyed = greyLines.contains { abs($0 - element.frame.midY) < 4 }
                seen[id] = greyed ? "不可用" : "ok"
                order.append("\(id)\t\(element.label)\t\(seen[id]!)")
            }
            still = seen.count == before ? still + 1 : 0
            scroller.swipeUp(velocity: .slow)
        }
        let grey = order.filter { $0.hasSuffix("\t不可用") }
        attach("menu4-rows", text: order.joined(separator: "\n"))
        attach("menu4-grey", text: grey.joined(separator: "\n"))
        attach("menu4-summary", text: "rows \(order.count)\ngrey \(grey.count)")
    }

    /// One real two-tap row, armed by a single tap and photographed. The row is
    /// `remove.webapp`, whose first effect on the host would only be a picker,
    /// and it is tapped exactly once: the arm lapses on its own.
    func testCOneRealRowAsksBeforeItRuns() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60))
        XCTAssertTrue(appears(row(app, "remove"), seconds: 60))
        let scroller = app.scrollViews.firstMatch
        let remove = row(app, "remove")
        XCTAssertTrue(reveal(remove, in: scroller))
        remove.tap()
        let webapp = row(app, "remove.webapp")
        guard reveal(webapp, in: scroller) else { XCTFail("remove.webapp never came on screen"); return }
        webapp.tap()
        let armed = app.descendants(matching: .any)["menu-confirm-remove.webapp"].firstMatch
        XCTAssertTrue(armed.waitForExistence(timeout: 1.5), "the first tap on a confirm row arms it")
        capture("menu4-real-armed")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "panel-toast").firstMatch.exists,
                       "the first tap sends nothing")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: armed)
        wait(for: [gone], timeout: 4)
        attach("menu4-real-armed-lapsed", text: "armed, never tapped again, lapsed on its own")
    }
}
