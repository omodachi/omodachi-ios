import XCTest

/// REL2-POLISH-1, hermetic (demo and fixtures, no host).
///
/// 1. Herdr with the keyboard up: the composer and the control bar sit on the
///    keyboard's top edge in every layout - an iPhone on its side too, where
///    they used to be pushed under the keys - and the mirror is what gets
///    shorter.
/// 2. The Plan chip still comes after the model list was opened and the
///    phone turned (AGENT-UI-2 saw it missing in that order).
@MainActor
final class REL2POLISH1UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 300
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            app?.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        try await super.tearDown()
    }

    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The screen's own picture: after a rotation `app.screenshot()` is a
    /// portrait image drawn sideways (ARCH1AcceptanceTests).
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name + "-" + (phone ? "iphone" : "ipad") // non-copy
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func rotate(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        sleep(2)
    }

    // MARK: - 1. Herdr's bar above the keyboard

    private func openHerdr() {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "--herdr-choices-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30))
        any["demo-enter"].tap()
        XCTAssertTrue(any["home-panel"].waitForExistence(timeout: 10))
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["herdr-composer"].firstMatch.waitForExistence(timeout: 10))
        if any["hint-dismiss"].firstMatch.exists { any["hint-dismiss"].firstMatch.tap() }
    }

    /// The bar and (when shown) the composer are on screen, tappable and
    /// above the keyboard; the mirror ends above them.
    private func checkAboveTheKeyboard(_ moment: String, composer expectsComposer: Bool) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "\(moment): no software keyboard")
        Thread.sleep(forTimeInterval: 1.0) // the keyboard's own animation
        let top = keyboard.frame.minY
        let bar = element("herdr-control-bar")
        XCTAssertTrue(bar.exists, "\(moment): no control bar")
        XCTAssertLessThanOrEqual(bar.frame.maxY, top + 1, "\(moment): the bar \(bar.frame) is under the keyboard at \(top)")
        XCTAssertGreaterThanOrEqual(bar.frame.minY, 0, "\(moment): the bar \(bar.frame) is off the top")
        let type = element("herdr-type")
        XCTAssertTrue(type.exists && type.isHittable, "\(moment): Type cannot be tapped")
        XCTAssertLessThanOrEqual(type.frame.maxY, top + 1, "\(moment): Type is under the keyboard")
        var bottomTop = bar.frame.minY
        if expectsComposer {
            let field = element("herdr-composer")
            XCTAssertTrue(field.exists, "\(moment): no composer")
            XCTAssertLessThanOrEqual(field.frame.maxY, bar.frame.minY + 1, "\(moment): the composer is not above the bar")
            XCTAssertGreaterThanOrEqual(field.frame.minY, 0, "\(moment): the composer \(field.frame) is off the top")
            bottomTop = field.frame.minY
        }
        let any = app.descendants(matching: .any)
        let mirror = any["herdr-wrap"].firstMatch.exists ? any["herdr-wrap"].firstMatch : any["herdr-fit"].firstMatch
        if mirror.exists, mirror.frame.height > 0 {
            XCTAssertLessThanOrEqual(mirror.frame.maxY, bottomTop + 1, "\(moment): the mirror runs under the composer")
        }
        let note = XCTAttachment(string: String(format: "%@: keyboard top %.0f, bar %.0f–%.0f, composer top %.0f, mirror %.0f pt, window %.0f×%.0f",
                                                moment, top, bar.frame.minY, bar.frame.maxY, bottomTop,
                                                mirror.exists ? mirror.frame.height : -1,
                                                app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height))
        note.name = "rel2-polish1-geometry-\(moment)"
        note.lifetime = .keepAlways
        add(note)
    }

    /// iPhone: on its side and upright; iPad the same. Type goes first, as
    /// in AGENT-UI-2's run: in the demo it answers with a notice row ("the
    /// demo's panes are drawn…"), the extra row that pushed the composer and
    /// the bar under the keyboard on a phone on its side.
    func testTheBarAndComposerStayAboveTheKeyboard() {
        openHerdr()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            let tag = orientation == .portrait ? "portrait" : "landscape"
            rotate(orientation)
            let type = element("herdr-type")
            XCTAssertTrue(type.waitForExistence(timeout: 5))
            type.tap()
            let field = element("herdr-composer")
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            checkAboveTheKeyboard("\(tag)-composer", composer: true)
            capture("rel2-polish1-herdr-\(tag)-composer-keyboard")
            // The keyboard stays up through the turn to upright.
        }
    }

    // MARK: - 2. The Plan chip after the picker and a turn of the phone

    private func openAgent() {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--agent-plan-fixture", "--agent-models-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 10))
        app.buttons["open-agent"].tap()
        let hint = element("hint-dismiss")
        if hint.waitForExistence(timeout: 2) { hint.tap() }
    }

    private func type(_ words: String) {
        let composer = element("agent-chat-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText(words)
        let send = element("agent-send")
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    private func planAfterPicker(turnTo first: UIDeviceOrientation, then second: UIDeviceOrientation?, tag: String) {
        openAgent()
        let control = element("agent-model-control")
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        control.tap()
        let picker = element("agent-model-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "\(tag): the model list did not open")
        rotate(first)
        if let second { rotate(second) }
        // Closed by the control (UX-4 §4) if the turn did not close it.
        for _ in 0..<3 where picker.exists {
            control.tap()
            _ = picker.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(picker.exists, "\(tag): the list is still open")
        type("/plan")
        let chip = element("agent-plan-chip")
        let shown = chip.waitForExistence(timeout: 10)
        capture("rel2-polish1-plan-\(tag)")
        XCTAssertTrue(shown, "\(tag): no Plan chip after the list and a turn of the phone")
        XCTAssertTrue(chip.isHittable, "\(tag): the Plan chip cannot be tapped")
        chip.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: chip)
        waitForExpectations(timeout: 10)
    }

    func testThePlanChipComesAfterThePickerAndATurnToItsSide() {
        planAfterPicker(turnTo: .landscapeLeft, then: nil, tag: "landscape")
    }

    func testThePlanChipComesAfterThePickerAndATurnThereAndBack() {
        planAfterPicker(turnTo: .landscapeLeft, then: .portrait, tag: "there-and-back")
    }

    /// No list at all: the turn of the phone alone. The panel is drawn again
    /// on the turn, and the conversation must still be followed - the chip
    /// comes from the host's event, and so does a reply.
    func testThePanelStillFollowsTheConversationAfterATurn() {
        openAgent()
        XCTAssertTrue(element("agent-chat-composer").waitForExistence(timeout: 15))
        rotate(.landscapeLeft)
        rotate(.portrait)
        type("/plan")
        let chip = element("agent-plan-chip")
        let shown = chip.waitForExistence(timeout: 10)
        capture("rel2-polish1-plan-after-turn")
        XCTAssertTrue(shown, "no Plan chip after a turn of the phone")
        chip.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: chip)
        waitForExpectations(timeout: 10)
        type("Read the port from the environment")
        let reply = app.staticTexts["Done. The port now comes from the environment."]
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the reply never arrived after a turn of the phone")
    }
}
