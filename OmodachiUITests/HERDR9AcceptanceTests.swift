import XCTest

/// HERDR-9 on the real host, in the throwaway session `h9-test` only (never
/// Leo's sessions): codex's approval answered from the strip, codex's input
/// line deleted with ⌫ from the empty composer, the keyboard up with the
/// input line in view, and Type's echo. The same file runs on the batch2
/// build for the "before" pictures (where there is no strip, it only looks).
/// Disabled without `OMODACHI_HERDR9_ACCEPTANCE`, and refuses any simulator
/// but the one named in `OMODACHI_H9_DEVICE`. The host side (what codex is
/// asked, the draft on its input line) is set up between the steps by the
/// person running them, in `h9-test`.
@MainActor final class HERDR9AcceptanceTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func application() throws -> XCUIApplication {
        #if OMODACHI_HERDR9_ACCEPTANCE
        let device = environment["SIMULATOR_UDID"] ?? environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, let allowed = environment["OMODACHI_H9_DEVICE"], device == allowed else {
            throw XCTSkip("HERDR-9 refuses any simulator but OMODACHI_H9_DEVICE (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let language = environment["OMODACHI_H9_LANG"] ?? "en"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("HERDR-9 acceptance is disabled; build with OMODACHI_HERDR9_ACCEPTANCE")
        #endif
    }

    private var tag: String { (environment["OMODACHI_H9_TAG"] ?? "run") + "-" + (environment["OMODACHI_H9_LANG"] ?? "en") }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "HERDR-9-" + tag + "-" + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "HERDR-9-" + tag + "-note"
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

    /// Into `h9-test`, on codex's pane (the workspace `w1`).
    @discardableResult private func openCodex(_ app: XCUIApplication) -> Bool {
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.otherElements["home-panel"].waitForExistence(timeout: 60))
        app.buttons["open-herdr"].tap()
        let switcher = any["herdr-session-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 30))
        // The session is chosen for this device on the host beforehand. The
        // switcher's menu is never touched here: a tap that lands on another
        // item could start one of Leo's sessions (it did, once).
        Thread.sleep(forTimeInterval: 3)
        guard (switcher.value as? String ?? "").contains("h9-test") else {
            capture("wrong-session")
            XCTFail("not on h9-test (\(switcher.value as? String ?? "?")); nothing else is touched")
            return false
        }
        let chip = any["herdr-workspace-w1"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        chip.tap()
        Thread.sleep(forTimeInterval: 5)
        if any["hint-dismiss"].firstMatch.exists { any["hint-dismiss"].firstMatch.tap() }
        return true
    }

    private func mirrorNote(_ app: XCUIApplication, _ what: String) {
        let any = app.descendants(matching: .any)
        let mirror = [any["herdr-wrap"].firstMatch, any["herdr-fit"].firstMatch].first(where: \.exists)
        let keyboard = app.keyboards.firstMatch
        note(String(format: "%@: mirror %.0f–%.0f, keyboard top %@, composer top %.0f", what,
                    mirror?.frame.minY ?? 0, mirror?.frame.maxY ?? 0,
                    keyboard.exists ? String(format: "%.0f", keyboard.frame.minY) : "-",
                    any["herdr-composer"].firstMatch.frame.minY))
    }

    /// codex is waiting on a command approval. Before: the screen, then the
    /// keyboard up. After: the strip, a tap on the option `OMODACHI_H9_ANSWER`
    /// names (0 = "Yes, proceed", 2 = "No, …"; never the "don't ask again"
    /// row), and the strip gone.
    func testBTheApprovalFromTheStrip() throws {
        let app = try application()
        let any = app.descendants(matching: .any)
        guard openCodex(app) else { return }
        capture("approval")
        let strip = any["herdr-choices"].firstMatch
        guard strip.waitForExistence(timeout: 10) else {
            // The build before HERDR-9: no strip. The keyboard up, as Leo saw it.
            note("no strip")
            any["herdr-composer"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 2)
            mirrorNote(app, "approval, keyboard up")
            capture("approval-keyboard")
            return
        }
        let index = Int(environment["OMODACHI_H9_ANSWER"] ?? "0") ?? 0
        XCTAssertTrue([0, 2].contains(index), "a one-time answer only")
        let choice = any["herdr-choice-\(index)"].firstMatch
        XCTAssertFalse(choice.label.lowercased().contains("don't ask again"), choice.label)
        note("strip: " + (0..<3).map { any["herdr-choice-\($0)"].firstMatch.label }.joined(separator: " | ")
             + "; tapping \(index): \(choice.label)")
        choice.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: strip)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, "codex took the answer and moved on")
        Thread.sleep(forTimeInterval: 2)
        capture("answered")
    }

    /// A draft is on codex's input line (the host typed it). The keyboard up
    /// for the empty composer keeps the line in view; ⌫ there deletes from it.
    func testCDeleteTheInputLineFromTheEmptyComposer() throws {
        let app = try application()
        let any = app.descendants(matching: .any)
        guard openCodex(app) else { return }
        let composer = any["herdr-composer"].firstMatch
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        mirrorNote(app, "draft, keyboard up")
        capture("draft-keyboard")
        let count = Int(environment["OMODACHI_H9_DELETES"] ?? "6") ?? 6
        let delete = keyboard.keys["delete"].firstMatch
        guard delete.waitForExistence(timeout: 5) else { return XCTFail("no delete key") }
        for _ in 0..<count { delete.tap() }
        Thread.sleep(forTimeInterval: 0.4)
        capture("deleted-echo")
        Thread.sleep(forTimeInterval: 2.5)
        capture("deleted")
    }

    /// Type: two letters and ⌫ straight in, their echo, and a tap on the
    /// screen ends it.
    func testDTypeEchoesAndEndsOnATap() throws {
        let app = try application()
        let any = app.descendants(matching: .any)
        guard openCodex(app) else { return }
        let type = any["herdr-type"].firstMatch
        XCTAssertTrue(type.waitForExistence(timeout: 10))
        type.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        // The terminal holds the keyboard; its keys are tapped one by one.
        keyboard.keys["o"].firstMatch.tap()
        keyboard.keys["k"].firstMatch.tap()
        keyboard.keys["delete"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.3)
        capture("type-echo")
        let mirror = [any["herdr-wrap"].firstMatch, any["herdr-fit"].firstMatch].first(where: \.exists)
        mirror?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        Thread.sleep(forTimeInterval: 1.5)
        note("Type after a tap on the screen: " + (any["herdr-type-strip"].firstMatch.exists ? "still on" : "off")
             + ", keyboard " + (app.keyboards.firstMatch.exists ? "up" : "away"))
        capture("type-ended")
    }
}
