import SwiftUI
import UIKit
import XCTest
@testable import Omodachi

/// MENU-2 / A-67. Our mark, drawn over the host bar's Omarchy logo.
///
/// This is what retires `com.omodachi.menu`. The clone existed so that tapping
/// the Omarchy logo from the iPad could become a recall of panel ①; it paid for
/// that by owning the `menu` kind, by rewriting the user's `shell.json` and by
/// having to track upstream. The App does it alone: core says where the logo
/// is, the App puts its own mark on top, and a view above the stream gets its
/// own taps. Nothing on the picture is intercepted, withheld or replayed.
///
/// The Omodachi plugin's own bar slot is deliberately *not* covered: it moves
/// with every other widget beside it, so a tap there goes to the host's icon
/// in both modes and that icon decides what a takeover means.
@MainActor final class BarMarksTests: XCTestCase {

    // MARK: - The geometry as it arrives from core

    private func decode(_ name: String) throws -> HostBarLayoutDTO {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures"))
        return try JSONDecoder().decode(HostBarLayoutDTO.self, from: Data(contentsOf: url))
    }

    func testTheContractFixtureDecodesIntoOneMark() throws {
        let geometry = try XCTUnwrap(decode("bar-geometry").geometry?.native)
        XCTAssertEqual(geometry.output, "OMODACHI-0123456789abcdef")
        XCTAssertEqual(geometry.position, .top)
        XCTAssertEqual(geometry.logicalSize, CGSize(width: 1280, height: 894))
        // UX-3 §3: inset by `Style.space(8)` and `Style.bar.iconSlot` long,
        // not a square at the corner. On a 30-thick bar at `base-size = 14`
        // that is 9 and 32.
        XCTAssertEqual(geometry.logo, CGRect(x: 9, y: 0, width: 32, height: 30))
        XCTAssertTrue(geometry.hasTargets)
    }

    func testABarWithNoGeometryDrawsNoMark() throws {
        XCTAssertNil(try decode("bar").geometry)
    }

    /// A rectangle the host reports off its own output is not a measurement of
    /// anything on the picture, so it is refused rather than clamped.
    func testARectangleOutsideTheOutputIsRefused() throws {
        let raw = """
        {"source":"shell.json","source_status":"available","position":"top","revision":"0123456789abcdef",
         "modules":[],"left":[],"center":[],"right":[],
         "geometry":{"output":"OMODACHI-1","logical_size":{"width":1280,"height":894},"position":"top",
          "bar":{"x":0,"y":0,"width":1280,"height":30},
          "logo":{"x":4000,"y":0,"width":30,"height":30}}}
        """
        let geometry = try XCTUnwrap(JSONDecoder()
            .decode(HostBarLayoutDTO.self, from: Data(raw.utf8)).geometry?.native)
        XCTAssertNil(geometry.logo)
        XCTAssertFalse(geometry.hasTargets, "no logo, no mark, and the corner handle instead")
    }

    // MARK: - Where the marks land on the picture

    private func geometry(logo: CGRect? = CGRect(x: 9, y: 0, width: 32, height: 30),
                          position: HostBarPosition = .top) -> HostBarGeometry {
        HostBarGeometry(output: "OMODACHI-1", logicalSize: CGSize(width: 1280, height: 894),
                        position: position, bar: CGRect(x: 0, y: 0, width: 1280, height: 30),
                        logo: logo)
    }

    /// The picture is letterboxed inside the view, so the mark has to be placed
    /// by a fraction of the *output* — never by view points or stream pixels.
    func testTheMarkFollowsThePictureThroughLetterboxingAndScale() throws {
        let hit = RemoteBarHitTest(geometry: geometry())
        let video = CGRect(x: 40, y: 12, width: 1194, height: 834)
        let logo = try XCTUnwrap(hit.rect(for: .logo, videoRect: video))
        XCTAssertEqual(logo.minX, 40 + 9.0 / 1280 * 1194, accuracy: 0.01)
        XCTAssertEqual(logo.minY, 12, accuracy: 0.01)
        XCTAssertEqual(logo.width, 32.0 / 1280 * 1194, accuracy: 0.01)
        XCTAssertEqual(logo.height, 30.0 / 894 * 834, accuracy: 0.01)
        let small = CGRect(x: 0, y: 0, width: 597, height: 417)
        XCTAssertEqual(hit.rect(for: .logo, videoRect: small)?.width ?? -1,
                       32.0 / 1280 * 597, accuracy: 0.01)
        XCTAssertEqual(hit.fractions(for: .logo)?.minX ?? -1, 9.0 / 1280, accuracy: 0.0001)
    }

