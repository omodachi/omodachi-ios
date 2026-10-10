import XCTest

/// TUTORIAL-1. The first-steps tour, walked on the demo: every stop to Done,
/// Skip midway, a tap on the bar stepping out of it, and "Show the tour
/// again" in Settings bringing it and the per-panel tips back.
///
/// Hermetic: `--ui-testing --unpaired` is the host list with nothing stored,
/// and `--tour` is what lets the demo arm the tour in a UI-test launch (the
/// other suites that enter the demo leave it out and never see it).
@MainActor
final class TUTORIAL1UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func launch(tour: Bool = true, language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
            + (tour ? ["--tour"] : [])
        app.launch()
        return app
    }

    private func enterDemo(_ app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30), "the first screen offers the demo")
        any["demo-enter"].tap()
        XCTAssertTrue(any["demo-banner"].waitForExistence(timeout: 10))
    }

    private func stop(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any)["tour-step-" + id].waitForExistence(timeout: timeout)
    }

    func testTheDemoWalksEveryStopToDoneAndTheTourDoesNotComeBack() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        enterDemo(app)

        XCTAssertTrue(stop(app, "bar", timeout: 10), "the demo opens on the tour's first stop")
        XCTAssertTrue(any["tour-skip"].exists, "skippable at every stop")
        let card = any["tour-card"]
        XCTAssertEqual(any["tour-step-bar"].value as? String, "Step 1 of 6")
        for (number, id) in ["remote", "agent", "herdr", "notifications", "settings"].enumerated() {
            any["tour-next"].tap()
            XCTAssertTrue(stop(app, id), id)
            XCTAssertEqual(any["tour-step-" + id].value as? String, "Step \(number + 2) of 6")
            if id != "settings" { XCTAssertTrue(any["tour-skip"].exists, "skippable at \(id)") }
        }
        XCTAssertFalse(any["tour-next"].exists, "the last stop says Done")
        XCTAssertFalse(any["tour-skip"].exists)
        any["tour-done"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertTrue(any["home-panel"].exists, "the tour opened nothing: the first panel is still there")

        // Shown once: leaving the demo and coming back is not a first look.
        any["demo-exit"].tap()
        enterDemo(app)
        XCTAssertFalse(stop(app, "bar", timeout: 3))
    }

    func testSkipMidwayEndsItAndATapOnTheBarStepsOutOfIt() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        enterDemo(app)
        XCTAssertTrue(stop(app, "bar", timeout: 10))
        any["tour-next"].tap()
        XCTAssertTrue(stop(app, "remote"))
        any["tour-skip"].tap()
        XCTAssertTrue(any["tour-card"].waitForNonExistence(timeout: 5))

        // Replay, then go into a panel yourself: the tour gets out of the way.
        app.buttons["open-setup"].tap()
        XCTAssertTrue(any["settings-tour-replay"].waitForExistence(timeout: 5))
        any["settings-tour-replay"].tap()
        XCTAssertTrue(stop(app, "bar"))
        app.buttons["open-remote"].tap()
        XCTAssertTrue(any["tour-card"].waitForNonExistence(timeout: 5), "never over a panel the person tapped into")
        XCTAssertTrue(any["demo-remote-needs-host"].waitForExistence(timeout: 5), "and the tap still opened Remote")
    }

    func testShowTheTourAgainBringsTheTourAndTheTipsBack() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        enterDemo(app)
        XCTAssertTrue(stop(app, "bar", timeout: 10))
        any["tour-skip"].tap()

        // Put the Herdr tip away (AGENT-PLAN-1: the Agent panel has none).
        app.buttons["open-herdr"].tap()
        let tip = any["hint-herdr"]
        XCTAssertTrue(tip.waitForExistence(timeout: 10))
        any["hint-dismiss"].firstMatch.tap()
        XCTAssertTrue(tip.waitForNonExistence(timeout: 5))

        app.buttons["open-setup"].tap()
        XCTAssertTrue(any["settings-tour-replay"].waitForExistence(timeout: 5))
        any["settings-tour-replay"].tap()
        XCTAssertTrue(stop(app, "bar"), "the tour starts again, here")
        any["tour-skip"].tap()
        XCTAssertTrue(any["tour-card"].waitForNonExistence(timeout: 5))
        app.buttons["open-herdr"].tap()
        XCTAssertTrue(any["hint-herdr"].waitForExistence(timeout: 10), "the tip is back")
    }

    /// WEB-14's finding: Settings › Bar edge used to save and do nothing.
    func testSettingsBarEdgeMovesTheBar() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(tour: false)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        enterDemo(app)
        let gear = app.buttons["open-setup"]
        XCTAssertLessThan(gear.frame.midX, app.frame.width / 2, "the bar starts on the left")
        gear.tap()
        let edge = any["settings-bar-edge"]
        for _ in 0..<15 where !edge.firstMatchHittable { app.swipeUp() }
        segment(app, "settings-bar-edge", 1).tap()
        let moved = NSPredicate { _, _ in gear.frame.midX > app.frame.width / 2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5),
                       .completed, "the bar is on the right now")
        XCTAssertTrue(any["settings-bar-edge-landscape"].exists, "landscape has its own choice: top or bottom")
    }

    /// Found while taking the evidence: an iPad turned with the app open kept
    /// its portrait bar down the side (its safe area is the same either way
    /// up, so nothing told the Shell the window had turned).
    func testTurningTheDeviceTurnsTheBar() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(tour: false)
        defer { app.terminate() }
        enterDemo(app)
        let gear = app.buttons["open-setup"]
        XCTAssertLessThan(gear.frame.minX, 60, "portrait: the bar is down the left")
        XCUIDevice.shared.orientation = .landscapeLeft
        let top = NSPredicate { _, _ in gear.frame.minY < 60 && gear.frame.minX > app.frame.width / 2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: top, object: nil)], timeout: 8),
                       .completed, "landscape: the bar is along the top, \(gear.frame) in \(app.frame)")
    }

    func testWithoutTheFlagAUITestDemoHasNoTour() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(tour: false)
        defer { app.terminate() }
        enterDemo(app)
        XCTAssertFalse(stop(app, "bar", timeout: 3))
    }

    func testTheTourWalksInLandscapeAndInChinese() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(language: "zh-Hans")
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        enterDemo(app)
        XCTAssertTrue(stop(app, "bar", timeout: 10))
        XCTAssertEqual(any["tour-step-bar"].value as? String, "第 1 步，共 6 步")
        XCTAssertTrue(any["tour-card"].isHittable)
        for id in ["remote", "agent", "herdr", "notifications", "settings"] {
            any["tour-next"].tap()
            XCTAssertTrue(stop(app, id), id)
            XCTAssertTrue(any["tour-card"].isHittable, "the callout is on screen at \(id)")
        }
        any["tour-done"].tap()
        XCTAssertTrue(any["tour-card"].waitForNonExistence(timeout: 5))
    }
}

