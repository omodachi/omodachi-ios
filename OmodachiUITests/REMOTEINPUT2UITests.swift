import XCTest

/// REMOTE-INPUT-2: the compose bar, over the in-memory harness
/// (`--remote-compose-harness`): the real session controller and the real
/// bar, with a stand-in computer that writes what reached it on the picture.
@MainActor
final class REMOTEINPUT2UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 240
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--remote-compose-harness"]
            app.launch()
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var log: String { element("harness-host-log").label }

    private func waitFor(_ what: String, _ seconds: TimeInterval = 8, _ predicate: () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("\(what) — log: \(log)", file: file, line: line)
    }

    func testTheBarTypesTheDraftOnceAndAnEmptyFieldPassesKeysThrough() {
        let bar = element("remote-compose-bar")
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "the keyboard is the compose bar")
        let field = element("remote-compose-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        waitFor("the field never took the keyboard") { field.value(forKey: "hasKeyboardFocus") as? Bool == true }
        // The bar sits above the keyboard, never under it.
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(bar.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        }

        // REMOTE-INPUT-2b. Insert only: the words go in, no Return.
        let insert = element("remote-compose-insert")
        XCTAssertFalse(insert.isEnabled, "nothing to insert in an empty field")
        field.typeText("Hello, World!")
        XCTAssertEqual(log, "typed= keys=", "nothing reaches the computer before it is asked")
        XCTAssertTrue(insert.isEnabled)
        insert.tap()
        waitFor("the draft was never inserted") { log.hasPrefix("typed=Hello, World! ") }
        XCTAssertTrue(element("remote-compose-state").waitForExistence(timeout: 3), "it says it was sent")
        XCTAssertEqual((field.value as? String) ?? "", "", "the field clears")

        // An empty field: Backspace and Return are the computer's keys.
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText("\n")
        waitFor("the empty field did not pass the keys through") { log.hasSuffix("keys=2A,28") }

        // The keyboard's return key with words: the words and Return, one send.
        field.typeText("ls")
        field.typeText("\n")
        waitFor("Return did not send the words and Return") { log.contains("|ls⏎ ") }
        XCTAssertTrue(log.hasSuffix("keys=2A,28"), "the Return went with the text, not as a key")

        // The keys row is always keys.
        element("remote-key-esc").tap()
        element("remote-key-ctrl-c").tap()
        waitFor("the keys row did not reach the computer") { log.hasSuffix("keys=2A,28,29,06+1") }
    }

    func testKeysModeIsThePerKeyKeyboardAndTheSwitchComesBack() {
        XCTAssertTrue(element("remote-compose-field").waitForExistence(timeout: 15))
        element("remote-compose-keys-mode").tap()
        waitFor("the field did not step aside") { !element("remote-compose-field").exists }
        waitFor("the per-key keyboard did not come up") { log.contains("perkey-up") }
        XCTAssertTrue(element("remote-key-esc").exists, "the keys row stays for vim")
        XCTAssertFalse(element("remote-compose-insert").exists, "insert only belongs to the field")
        element("remote-compose-keys-mode").tap()
        XCTAssertTrue(element("remote-compose-field").waitForExistence(timeout: 5))
        waitFor("the per-key keyboard did not go") { log.contains("perkey-down") }
    }
}
