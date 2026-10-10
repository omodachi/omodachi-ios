import XCTest

/// LITE-1c: the bar stays icons only, and says what each icon is when asked.
/// A touch-and-hold on an entry shows its name beside it and does not open
/// the entry; a tap still does. The name is drawn, not announced (VoiceOver
/// already reads the entry's label), so what this suite asserts is the
/// behaviour around it, and the screenshot shows the bubble itself.
@MainActor
final class LITE1cBarNameUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 90
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.buttons["open-setup"].waitForExistence(timeout: 10))
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    func testHoldingAnEntryNamesItWithoutOpeningIt() {
        let settings = app.buttons["open-setup"]
        XCTAssertEqual(settings.label, "Settings", "VoiceOver keeps the entry's name")
        // The icon's own spot, read before the hold: while the name shows,
        // the element's frame takes in the name box beside it.
        let spot = settings.frame
        settings.press(forDuration: 0.8)
        capture("lite1c-bar-name-bubble")
        XCTAssertFalse(app.descendants(matching: .any)["settings-screen"].exists,
                       "releasing after a hold does not open the entry")
        XCTAssertFalse(["Bar at top", "Bar at bottom", "Bar at left", "Bar at right"].contains { app.buttons[$0].exists },
                       "a hold on an entry names it; the bar's own menu is not what opens")
        // A tap on the icon while its name is still showing opens it.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: spot.midX, dy: spot.midY)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-screen"].waitForExistence(timeout: 5),
                      "a tap still opens it")
    }

    /// The bar's own menu (which edge) is still a hold away, on the bar's
    /// empty stretch rather than on an icon.
    func testHoldingTheBarsEmptyStretchStillOffersItsEdges() {
        let bar = app.descendants(matching: .any)["panel-topbar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        let edges = ["Bar at top", "Bar at bottom", "Bar at left", "Bar at right"]
        let deadline = Date().addingTimeInterval(5)
        while !edges.contains(where: { app.buttons[$0].exists }), Date() < deadline {
            _ = app.buttons["open-setup"].waitForExistence(timeout: 0.2)
        }
        XCTAssertTrue(edges.contains { app.buttons[$0].exists }, "the edge menu opens from the bar itself")
        capture("lite1c-bar-edge-menu")
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
