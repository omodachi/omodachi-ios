import XCTest

/// AGENT-FIX-2 (Leo: "agent 在工具调用的时候，聊天记录会消失" and "通过的
/// permission 会在底部堆积"). A scripted agent (`--agent-tool-fixture`) runs
/// three commands in one turn, each behind an approval, streams their output,
/// and drops the event stream once in the middle. The history must stay on
/// screen the whole time, the panel must reconnect by itself, and each
/// answered approval must be one line under its own command - not a pile of
/// cards at the bottom.
@MainActor
final class AGENTFIX2UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 240
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--agent-tool-fixture"]
            app.launch()
            XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 10))
            app.buttons["open-agent"].tap()
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var history: XCUIElement { app.staticTexts["A Makefile and a src directory."] }

    func testHistoryStaysAndAnsweredApprovalsStayWhereTheyHappened() {
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        let composer = app.textFields["agent-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("build it")
        app.buttons["agent-send"].tap()

        for index in 0..<3 {
            // AGENT-COLLIE-1: the card is a container now, so its buttons
            // keep their own names.
            let accept = app.buttons["agent-approval-accept-\(index)"]
            XCTAssertTrue(accept.waitForExistence(timeout: 20), "approval \(index) never arrived")
            if index == 1 { attach("agent-fix2-during-tool") }
            accept.tap()
            XCTAssertTrue(element("agent-approval-resolved-\(index)").waitForExistence(timeout: 20),
                          "approval \(index) did not settle")
        }
        XCTAssertTrue(app.staticTexts["All three steps ran."].waitForExistence(timeout: 20))
        // The stream broke after the first approval; the panel came back by
        // itself, without a Reconnect tap.
        XCTAssertFalse(app.buttons["Reconnect"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Accept")).firstMatch.exists,
                       "no card still waiting")

        let reply = app.staticTexts["All three steps ran."]
        XCTAssertLessThan(element("agent-approval-resolved-2").frame.minY, reply.frame.minY,
                          "answered approvals stacked at the bottom")
        // Each answered approval is one line directly under its own command
        // (newest first, scrolling back as the lazy list needs).
        for index in stride(from: 2, through: 0, by: -1) {
            let tool = element("agent-tool-cmd\(index)")
            let answered = element("agent-approval-resolved-\(index)")
            var tries = 0
            while !(tool.exists && answered.exists && tool.isHittable) && tries < 4 {
                app.swipeDown(); tries += 1
            }
            XCTAssertTrue(tool.exists && answered.exists, "command \(index) or its approval is missing")
            XCTAssertGreaterThan(answered.frame.minY, tool.frame.minY, "approval \(index) above its command")
            XCTAssertLessThan(answered.frame.minY - tool.frame.maxY, 60, "approval \(index) is not under its command")
        }
        app.swipeDown()
        XCTAssertTrue(history.waitForExistence(timeout: 5), "the history is gone")
        attach("agent-fix2-after")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + "-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") // non-copy
        shot.lifetime = .keepAlways
        add(shot)
    }
}
