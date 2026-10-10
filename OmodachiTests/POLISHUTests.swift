import XCTest
import SwiftTerm
@testable import Omodachi

/// POLISH-U: the Herdr mirror at Actual size, with no host in the room.
@MainActor
final class POLISHUTests: XCTestCase {
    private var home: HomeStore?

    private func store() -> HerdrStore {
        let defaults = UserDefaults(suiteName: "polishu-\(UUID().uuidString)")!
        let home = HomeStore(defaults: defaults, clientFactory: { _, _ in PolishUNoService() }, autoConnect: false)
        self.home = home
        return HerdrStore(home: home)
    }

    /// The mirror's terminal is exactly the pane's screen. It keeps no
    /// scrollback and never scrolls itself: the fit view does all the panning.
    /// With a scrollback, a vertical pan at Actual size scrolled SwiftTerm's
    /// own scroll view into the rows Herdr's frames had pushed off the top,
    /// and following the bottom it rested half a row into them - stale rows
    /// under codex's live redraws, which is what the host showed as garbled.
    func testTheMirrorHasNoScrollbackAndNeverScrollsItself() throws {
        let store = store()
        let terminal = store.terminal
        XCTAssertFalse(terminal.isScrollEnabled)
        XCTAssertFalse(terminal.scrollsToTop)
        XCTAssertEqual(terminal.getTerminal().options.scrollback, 0)

        let fit = store.fitView
        fit.frame = CGRect(x: 0, y: 0, width: 356, height: 400)
        fit.setPaneSize((cols: 200, rows: 49))
        fit.layoutIfNeeded()
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.getTerminal().cols, 200)
        XCTAssertEqual(terminal.getTerminal().rows, 49)

        // A frame's worth of output that scrolls the screen many times over,
        // as codex's inline history does.
        var text = ""
        for line in 1...180 { text += "line \(line) " + String(repeating: "x", count: 90) + "\r\n" }
        terminal.feed(text: text)
        terminal.layoutIfNeeded()

        // Nothing is kept above the screen: the content is the screen's 49
        // rows, shorter than the view (which has half a row of slack), so
        // there is nothing to scroll to and row 0 of the view is row 0 of
        // the pane.
        let cell = try XCTUnwrap(fit.cellSize)
        XCTAssertEqual(terminal.contentSize.height, cell.height * 49, accuracy: 0.5)
        XCTAssertLessThanOrEqual(terminal.contentSize.height, terminal.bounds.height)
        XCTAssertEqual(terminal.contentOffset, .zero)

        // Actual size, then a pan: the fit view moves, the terminal does not.
        fit.toggleZoom()
        XCTAssertEqual(fit.zoomMode, .actual)
        fit.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
        XCTAssertEqual(terminal.contentOffset, .zero)
        XCTAssertEqual(terminal.getTerminal().cols, 200, "watching never changes the grid")
        XCTAssertEqual(terminal.getTerminal().rows, 49)
        let first = try XCTUnwrap(terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true))
        XCTAssertTrue(first.hasPrefix("line 133 "), first)
        let last = try XCTUnwrap(terminal.getTerminal().getLine(row: 47)?.translateToString(trimRight: true))
        XCTAssertTrue(last.hasPrefix("line 180 "), last)
    }
}

/// A host that is never reached.
private struct PolishUNoService: CompanionServing {
    func connect() async throws { throw CompanionHostError.notConnected }
    func disconnect() async {}
    func fetchState() async throws -> HostStateDTO { throw CompanionHostError.notConnected }
    func fetchSnapshot() async throws -> CompanionSnapshot { throw CompanionHostError.notConnected }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter],
                targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse {
        throw CompanionHostError.notConnected
    }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse {
        throw CompanionHostError.notConnected
    }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
