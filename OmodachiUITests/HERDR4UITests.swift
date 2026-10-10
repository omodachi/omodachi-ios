import XCTest

/// HERDR-4, hermetic (the demo, no host): the mirror holds the demo's
/// 96-column pane at its own size and fits it; a double tap and the chip both
/// toggle fit and 1:1; the Quick dock opens with the shipped rows; Agent has
/// a `/` button.
@MainActor
final class HERDR4UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    func testFitToWidthQuickDockAndTheSlashButton() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))

        app.buttons["open-herdr"].tap()
        // HERDR-8: the demo opens on its vim pane, a full-screen program, so
        // even an iPhone (whose default is Wrap) shows the grid here.
        let fit = any["herdr-fit"].firstMatch
        XCTAssertTrue(fit.waitForExistence(timeout: 10), "the mirror sits in the fit view")
        XCTAssertEqual(fit.value as? String, "Fit to width")
        let zoom = any["herdr-zoom"].firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 5), "the chip says what the mirror shows")

        if UIDevice.current.userInterfaceIdiom == .phone {
            // HERDR-12: a phone has no 1:1; the double tap goes to Wrap and
            // the chip back to fit.
            any["herdr-terminal"].firstMatch.doubleTap()
            XCTAssertTrue(any["herdr-wrap"].firstMatch.waitForExistence(timeout: 5), "Fit → Wrap")
            zoom.tap()
            XCTAssertTrue(waitFor(fit, value: "Fit to width"), "the chip goes back to fit")
        } else {
            any["herdr-terminal"].firstMatch.doubleTap()
            XCTAssertTrue(NSPredicate(format: "value == %@", "Actual size")
                .evaluate(with: fit) || waitFor(fit, value: "Actual size"), "a double tap goes to 1:1")
            // HERDR-8: the chip goes on to Wrap, and once more back to fit.
            zoom.tap()
            XCTAssertTrue(any["herdr-wrap"].firstMatch.waitForExistence(timeout: 5), "1:1 → Wrap")
            zoom.tap()
            XCTAssertTrue(waitFor(fit, value: "Fit to width"), "the chip goes back to fit")
        }

        any["herdr-quick"].firstMatch.tap()
        XCTAssertTrue(any["herdr-quick-dock"].firstMatch.waitForExistence(timeout: 5))
        // The demo opens on its shell pane: a shell gets y / n only.
        XCTAssertTrue(any["herdr-quick-item-y"].firstMatch.exists || any["herdr-quick-item-yes"].firstMatch.exists,
                      "the dock has the shipped replies")
        any["herdr-quick"].firstMatch.tap()
        XCTAssertFalse(any["herdr-quick-dock"].firstMatch.exists)

        // AGENT-PLAN-1 (Leo): the Agent composer has no `/` button any more -
        // what is typed is sent as typed.
        app.buttons["open-agent"].tap()
        XCTAssertTrue(any["agent-chat-composer"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(any["agent-slash"].firstMatch.exists, "the composer has no / button")
    }

    private func waitFor(_ element: XCUIElement, value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
