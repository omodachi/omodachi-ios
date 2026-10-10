import SwiftUI
import XCTest
@testable import Omodachi

/// SHELL-FIX-1: an orientation is the window's, never a keyboard-avoided rectangle's.
@MainActor
final class SHELLFIX1Tests: XCTestCase {
    func testAKeyboardOverAnUprightIPadIsNotLandscape() {
        // iPad Pro 13 upright with the soft keyboard up: the panel area left
        // over is 986 × ~950, wider than tall.
        let window = CGSize(width: 1032, height: 1376)
        let area = CGSize(width: 986, height: 950)
        XCTAssertFalse(PanelMeasure.isLandscape(window: window, area: area))
        XCTAssertFalse(PanelMeasure.sideBySide(landscape: PanelMeasure.isLandscape(window: window, area: area),
                                               width: area.width), "① stays one column under the keyboard")
        // iPad Pro 11 upright: 788 wide, and under Leo's keyboard about 786 tall.
        XCTAssertFalse(PanelMeasure.isLandscape(window: CGSize(width: 834, height: 1210), area: CGSize(width: 788, height: 786)))
        // A real turn is landscape whatever the keyboard leaves.
        XCTAssertTrue(PanelMeasure.isLandscape(window: CGSize(width: 1376, height: 1032), area: CGSize(width: 1330, height: 600)))
        // Outside the Shell (no window yet) the area is all there is.
        XCTAssertTrue(PanelMeasure.isLandscape(window: .zero, area: CGSize(width: 900, height: 500)))
    }

    func testTheBarEdgeIgnoresTheKeyboard() {
        // The bar is placed from the window only; nothing keyboard-shaped
        // reaches `update`, and an occlusion is refused even if it did.
        var placement = NativeBarPlacement()
        placement.update(width: 1032, height: 1376, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .left)
        placement.update(width: 1032, height: 1376 - 345, reason: .temporaryOcclusion)
        XCTAssertEqual(placement.edge, .left)
    }
}
