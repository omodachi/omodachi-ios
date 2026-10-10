import CoreText
import SwiftUI
import XCTest
@testable import Omodachi

/// TUTORIAL-1: the first-steps tour's state machine (shown once, skip,
/// replay brings the hints back), which stops there are, and where the
/// callout lands on each of the bar's four edges.
@MainActor
final class TUTORIAL1Tests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "tutorial1-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func tour() -> FirstStepsTour { FirstStepsTour(hints: OnceHints(defaults: defaults), defaults: defaults) }
    private let all = TourStep.allCases

    // MARK: - Shown once

    func testATourArmedByAPairingStartsOnceAndWalksEveryStopToDone() {
        let tour = tour()
        XCTAssertFalse(tour.startIfPending(available: all), "nothing armed, nothing starts")
        tour.arm()
        XCTAssertTrue(tour.pending)
        XCTAssertTrue(tour.startIfPending(available: all))
        XCTAssertFalse(tour.startIfPending(available: all), "already up")
        var seen: [TourStep] = []
        while let step = tour.step {
            seen.append(step)
            XCTAssertEqual(tour.position?.number, seen.count)
            XCTAssertEqual(tour.position?.count, 6)
            XCTAssertEqual(tour.isLast, seen.count == 6)
            tour.next()
        }
        XCTAssertEqual(seen, [.bar, .remote, .agent, .herdr, .notifications, .settings])
        XCTAssertLessThanOrEqual(seen.count, 6, "the spec's ceiling")
        XCTAssertFalse(tour.isShowing)
        XCTAssertFalse(tour.pending)
        XCTAssertFalse(tour.hints.shows(.tour), "seen")

        // A second pairing, the demo, a relaunch: never again by itself.
        tour.arm()
        XCTAssertFalse(tour.pending)
        let relaunched = self.tour()
        relaunched.arm()
        XCTAssertFalse(relaunched.startIfPending(available: all))
    }

    func testAnArmedTourSurvivesARelaunchUntilItIsShown() {
        tour().arm()
        let relaunched = tour()
        XCTAssertTrue(relaunched.pending, "the app was closed right after pairing")
        XCTAssertTrue(relaunched.startIfPending(available: all))
    }

    func testSkipMidwayEndsItAsSeen() {
        let tour = tour()
        tour.arm()
        tour.startIfPending(available: all)
        tour.next()
        XCTAssertEqual(tour.step, .remote)
        tour.finish()
        XCTAssertNil(tour.step)
        XCTAssertFalse(tour.pending)
        XCTAssertFalse(tour.hints.shows(.tour))
        XCTAssertFalse(self.tour().pending)
    }

    func testABarThatGoesAwayPutsTheTourDownWithoutCallingItSeen() {
        let tour = tour()
        tour.arm()
        tour.startIfPending(available: all)
        tour.next()
        tour.suspend()
        XCTAssertFalse(tour.isShowing)
        XCTAssertTrue(tour.pending)
        XCTAssertTrue(tour.hints.shows(.tour))
        XCTAssertTrue(tour.startIfPending(available: all))
        XCTAssertEqual(tour.step, .bar, "it starts again from the top")
    }

    func testAUITestLaunchDoesNotArmItUnlessAsked() {
        let tour = tour()
        tour.startsByItself = false
        tour.arm()
        XCTAssertFalse(tour.pending)
        tour.replay(available: all)
        XCTAssertEqual(tour.step, .bar, "Settings' row works whatever the launch")
    }

    // MARK: - Replay resets the hints

    func testReplayBringsTheTourAndEveryHintBack() {
        let tour = tour()
        tour.hints.dismiss(.herdr)
        tour.arm()
        tour.startIfPending(available: all)
        tour.finish()
        XCTAssertFalse(tour.hints.shows(.herdr))
        tour.replay(available: all)
        XCTAssertEqual(tour.step, .bar)
        XCTAssertTrue(tour.hints.shows(.herdr))
        let fresh = OnceHints(defaults: defaults)
        XCTAssertTrue(fresh.shows(.herdr), "the reset is written down, not just in memory")
        tour.finish()
        XCTAssertFalse(OnceHints(defaults: defaults).shows(.tour))
        XCTAssertTrue(OnceHints(defaults: defaults).shows(.herdr), "finishing the tour leaves the tips alone")
    }

    func testOneRegistryNoSecondCopyOfAHint() {
        // AGENT-PLAN-1: no Agent hint - the slash list it pointed at is gone.
        XCTAssertEqual(OnceHints.Hint.allCases.map(\.rawValue), ["herdr", "tour"])
        XCTAssertEqual(Set(OnceHints.Hint.allCases.map(\.defaultsKey)).count, 2)
        // The Herdr hint keeps the key HERDR-4 wrote, so a hint dismissed
        // before this build stays dismissed.
        XCTAssertEqual(OnceHints.Hint.herdr.defaultsKey, "omodachi.hint.herdr.v1")
    }

    // MARK: - Stops

    func testAnEntrySwitchedOffHasNoStopAndTheBarAndSettingsAlwaysDo() {
        let none = TourStep.available { _ in false }
        XCTAssertEqual(none, [.bar, .settings])
        let noRemote = TourStep.available { $0 != "remote" }
        XCTAssertEqual(noRemote, [.bar, .agent, .herdr, .notifications, .settings])
        let tour = tour()
        tour.replay(available: noRemote)
        XCTAssertEqual(tour.position?.count, 5)
        // Every stop's anchor is a panel id the bar tags (or the bar).
        for step in TourStep.allCases where step != .bar {
            XCTAssertNotNil(PanelID(rawValue: step.anchor), step.rawValue)
        }
    }

    func testEveryStopHasWordsInBothLanguages() throws {
        let app = Bundle(for: FirstStepsTour.self)
        let keys = TourStep.allCases.flatMap { ["tour.\($0.rawValue).title", "tour.\($0.rawValue).body"] }
            + ["tour.next", "tour.skip", "tour.done", "tour.progress", "settings.tour.replay"]
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{1}", table: nil)
                XCTAssertNotEqual(value, "\u{1}", "\(language) \(key)")
                XCTAssertFalse(value.isEmpty)
            }
        }
        XCTAssertEqual(TourStep.allCases.map { TourWords.title($0) }.count, 6)
    }

    // MARK: - Where the callout lands

    private let phone = CGSize(width: 402, height: 874)
    private let safe = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)

    private func frame(_ target: CGRect?, _ edge: HostBarPosition, size: CGSize? = nil,
                       safe: EdgeInsets? = nil, wants: CGFloat = 200) -> CGRect {
        TourCalloutLayout.frame(in: size ?? phone, target: target, edge: edge, safe: safe ?? self.safe,
                                margin: 12, gap: 10, maxWidth: 360) { _, limit in min(wants, limit) }
    }

    func testOnALeftBarTheCalloutOpensToTheRightBesideItsEntry() {
        let entry = CGRect(x: 0, y: 700, width: 44, height: 44)
        let f = frame(entry, .left)
        XCTAssertGreaterThanOrEqual(f.minX, entry.maxX + 10)
        XCTAssertLessThanOrEqual(f.maxX, phone.width - 12)
        XCTAssertLessThanOrEqual(f.maxY, phone.height - 34 - 12, "clear of the home indicator")
        XCTAssertTrue(f.minY <= entry.midY && entry.midY <= f.maxY || f.maxY == phone.height - 34 - 12)
    }

    func testOnARightBarTheCalloutOpensToTheLeft() {
        let entry = CGRect(x: phone.width - 44, y: 300, width: 44, height: 44)
        let f = frame(entry, .right)
        XCTAssertLessThanOrEqual(f.maxX, entry.minX - 10)
        XCTAssertGreaterThanOrEqual(f.minX, 12)
        XCTAssertEqual(f.midY, entry.midY, accuracy: 1)
    }

    func testOnATopBarTheCalloutHangsBelowAndSlidesToStayOnScreen() {
        let landscape = CGSize(width: 874, height: 402)
        let side = EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
        let entry = CGRect(x: 790, y: 0, width: 44, height: 44)
        let f = frame(entry, .top, size: landscape, safe: side)
        XCTAssertGreaterThanOrEqual(f.minY, entry.maxY + 10)
        XCTAssertLessThanOrEqual(f.maxX, landscape.width - 62 - 12, "slid left, clear of the sensor housing")
        XCTAssertEqual(f.width, 360)
    }

    func testOnABottomBarTheCalloutSitsAbove() {
        let landscape = CGSize(width: 874, height: 402)
        let side = EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
        let entry = CGRect(x: 80, y: 402 - 44 - 21, width: 44, height: 44)
        let f = frame(entry, .bottom, size: landscape, safe: side)
        XCTAssertLessThanOrEqual(f.maxY, entry.minY - 10)
        XCTAssertGreaterThanOrEqual(f.minX, 62 + 12)
    }

    func testAnUnmeasuredTargetCentresTheCalloutAndATallOneIsCutToTheSpaceLeft() {
        let centred = frame(nil, .left)
        XCTAssertEqual(centred.midX, phone.width / 2, accuracy: 1)
        let landscape = CGSize(width: 874, height: 402)
        let entry = CGRect(x: 400, y: 0, width: 44, height: 44)
        let tall = frame(entry, .top, size: landscape, safe: EdgeInsets(), wants: 2_000)
        XCTAssertLessThanOrEqual(tall.maxY, landscape.height - 12, "the words scroll inside instead")
    }

    func testANarrowScreenGivesTheCalloutTheWidthThereIs() {
        let narrow = CGSize(width: 320, height: 568)
        let entry = CGRect(x: 0, y: 200, width: 44, height: 44)
        let f = TourCalloutLayout.frame(in: narrow, target: entry, edge: .left, safe: EdgeInsets(), margin: 12,
                                        gap: 10, maxWidth: 360) { _, limit in min(150, limit) }
        XCTAssertEqual(f.width, 320 - 12 - 54, accuracy: 0.5)
    }

    // MARK: - WEB-14's finding: Settings' Bar edge takes effect, and lasts

    func testTheStoredBarEdgesPlaceTheBarAfterARestart() {
        var chosen = ShellPreferences()
        chosen.barEdges.choose(.right)
        chosen.barEdges.choose(.bottom)
        chosen.save(defaults: defaults)

        // What ShellView does at launch.
        let loaded = ShellPreferences.load(defaults: defaults)
        XCTAssertEqual(loaded.barEdges, NativeBarEdgePreferences(landscape: .bottom, portrait: .right))
        var placement = NativeBarPlacement()
        placement.preferences = loaded.barEdges
        placement.update(width: 402, height: 874, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .right, "portrait: the side chosen")
        placement.update(width: 874, height: 402, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .bottom, "landscape: the edge chosen, not always the top")
    }

    func testAChoiceInSettingsMovesTheBarThatIsUpNow() {
        var placement = NativeBarPlacement()
        placement.update(width: 402, height: 874, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .left)
        var edges = placement.preferences
        edges.choose(.right)
        placement.apply(edges)
        XCTAssertEqual(placement.edge, .right)
        edges.choose(.bottom)
        placement.apply(edges)
        XCTAssertEqual(placement.edge, .right, "a landscape choice waits for landscape")
        placement.update(width: 874, height: 402, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .bottom)
        // The hold menu and Settings write one value.
        var menu = NativeBarPlacement()
        menu.update(width: 874, height: 402, reason: .windowGeometry)
        menu.choose(.bottom)
        XCTAssertEqual(menu.preferences.landscape, .bottom)
    }

    func testSettingsSaysWhatTheHoldMenuAllows() throws {
        let app = Bundle(for: FirstStepsTour.self)
        let path = try XCTUnwrap(app.path(forResource: "en", ofType: "lproj"))
        let en = try XCTUnwrap(Bundle(path: path)).localizedString(forKey: "settings.barEdge.detail", value: nil, table: nil)
        XCTAssertFalse(en.contains("Always on top"), en)
        XCTAssertTrue(en.contains("top or bottom in landscape"), en)
    }

    // MARK: - Leo: the Agent header's new conversation is a bubble with a plus

    func testNewConversationIsABubbleWithAPlusInTheBundledFace() throws {
        XCTAssertEqual(Icon.newConversation.symbol, "plus.bubble")
        XCTAssertEqual(Icon.newConversation.nerd, "\u{f10bb}")
        let url = try XCTUnwrap(Bundle(for: FirstStepsTour.self).url(forResource: "SymbolsNerdFontMono-Regular",
                                                                      withExtension: "ttf"))
        let provider = try XCTUnwrap(CGDataProvider(url: url as CFURL))
        let font = CTFontCreateWithGraphicsFont(try XCTUnwrap(CGFont(provider)), 14, nil, nil)
        var unichars = Array("\u{f10bb}".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count),
                      "nf-md-message_plus_outline is in the face the app ships")
    }
}
