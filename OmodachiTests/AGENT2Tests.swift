import XCTest
@testable import Omodachi

/// AGENT-2 items 1, 4 and 5, at the level they are decided: which mark a
/// provider gets, and what the chat model does between the tap and the reply.
final class AGENT2Tests: XCTestCase {

    // MARK: - Items 1 and 5 · the marks

    /// The mark follows what core reports, and an unknown provider gets no
    /// mark rather than somebody else's.
    func testTheProviderMarkFollowsWhatTheHostReports() {
        XCTAssertEqual(BrandMark.provider("codex"), .codex)
        XCTAssertEqual(BrandMark.provider("Codex"), .codex, "core's casing is not a contract")
        XCTAssertEqual(BrandMark.provider("openai"), .codex)
        XCTAssertNil(BrandMark.provider("claude"), "a provider we have no mark for keeps the glyph")
        XCTAssertNil(BrandMark.provider(nil))
        XCTAssertNil(BrandMark.provider(""))
    }

    /// Both marks are in the bundle. A missing asset would draw an empty box
    /// in a bar slot, which is precisely the failure UX-1 item 8 existed to
    /// stop, so it is asserted rather than eyeballed.
    func testBothMarksAreInTheBundle() {
        for mark in BrandMark.allCases {
            XCTAssertNotNil(UIImage(named: mark.rawValue, in: .main, compatibleWith: nil),
                            "\(mark.rawValue) is missing from Brand.xcassets")
        }
    }