    /// The mark and the picture under it have to compute the same rectangle, or
    /// the mark sits beside the icon it is covering. Both backends lay the
    /// stream out aspect-fit and centred.
    func testTheMarkUsesThePicturesOwnAspectFit() {
        let pixels = CGSize(width: 1280, height: 894)
        let wide = RemoteBarHitTest.aspectFit(pixels, in: CGSize(width: 1366, height: 894))
        XCTAssertEqual(wide.width, 1280, accuracy: 0.01)
        XCTAssertEqual(wide.minX, 43, accuracy: 0.01, "centred, so the letterbox is split")
        let tall = RemoteBarHitTest.aspectFit(pixels, in: CGSize(width: 640, height: 894))
        XCTAssertEqual(tall.width, 640, accuracy: 0.01)
        XCTAssertEqual(tall.height, 894 * (640.0 / 1280), accuracy: 0.01)
        XCTAssertEqual(RemoteBarHitTest.aspectFit(.zero, in: CGSize(width: 10, height: 10)), .zero)
        XCTAssertEqual(RemoteBarHitTest.aspectFit(pixels, in: .zero), .zero)
    }

    func testEachBarPositionPutsTheMarkWhereTheIconIsDrawn() {
        // UX-3 §3. Each one is `Style.space(8)` along the bar from its leading
        // end and `Style.bar.iconSlot` long, at `base-size = 14`: 9 and 32.
        let cases: [(HostBarPosition, CGRect)] = [
            (.top, CGRect(x: 9, y: 0, width: 32, height: 30)),
            (.bottom, CGRect(x: 9, y: 864, width: 32, height: 30)),
            (.left, CGRect(x: 0, y: 9, width: 34, height: 32)),
            (.right, CGRect(x: 1246, y: 9, width: 34, height: 32)),
        ]
        let video = CGRect(x: 0, y: 0, width: 1280, height: 894)
        for (position, logo) in cases {
            let hit = RemoteBarHitTest(geometry: geometry(logo: logo, position: position))
            XCTAssertEqual(hit.rect(for: .logo, videoRect: video), logo,
                           "\(position): the mark is not where the icon is drawn")
            XCTAssertEqual(hit.target(at: CGPoint(x: logo.midX, y: logo.midY), videoRect: video), .logo)
            XCTAssertNil(hit.target(at: CGPoint(x: 640, y: 447), videoRect: video),
                         "\(position): the middle of the desktop carries no mark")
        }
    }

    /// UX-3 §3, end to end, with the numbers off Leo's own machine.
    ///
    /// `hyprctl layers` on omarchy reports the `omarchy-bar` surface at
    /// `0,0 2304x30` on a 3072x1920 output at scale 4/3, and
    /// `~/.config/omarchy/shell.toml` says `base-size = 14`. Core therefore
    /// publishes the logo at `9,0 32x30`, and the iPad letterboxes a
    /// 2304x1440 picture into its own landscape canvas.
    ///
    /// The assertion worth keeping is the *difference*: where MENU-2's square
    /// would have put the mark's centre, against where this one does. That
    /// difference is what Leo saw.
    func testTheRealHostGeometryPutsTheMarkOnTheIconAndNotBesideIt() throws {
        let output = CGSize(width: 2304, height: 1440)
        let hit = RemoteBarHitTest(geometry: HostBarGeometry(
            output: "OMODACHI-leo", logicalSize: output, position: .top,
            bar: CGRect(x: 0, y: 0, width: 2304, height: 30),
            logo: CGRect(x: 9, y: 0, width: 32, height: 30)))
        // An 11-inch iPad in landscape, the picture letterboxed into it.
        let canvas = CGSize(width: 1194, height: 834)
        let video = RemoteBarHitTest.aspectFit(output, in: canvas)
        XCTAssertEqual(video.width, 1194, accuracy: 0.01, "the picture is width-limited here")
        let mark = try XCTUnwrap(hit.rect(for: .logo, videoRect: video))

        let scale = video.width / output.width
        XCTAssertEqual(mark.midX, video.minX + 25 * scale, accuracy: 0.01,
                       "the icon's centre on the host is 9 + 32/2 = 25")

        // What MENU-2 published for the same bar, for the size of the error.
        let before = RemoteBarHitTest(geometry: HostBarGeometry(
            output: "OMODACHI-leo", logicalSize: output, position: .top,
            bar: CGRect(x: 0, y: 0, width: 2304, height: 30),
            logo: CGRect(x: 0, y: 0, width: 30, height: 30)))
        let old = try XCTUnwrap(before.rect(for: .logo, videoRect: video))
        XCTAssertEqual(mark.midX - old.midX, 10 * scale, accuracy: 0.01,
                       "ten host pixels, which is why it read as misplaced")
        XCTAssertGreaterThan(mark.midX - old.midX, 4, "and visible on an 11-inch canvas")
    }

