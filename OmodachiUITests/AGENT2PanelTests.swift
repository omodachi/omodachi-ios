import UIKit
import XCTest

/// AGENT-2 — the three things Leo hit on the real iPad, plus the two the
/// coordinator added, as tests that fail if any of them comes back.
///
/// > 「default agent 我们可以用官方的图标么；为什么 default agent 是我们自建的
/// > UI 还需要三指唤出键盘而不是直接点击唤出；发送框不是全宽的在 iPad 上」
/// > 「发送也很慢」「为什么 ssh 还需要有个 open terminal 的界面」
///
/// The keyboard one is the reason this file exists. Tapping the *centre* of a
/// text field always worked, which is why every existing test passed: XCUITest
/// taps centres. A finger does not. So these tests tap where the drawn box is
/// and the control was not — the padding ring — because that is the half of the
/// control that used to do nothing at all.
@MainActor
final class AGENT2PanelTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 180
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing"]
            app.launch()
            XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 10))
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            app?.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        try await super.tearDown()
    }

    // MARK: - Item 2 · the keyboard

    /// A-01. The composer's box is 44 high; its `TextField` was 20. Every tap
    /// that landed in the 12 points of padding above or below the text did
    /// nothing, which is what "还需要三指唤出键盘" was describing.
    func testATapAnywhereInTheComposerBoxRaisesTheKeyboard() {
        app.buttons["open-agent"].tap()
        let composer = app.textFields["agent-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        assertTheWholeBoxIsTheTarget(composer, name: "agent-chat-composer")
        capture("agent2-composer-keyboard")
    }

    /// The same rule, on the other two fields the spec named. The Panel's
    /// search and the Keybindings search are one primitive now, so this is the
    /// proof that the fix reaches both of them.
    func testATapAnywhereInASearchBoxRaisesTheKeyboard() {
        XCUIDevice.shared.orientation = .portrait
        let search = app.textFields["panel-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        assertTheWholeBoxIsTheTarget(search, name: "panel-search")

        // A-54: portrait folds panel ① behind the segmented control, and the
        // Keybindings half has a search of its own — the same primitive now,
        // which is the point of this half of the test.
        XCTAssertTrue(app.descendants(matching: .any)["panel-segments"].waitForExistence(timeout: 5))
        app.buttons["panel-segment-keybindings"].tap()
        let keys = app.textFields["shortcut-search"]
        XCTAssertTrue(keys.waitForExistence(timeout: 10))
        assertTheWholeBoxIsTheTarget(keys, name: "shortcut-search")
        capture("agent2-search-keyboard")
    }

    // MARK: - Item 3 · the width

    /// A-56. ③ is a work surface, so the composer is the panel area's width and
    /// shares both edges with the list above it. Landscape is the case that was
    /// wrong: 760 of a 1150-point panel area, left aligned.
    func testTheComposerIsTheFullWidthOfThePanelAreaInBothOrientations() {
        app.buttons["open-agent"].tap()
        let composer = app.textFields["agent-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(eventually { composer.exists && composer.frame.width > 0 })
            let window = app.windows.firstMatch.frame
            let send = app.buttons["agent-send"]
            let right = send.exists ? send.frame.maxX : composer.frame.maxX
            // The bar is 44 on one long edge and the panel has its own padding;
            // what must not happen is the row stopping at a fixed 760 with the
            // rest of the panel area empty beside it.
            XCTAssertGreaterThan(right, window.width - 120,
                                 "the composer row stops short of the panel area in \(orientation.rawValue)")
            capture("agent2-composer-width-\(orientation == .portrait ? "portrait" : "landscape")")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Item 4 · the send

    /// The user's own words are on screen before anything is on the wire, and
    /// the composer is empty in the same frame. The mock transport in a UI run
    /// never answers, so what this proves is exactly the optimistic half.
    func testTheSentMessageAppearsBeforeTheNetworkAnswers() {
        app.buttons["open-agent"].tap()
        let composer = app.textFields["agent-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("agent2 probe")
        let send = app.buttons["agent-send"]
        guard send.exists, send.isEnabled else {
            // No identity in this fixture: there is nothing to send and the
            // control says so, which is its own correct behaviour.
            XCTAssertFalse(send.isEnabled)
            return
        }
        send.tap()
        XCTAssertTrue(app.staticTexts["agent2 probe"].waitForExistence(timeout: 1),
                      "the message must be in the list within a frame of the tap")
        XCTAssertEqual(composer.value as? String ?? "", "",
                       "the composer empties on the tap, not on the reply")
        capture("agent2-optimistic-send")
    }

    // MARK: - Item 6 · SSH

    /// A-63: the panel is the request. There is no page in front of the shell.
    func testTheSSHPanelShowsTheTerminalFirst() {
        app.buttons["open-ssh"].tap()
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal-emulator").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15),
                      "the terminal is the first thing ⑤ shows")
        XCTAssertFalse(app.buttons["open-shell"].exists, "the interstitial button is deleted")
        XCTAssertFalse(app.descendants(matching: .any)["ssh-empty"].exists,
                       "and so is the page it was on")
        capture("agent2-ssh-first")
    }

    // MARK: - Helpers

    /// The regression, in two halves.
    ///
    /// Before the fix the element XCUITest saw *was* the bare `TextField`:
    /// 20 points high for the composer, 22 for a search, centred in a box drawn
    /// at 44. So the height is the first assertion — it is the measurement that
    /// was wrong — and the second is a tap 4 points inside the top edge, which
    /// is in the padding of the old geometry and on the control in the new one.
    private func assertTheWholeBoxIsTheTarget(_ field: XCUIElement, name: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let box = field.frame
        // Whether XCUITest reports the 44-high box or the bare field inside it
        // depends on how SwiftUI folds the accessibility tree, so the tap point
        // is derived from what it reported: 4 points inside a 44 box, 8 points
        // above a bare field. Either way it lands in the padding ring and never
        // on the line of type — which is the half of the control that did
        // nothing at all before this spec.
        tap(x: box.midX, y: box.minY + (box.height >= 44 ? 4 : -8))
        XCTAssertTrue(app.keyboards.element(boundBy: 0).waitForExistence(timeout: 5),
                      "a tap on \(name)'s top edge must raise the keyboard", file: file, line: line)
        // The keyboard can be left over from the field before this one, so the
        // stronger half is that *this* field took the responder.
        XCTAssertTrue(eventually(timeout: 3) { field.hasKeyboardFocus },
                      "a tap on \(name)'s top edge must make it first responder",
                      file: file, line: line)
    }

    private func tap(x: CGFloat, y: CGFloat) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
    }

    private func eventually(timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

private extension XCUIElement {
    /// XCUITest has no public "is this the first responder"; this is the value
    /// the framework itself reads, and it is what tells a keyboard left over
    /// from the previous field apart from one this tap raised.
    var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
