import XCTest
@testable import Omodachi

/// HERDR-7: Herdr shows which pane runs an agent with a still marker, not the
/// animated face (Leo: "herdr 没必要为了 agent 加 agent 动画啦"). The marker is
/// the bar's idle Agent glyph — the vendor's mark only where the App already
/// ships one — in the colour of the row's own status words; a shell pane keeps
/// its square; the state is still said in words to VoiceOver.
final class HERDR7Tests: XCTestCase {
    private func pane(_ json: String) throws -> HerdrPaneDTO {
        try JSONDecoder().decode(HerdrPaneDTO.self, from: Data(json.utf8))
    }

    func testAnAgentPaneHasAMarkerInItsStatusColourAndAShellPaneHasNone() throws {
        let cases: [(String, ThemeColorRole, AgentFaceState)] = [
            ("working", .accent, .working), ("blocked", .red, .waiting), ("done", .green, .done), ("idle", .muted, .idle),
        ]
        for (status, role, state) in cases {
            let codex = try pane(#"{"id":"w1:p1","focused":false,"zoomed":false,"agent_status":"\#(status)","agent":{"kind":"codex","status":"\#(status)"}}"#)
            let marker = try XCTUnwrap(codex.marker, status)
            XCTAssertEqual(marker.role, role, "the marker is the subtitle's colour for \(status)")
            XCTAssertEqual(marker.role, codex.status.role, "one colour system per row")
            XCTAssertEqual(codex.face, state, "the row still says \(status) in words")
            XCTAssertTrue(codex.agentLabel?.contains(status) == true, "the subtitle keeps Herdr's own word")
        }
        let shell = try pane(#"{"id":"w1:p2","focused":false,"zoomed":false,"agent_status":"idle"}"#)
        XCTAssertNil(shell.marker, "a shell pane keeps the status square")
        XCTAssertNil(shell.face)
    }

    func testOnlyAMarkTheAppAlreadyShipsIsUsed() throws {
        let codex = try pane(#"{"id":"a","focused":false,"zoomed":false,"agent":{"kind":"codex","status":"idle"}}"#)
        XCTAssertEqual(codex.marker?.mark, .codex, "the bar's idle Agent slot draws codex's own mark")
        for kind in ["claude", "gemini", "opencode", "pi"] {
            let other = try pane(#"{"id":"a","focused":false,"zoomed":false,"agent":{"kind":"\#(kind)","status":"idle"}}"#)
            XCTAssertNotNil(other.marker)
            XCTAssertNil(other.marker?.mark, "\(kind): no third-party logo the App does not already carry")
        }
        XCTAssertEqual(Set(BrandMark.allCases), [.codex, .herdr], "no new vendor artwork came with HERDR-7")
        // Named by `name` only, the way an older Herdr reports it.
        let named = try pane(#"{"id":"a","focused":false,"zoomed":false,"agent":{"name":"codex","status":"working"}}"#)
        XCTAssertEqual(named.marker?.mark, .codex)
    }

    func testTheFixtureHasEveryStateAndTheShippedDemoIsUnchanged() throws {
        let raw = try XCTUnwrap(DemoHost.data("demo-herdr"))
        let shipped = try JSONDecoder().decode(DemoHost.Herdr.self, from: raw)
        let shippedPanes = shipped.layout.workspaces.flatMap(\.tabs).flatMap(\.panes)
        XCTAssertEqual(shippedPanes.count, 3)
        XCTAssertTrue(shippedPanes.allSatisfy { $0.marker == nil }, "the shipped demo has no agent")

        let fixed = try JSONDecoder().decode(DemoHost.Herdr.self, from: XCTUnwrap(HerdrAgentsFixture.apply(raw)))
        let panes = fixed.layout.workspaces.flatMap(\.tabs).flatMap(\.panes)
        XCTAssertEqual(panes.map(\.id), ["w1:p1", "w1:p2", "w1:p3", "w1:p4"])
        XCTAssertEqual(panes.map { $0.marker?.role }, [.red, nil, .accent, .green])
        XCTAssertEqual(panes.map(\.agentName), ["codex", nil, "claude", "codex"])
        XCTAssertTrue(panes[0].isWaiting)
        XCTAssertNotNil(fixed.screens["w1:p4"], "the new pane has something on its screen")
        XCTAssertEqual(fixed.sessions.sessions.first?.agents, 3)
        XCTAssertFalse(HerdrAgentsFixture.requested, "unit runs do not ask for the fixture")
    }
}
