import UIKit
import XCTest

/// AGENT-2 against the real host. Disabled in ordinary builds; compiled only
/// with `OMODACHI_AGENT2_ACCEPTANCE`.
///
/// Two of this spec's six items cannot be answered by a fixture:
///
/// * **item 1** — the provider's mark is drawn from what core reports
///   (`state.agent.default_agent`, `identity.provider`), and the local fixture
///   reports no provider at all, so the mark that appears on a paired device is
///   only visible on a paired device;
/// * **item 4** — "发送也很慢" is a measurement. `AgentChatTrace` writes five
///   legs of one send to `os_log`, and this walks the one short message that
///   produces them.
///
/// It pairs for real (nothing is seeded, nothing is typed) and the operator
/// approves on the host while it waits.
@MainActor final class AGENT2AcceptanceTests: XCTestCase {
    /// The two simulators AGENT-2 was given. Anything else is refused rather
    /// than paired with somebody's machine.
    private let authorizedDevices = ["BD431ECD-4DC6-4EE8-8183-7B0AA3B313EA",
                                     "E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7"]

    private func application() throws -> XCUIApplication {
        #if OMODACHI_AGENT2_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("AGENT-2 refuses any simulator other than the two it was given (saw \(device ?? "no device id"))")
        }
        continueAfterFailure = false
        executionTimeAllowance = 600
        let app = XCUIApplication()
        app.launch()
        return app
        #else
        throw XCTSkip("Real-host acceptance is disabled; build explicitly with OMODACHI_AGENT2_ACCEPTANCE")
        #endif
    }

    /// The whole walk: pair, open ③, look at it, send one short message.
    func testAgentPanelOnTheRealHost() throws {
        let app = try application()
        pairIfNeeded(app)

        XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 60), "the bar never appeared")
        app.buttons["open-agent"].tap()
        let composer = app.textFields["agent-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 60), "③ never reached its composer")
        // A-63: entering is the ensure, so wait for the identity strip to name
        // the provider rather than for a button that does not exist.
        let identity = app.descendants(matching: .any)["agent-identity"].firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 60))
        _ = waitUntil(seconds: 90) { app.buttons["agent-send"].isEnabled }
        capture("agent2-host-agent-portrait", app)

        XCUIDevice.shared.orientation = .landscapeLeft
        _ = waitUntil(seconds: 10) { composer.exists && composer.frame.width > 0 }
        capture("agent2-host-agent-landscape", app)
        XCUIDevice.shared.orientation = .portrait
        _ = waitUntil(seconds: 10) { composer.exists && composer.frame.width > 0 }

        guard app.buttons["agent-send"].isEnabled else {
            capture("agent2-host-agent-not-ready", app)
            return XCTFail("the agent never became ready, so the send could not be measured")
        }
        composer.tap()
        composer.typeText("ping")
        // One short message. `AgentChatTrace` is what measures it; this only
        // has to make the tap happen and then watch the screen.
        app.buttons["agent-send"].tap()
        XCTAssertTrue(app.staticTexts["ping"].waitForExistence(timeout: 2),
                      "the words must be on screen within a frame or two of the tap")
        capture("agent2-host-send-optimistic", app)
        _ = waitUntil(seconds: 120) { !app.descendants(matching: .any)["agent-thinking"].exists }
        capture("agent2-host-send-answered", app)
    }

    // MARK: - Helpers

    /// PAIR-2's real handshake: pick the host the browser found and wait for
    /// the operator to approve it. A device that is already paired goes
    /// straight past this.
    private func pairIfNeeded(_ app: XCUIApplication) {
        if app.buttons["open-agent"].waitForExistence(timeout: 12) { return }
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 20))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no _omodachi._tcp instance was discovered")
        row.tap()
        // PAIR-2: one tap is the whole request; the card asks for nothing.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pair-waiting")
            .firstMatch.waitForExistence(timeout: 30), "the waiting card never appeared")
        capture("agent2-host-pairing", app)
        XCTAssertTrue(waitUntil(seconds: 300) { app.buttons["open-agent"].exists },
                      "the pairing claim never completed")
    }

    private func waitUntil(seconds: Int, _ condition: () -> Bool) -> Bool {
        for _ in 0..<(seconds * 2) {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
