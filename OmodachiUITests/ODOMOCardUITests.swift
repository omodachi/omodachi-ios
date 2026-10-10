import XCTest

/// ODOMO-CARD: "Hide" on the Odomo card and the switch in Settings that brings
/// it back; a link from Odomo (`from=odomo`) that says Odomo is on this device.
/// The host is the PAIR-5 offline fixture (host id `5…5`), so nothing
/// answers; what the host would say about Odomo comes from launch flags, as in
/// LITE1dOdomoUITests. The link is opened the way iOS hands one over.
@MainActor final class ODOMOCardUITests: XCTestCase {
    private var app: XCUIApplication!
    private let fixtureHost = String(repeating: "5", count: 32)

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 180
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    private func launch(pushDevices: Int = 0) {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--pair5-offline", "--odomo-url=http://127.0.0.1:18099/odomo/",
                               "--odomo-push-devices=\(pushDevices)", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["open-notifications"].waitForExistence(timeout: 30))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func notifications() -> XCUIElement {
        app.buttons["open-notifications"].tap()
        XCTAssertTrue(element("notifications-panel").waitForExistence(timeout: 10))
        return element("notifications-odomo-card")
    }

    private func settingsSwitch() -> XCUIElement {
        app.buttons["open-setup"].tap()
        XCTAssertTrue(element("settings-odomo").waitForExistence(timeout: 10))
        let toggle = element("settings-odomo-card")
        for _ in 0..<4 where !(toggle.exists && toggle.isHittable) { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the switch is under the Odomo row")
        return toggle
    }

    func testHideThenTheSwitchInSettingsBringsTheCardBack() {
        launch()
        let card = notifications()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        element("odomo-card-hide").tap()
        XCTAssertTrue(waitForAbsence(card), "Hide puts it away for this computer")
        let hidden = element("odomo-card-hidden")
        XCTAssertTrue(hidden.exists)
        XCTAssertTrue((hidden.label as String).contains("Settings › Notifications"), "and says the way back")

        let toggle = settingsSwitch()
        XCTAssertEqual(toggle.value as? String, "Off", "off after Hide")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "On")
        XCTAssertTrue(notifications().waitForExistence(timeout: 10), "the card is back")
        XCTAssertFalse(element("odomo-card-hidden").exists)

        // And off again from Settings is the same as Hide.
        let again = settingsSwitch()
        again.tap()
        XCTAssertEqual(again.value as? String, "Off")
        let card2 = notifications()
        XCTAssertTrue(waitForAbsence(card2))
    }

    func testALinkFromOdomoSaysItIsOnThisDevice() throws {
        launch()
        XCTAssertTrue(notifications().waitForExistence(timeout: 10))
        // An unknown host teaches nothing.
        app.open(try XCTUnwrap(URL(string: "omodachi://open/app?host=\(String(repeating: "a", count: 32))&from=odomo")))
        XCTAssertTrue(notifications().waitForExistence(timeout: 10), "an unknown host is ignored")
        // A link not from Odomo teaches nothing.
        app.open(try XCTUnwrap(URL(string: "omodachi://open/app?host=\(fixtureHost)")))
        XCTAssertTrue(notifications().waitForExistence(timeout: 10))

        app.open(try XCTUnwrap(URL(string: "omodachi://open/app?host=\(fixtureHost)&from=odomo")))
        let card = notifications()
        XCTAssertTrue(waitForAbsence(card), "Odomo is on this device: the card stops offering it")

        let toggle = settingsSwitch()
        let row = element("settings-odomo")
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        XCTAssertEqual(row.value as? String, "Odomo is on this \(device).")
        XCTAssertFalse(app.buttons["settings-odomo"].exists, "not a way into the Safari view's install page")
        XCTAssertEqual(toggle.value as? String, "Off")

        // Turning the switch on is for someone who took Odomo off the Home Screen.
        toggle.tap()
        XCTAssertTrue(notifications().waitForExistence(timeout: 10), "offered again")
        _ = settingsSwitch()
        XCTAssertEqual(element("settings-odomo").value as? String, "Not set up yet.")
    }

    func testWithAPhoneGettingOdomoTheSwitchDoesNotBringTheCard() {
        launch(pushDevices: 1)
        XCTAssertFalse(notifications().waitForExistence(timeout: 3))
        let toggle = settingsSwitch()
        XCTAssertEqual(toggle.value as? String, "On", "on by default")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "Off")
        toggle.tap()
        XCTAssertFalse(notifications().waitForExistence(timeout: 3), "push is already on: no card either way")
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return !element.exists
    }
}
