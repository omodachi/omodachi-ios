import XCTest

/// HERDR-5, hermetic (the demo, no host): the bar sits on the keyboard with no
/// band between them, a tap on the mirror puts the composer's keyboard away,
/// and once it is away the bar is back at the bottom of the window — no empty
/// space where the keyboard was. And the More menu has lost three items.
///
/// Before the fix this failed on both form factors: an iPhone 17 kept a
/// 34-point band between the bar and the keyboard (the home-indicator inset
/// added on top of SwiftUI's keyboard area), and a tap on the mirror did not
/// put the keyboard away at all.
@MainActor
final class HERDR5UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func launchIntoHerdr(_ app: XCUIApplication) {
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-composer"].firstMatch.waitForExistence(timeout: 10))
    }

    func testTheBarFollowsTheKeyboardDownAndLeavesNoGap() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        launchIntoHerdr(app)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        let bar = any["herdr-control-bar"].firstMatch
        let window = app.windows.firstMatch.frame
        // The one-time hint takes the room the mirror needs for a tap while
        // the keyboard is up on a phone.
        if any["hint-dismiss"].firstMatch.exists { any["hint-dismiss"].firstMatch.tap() }
        let restingBottom = bar.frame.maxY
        // HERDR-9: on a phone the session row steps aside while the keyboard
        // is up, so where the mirror starts is read before it comes up.
        let switcherBottom = any["herdr-session-switcher"].firstMatch.frame.maxY
        // HERDR-10: where the mirror's left edge is (on an iPad the pane list
        // is left of it), read before the keyboard moves things.
        let mirrorLeft = [any["herdr-wrap"].firstMatch, any["herdr-fit"].firstMatch]
            .first(where: { $0.exists && $0.isHittable })?.frame.minX ?? bar.frame.minX

        any["herdr-composer"].firstMatch.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "the composer raises the soft keyboard")
        Thread.sleep(forTimeInterval: 1.0) // the keyboard's own animation
        attach(app, "HERDR-5-keyboard-up")
        // The keyboard element's frame starts under the system's suggestion
        // row (44 points on an iPhone 17, 55 on an iPad Pro 11, iOS 27),
        // which the app sits on. Before the fix the home indicator's inset was
        // added on top: 78 on the iPhone, 75 on the iPad.
        let gap = keyboard.frame.minY - bar.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, -1, "the bar is above the keyboard")
        XCTAssertLessThanOrEqual(gap, 60, "the bar sits on the keyboard (gap \(gap) pt; it was 78 / 75)")

        // A tap on the mirror is how a phone puts the composer's keyboard away.
        // The mirror's own frame is not re-read while it shrinks, so the tap
        // aims between the pane strip / grid top and the composer.
        let top = switcherBottom + 60
        let bottom = any["herdr-composer"].firstMatch.frame.minY - 20
        // HERDR-10: near the left edge, on vim's line numbers. With the grid
        // at the pane's own size (it used to be cut on a phone) the middle
        // of the mirror is vim's `http://localhost:8000/`, and a tap on a link
        // opens it (LINKS-1) instead of putting the keyboard away.
        let x = mirrorLeft + 12
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: (top + bottom) / 2)).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "a tap on the mirror hides the keyboard")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(bar.frame.maxY, restingBottom, accuracy: 1,
                       "the bar is back where it rested, not held up by the keyboard's space")
        XCTAssertGreaterThanOrEqual(bar.frame.maxY, window.maxY - 40, "only the home indicator is below the bar")
        attach(app, "HERDR-5-keyboard-hidden")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + "-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") // non-copy
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheMoreMenuNoLongerOffersTheThreeItems() {
        let app = XCUIApplication()
        launchIntoHerdr(app)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        any["herdr-more"].firstMatch.tap()
        XCTAssertTrue(any["herdr-menu-newWorkspace"].firstMatch.waitForExistence(timeout: 5))
        for kept in ["newTab", "closeTab", "close"] {
            XCTAssertTrue(any["herdr-menu-\(kept)"].firstMatch.exists, kept)
        }
        // HERDR-13: split right, split down and zoom are gone too.
        for gone in ["showOnComputer", "openInAgent", "takeKeyboard", "splitRight", "splitDown", "zoom"] {
            XCTAssertFalse(any["herdr-menu-\(gone)"].firstMatch.exists, gone)
        }
    }

    func testTheSwitcherOffersANewSession() {
        let app = XCUIApplication()
        launchIntoHerdr(app)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        any["herdr-session-switcher"].firstMatch.tap()
        XCTAssertTrue(any["herdr-new-session-open"].firstMatch.waitForExistence(timeout: 5),
                      "the last item makes a new session")
    }
}
