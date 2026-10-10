import SwiftUI
import XCTest
@testable import Omodachi

/// LITE-1c: the bar's names, one gesture away.
final class LITE1cBarTests: XCTestCase {
    func testAReleaseAfterAHoldDoesNotActAndTheNextTapDoes() {
        var gate = BarHoldGate()
        XCTAssertTrue(gate.release(), "a tap acts")
        gate.hold()
        XCTAssertFalse(gate.release(), "a hold shows the name and does not act on release")
        XCTAssertTrue(gate.release(), "the gate does not stay shut after a hold")
        // A hold whose lift never reached the button (the finger slid off):
        // the gate opens by itself shortly after the lift.
        gate.hold()
        gate.settle()
        XCTAssertTrue(gate.release(), "a later tap or VoiceOver activation is not swallowed")
        XCTAssertEqual(BarHoldGate.settle, 0.3)
    }

    func testTheNameHangsOffTheContentSideAndNeverOffTheScreenEdge() {
        typealias A = (slot: Alignment, bubble: Alignment)
        func check(_ edge: HostBarPosition, _ segment: BarSegment, _ slot: Alignment, _ bubble: Alignment,
                   line: UInt = #line) {
            let anchor: A = BarNameBubble.anchor(edge: edge, segment: segment)
            XCTAssertEqual(anchor.slot, slot, line: line)
            XCTAssertEqual(anchor.bubble, bubble, line: line)
        }
        check(.top, .leading, .bottomLeading, .topLeading)
        check(.top, .trailing, .bottomTrailing, .topTrailing)
        check(.bottom, .centre, .top, .bottom)
        check(.left, .leading, .trailing, .leading)
        check(.left, .trailing, .trailing, .leading)
        check(.right, .centre, .leading, .trailing)
        check(.right, .trailing, .leading, .trailing)
        XCTAssertEqual(BarNameBubble.hold, 0.45)
        XCTAssertEqual(BarNameBubble.linger, 1.5)
    }
}
