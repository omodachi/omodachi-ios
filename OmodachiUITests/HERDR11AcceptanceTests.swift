import XCTest

/// HERDR-11 on the real host, in the throwaway session `h11-test` only (never
/// Leo's sessions): this build against the core omarchy has installed (from
/// before HERDR-11). It is the degradation that matters until core is
/// reinstalled: no launchers and no stars on the New workspace card, no reply
/// card over codex's pane (HERDR-12: none at all now), the full state read, and the one
/// connection clock live (the beat pings answer). Disabled without
/// `OMODACHI_HERDR11_ACCEPTANCE`, and refuses any simulator but the one named
/// in `OMODACHI_H11_DEVICE`. The session is chosen for the device on the host.
@MainActor final class HERDR11AcceptanceTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func application() throws -> XCUIApplication {
        #if OMODACHI_HERDR11_ACCEPTANCE
        let device = environment["SIMULATOR_UDID"] ?? environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, let allowed = environment["OMODACHI_H11_DEVICE"], device == allowed else {
            throw XCTSkip("HERDR-11 refuses any simulator but OMODACHI_H11_DEVICE (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 600
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let language = environment["OMODACHI_H11_LANG"] ?? "en"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("HERDR-11 acceptance is disabled; build with OMODACHI_HERDR11_ACCEPTANCE")
        #endif
    }

    private var tag: String { environment["OMODACHI_H11_LANG"] ?? "en" }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "HERDR-11-host-" + tag + "-" + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "HERDR-11-host-" + tag + "-note"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("=== " + text + " ===")
    }

    func testAPairWithTheRealHost() throws {
        let app = try application()
        let gate = app.otherElements["onboarding-gate"]
        if !gate.waitForExistence(timeout: 10) { return }
        let manual = OnboardingNavigation.manualAdd(app)
        if manual.waitForExistence(timeout: 10) {
            manual.tap()
            let field = app.textFields["connect-manual-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(environment["OMODACHI_OPERATOR_HOST"] ?? "omarchy")
            app.buttons["connect-manual-submit"].tap()
        }
        let home = app.otherElements["home-panel"]
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !home.exists { Thread.sleep(forTimeInterval: 2) }
        XCTAssertTrue(home.exists, "approve the request on the host with `omodachi-host pair approve <id> --no-remote`")
    }

    func testBThisBuildOnTheInstalledCore() throws {
        let app = try application()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 60))
        app.buttons["open-herdr"].tap()
        let switcher = any["herdr-session-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        guard (switcher.value as? String ?? "").contains("h11-test") else {
            capture("wrong-session")
            XCTFail("not on h11-test; nothing else is touched")
            return
        }
        let chip = any["herdr-workspace-w2"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        chip.tap()
        Thread.sleep(forTimeInterval: 8)
        if any["hint-dismiss"].firstMatch.exists { any["hint-dismiss"].firstMatch.tap() }
        // The clock is live: the beat pings to the installed core answer.
        XCTAssertFalse(any["connection-banner-trouble"].firstMatch.exists)
        XCTAssertFalse(any["connection-banner-lost"].firstMatch.exists)
        XCTAssertFalse(any["herdr-mirror-stale"].firstMatch.exists, "a live mirror is not dimmed")
        // HERDR-12: no reply card and no menu switch, on any core.
        XCTAssertFalse(any["herdr-reply"].firstMatch.exists)
        capture("1-codex-pane")
        any["herdr-more"].firstMatch.tap()
        XCTAssertTrue(any["herdr-menu-copyOutput"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(any["herdr-menu-reply"].firstMatch.exists)
        capture("2-more-menu")
        let item = any["herdr-menu-newWorkspace"].firstMatch
        item.tap()
        XCTAssertTrue(any["herdr-new-workspace"].firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        // Older core: no Start row, no stars - and still a card that works.
        XCTAssertFalse(any["herdr-launch-row"].firstMatch.exists)
        let stars = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '-star'"))
        XCTAssertEqual(stars.count, 0)
        note("launch row: \(any["herdr-launch-row"].firstMatch.exists), stars: \(stars.count)")
        capture("3-new-workspace-card")
        any["herdr-new-workspace-cancel"].firstMatch.tap()
    }
}
