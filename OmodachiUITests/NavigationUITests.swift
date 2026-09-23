import UIKit
import XCTest

/// The seven panels, walked (ARCH-1 §1, A-55). These launch only isolated local
/// mock data; screenshots prove navigation and layout, never terminal bytes.
///
/// The shape every case here asserts is the one Study 04 rev 5 settled: **one
/// bar, one panel area, one panel in it.** An entry opens its panel, the same
/// entry again puts ① back, and there is no ×, no back arrow and no push stack
/// to check for — only their absence.
@MainActor
final class NavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 90
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            // I18N-1: every word the app says now comes from the catalog, so
            // what this suite reads depends on the simulator's language. It
            // pins one rather than inheriting whichever locale the machine
            // that runs it happens to have.
            app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 10))
            assertTheBarIsTheWayIn()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            app?.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        try await super.tearDown()
    }

    /// A-50 / N-30: the six entries are on the bar and nowhere else, and the
    /// seventh panel is the logo's. The Panel's four pinned surface tiles are
    /// gone, and so is the terminal icon that used to sit beside them.
    func testTheSixEntriesAreTheOnlyWayInAndTheLogoIsTheSeventh() {
        for entry in ["open-remote", "open-agent", "open-herdr", "open-ssh",
                      "open-setup", "open-notifications", "open-panel"] {
            XCTAssertTrue(app.buttons[entry].exists, "\(entry) is a bar entry")
        }
        for deleted in ["panel-pin-remote", "panel-pin-agent", "panel-pin-herdr", "panel-pin-ssh",
                        "panel-pins", "bar-clock", "bar-focus", "panel-notifications", "panel-dnd"] {
            XCTAssertFalse(app.descendants(matching: .any)[deleted].exists,
                           "\(deleted) is deleted by A-49/A-50/A-52")
        }
        capture("arch1-bar-and-panel-one")
    }

    /// A-55, as one gesture repeated: tap an entry, tap it again, and you are
    /// back at ① every time. No × and no back arrow anywhere in the app.
    func testEveryEntryOpensItsPanelAndTheSameEntryAgainReturnsToPanelOne() {
        for (entry, marker) in [("open-setup", "settings-screen"),
                                ("open-notifications", "notifications-panel"),
                                ("open-remote", "remote-entry-page")] {
            app.buttons[entry].tap()
            XCTAssertTrue(app.descendants(matching: .any)[marker].waitForExistence(timeout: 5),
                          "\(entry) opens \(marker)")
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "panel-topbar").count, 1,
                           "there is one bar, and a panel never takes it away")
            for closed in ["settings-close", "remote-entry-close", "panel-collapse"] {
                XCTAssertFalse(app.buttons[closed].exists, "\(closed) is deleted by A-55")
            }
            app.buttons[entry].tap()
            XCTAssertTrue(app.descendants(matching: .any)["home-panel"].waitForExistence(timeout: 5),
                          "the same entry again is panel ①")
        }
        capture("arch1-entry-toggle")
    }

    /// A-63: the Agent panel starts the agent on entry, and what is on screen
    /// is the chat rather than a question. Leaving and coming back keeps the
    /// unsent draft, because the panel is not torn down (A-31).
    func testAgentOpensTheChatAndKeepsItsDraftAcrossAVisitToPanelOne() {
        app.buttons["open-agent"].tap()
        let composer = app.textFields["agent-chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(sessionIDs().isEmpty, "Agent is not an SSH session")
        XCTAssertFalse(terminal.exists)
        composer.tap()
        composer.typeText("ui-probe")
        capture("arch1-agent")

        app.buttons["open-agent"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-panel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["agent-chat-composer"].exists)

        app.buttons["open-agent"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "ui-probe",
                       "the draft survives, because the panel was not rebuilt")
    }

    /// SPEC-F3 §1 / A-63: Herdr is core's bridge, it starts on entry, and it
    /// opens no SSH session.
    func testHerdrOpensTheNativeGridWithoutAnSSHSession() {
        app.buttons["open-herdr"].tap()
        let grid = app.descendants(matching: .any).matching(identifier: "herdr-grid").firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        XCTAssertFalse(terminal.exists)
        XCTAssertTrue(sessionIDs().isEmpty)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "herdr-control-bar").firstMatch.exists)
        let newTab = app.buttons["herdr-action-newTab"]
        XCTAssertTrue(newTab.exists)
        XCTAssertFalse(newTab.isEnabled, "the bridge has no tab route, so the control says so")
        capture("arch1-herdr")
    }

    /// A-14 / A-63: the SSH panel *is* the terminal. Leo: "为什么 ssh 还需要有
    /// 个 open terminal 的界面" — entering ⑤ dials the paired host, so the
    /// first thing the panel shows is the shell, never a page asking for the
    /// thing the user has already asked for.
    func testTheSSHPanelOpensATerminalWithTheAssistRowAndNoSemanticBar() {
        app.buttons["open-ssh"].tap()
        assertTerminalConnected()
        XCTAssertFalse(app.buttons["open-shell"].exists,
                       "A-63: the interstitial and its button are deleted")
        XCTAssertFalse(app.descendants(matching: .any)["ssh-empty"].exists)
        ensureAssistRow()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "herdr-control-bar").firstMatch.exists,
                       "N-07: Herdr's semantics do not exist on SSH")
        XCTAssertFalse(app.buttons["Prefix"].exists)
        // A-55 deleted the terminal's own way home and its panel toggle.
        XCTAssertFalse(app.buttons["terminal-home"].exists)
        XCTAssertFalse(app.buttons["terminal-panel-toggle"].exists)
        capture("arch1-ssh")
    }

    func testTheSSHPanelKeepsItsSessionAcrossAVisitToPanelOne() {
        app.buttons["open-ssh"].tap()
        assertTerminalConnected()
        assertTarget("SSH")
        let original = sessionIDs()
        XCTAssertEqual(original.count, 1)

        app.buttons["open-ssh"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-panel"].waitForExistence(timeout: 5))
        app.buttons["open-ssh"].tap()
        assertTerminalConnected()
        XCTAssertEqual(sessionIDs(), original, "the session is the panel's, not the visit's")
        capture("arch1-ssh-returned")
    }

    func testTerminalPTYSizeChangesWithPortraitLandscapePortrait() {
        app.buttons["open-ssh"].tap()
        assertTerminalConnected()
        let originalSessionIDs = sessionIDs()
        let portrait = validTerminalSize()

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(eventually {
            self.terminal.exists && self.terminal.frame.width > 0 && self.terminal.frame.height > 0
                && self.terminalSizeText() != portrait
        }, "Rotating the native terminal must change its PTY rows or columns.")
        let landscape = validTerminalSize()
        XCTAssertNotEqual(landscape, portrait)
        assertState("connected")
        XCTAssertEqual(sessionIDs(), originalSessionIDs)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(eventually {
            self.terminal.exists && self.terminal.frame.width > 0 && self.terminal.frame.height > 0
                && self.terminalSizeText() != landscape
        }, "Returning to portrait must update the terminal size again.")
        _ = validTerminalSize()
        assertState("connected")
        XCTAssertEqual(sessionIDs(), originalSessionIDs, "Rotation must retain the same shell session.")
    }

    /// N-31: the search field is panel ①'s, it has no microphone (N-35 rev 5),
    /// and the workspace it finds is the host's catalog row rather than one the
    /// client made up.
    func testTheSearchUsesOneCatalogWorkspaceEntryAndHasNoMicrophone() {
        let search = app.textFields["panel-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["voice-button"].exists, "N-35: there is no microphone in the app")
        search.tap()
        search.typeText("3")
        let result = app.buttons["Workspace 3"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5),
                      "Workspace 3 must come from the explicit fixture catalog")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Workspace 3")).count, 1)
        XCTAssertFalse(app.buttons["search-workspace-3"].exists)
        result.tap()
        // A-12: the result is the 26-high toast, not a sentence under the menu.
        let toast = app.descendants(matching: .any).matching(identifier: "panel-toast").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertTrue(toast.label.contains("Workspace 3"), toast.label)
        XCTAssertTrue(toast.label.contains("applied"), toast.label)
        XCTAssertFalse(terminal.exists)
        capture("arch1-search")
    }

    /// A-54 rev 5: portrait folds panel ① behind the segmented control in the
    /// title row; landscape puts the two halves side by side once the panel
    /// area is at least 785 wide.
    func testPanelOneFoldsInPortraitAndSplitsInLandscape() {
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["panel-segments"].waitForExistence(timeout: 5),
                      "portrait always folds, whatever the width")
        capture("arch1-panel-one-portrait")

        // The two halves are told apart by their own search fields, which are
        // the one thing each of them always has (A-31: each keeps its own).
        XCTAssertTrue(app.textFields["panel-search"].exists, "folded, the menu half is the first segment")
        app.buttons["panel-segment-keybindings"].tap()
        XCTAssertTrue(app.textFields["shortcut-search"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["panel-search"].exists, "folded means one at a time")
        capture("arch1-panel-one-keybindings")

        XCUIDevice.shared.orientation = .landscapeLeft
        // A-54 rev 5 is orientation **and** width, and the width it means is
        // the panel area's — the window minus the bar minus what the glass
        // reserves at the sides. An iPad clears the 785; an iPhone in landscape
        // is 852 wide on paper and about 734 once the notch's two insets are
        // taken off, so it folds. Whichever it is, exactly one of the two
        // layouts is on screen, and it is never both.
        XCTAssertTrue(eventually(timeout: 8) {
            let split = self.app.textFields["panel-search"].exists
                && self.app.textFields["shortcut-search"].exists
            let folded = self.app.descendants(matching: .any)["panel-segments"].exists
            return split != folded
        }, "A-54: side by side or folded, never both and never neither")
        capture("arch1-panel-one-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    /// GEST-1 §4 / N-37: settings ⑥ names all five picture gestures and, on the
    /// right of each, the host row it resolved to. With no host — which is what
    /// a hermetic run is — the four that travel say the host has no such row and
    /// are dimmed *and* disabled (A-65), while the keyboard tap, which is this
    /// device's own, is not.
    func testSettingsNamesEveryPictureGestureAndWhatItResolvedTo() {
        app.buttons["open-setup"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings-gesture-2"].firstMatch
            .waitForExistence(timeout: 5))
        // The section is near the bottom of a long page. Existence does not
        // need it on screen, but a screenshot does, and on a phone that is
        // several swipes down.
        let screen = app.descendants(matching: .any)["settings-screen"].firstMatch
        for _ in 0..<8 where !app.descendants(matching: .any)["settings-gesture-1"].firstMatch.isHittable {
            screen.swipeUp()
        }
        for raw in 1...5 {
            let row = app.descendants(matching: .any)["settings-gesture-\(raw)"].firstMatch
            XCTAssertTrue(row.exists, "gesture row \(raw) is missing from settings ⑥")
        }
        for raw in 2...5 {
            XCTAssertFalse(app.descendants(matching: .any)["settings-gesture-\(raw)"].firstMatch.isEnabled,
                           "N-37 / A-65: an unresolved gesture is dimmed and disabled, row \(raw)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["settings-gesture-1"].firstMatch.isEnabled,
                      "A-62: the keyboard tap is local and never unresolved")
        capture("gest1-settings-gestures")
    }

    /// N-38: Settings carries the switch for every bar entry, and turning one
    /// off takes its slot off the bar without taking the panel away.
    func testSettingsCanTakeAnEntryOffTheBarAndPutItBack() {
        app.buttons["open-setup"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-screen"].waitForExistence(timeout: 5))
        let toggle = app.descendants(matching: .any)["settings-entry-herdr-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        capture("arch1-settings")

        toggle.tap()
        XCTAssertTrue(eventually { !self.app.buttons["open-herdr"].exists },
                      "N-38: the slot goes")
        toggle.tap()
        XCTAssertTrue(eventually { self.app.buttons["open-herdr"].exists }, "and comes back")
        // Settings can never take its own way back away.
        XCTAssertFalse(app.descendants(matching: .any)["settings-entry-settings-toggle"].firstMatch.isEnabled)
    }

    /// A-52 / N-36: notifications are a panel behind the bell, and Do Not
    /// Disturb is at its head and nowhere else.
    func testNotificationsAreAPanelAndDoNotDisturbIsAtItsHead() {
        app.buttons["open-notifications"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["notifications-panel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["panel-dnd"].exists, "N-36: the one switch, on this page")
        capture("arch1-notifications")
        app.buttons["open-notifications"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-panel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["panel-dnd"].exists, "it does not exist anywhere else")
    }

    /// A-56 / rev 4b: panel ② is one column, and its two cards stay inside it
    /// in both orientations. The picture is not reachable without a session
    /// (N-32), so this is the panel, not the stream.
    func testTheRemotePanelKeepsItsCardsInsideItsColumn() {
        XCUIDevice.shared.orientation = .portrait
        app.buttons["open-remote"].tap()
        let page = app.descendants(matching: .any).matching(identifier: "remote-entry-page").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["remote-start-extend"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["remote-start-takeover"].exists)
        XCTAssertTrue(app.buttons["remote-advanced"].exists)
        XCTAssertFalse(terminal.exists)

        // A-40/A-58: the strip and its three controls are gone for good.
        for gone in ["remote-edge-strip", "remote-pointer-mode", "remote-open-panel",
                     "remote-shortcut-keys"] {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: gone).firstMatch.exists,
                           "\(gone) is deleted by A-40/A-42/A-58")
        }
        for kind in ["extend", "takeover"] {
            let card = app.descendants(matching: .any).matching(identifier: "remote-card-\(kind)").firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(card.frame.minX, page.frame.minX - 0.5)
            XCTAssertLessThanOrEqual(card.frame.maxX, page.frame.maxX + 0.5,
                                     "the \(kind) card ran past the panel")
        }
        capture("arch1-remote-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(eventually { page.exists && page.frame.width > 0 })
        capture("arch1-remote-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Helpers

    private var terminal: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "terminal-emulator").firstMatch
    }

    private func assertTheBarIsTheWayIn(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.descendants(matching: .any)["panel-topbar"].waitForExistence(timeout: 5),
                      "there is one bar and it is always there", file: file, line: line)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "panel-topbar").count, 1,
                       "and only one", file: file, line: line)
    }

    private func assertTerminalConnected(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "the terminal must exist", file: file, line: line)
        XCTAssertGreaterThan(terminal.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(terminal.frame.height, 0, file: file, line: line)
        assertState("connected", file: file, line: line)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "panel-topbar").count, 1,
                       "a work surface keeps the one bar", file: file, line: line)
    }

    private func assertState(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = app.staticTexts["terminal-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(eventually { state.label == expected }, "Expected terminal state \(expected).",
                      file: file, line: line)
    }

    private func assertTarget(_ target: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.staticTexts["terminal-target"]
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Expected explicit terminal target.", file: file, line: line)
        XCTAssertEqual(row.label, target, "Expected the \(target) target.", file: file, line: line)
    }

    private func sessionIDs() -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-"))
            .allElementsBoundByIndex.map(\.identifier).sorted()
    }

    private func ensureAssistRow() {
        if !app.buttons["ssh-key-esc"].exists {
            let options = app.buttons["terminal-options"]
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.tap()
            // The label is a catalog string, so the test reaches for the
            // identifier rather than for one language's words (ARCH-1 §6).
            let option = app.buttons["terminal-modifier-row"].firstMatch
            if option.waitForExistence(timeout: 3) { option.tap() }
        }
        XCTAssertTrue(app.buttons["ssh-key-esc"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ssh-key-ctrl"].exists)
    }

    private func terminalSizeText() -> String { app.staticTexts["terminal-size"].label }

    @discardableResult
    private func validTerminalSize(file: StaticString = #filePath, line: UInt = #line) -> String {
        let size = app.staticTexts["terminal-size"]
        XCTAssertTrue(size.waitForExistence(timeout: 5), file: file, line: line)
        let text = size.label
        let dimensions = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        XCTAssertEqual(dimensions.count, 2, "PTY size must expose columns and rows.", file: file, line: line)
        XCTAssertTrue(dimensions.allSatisfy { $0 > 0 }, "PTY dimensions must be positive.", file: file, line: line)
        return text
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