    /// A mark that resolves but rasterises to nothing is the tofu box UX-1
    /// item 8 was about, one level down: `actool` accepts an SVG it cannot draw
    /// and hands back an empty image. So each mark is rendered at the bar's own
    /// 22 points, as a template, and asked how much of it is ink.
    func testBothMarksRasteriseToVisibleInkAtTheBarSize() throws {
        for mark in BrandMark.allCases {
            let image = try XCTUnwrap(UIImage(named: mark.rawValue, in: .main, compatibleWith: nil))
                .withRenderingMode(.alwaysTemplate)
            let side: CGFloat = 22
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 2
            let drawn = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
                .image { context in
                    UIColor.white.setFill()
                    image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
                    _ = context
                }
            let cg = try XCTUnwrap(drawn.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            let bitmap = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
                                                 bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                                 space: space,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let opaque = stride(from: 3, to: pixels.count, by: 4).reduce(into: 0) { total, index in
                if pixels[index] > 32 { total += 1 }
            }
            let coverage = Double(opaque) / Double(cg.width * cg.height)
            XCTAssertGreaterThan(coverage, 0.05, "\(mark.rawValue) rasterises to nothing at 22 points")
            XCTAssertLessThan(coverage, 0.95, "\(mark.rawValue) rasterises to a solid block")
            // The picture is kept so a human can check it is the vendor's mark
            // and not merely *a* shape with the right amount of ink in it.
            let proof = XCTAttachment(image: UIGraphicsImageRenderer(size: CGSize(width: 220, height: 220),
                                                                     format: format).image { context in
                UIColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 220, height: 220))
                UIColor.white.setFill()
                image.draw(in: CGRect(x: 10, y: 10, width: 200, height: 200))
            })
            proof.name = "\(mark.rawValue)-rendered"
            proof.lifetime = .keepAlways
            add(proof)
        }
    }

    /// ③ carries the provider's mark and ④ always carries Herdr's; everything
    /// else on the bar is ours and keeps the study's glyph.
    func testOnlyTheTwoVendorEntriesCarryAMark() {
        func entry(_ id: PanelID) -> PanelEntry {
            PanelEntry(id: id, order: 0, enabled: true, canDisable: true)
        }
        XCTAssertEqual(entry(.agent).brand(provider: "codex"), .codex)
        XCTAssertNil(entry(.agent).brand(provider: "something-else"))
        XCTAssertEqual(entry(.herdr).brand(provider: "codex"), .herdr)
        for id: PanelID in [.menu, .remote, .ssh, .settings, .notifications] {
            XCTAssertNil(entry(id).brand(provider: "codex"), "\(id) is ours")
        }
    }

    // MARK: - Item 4 · the send is not silent

    /// "发送也很慢" was "发送很安静": the words went nowhere visible until the
    /// round trip finished. `beginSend` now puts them in the model and empties
    /// the composer, both before anything is on the wire.
    func testTheMessageIsOnScreenBeforeTheRequestLeaves() {
        var model = ready()
        model.draft = "ping"
        XCTAssertEqual(model.beginSend(), "ping")
        XCTAssertEqual(model.draft, "", "the composer empties on the tap")
        XCTAssertEqual(model.localEcho?.text, "ping")
        XCTAssertEqual(model.localEcho?.role, .user)
        XCTAssertTrue(model.awaitingFirstToken, "and something says the turn is in flight")
    }

    /// The optimistic copy is replaced by the provider's own row, never added
    /// to it: one sentence, once.
    func testTheEchoIsReplacedByTheProvidersOwnRowAndNeverDuplicated() {
        var model = ready()
        model.draft = "ping"
        _ = model.beginSend()
        XCTAssertTrue(model.apply(.turnStarted("t1"), identity: Self.identity, sequence: 1))
        XCTAssertNotNil(model.localEcho, "a started turn is not an echoed message")
        XCTAssertTrue(model.apply(.message(.init(id: "u1", turnID: "t1", role: .user, text: "ping")),
                                  identity: Self.identity, sequence: 2))
        XCTAssertNil(model.localEcho, "the real row arrived, so the local copy goes")
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertTrue(model.awaitingFirstToken, "the user's own words are not the first token")
    }

    /// The row that says "thinking" is only up while nothing has come back,
    /// and the first token takes it away — not the end of the turn (D-15).
    func testTheThinkingRowEndsAtTheFirstTokenNotAtTheEndOfTheTurn() {
        var model = ready()
        model.draft = "ping"
        _ = model.beginSend()
        _ = model.apply(.turnStarted("t1"), identity: Self.identity, sequence: 1)
        _ = model.apply(.message(.init(id: "u1", turnID: "t1", role: .user, text: "ping")),
                        identity: Self.identity, sequence: 2)
        XCTAssertTrue(model.awaitingFirstToken)
        _ = model.apply(.message(.init(id: "a1", turnID: "t1", role: .assistant, text: "p")),
                        identity: Self.identity, sequence: 3)
        XCTAssertFalse(model.awaitingFirstToken, "one character is a first token")
        _ = model.apply(.message(.init(id: "a1", turnID: "t1", role: .assistant, text: "pong")),
                        identity: Self.identity, sequence: 4)
        XCTAssertEqual(model.rows.count, 2, "streaming updates the row in place")
    }

    /// An unconfirmed send gives the words back rather than leaving a message
    /// on screen that may never have been said.
    func testAFailedSendPutsTheWordsBackInTheComposer() {
        var model = ready()
        model.draft = "ping"
        _ = model.beginSend()
        model.sendFailed(text: "ping", message: "unconfirmed")
        XCTAssertNil(model.localEcho)
        XCTAssertEqual(model.draft, "ping")
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.awaitingFirstToken)
    }

    /// A snapshot is the host's whole answer, so nothing this client was
    /// holding survives it.
    func testASnapshotClearsTheEcho() {
        var model = ready()
        model.draft = "ping"
        _ = model.beginSend()
        XCTAssertTrue(model.restore(identity: Self.identity, rows: [], activeTurn: nil, sequence: 9))
        XCTAssertNil(model.localEcho)
    }

    // MARK: - Helpers

    private static let identity = AgentChatIdentity(hostID: "h", agentID: "default",
                                                    provider: "codex", providerSessionID: "s")

    private func ready() -> AgentChatModel {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(identity: Self.identity, rows: [], activeTurn: nil, sequence: 0))
        return model
    }
}
