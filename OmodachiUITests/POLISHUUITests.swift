import XCTest

/// POLISH-U: the line a tapped link leaves behind never sits on the Agent
/// panel's header (its face, its name, New conversation, the model) — not
/// with the keyboard up, not with a phone on its side, where the panel area
/// is shortest. The fixture is LINKS-1's (`--links-fixture`); with no computer
/// behind the UI run a file link always answers with a sentence.
@MainActor
final class POLISHUUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 240
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--links-fixture"]
            app.launch()
            XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 10))
            app.buttons["open-agent"].tap()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            XCUIDevice.shared.orientation = .portrait
            app?.terminate()
        }
        try await super.tearDown()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var notice: XCUIElement { element("link-notice") }

    /// The header's parts, as the reader sees them: on screen, whole, and with
    /// nothing of the notice over them.
    private func assertTheHeaderIsClear(_ moment: String, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(notice.exists, "\(moment): the notice went away", file: file, line: line)
        let over = notice.frame
        // New conversation is a full-height square of the header row (44),
        // so the row - and the face in it - starts where it starts.
        let row = element("agent-new").frame
        let header = CGRect(x: over.minX, y: row.minY, width: over.width, height: row.height)
        XCTAssertFalse(over.intersects(header.insetBy(dx: 0, dy: 0.5)),
                       "\(moment): the notice \(over) reaches into the header row \(row)", file: file, line: line)
        // ...and it takes nothing from the panel: the composer keeps its
        // height and is not under it.
        let composer = element("agent-chat-composer").frame
        XCTAssertGreaterThan(composer.height, 10, "\(moment): the composer was squeezed to \(composer)",
                             file: file, line: line)
        XCTAssertFalse(composer.intersects(over), "\(moment): the notice covers the composer", file: file, line: line)
        for identifier in ["agent-identity", "agent-new", "agent-model-control"] {
            let part = element(identifier)
            XCTAssertTrue(part.waitForExistence(timeout: 5), "\(moment): \(identifier) is gone", file: file, line: line)
            let frame = part.frame
            XCTAssertFalse(frame.intersects(over),
                           "\(moment): the notice \(over) covers \(identifier) \(frame)", file: file, line: line)
            XCTAssertTrue(window.contains(frame), "\(moment): \(identifier) \(frame) is off the screen \(window)",
                          file: file, line: line)
            XCTAssertTrue(part.isHittable, "\(moment): \(identifier) cannot be tapped", file: file, line: line)
        }
    }

    func testTheLinkNoticeNeverCoversTheAgentHeader() {
        let link = app.links["report.md"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        assertTheHeaderIsClear("portrait")
        attach("polishu-notice-portrait")

        // The keyboard up: the panel area is half the screen.
        let composer = element("agent-chat-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        assertTheHeaderIsClear("portrait, keyboard up")
        attach("polishu-notice-keyboard")

        // On its side with the keyboard up: the shortest the panel area gets.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        if !app.keyboards.firstMatch.exists { composer.tap() }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        assertTheHeaderIsClear("landscape, keyboard up")
        attach("polishu-notice-landscape-keyboard")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + "-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") // non-copy
        shot.lifetime = .keepAlways
        add(shot)
    }
}
