import XCTest

/// ATTACH-1, hermetic (the demo, no host): the paperclip is beside both
/// composers, a picture pasted from the clipboard becomes a chip with its
/// marker in the words, and the × takes both away again. (The demo "uploads"
/// at once; the real upload, the host's refusals and the agents reading the
/// files are proved against the host — ATTACH-1 report §5.)
@MainActor
final class ATTACH1UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func launch(_ app: XCUIApplication, into entry: String, composer: String) {
        // `--clipboard-picture`: the app puts a picture on its clipboard at
        // launch, as a copied screenshot would (DevelopmentLaunch).
        app.launchArguments = ["--ui-testing", "--unpaired", "--clipboard-picture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        app.buttons[entry].tap()
        XCTAssertTrue(any[composer].firstMatch.waitForExistence(timeout: 10))
        if any["hint-dismiss"].firstMatch.exists { any["hint-dismiss"].firstMatch.tap() }
    }

    /// iOS asks once whether the app may read what another app copied.
    private func allowPaste() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Paste"] // non-copy: the system's own button
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    private func pasteAChip(_ app: XCUIApplication, paperclip: String, chips: String, composer: String) {
        let any = app.descendants(matching: .any)
        any[paperclip].firstMatch.tap()
        XCTAssertTrue(any[paperclip + "-photos"].firstMatch.waitForExistence(timeout: 5), "Photos is offered")
        XCTAssertTrue(any[paperclip + "-files"].firstMatch.exists, "Files is offered")
        any[paperclip + "-paste"].firstMatch.tap()
        allowPaste()
        XCTAssertTrue(any[chips + "-1"].firstMatch.waitForExistence(timeout: 10), "the picture is a chip")
        let words = any[composer].firstMatch.value as? String ?? ""
        XCTAssertTrue(words.contains("[Image #1]"), "its marker is in the words: \(words)")
        attach(app, "ATTACH-1-chip")
        any[chips + "-remove-1"].firstMatch.tap()
        XCTAssertFalse(any[chips + "-1"].firstMatch.waitForExistence(timeout: 2), "the × takes the chip away")
        let after = any[composer].firstMatch.value as? String ?? ""
        XCTAssertFalse(after.contains("[Image #1]"), "and its marker: \(after)")
    }

    func testTheAgentComposerTakesAPastedPicture() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launch(app, into: "open-agent", composer: "agent-chat-composer")
        defer { app.terminate() }
        pasteAChip(app, paperclip: "agent-attach", chips: "agent-chips", composer: "agent-chat-composer")
    }

    func testTheHerdrComposerTakesAPastedPicture() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launch(app, into: "open-herdr", composer: "herdr-composer")
        defer { app.terminate() }
        pasteAChip(app, paperclip: "herdr-attach", chips: "herdr-chips", composer: "herdr-composer")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + "-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") // non-copy
        shot.lifetime = .keepAlways
        add(shot)
    }
}
