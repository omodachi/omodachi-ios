import CoreGraphics
import XCTest
@testable import Omodachi

/// DUO-1. Where ① divides on an open foldable, as arithmetic. The Duo's own
/// numbers (Xcode 27.1's profile): inner screen 951 × 669 held wide,
/// 669 × 951 held tall; outer screen 466 × 678; the bar is 44 (+ its rule).
final class DUO1FoldTests: XCTestCase {
    func testTheFoldIsTheMiddleOfTheLongSide() {
        XCTAssertEqual(FoldLine.middle(of: CGRect(x: 0, y: 0, width: 951, height: 669)),
                       FoldLine(axis: .vertical, position: 475.5))
        XCTAssertEqual(FoldLine.middle(of: CGRect(x: 0, y: 0, width: 669, height: 951)),
                       FoldLine(axis: .horizontal, position: 475.5))
    }

    /// Held wide: the bar is on top, ① spans the width, and divides on the fold.
    func testHeldWideTheHalvesAreLeftAndRight() {
        let fold = FoldLine(axis: .vertical, position: 475.5)
        let panel = CGRect(x: 0, y: 81, width: 951, height: 588)
        XCTAssertEqual(PanelMeasure.foldSplit(fold, panel: panel, enabled: true), .columns(lead: 475.5))
    }

    /// Held tall the fold runs across, and ① keeps the width rule — one
    /// column behind the segmented control (Leo, round 2).
    func testHeldTallDoesNotSplit() {
        let fold = FoldLine(axis: .horizontal, position: 475.5)
        let panel = CGRect(x: 46, y: 36, width: 623, height: 915)
        XCTAssertNil(PanelMeasure.foldSplit(fold, panel: panel, enabled: true))
    }

    func testNoFoldOrTheSwitchOffKeepsTheWidthRule() {
        let panel = CGRect(x: 0, y: 81, width: 951, height: 588)
        XCTAssertNil(PanelMeasure.foldSplit(nil, panel: panel, enabled: true), "closed, or not a foldable")
        XCTAssertNil(PanelMeasure.foldSplit(FoldLine(axis: .vertical, position: 475.5), panel: panel, enabled: false),
                     "variant A")
    }

    /// A fold that leaves one half too small to hold its list does not split.
    func testAHalfTooSmallDoesNotSplit() {
        let fold = FoldLine(axis: .vertical, position: 475.5)
        XCTAssertNil(PanelMeasure.foldSplit(fold, panel: CGRect(x: 300, y: 0, width: 651, height: 669), enabled: true))
    }

    // MARK: - Round 2

    /// The closed Duo keeps ~84 points down its right side; the picture goes
    /// beside it. Every other device has the same inset on both sides.
    func testTheRemotePictureKeepsClearOfAOneSidedColumn() {
        let column = RemotePictureColumn.measure(left: 0, right: 84)
        XCTAssertEqual(column, RemotePictureColumn(leading: 0, trailing: 84))
        XCTAssertEqual(column.picture(CGSize(width: 466, height: 678)), CGSize(width: 382, height: 678))
        let corners = column.corners(DisplayCorners(topLeft: 59, topRight: 59, bottomLeft: 59, bottomRight: 59))
        XCTAssertEqual(corners, DisplayCorners(topLeft: 59, topRight: 0, bottomLeft: 59, bottomRight: 0))
        XCTAssertEqual(RemotePictureColumn.measure(left: 62, right: 62), .none, "iPhone held wide: the island's band, both sides")
        XCTAssertEqual(RemotePictureColumn.measure(left: 0, right: 0), .none, "upright, and every iPad")
        XCTAssertEqual(RemotePictureColumn.none.picture(CGSize(width: 402, height: 874)), CGSize(width: 402, height: 874))
    }

    /// The demo's drawing goes beside its words where stacked they would not fit.
    func testTheDemoDrawingGoesBesideTheWordsOnAShortPanel() {
        XCTAssertTrue(DemoSketchLayout.beside(area: CGSize(width: 594, height: 340), padding: 12), "closed Duo held wide")
        XCTAssertFalse(DemoSketchLayout.beside(area: CGSize(width: 338, height: 600), padding: 12), "closed Duo upright")
        XCTAssertFalse(DemoSketchLayout.beside(area: CGSize(width: 1150, height: 780), padding: 12), "an iPad held wide")
        let width = DemoSketchLayout.besideWidth(area: CGSize(width: 594, height: 340))
        XCTAssertLessThanOrEqual(width * DemoSketchLayout.aspect, 340 - DemoSketchLayout.titleRow - 48 + 0.5)
        XCTAssertLessThanOrEqual(width, 594 * 0.45 + 0.5)
    }

    /// An open foldable shows Herdr's mirror the iPad's way (Actual size in
    /// the cycle, Fit by default); closed, the device's own way.
    @MainActor func testAnOpenFoldableShowsHerdrTheIPadsWay() {
        let defaults = UserDefaults(suiteName: "duo1-\(UUID().uuidString)")!
        let home = HomeStore(defaults: defaults, autoConnect: false)
        let store = HerdrStore(home: home)
        store.setFoldOpen(true)
        XCTAssertFalse(store.mirrorPreference.phone)
        XCTAssertEqual(store.mirrorPreference.mode(agent: nil), HerdrMirrorMode.fit, "Fit by default")
        XCTAssertEqual(HerdrMirrorMode.fit.next(phone: store.mirrorPreference.phone), .actual, "Actual size in the cycle")
        store.setFoldOpen(false)
        XCTAssertEqual(store.mirrorPreference.phone, HerdrMirrorPreference.devicePhone)
    }
}
