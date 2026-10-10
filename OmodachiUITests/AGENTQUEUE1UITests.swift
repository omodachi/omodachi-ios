import XCTest

/// AGENT-QUEUE-1 on iPhone and iPad (`--agent-queue-fixture`, codex shaped like
/// the real 0.160 capture): while a turn runs, Send waits in codex's queue
/// ("1 waiting · Send now · Edit · Delete") and goes out when the turn ends;
/// codex's checklist is pinned while its plan is active; a decline can say
/// why, and the words reach the turn; a long thread opens on its newest rows
/// with "Earlier messages" above them. And after a plan, "Keep planning".
@MainActor
final class AGENTQUEUE1UITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ fixture: String) {
        continueAfterFailure = false
        executionTimeAllowance = 240
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", fixture]
        app.launch()
        XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 10))
        app.buttons["open-agent"].tap()
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

    private func type(_ words: String, then button: String) {
        let composer = app.textFields["agent-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText(words)
        let action = element(button)
        XCTAssertTrue(action.waitForExistence(timeout: 5), "no \(button)")
        action.tap()
    }

    private func gone(_ target: XCUIElement, timeout: TimeInterval = 10) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: target)
        waitForExpectations(timeout: timeout)
    }

    func testAMessageWaitsInTheQueueAndADeclineSaysWhy() {
        launch("--agent-queue-fixture")
        type("Change the port", then: "agent-send")
        // codex asks to run a command; its checklist is pinned meanwhile.
        XCTAssertTrue(element("agent-approval-r1").waitForExistence(timeout: 10), "no approval")
        let steps = element("agent-steps-toggle")
        XCTAssertTrue(steps.waitForExistence(timeout: 5), "no checklist")
        XCTAssertTrue(steps.label.contains("0 of 3"), steps.label)
        // Send while it works: the words wait in the queue.
        XCTAssertFalse(element("agent-steer").exists, "a codex with a queue is not steered from the composer")
        type("And then run the tests", then: "agent-queue-send")
        XCTAssertTrue(element("agent-queue-count").waitForExistence(timeout: 10), "no queue row")
        XCTAssertEqual(element("agent-queue-count").label, "1 waiting")
        XCTAssertFalse((app.textFields["agent-chat-composer"].value as? String ?? "").contains("And then"),
                       "the composer emptied once the host had the words")
        attach("agent-queue1-queued")
        // Edit it in place.
        element("agent-queue-edit-q-1").tap()
        let field = app.textFields["agent-queue-field-q-1"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Edit put the cursor after the words.
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        field.typeText(" on SQLite")
        element("agent-queue-save-q-1").tap()
        XCTAssertTrue(element("agent-queue-text-q-1").waitForExistence(timeout: 5))
        XCTAssertTrue(element("agent-queue-text-q-1").label.contains("And then run the tests on SQLite"),
                      element("agent-queue-text-q-1").label)
        // The checklist opens to its steps.
        steps.tap()
        XCTAssertTrue(element("agent-steps-list").waitForExistence(timeout: 5))
        steps.tap()
        // Decline, with one line of why.
        let why = element("agent-approval-why-r1")
        reach(why)
        XCTAssertTrue(why.waitForExistence(timeout: 5), "no Decline with a reason")
        why.tap()
        let reason = app.textFields["agent-approval-why-field-r1"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        reason.typeText("Not there - use a temp dir instead.")
        attach("agent-queue1-decline-reason")
        element("agent-approval-why-send-r1").tap()
        // The reason is the person's words in the turn; the reply follows.
        XCTAssertTrue(app.staticTexts["Not there - use a temp dir instead."].waitForExistence(timeout: 10))
        XCTAssertTrue(element("agent-approval-resolved-r1").waitForExistence(timeout: 10))
        // The turn ended: the queue drained, a turn of its own.
        XCTAssertTrue(app.staticTexts["Got it: And then run the tests on SQLite"].waitForExistence(timeout: 10))
        gone(element("agent-queue"))
        gone(element("agent-steps"))
        attach("agent-queue1-drained")
    }

    /// Leo (2026-10-07): "askuserquestion 的卡片 会循环". Three questions; the first
    /// answer is lost and codex asks the identical request again after a
    /// re-attach. The card comes back at "Check your answers" with what was
    /// chosen - one tap - not at question 1.
    func testTheSameThreeQuestionsComingBackDoNotStartOver() {
        launch("--agent-queue-fixture")
        type("Ask me three questions", then: "agent-send")
        for question in ["db", "port", "tests"] {
            let choice = element("agent-question-choice-\(question)-1")
            reach(choice)
            XCTAssertTrue(choice.waitForExistence(timeout: 10), "no question \(question)")
            choice.tap()
            element("agent-question-next-a1").tap()
        }
        let answer = element("agent-approval-answer-a1")
        reach(answer)
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.tap()
        // The identical request again: the review, with the answers.
        let review = element("agent-question-review-db")
        reach(review)
        XCTAssertTrue(review.waitForExistence(timeout: 10), "the card came back somewhere other than its review")
        XCTAssertTrue(review.label.contains("Postgres"), review.label)
        XCTAssertTrue(element("agent-question-review-tests").label.contains("No"))
        XCTAssertFalse(element("agent-question-choice-db-0").exists, "back at question 1")
        attach("agent-queue1-question-came-back-at-review")
        let again = element("agent-approval-answer-a1")
        reach(again)
        again.tap()
        XCTAssertTrue(app.staticTexts["Thanks - Postgres, 8080, No."].waitForExistence(timeout: 10))
    }

    func testSendNowSteersAndDeleteRemoves() {
        launch("--agent-queue-fixture")
        type("Change the port", then: "agent-send")
        XCTAssertTrue(element("agent-approval-r1").waitForExistence(timeout: 10))
        type("Keep the old port as a fallback", then: "agent-queue-send")
        XCTAssertTrue(element("agent-queue-item-q-1").waitForExistence(timeout: 10))
        type("Never mind", then: "agent-queue-send")
        XCTAssertTrue(element("agent-queue-item-q-2").waitForExistence(timeout: 10))
        XCTAssertEqual(element("agent-queue-count").label, "2 waiting")
        element("agent-queue-delete-q-2").tap()
        gone(element("agent-queue-item-q-2"))
        element("agent-queue-send-q-1").tap()
        // Into the running turn, as the person's words.
        XCTAssertTrue(app.staticTexts["Keep the old port as a fallback"].waitForExistence(timeout: 10))
        gone(element("agent-queue"))
        XCTAssertTrue(element("agent-approval-r1").exists, "the turn goes on")
        attach("agent-queue1-sent-now")
    }

    func testAHugeThreadOpensOnItsNewestRowsWithEarlierAbove() {
        launch("--agent-queue-fixture")
        XCTAssertTrue(app.staticTexts["Got it: hello 10"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["hello 1"].exists)
        let earlier = element("agent-earlier")
        XCTAssertTrue(earlier.waitForExistence(timeout: 5), "no Earlier messages")
        earlier.tap()
        XCTAssertTrue(app.staticTexts["hello 1"].waitForExistence(timeout: 10), "earlier rows did not come")
        gone(earlier)
        XCTAssertFalse(element("agent-jump-newest-unseen").exists, "earlier rows are not new output")
        // A giant message is marked as cut.
        let trimmed = element("agent-message-trimmed-a3")
        reach(trimmed)
        XCTAssertTrue(trimmed.waitForExistence(timeout: 5))
        XCTAssertTrue(trimmed.label.contains("more characters are not shown here."), trimmed.label)
        attach("agent-queue1-earlier")
    }

    func testKeepPlanningStaysInPlanAndOpensTheComposer() {
        launch("--agent-plan-fixture")
        type("/plan Read the port from the environment", then: "agent-send")
        let choice = element("agent-question-choice-db-0")
        reach(choice)
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        choice.tap()
        let answer = element("agent-approval-answer-q1")
        reach(answer)
        answer.tap()
        let keep = element("agent-plan-keep")
        reach(keep)
        XCTAssertTrue(keep.waitForExistence(timeout: 10), "no Keep planning")
        // Dismiss the keyboard the answer left up, so the tap is what brings it.
        if app.keyboards.count > 0 { app.swipeDown() }
        keep.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the composer did not take the cursor")
        XCTAssertTrue(element("agent-plan-chip").exists, "Keep planning left Plan mode")
        attach("agent-queue1-keep-planning")
    }
}
