import XCTest
@testable import Omodachi

/// VERIFY-1: what the real host (real codex, a 180-column pane) showed that
/// the lab could not.
@MainActor
final class VERIFY1Tests: XCTestCase {
    private func fixtures() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["OMODACHI_CORE_FIXTURES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
    }

    /// A reply sent while codex's approval dialog has the keyboard: core types
    /// nothing, and the line under the composer says to use the keys.
    func testABlockedAgentGetsNothingTypedAndTheReasonSaysUseTheKeys() throws {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("herdr-text-agent-blocked.json"))
        let reply = try JSONDecoder().decode(HerdrTextResultDTO.self, from: data)
        XCTAssertFalse(reply.delivered)
        XCTAssertFalse(reply.submitted)
        XCTAssertEqual(reply.reason, "herdr_agent_blocked")
        XCTAssertEqual(ReasonText.knownCodes["herdr_agent_blocked"], .herdr)
        // `agent_blocked` stays the Agent lifecycle's own code.
        XCTAssertEqual(ReasonText.knownCodes["agent_blocked"], .agent)
        let sentence = ReasonText.message("herdr_agent_blocked", domain: .herdr)
        XCTAssertEqual(sentence, Strings.reasonHerdrAgentBlocked)
        XCTAssertFalse(sentence.contains("agent_blocked"))
    }

    /// The phone's second keys row: every key the row carries fits in an
    /// iPhone 17's panel width at the narrowest cap, so none sits past the edge.
    func testThePhonesSecondRowFitsEveryShippedKeyAtTheNarrowestCap() {
        let second = HerdrKeyCap.row.dropFirst(HerdrKeyCap.firstRow).count
        let presets = 4 // ^U ^R ^L ^Z, the shipped presets not already on the row
        let narrowest: CGFloat = 24
        let spacing = OmodachiTheme.space("xs")
        let width = CGFloat(second + presets) * narrowest + CGFloat(second + presets + 2) * spacing
            + 2 * spacing + NativeBarMetrics.edgeRule
        XCTAssertLessThan(width, 356, "the iPhone 17 Herdr panel is 356 points wide")
    }
}
