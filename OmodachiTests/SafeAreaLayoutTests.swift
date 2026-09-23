import SwiftUI
import XCTest
@testable import Omodachi

/// A-32. The glass has rounded corners, a camera island and a home indicator.
/// Backgrounds may reach all of them; controls may not.
///
/// The insets here are a fake window's, not a device's: the rule binds to what
/// the window reports, so an iPhone, an iPad and a Duo panel all get the same
/// answer from the same numbers (N-11).
final class SafeAreaLayoutTests: XCTestCase {
    /// An iPhone in portrait: the island at the top, the indicator at the
    /// bottom, nothing at the sides.
    private let portrait = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
    /// The same phone rotated with the island on the leading edge.
    private let landscape = EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)

    func testPortraitBarStartsBelowTheIsland() {
        // A-02 puts the bar on the long edge, so portrait is a left bar.
        let bar = SafeAreaLayoutPolicy.barContent(edge: .left, window: portrait)
        XCTAssertEqual(bar.top, 59, "the first bar item cannot live under the island")
        XCTAssertEqual(bar.bottom, 34, "nor the last one under the home indicator (A-11)")
        XCTAssertEqual(bar.leading, 0, "a portrait window reserves no width on the left")
        XCTAssertEqual(bar.trailing, 0, "the bar's inner edge is the stage's business")
    }

    func testLandscapeBarStartsAfterTheIslandSide() {
        let bar = SafeAreaLayoutPolicy.barContent(edge: .top, window: landscape)
        XCTAssertEqual(bar.leading, 59)
        XCTAssertEqual(bar.trailing, 59)
        XCTAssertEqual(bar.top, 0, "a landscape window reserves no height at the top")
        XCTAssertEqual(bar.bottom, 0, "the bar's inner edge is the stage's business")
    }

    /// The bar is what sits at its own edge now, so the stage does not clear
    /// that inset a second time — that would push the Panel an island's width
    /// away from a bar that already dealt with it.
    func testTheStageDoesNotPadTheEdgeTheBarHolds() {
        let stage = SafeAreaLayoutPolicy.stage(edge: .left, window: portrait)
        XCTAssertEqual(stage.leading, 0)
        XCTAssertEqual(stage.top, 59, "Panel content still starts below the island")
        XCTAssertEqual(stage.bottom, 34)
        XCTAssertEqual(stage.trailing, 0)

        let top = SafeAreaLayoutPolicy.stage(edge: .top, window: landscape)
        XCTAssertEqual(top.top, 0)
        XCTAssertEqual(top.leading, 59, "a content column still clears the island in landscape")
        XCTAssertEqual(top.trailing, 59)
        XCTAssertEqual(top.bottom, 21)
    }

    func testEveryEdgeIsCoveredAndNothingIsInvented() {
        for edge in [HostBarPosition.top, .bottom, .left, .right] {
            let bar = SafeAreaLayoutPolicy.barContent(edge: edge, window: portrait)
            let stage = SafeAreaLayoutPolicy.stage(edge: edge, window: portrait)
            for value in [bar.top, bar.bottom, bar.leading, bar.trailing,
                          stage.top, stage.bottom, stage.leading, stage.trailing] {
                XCTAssertGreaterThanOrEqual(value, 0, "no negative padding for \(edge)")
            }
            // Between the two of them, every side the window reserved is
            // cleared exactly once by whoever is standing on it.
            XCTAssertEqual(max(bar.top, stage.top), portrait.top, "\(edge) leaves the island covered")
            XCTAssertEqual(max(bar.bottom, stage.bottom), portrait.bottom, "\(edge) leaves the indicator covered")
        }
    }

    /// A surface with no bar of its own — the Panel over the Remote stream —
    /// has nobody holding an edge for it, so it clears all four.
    func testASurfaceWithNoBarClearsEverySide() {
        XCTAssertEqual(SafeAreaLayoutPolicy.stage(window: landscape), landscape)
    }

    func testAWindowThatReservesNothingAddsNothing() {
        let none = EdgeInsets()
        XCTAssertEqual(SafeAreaLayoutPolicy.barContent(edge: .left, window: none), none)
        XCTAssertEqual(SafeAreaLayoutPolicy.stage(edge: .left, window: none), none)
    }

    /// One reading of the window, split into the two answers the Shell needs:
    /// what the bar's items clear, and what the panel area clears. The Shell
    /// asks both from the same insets, so they can never disagree about one
    /// window.
    func testOneReadingBecomesTwoAnswersAndOneLongEdge() {
        for edge in [HostBarPosition.left, .right, .top, .bottom] {
            let bar = SafeAreaLayoutPolicy.barContent(edge: edge, window: portrait)
            let stage = SafeAreaLayoutPolicy.stage(edge: edge, window: portrait)
            // The bar holds its own edge; the panel area does not pad it again.
            switch edge {
            case .left: XCTAssertEqual(stage.leading, 0); XCTAssertEqual(bar.leading, portrait.leading)
            case .right: XCTAssertEqual(stage.trailing, 0); XCTAssertEqual(bar.trailing, portrait.trailing)
            case .top: XCTAssertEqual(stage.top, 0); XCTAssertEqual(bar.top, portrait.top)
            case .bottom: XCTAssertEqual(stage.bottom, 0); XCTAssertEqual(bar.bottom, portrait.bottom)
            }
        }
        // A-58: the picture holds no edge for anything, so a surface with no
        // bar clears all four.
        XCTAssertEqual(SafeAreaLayoutPolicy.stage(window: portrait), portrait)
    }

    /// A-60's ladder is measured against the bar's own long edge, minus what the
    /// window reserves at its two ends — never against the raw window.
    func testTheBarsExtentIsItsLongEdgeMinusWhatTheWindowReserves() {
        let phone = CGSize(width: 393, height: 852)
        XCTAssertEqual(SafeAreaLayoutPolicy.barExtent(edge: .left, window: portrait, size: phone),
                       852 - portrait.top - portrait.bottom)
        let landscapeSize = CGSize(width: 852, height: 393)
        XCTAssertEqual(SafeAreaLayoutPolicy.barExtent(edge: .top, window: landscape, size: landscapeSize),
                       852 - landscape.leading - landscape.trailing)
    }
}
