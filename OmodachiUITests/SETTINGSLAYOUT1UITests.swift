import XCTest

/// SETTINGS-LAYOUT-1. Every Settings row follows one rule: a switch, a short
/// value or a single action sits beside its title on every width; a choice
/// sits beside its title only when it fits there at its natural width, and
/// under it otherwise; a long value (a fingerprint, a URL) always goes under
/// its title.
///
/// Hermetic: the demo (`--ui-testing --unpaired`) plus `--settings-fixture`,
/// which gives Diagnostics two synthetic SSH fingerprints.
@MainActor
final class SETTINGSLAYOUT1UITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    func testShortValuesAndSwitchesSitBesideTheirTitle() {
        XCUIDevice.shared.orientation = .portrait
        let app = SETTINGSLAYOUT1.launchDemo()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)

        // A switch: the title and the square are on one line.
        let audio = any["settings-host-audio"]
        XCTAssertTrue(SETTINGSLAYOUT1.reveal(audio, in: app))
        let audioTitle = app.staticTexts["settings-host-audio-title"]
        XCTAssertTrue(audioTitle.exists)
        XCTAssertGreaterThan(audio.frame.minX, audioTitle.frame.maxX, "the switch is right of its title")
        XCTAssertLessThan(abs(audio.frame.minY - audioTitle.frame.minY), audio.frame.height,
                          "and on the title's line, not under it")

        // A short value: the version is on its name's line, at the right.
        let version = any["settings-version"]
        XCTAssertTrue(SETTINGSLAYOUT1.reveal(version, in: app))
        let versionTitle = app.staticTexts["settings-version-title"]
        XCTAssertTrue(versionTitle.exists)
        XCTAssertGreaterThan(version.frame.minX, versionTitle.frame.maxX)
        XCTAssertLessThan(abs(version.frame.midY - versionTitle.frame.midY), 4)
    }

    func testLongValuesGoUnderTheirTitle() {
        XCUIDevice.shared.orientation = .portrait
        let app = SETTINGSLAYOUT1.launchDemo()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)

        let local = any["settings-diagnostics-key-local"]
        XCTAssertTrue(SETTINGSLAYOUT1.reveal(local, in: app), "the fixture's fingerprint is drawn")
        let title = app.staticTexts["settings-diagnostics-key-local-title"]
        XCTAssertTrue(title.exists)
        XCTAssertGreaterThan(local.frame.midY, title.frame.maxY, "a fingerprint goes under its title")
        // A selectable text reports a frame a little wider than its glyphs,
        // so "left-aligned" is checked as "not beside": it starts left of
        // where the title ends.
        XCTAssertLessThan(local.frame.minX, title.frame.midX, "left-aligned with it, not beside it")
        XCTAssertTrue(any["settings-diagnostics-key-host"].exists)
    }

    /// The choice controls decide by the column they are in, not by the
    /// device: beside the title when the control fits at its own width,
    /// under it otherwise. Either way it starts at the title's left edge or
    /// after the title, never over it.
    func testAChoiceIsBesideItsTitleOnlyWhenItFits() {
        XCUIDevice.shared.orientation = .portrait
        let app = SETTINGSLAYOUT1.launchDemo()
        defer { app.terminate() }
        let any = app.descendants(matching: .any)

        for identifier in ["settings-remote-mode", "settings-remote-touch-mode", "settings-remote-placement",
                           "settings-clipboard-sync", "settings-badge-style"] {
            let control = any.matching(identifier: identifier).firstMatch
            XCTAssertTrue(SETTINGSLAYOUT1.reveal(control, in: app), identifier)
            let title = app.staticTexts["\(identifier)-title"]
            XCTAssertTrue(title.exists, identifier)
            let frame = SETTINGSLAYOUT1.frame(of: identifier, in: app)
            let beside = frame.minX > title.frame.maxX && abs(frame.minY + min(frame.height, 44) / 2 - title.frame.midY) < 4
            let under = frame.minY >= title.frame.maxY - 1 && abs(frame.minX - title.frame.minX) < 4
            XCTAssertTrue(beside || under, "\(identifier): \(frame) against \(title.frame)")
            // Four places and a long label cannot share a phone's column.
            if identifier == "settings-remote-placement" && app.frame.width < 470 {
                XCTAssertTrue(under, "\(identifier) goes under its title on a phone held upright")
            }
        }
    }
}

