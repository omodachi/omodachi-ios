import XCTest

/// AGENT-PLAN-1 on iPhone and iPad (`--agent-plan-fixture`, codex's Plan mode
/// shaped like the real 0.160 capture). No slash list and no `/` button (Leo):
/// `/plan` is typed and sent like any words, the host turns Plan mode on, and
/// the header's Plan chip takes it off again; `/plan <words>` asks a question,
/// then shows the proposed plan as a card whose "Implement this plan" leaves
/// Plan mode and sends the words that ask for it.
@MainActor
final class AGENTPLAN1UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 240
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--agent-plan-fixture"]
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

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func reach(_ target: XCUIElement, tries: Int = 6) {
        var left = tries
        while !(target.exists && target.isHittable) && left > 0 {
            app.swipeUp()
            left -= 1
        }
    }

    /// Typed and sent like any words.
    private func run(_ command: String) {
        let composer = app.textFields["agent-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText(command)
        let send = element("agent-send")
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    func testTypedPlanTurnsItOnAndTheChipTakesItOff() {
        XCTAssertTrue(element("agent-chat-composer").waitForExistence(timeout: 15))
        XCTAssertFalse(element("agent-plan-chip").exists, "the thread starts in the default mode")
        XCTAssertFalse(element("agent-slash").exists, "no / button")
        run("/plan")
        let chip = element("agent-plan-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "no Plan chip after /plan")
        XCTAssertEqual(chip.label, "Plan mode is on")
        // Quietly: no answer to read, and the words did not stay as a message.
        XCTAssertFalse(app.staticTexts["/plan"].exists)
        XCTAssertFalse(element("agent-thinking").exists)
        attach("agent-plan1-chip-on")
        chip.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: chip)
        waitForExpectations(timeout: 10)
        // /plan again works both ways too.
        run("/plan")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        run("/plan")
        expectation(for: gone, evaluatedWith: chip)
        waitForExpectations(timeout: 10)
    }

    func testPlanWithWordsAsksThenProposesAPlanToImplement() {
        run("/plan Read the port from the environment")
        XCTAssertTrue(element("agent-plan-chip").waitForExistence(timeout: 10))
        // codex asks first (request_user_input), as a question card.
        let choice = element("agent-question-choice-db-0")
        reach(choice)
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the Plan turn's question did not arrive")
        XCTAssertTrue(choice.label.contains("Fast and needs no server."), choice.label)
        choice.tap()
        let answer = element("agent-approval-answer-q1")
        reach(answer)
        answer.tap()
        // Then the plan, as its own card, with what to do next.
        let card = element("agent-plan-t1-plan")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no plan card")
        XCTAssertTrue(app.staticTexts["Proposed plan"].exists)
        let implement = element("agent-plan-implement")
        reach(implement)
        XCTAssertTrue(implement.waitForExistence(timeout: 5))
        // AGENT-QUEUE-1: the plan is drawn while its turn is still finishing,
        // when Implement is rightly off ("…once this turn has finished"); it
        // comes on with the turn's end. Waited for, not read at one instant.
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: implement)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["This leaves Plan mode and asks the agent to start."].waitForExistence(timeout: 5))
        attach("agent-plan1-plan-card")
        implement.tap()
        // Back in the default mode, the words sent as the person's own.
        let chip = element("agent-plan-chip")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: chip)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Implement the plan."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Done. The port now comes from the environment."].waitForExistence(timeout: 10))
        XCTAssertFalse(element("agent-plan-implement").exists, "the plan is still offered after leaving Plan mode")
        attach("agent-plan1-implemented")
    }
}
