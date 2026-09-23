import XCTest

/// PAIR-5 §4, the three cases as the app actually routes them.
///
/// Each one launches with records already in the container — that is the whole
/// point: AGENT-2 §9.4 was a device that walked past the host list because a
/// record said it was paired, and no code asked the host whether that was still
/// true. The fixtures name a host that never answers (`.invalid` resolves
/// nowhere, and a closed loopback port refuses at once), so nothing here
/// touches a real machine; the 401 the first case needs is the one thing a
/// hermetic run cannot get from a host, so it is told to the probe instead.
/// The real 401, from `omarchy`, is PAIR-5 §5's acceptance run.
@MainActor final class PAIR5Tests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 120
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
        self.app = app
        return app
    }

    /// The host refuses the credential this device is holding. Everything local
    /// goes, and the app is on the host list with one line saying why — not in
    /// a Panel whose ① reads "The host rejected companion authorization".
    func testAHostThatRefusesTheCredentialLandsOnTheHostList() {
        let app = launch(["--pair5-rejected", "--host-answers-401"])
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30),
                      "a refused credential belongs on the host list")
        XCTAssertTrue(app.descendants(matching: .any)["connect-credential-stale"].exists,
                      "and the list says why it is being looked at again")
        XCTAssertFalse(app.buttons["open-agent"].exists, "there is no bar without a host")
    }

    /// `simctl keychain reset`: the records are here, the secret is not. Same
    /// landing, and no request is made with a credential that does not exist.
    func testACredentialThatIsGoneLandsOnTheHostList() {
        let app = launch(["--pair5-credential-gone"])
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["connect-credential-stale"].exists)
        XCTAssertFalse(app.buttons["open-agent"].exists)
    }

    /// The host is off. Nothing is deleted, the Panel is where the app stays,
    /// and ① carries one row with the retry on it.
    func testAnOfflineHostKeepsThePanelAndOffersOneRetry() {
        let app = launch(["--pair5-offline"])
        XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 30),
                      "an unreachable host is not a revocation; the Panel stays")
        XCTAssertTrue(app.descendants(matching: .any)["panel-host-offline"].waitForExistence(timeout: 30),
                      "① says the host is offline")
        XCTAssertTrue(app.descendants(matching: .any)["panel-host-offline"].buttons.firstMatch.exists,
                      "and the row is where the retry is")
        XCTAssertFalse(app.otherElements["onboarding-gate"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["panel-notice"].exists,
                       "there is no second sentence to sit in")
    }
}