/// SETTINGS-LAYOUT-1's before/after pictures. Compiled only with
/// `OMODACHI_SETTINGS_LAYOUT1_SCREENSHOTS` (pass it as
/// `OMODACHI_OPERATOR_SWIFT_CONDITION`); the attachments are exported from the
/// result bundle. Light mode, the demo and the PAIR-5 offline fixture only —
/// no host, and never the nearby list.
@MainActor
final class SETTINGSLAYOUT1ScreenshotTests: XCTestCase {
    func testPortrait() throws {
        #if OMODACHI_SETTINGS_LAYOUT1_SCREENSHOTS
        walk(orientation: .portrait, label: "portrait")
        #else
        throw XCTSkip("build with OMODACHI_SETTINGS_LAYOUT1_SCREENSHOTS")
        #endif
    }

    func testLandscape() throws {
        #if OMODACHI_SETTINGS_LAYOUT1_SCREENSHOTS
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        walk(orientation: .landscapeLeft, label: "landscape")
        #else
        throw XCTSkip("build with OMODACHI_SETTINGS_LAYOUT1_SCREENSHOTS")
        #endif
    }

    private func walk(orientation: UIDeviceOrientation, label: String) {
        continueAfterFailure = true
        executionTimeAllowance = 600
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let prefix = "\(device)-\(label)"

        // 1. The demo, with every optional row of the page opened.
        var app = SETTINGSLAYOUT1.launchDemo()
        let any = app.descendants(matching: .any)
        let custom = segment(app, "settings-stream-preset-other", 2)
        if SETTINGSLAYOUT1.reveal(any.matching(identifier: "settings-stream-preset-other").firstMatch, in: app) {
            custom.tap()
        }
        if SETTINGSLAYOUT1.reveal(any.matching(identifier: "settings-clipboard-sync").firstMatch, in: app) {
            segment(app, "settings-clipboard-sync", 2).tap()
        }
        SETTINGSLAYOUT1.toTop(app)
        settle()
        var page = 1
        while page <= 16 {
            capture("\(prefix)-demo-\(String(format: "%02d", page))")
            if any["settings-privacy"].exists && any["settings-privacy"].isHittable { break }
            SETTINGSLAYOUT1.page(app)
            settle(0.8)
            page += 1
        }
        any["settings-licence"].tap()
        if any["licence-page"].waitForExistence(timeout: 5) {
            _ = SETTINGSLAYOUT1.reveal(any["licence-component-2"], in: app)
            settle()
            capture("\(prefix)-licence")
        }
        app.terminate()

        // 2. A paired host (PAIR-5's offline fixture): the host row, its
        //    detail, and the Notifications rows that need a host.
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--pair5-offline", "--settings-fixture",
                               "--odomo-url=http://127.0.0.1:18099/odomo/", "--odomo-push-devices=1",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let paired = app.descendants(matching: .any)
        XCTAssertTrue(app.buttons["open-setup"].waitForExistence(timeout: 30))
        app.buttons["open-setup"].tap()
        XCTAssertTrue(paired["settings-screen"].waitForExistence(timeout: 10))
        settle(2)
        capture("\(prefix)-host-01")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        if row.waitForExistence(timeout: 5) {
            row.tap()
            settle(1.5)
            capture("\(prefix)-host-02-detail")
            SETTINGSLAYOUT1.page(app)
            settle()
            capture("\(prefix)-host-03-detail")
        }
        app.terminate()
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

@MainActor
enum SETTINGSLAYOUT1 {
    static func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--unpaired", "--settings-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["demo-enter"].waitForExistence(timeout: 30), "the first screen offers the demo")
        any["demo-enter"].tap()
        XCTAssertTrue(any["demo-banner"].waitForExistence(timeout: 10))
        app.buttons["open-setup"].tap()
        XCTAssertTrue(any["settings-screen"].waitForExistence(timeout: 10))
        return app
    }

    /// Scrolls ⑥ until `element` is on screen; a bounded number of drags.
    static func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<30 {
            if element.exists && element.isHittable { return true }
            page(app, fraction: 0.35)
        }
        return element.exists && element.isHittable
    }

    /// One slow drag, held at the end so nothing coasts: the next picture
    /// starts where this one says it does.
    static func page(_ app: XCUIApplication, fraction: CGFloat = 0.6) {
        let screen = app.descendants(matching: .any)["settings-screen"]
        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let end = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85 - fraction))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    static func toTop(_ app: XCUIApplication) {
        let screen = app.descendants(matching: .any)["settings-screen"]
        for _ in 0..<12 { screen.swipeDown(velocity: .fast) }
    }

    /// A segmented control's frame: its buttons each carry the control's
    /// name, so it is their union; anything else is its own frame.
    static func frame(of identifier: String, in app: XCUIApplication) -> CGRect {
        let buttons = app.buttons.matching(identifier: identifier)
        guard buttons.count > 0 else { return app.descendants(matching: .any)[identifier].firstMatch.frame }
        return (0..<buttons.count).map { buttons.element(boundBy: $0).frame }.reduce(CGRect.null) { $0.union($1) }
    }
}