/// TUTORIAL-1 §4. Every stop, on this simulator, in the orientation and the
/// language the run names — the evidence for the report. Compiled only with
/// `OMODACHI_TUTORIAL1_SCREENSHOTS` and run through
/// `scripts/build.sh acceptance OMODACHI_TUTORIAL1_SCREENSHOTS TUTORIAL1ScreenshotTests`.
@MainActor
final class TUTORIAL1ScreenshotTests: XCTestCase {
    func testEveryStop() throws {
        #if OMODACHI_TUTORIAL1_SCREENSHOTS
        continueAfterFailure = true
        executionTimeAllowance = 900
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let device = pad ? "ipad" : "iphone"
        for language in ["en", "zh"] {
            for landscape in [false, true] {
                walk(device: device, language: language, landscape: landscape)
            }
        }
        // The other two edges: right in portrait, bottom in landscape.
        edges(device: device)
        #else
        throw XCTSkip("screenshots: OMODACHI_TUTORIAL1_SCREENSHOTS")
        #endif
    }

    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "--tour",
                               "-AppleLanguages", language == "en" ? "(en)" : "(zh-Hans)",
                               "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        return app
    }

    private func walk(device: String, language: String, landscape: Bool) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let app = launch(language)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        guard any["demo-enter"].waitForExistence(timeout: 30) else { return XCTFail("no demo") }
        any["demo-enter"].tap()
        let tag = "\(device)-\(language)-\(landscape ? "landscape" : "portrait")"
        for (index, id) in ["bar", "remote", "agent", "herdr", "notifications", "settings"].enumerated() {
            guard any["tour-step-" + id].waitForExistence(timeout: 10) else { return XCTFail("\(tag) \(id)") }
            settle()
            capture("TUTORIAL-1-\(tag)-\(index + 1)-\(id)")
            (any["tour-next"].exists ? any["tour-next"] : any["tour-done"]).tap()
        }
        settle(0.6)
        // Where the tour lives afterwards.
        app.buttons["open-setup"].tap()
        if any["settings-tour-replay"].waitForExistence(timeout: 5) {
            settle()
            capture("TUTORIAL-1-\(tag)-7-settings-row")
        }
        // Leo, 2026-10-05: the Agent header's New conversation glyph.
        if !landscape {
            app.buttons["open-agent"].tap()
            if any["agent-new"].firstMatch.waitForExistence(timeout: 10) {
                settle()
                capture("TUTORIAL-1-\(tag)-8-agent-new-icon")
            }
        }
    }

    private func edges(device: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = launch("en")
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        guard any["demo-enter"].waitForExistence(timeout: 30) else { return XCTFail("no demo") }
        any["demo-enter"].tap()
        guard any["tour-step-bar"].waitForExistence(timeout: 10) else { return XCTFail("no tour") }
        any["tour-skip"].tap()
        // Portrait: the bar on the right (Settings › This device › Bar edge).
        app.buttons["open-setup"].tap()
        let edge = any["settings-bar-edge"]
        for _ in 0..<12 where !edge.firstMatchHittable { app.swipeUp() }
        segment(app, "settings-bar-edge", 1).tap()
        for _ in 0..<12 where !any["settings-tour-replay"].firstMatchHittable { app.swipeDown() }
        any["settings-tour-replay"].tap()
        for id in ["bar", "agent"] {
            if id == "agent" { advance(app, through: ["remote", "agent"]) }
            guard any["tour-step-" + id].waitForExistence(timeout: 10) else { return XCTFail("right \(id)") }
            settle()
            capture("TUTORIAL-1-\(device)-en-portrait-right-\(id)")
        }
        any["tour-skip"].tap()
        // Landscape: the bar at the bottom (Settings › Bar edge › In landscape).
        let landscapeEdge = any["settings-bar-edge-landscape"]
        for _ in 0..<12 where !landscapeEdge.firstMatchHittable { app.swipeUp() }
        segment(app, "settings-bar-edge-landscape", 1).tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(1.5)
        for _ in 0..<15 where !any["settings-tour-replay"].firstMatchHittable { app.swipeDown() }
        any["settings-tour-replay"].tap()
        for id in ["bar", "notifications"] {
            if id == "notifications" { advance(app, through: ["remote", "agent", "herdr", "notifications"]) }
            guard any["tour-step-" + id].waitForExistence(timeout: 10) else { return XCTFail("bottom \(id)") }
            settle()
            capture("TUTORIAL-1-\(device)-en-landscape-bottom-\(id)")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Next, one stop at a time: a second tap while the callout is still
    /// moving can land beside it.
    private func advance(_ app: XCUIApplication, through stops: [String]) {
        let any = app.descendants(matching: .any)
        for id in stops {
            any["tour-next"].tap()
            _ = any["tour-step-" + id].waitForExistence(timeout: 5)
            settle(0.4)
        }
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// A `SegmentedRow`'s identifier lands on each of its buttons (or on the row,
/// depending on how SwiftUI flattened it); this finds the n-th one either way.
@MainActor
func segment(_ app: XCUIApplication, _ identifier: String, _ index: Int) -> XCUIElement {
    let buttons = app.buttons.matching(identifier: identifier)
    if buttons.count > index { return buttons.element(boundBy: index) }
    return app.descendants(matching: .any)[identifier].firstMatch.buttons.element(boundBy: index)
}

extension XCUIElement {
    @MainActor var firstMatchHittable: Bool { firstMatch.exists && firstMatch.isHittable }
}