    func testAPointOutsideThePictureCarriesNoMark() {
        let hit = RemoteBarHitTest(geometry: geometry())
        let video = CGRect(x: 40, y: 12, width: 1194, height: 834)
        XCTAssertNil(hit.target(at: CGPoint(x: 10, y: 4), videoRect: video))
        XCTAssertNil(hit.target(at: CGPoint(x: CGFloat.nan, y: 4), videoRect: video))
        XCTAssertNil(hit.target(at: CGPoint(x: 100, y: 500), videoRect: .zero))
    }

    func testAGeometryWithNoLogoDrawsNothing() {
        let hit = RemoteBarHitTest(geometry: geometry(logo: nil))
        XCTAssertNil(hit.fractions(for: .logo))
        XCTAssertNil(hit.rect(for: .logo, videoRect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertFalse(hit.geometry.hasTargets)
    }

    /// A-67: one mark, one destination. The plugin's own icon is not on this
    /// list, and there is no `.settings` anywhere on the host-bar path — from
    /// the picture, panel ⑥ is reached from our own bar.
    func testTheMarkRecallsPanelOneAndNothingElse() {
        XCTAssertEqual(RemoteBarHitTest.Target.allCases, [.logo])
        XCTAssertEqual(RemoteBarHitTest.Target.logo.source, "host_bar_logo")
        XCTAssertEqual(RemoteBarHitTest.Target.logo.view, .overview)
    }

    // MARK: - The controller publishes them, and only for a live session

    func testTheGeometryIsOnlyTakenUpWhileThereIsASession() {
        let controller = RemoteSessionController()
        controller.applyBarGeometry(geometry())
        XCTAssertNil(controller.barHitTest, "no session, no picture, nothing to cover")
        XCTAssertFalse(controller.needsCornerHandle)
    }

    func testAMarkTapAsksForItsPanelAndTellsTheHostNothing() {
        let controller = RemoteSessionController()
        var sources: [String] = []
        controller.onPanel = { sources.append($0) }
        controller.barMarkTapped(.logo)
        XCTAssertEqual(sources, ["host_bar_logo"])
        // The mark is a view above the stream; there is no backend here at all,
        // which is the point — nothing on this path can reach one.
        XCTAssertFalse(controller.hasSession)
    }

    // MARK: - What the router does with the two sources

    func testTheLogoMarkTogglesPanelOne() {
        let registry = PanelRegistry()
        let router = SurfaceRouter(registry: registry)
        router.enterPicture()
        func summon(_ source: String) {
            router.consume(PanelSummon(sessionID: "", revision: 0,
                                       view: source == "keyboard_settings" ? .settings : .overview))
        }
        summon(RemoteBarHitTest.Target.logo.source)
        XCTAssertTrue(router.overlayVisible)
        XCTAssertEqual(router.panel, .menu)
        // A-55 / A-59: the same destination again is the way back to the picture.
        summon(RemoteBarHitTest.Target.logo.source)
        XCTAssertFalse(router.overlayVisible)
        // The hardware alias for panel ⑥ is untouched; it is simply not
        // something the host's bar can ask for from the picture any more.
        summon("keyboard_settings")
        XCTAssertTrue(router.overlayVisible)
        XCTAssertEqual(router.panel, .settings)
    }

    // MARK: - A-67's fallback

    func testTheCornerHandleIsOfferedOnlyWhenThereIsNoMarkOnThePicture() {
        var preferences = ShellPreferences()
        XCTAssertFalse(preferences.cornerHandleWhenBarHidden, "off by default: it is furniture")
        preferences.cornerHandleWhenBarHidden = true
        XCTAssertTrue(preferences.cornerHandleWhenBarHidden)
        let controller = RemoteSessionController()
        XCTAssertFalse(controller.needsCornerHandle, "no session, no picture, no handle")
    }
}
