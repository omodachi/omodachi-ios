import XCTest
@testable import Omodachi

/// REL2-POLISH-1 §2. Turning the phone draws the Agent panel again, and the
/// new panel starts before the old one says it went away. The old panel's
/// leaving must not stop the new one's following the conversation (seen as
/// "no Plan chip after /plan" in AGENT-UI-2's run).
@MainActor final class REL2POLISH1Tests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testTheOldPanelLeavingAfterATurnDoesNotStopTheNewOne() async throws {
        let store = AgentChatStore(transport: AgentChatPlanFixtureTransport())
        // The panel on screen.
        store.panelAppeared()
        await store.open()
        XCTAssertTrue(store.isObserving)
        // The turn: the new panel appears and starts, then the old one goes.
        store.panelAppeared()
        await store.open()
        store.panelDisappeared()
        XCTAssertTrue(store.isObserving, "the panel on screen stopped following the conversation")
        // And it does follow it: `/plan` turns Plan mode on by the host's event.
        store.model.draft = "/plan"
        await store.send()
        try await waitUntil { store.model.planOn }
        // The last panel going away still leaves.
        store.panelDisappeared()
        XCTAssertFalse(store.isObserving)
    }

    func testTheOldPanelLeavingFirstStillOpensTheNewOne() async throws {
        let store = AgentChatStore(transport: AgentChatPlanFixtureTransport())
        store.panelAppeared()
        await store.open()
        store.panelDisappeared()
        XCTAssertFalse(store.isObserving)
        store.panelAppeared()
        await store.open()
        XCTAssertTrue(store.isObserving)
        store.panelDisappeared()
        XCTAssertFalse(store.isObserving)
    }
}
