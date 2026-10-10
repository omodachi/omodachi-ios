import XCTest

/// HERDR-8 on the real host: the iPhone's Herdr mirror on a 200-column codex
/// pane and a build log in the test session `h8-test` (never Leo's sessions),
/// for the before/after screenshots. Disabled without
/// `OMODACHI_HERDR8_ACCEPTANCE`, and refuses any simulator but the one named
/// in `OMODACHI_H8_DEVICE`. It only watches: it never types into a pane.
@MainActor final class HERDR8AcceptanceTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func application() throws -> XCUIApplication {
        #if OMODACHI_HERDR8_ACCEPTANCE
        let device = environment["SIMULATOR_UDID"] ?? environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, let allowed = environment["OMODACHI_H8_DEVICE"], device == allowed else {
            throw XCTSkip("HERDR-8 refuses any simulator but OMODACHI_H8_DEVICE (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let language = environment["OMODACHI_H8_LANG"] ?? "en"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("HERDR-8 acceptance is disabled; build with OMODACHI_HERDR8_ACCEPTANCE")
        #endif
    }

    private var tag: String { (environment["OMODACHI_H8_TAG"] ?? "run") + "-" + (environment["OMODACHI_H8_LANG"] ?? "en") }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "HERDR-8-" + tag + "-" + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "HERDR-8-" + tag + "-note"
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

    /// The codex pane, then the build log; each as it opens.
    func testBTheMirrorOnAWideCodexPaneAndABuildLog() throws {
        let app = try application()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 60))
        app.buttons["open-herdr"].tap()
        let switcher = any["herdr-session-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 30))
        if !(switcher.value as? String ?? "").contains("h8-test") {
            switcher.tap()
            let item = any["herdr-session-h8-test"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10))
            item.tap()
        }
        Thread.sleep(forTimeInterval: 4)
        for (workspace, name) in [("w1", "codex"), ("w2", "build")] {
            let chip = any["herdr-workspace-" + workspace].firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 20))
            chip.tap()
            Thread.sleep(forTimeInterval: 5)
            let window = app.windows.firstMatch.frame.height
            let mirror = [any["herdr-wrap"].firstMatch, any["herdr-fit"].firstMatch].first(where: \.exists)
            let zoom = any["herdr-zoom"].firstMatch
            note("\(name): mode \(zoom.exists ? zoom.label : "-") mirror \(Int(mirror?.frame.height ?? 0)) of \(Int(window)) pt")
            capture(name)
        }
        // After HERDR-8 only: the keys out, and the codex pane fitted.
        let keys = any["herdr-keys-toggle"].firstMatch
        if keys.exists {
            keys.tap()
            Thread.sleep(forTimeInterval: 1)
            capture("build-keys")
            keys.tap()
            any["herdr-workspace-w1"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 4)
            any["herdr-zoom"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 2)
            capture("codex-fit")
            // HERDR-12: one tap back to Wrap (no Actual size on a phone).
            any["herdr-zoom"].firstMatch.tap()
        }
    }
}
