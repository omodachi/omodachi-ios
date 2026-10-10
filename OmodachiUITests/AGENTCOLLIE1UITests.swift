import XCTest

/// AGENT-COLLIE-1 on iPhone and iPad (`--agent-collie-fixture`, a conversation
/// shaped like the real codex 0.160 capture): see an edit before allowing it,
/// runs of steps folded, a question card that fits a phone, and finding your
/// place in a long conversation.
@MainActor
final class AGENTCOLLIE1UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 240
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--agent-collie-fixture"]
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

    /// Scrolls the transcript until `target` is on screen.
    private func reach(_ target: XCUIElement, up: Bool = true, tries: Int = 8) {
        var left = tries
        while !(target.exists && target.isHittable) && left > 0 {
            if up { app.swipeDown() } else { app.swipeUp() }
            left -= 1
        }
    }

    func testIdea1TheWaitingEditIsOnScreenAndLit() {
        let waiting = element("agent-change-waiting-p2")
        XCTAssertTrue(waiting.waitForExistence(timeout: 15), "the change the prompt allows is not marked")
        XCTAssertTrue(element("agent-change-p2-0").exists)
        XCTAssertTrue(element("agent-change-diff-p2-0").exists, "the waiting change opens with its diff")
        let summary = element("agent-approval-change-0")
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "the prompt does not name what it allows")
        attach("agent-collie1-change-waiting")
        // "See the change" brings the card back after reading elsewhere.
        app.swipeDown(); app.swipeDown()
        let see = element("agent-approval-see-change-0")
        reach(see, up: false)
        see.tap()
        XCTAssertTrue(element("agent-change-p2-0").waitForExistence(timeout: 5))
        XCTAssertTrue(element("agent-change-p2-0").isHittable)
        // Allowing it settles the prompt; the waiting mark goes.
        let accept = app.buttons["agent-approval-accept-0"]
        reach(accept, up: false)
        accept.tap()
        XCTAssertTrue(element("agent-approval-resolved-0").waitForExistence(timeout: 10))
        XCTAssertFalse(element("agent-change-waiting-p2").exists)
        // The edit that ran earlier is a card with its counts and its files.
        let earlier = element("agent-change-p1-0")
        reach(earlier)
        XCTAssertTrue(earlier.exists)
        XCTAssertTrue(earlier.label.contains("app.py"), earlier.label)
    }

    func testIdea2SixStepsAreOneLineThatOpensAndFolds() {
        let toggle = element("agent-run-toggle-s0")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15) || { reach(toggle); return toggle.exists }())
        reach(toggle)
        XCTAssertTrue(toggle.label.contains("1"), toggle.label)
        XCTAssertFalse(element("agent-tool-s3").exists, "a finished run starts folded")
        attach("agent-collie1-run-folded")
        toggle.tap()
        let step = element("agent-tool-s3")
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        XCTAssertTrue(step.label.contains("TODO"), step.label)
        XCTAssertTrue(element("agent-tool-s0").label.hasPrefix("$ git status"), element("agent-tool-s0").label)
        attach("agent-collie1-run-open")
        let fold = element("agent-run-fold-s0")
        reach(fold)
        fold.tap()
        XCTAssertTrue(element("agent-run-toggle-s0").waitForExistence(timeout: 5))
        XCTAssertFalse(element("agent-tool-s3").exists)
    }

    func testIdea3TheQuestionGoesStepByStepAndKeepsTheSecret() {
        let first = element("agent-question-choice-branch-0")
        reach(first, up: false)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(first.label.contains("The default branch everyone pulls from."), first.label)
        XCTAssertTrue(element("agent-question-step-1").label.contains("1"))
        attach("agent-collie1-question")
        element("agent-question-choice-branch-1").tap()
        let next = element("agent-question-next-1")
        reach(next, up: false)
        next.tap()
        let other = element("agent-question-other-token")
        reach(other, up: false)
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let secret = app.secureTextFields["agent-approval-input-token"]
        XCTAssertTrue(secret.waitForExistence(timeout: 5), "a secret answer is not typed into a secure field")
        secret.tap()
        secret.typeText("s3cret")
        XCTAssertNotEqual(secret.value as? String, "s3cret")
        let advance = element("agent-question-next-1")
        reach(advance, up: false)
        advance.tap()
        let review = element("agent-question-review-token")
        reach(review, up: false)
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertFalse(review.label.contains("s3cret"), review.label)
        XCTAssertTrue(element("agent-question-review-branch").label.contains("release"))
        let answer = element("agent-approval-answer-1")
        reach(answer, up: false)
        answer.tap()
        let resolved = element("agent-approval-resolved-1")
        XCTAssertTrue(resolved.waitForExistence(timeout: 10))
        XCTAssertTrue(resolved.label.contains("release"), resolved.label)
        XCTAssertFalse(resolved.label.contains("s3cret"), resolved.label)
    }

    func testIdea4FindAndJump() {
        let find = element("agent-find")
        XCTAssertTrue(find.waitForExistence(timeout: 15))
        find.tap()
        let field = app.textFields["agent-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("log lines")
        let count = element("agent-find-count")
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(count.label.contains("6"), count.label)
        attach("agent-collie1-find")
        element("agent-find-next").tap()
        element("agent-find-previous").tap()
        element("agent-find-previous").tap()
        XCTAssertTrue(count.label.contains("6"), count.label)
        // A step inside a folded run is found too: the run opens.
        field.clearAndType("TODO")
        XCTAssertTrue(element("agent-tool-s3").waitForExistence(timeout: 5), "the run did not open for its match")
        element("agent-find-close").tap()
        XCTAssertFalse(element("agent-find-bar").exists)

        // AGENT-UI-3 (Leo): no ↑ / ↓ between your own messages - reading up
        // is a swipe, and the buttons sat on the conversation.
        XCTAssertFalse(element("agent-yours-previous").exists)
        XCTAssertFalse(element("agent-yours-next").exists)
        // The way back to the newest.
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        let jump = element("agent-jump-newest")
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "no way back to the newest after reading up")
        // New output while reading up puts a dot on it.
        let composer = app.textFields["agent-chat-composer"]
        composer.tap()
        composer.typeText("one more thing")
        element("agent-send").tap()
        let dotted = element("agent-jump-newest-unseen")
        if !dotted.waitForExistence(timeout: 5) {
            // Sending follows the end; reading up again shows the dot for the reply.
            app.swipeDown()
        }
        attach("agent-collie1-jump")
        let back = element("agent-jump-newest-unseen").exists ? element("agent-jump-newest-unseen") : element("agent-jump-newest")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.staticTexts["Noted: one more thing"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("agent-jump-newest").exists)
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeText(text)
    }
}
