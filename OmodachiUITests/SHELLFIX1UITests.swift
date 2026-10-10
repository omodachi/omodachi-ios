import XCTest

/// SHELL-FIX-1. Leo, iPad portrait: tap the menu's search and the keyboard
/// comes up and goes straight back down. The panel took "landscape" from its
/// own rectangle, which the keyboard had just made wider than tall, so ①
/// rebuilt itself side by side and the search field it was typing into went
/// away with the old layout. Every orientation decision reads the window.
@MainActor
final class SHELLFIX1UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    private func demo(chinese: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", chinese ? "(zh-Hans)" : "(en)",
                               "-AppleLocale", chinese ? "zh_CN" : "en_US"]
            // Pinyin: a candidate row over the keys, the taller keyboard Leo has.
            + (chinese ? ["-AppleKeyboards", "(zh_Hans-Pinyin@sw=Pinyin;hw=Automatic)"] : [])
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["demo-banner"].waitForExistence(timeout: 10))
        return app
    }

    /// Stays true for `seconds`, checked every quarter second.
    private func holds(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !condition() { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    func testPortraitMenuSearchKeepsTheKeyboardAndTheBar() {
        searchKeepsTheKeyboard(chinese: false)
    }

    func testPortraitMenuSearchKeepsTheKeyboardAndTheBarWithPinyin() {
        searchKeepsTheKeyboard(chinese: true)
    }

    private func searchKeepsTheKeyboard(chinese: Bool) {
        let app = demo(chinese: chinese)
        defer { app.terminate() }
        let gear = app.buttons["open-setup"]
        let barBefore = gear.frame
        XCTAssertLessThan(barBefore.minX, 60, "portrait: the bar is down the left")
        let search = app.textFields["panel-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard comes up")
        XCTAssertTrue(holds(3) { app.keyboards.firstMatch.exists }, "and stays up")
        XCTAssertTrue(search.exists && (search.value(forKey: "hasKeyboardFocus") as? Bool ?? false),
                      "the search field keeps the focus")
        XCTAssertEqual(gear.frame.minX, barBefore.minX, accuracy: 1, "the bar keeps its edge")
        XCTAssertLessThan(gear.frame.minX, 60)
        if !chinese {
            search.typeText("lock")
            XCTAssertEqual(search.value as? String, "lock", "typing reaches the field")
            XCTAssertTrue(app.keyboards.firstMatch.exists)
        }
    }

    /// The other text fields in portrait: each keeps its keyboard and the bar.
    func testPortraitComposersKeepTheKeyboardAndTheBar() {
        let app = demo()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let gear = app.buttons["open-setup"]
        let left = gear.frame.minX
        // Agent's composer.
        app.buttons["open-agent"].tap()
        XCTAssertTrue(any["agent-identity"].firstMatch.waitForExistence(timeout: 10))
        let agentField = any["agent-chat-composer"].firstMatch
        XCTAssertTrue(agentField.waitForExistence(timeout: 5))
        agentField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Agent: the keyboard comes up")
        XCTAssertTrue(holds(2) { app.keyboards.firstMatch.exists }, "Agent: and stays up")
        XCTAssertEqual(gear.frame.minX, left, accuracy: 1, "Agent: the bar keeps its edge")
        // Herdr's composer.
        app.buttons["open-herdr"].tap()
        let composer = any["herdr-composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        if any["hint-dismiss"].firstMatch.exists { any["hint-dismiss"].firstMatch.tap() }
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Herdr: the keyboard comes up")
        XCTAssertTrue(holds(2) { app.keyboards.firstMatch.exists }, "Herdr: and stays up")
        XCTAssertEqual(gear.frame.minX, left, accuracy: 1, "Herdr: the bar keeps its edge")
    }
}
