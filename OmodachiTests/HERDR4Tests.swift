import XCTest
@testable import Omodachi

/// HERDR-4: fit to width, the operator's rows, the short-reply proof, and the
/// visibility fixes — with no host in the room. The replies are core's own
/// fixtures (`herdr-operator-rows*.json`, `herdr-text-short.json`).
@MainActor
final class HERDR4Tests: XCTestCase {
    private func fixtures() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["OMODACHI_CORE_FIXTURES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
    }

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: fixtures().appendingPathComponent(name)))
    }

    // MARK: - Operator rows

    func testCoresShippedRowsDecodeAndMatchTheAppsOwnFallback() throws {
        let claude = try fixture("herdr-operator-rows.json", as: HerdrOperatorRowsDTO.self)
        XCTAssertEqual(claude.family, "claude")
        XCTAssertEqual(claude.quick.map(\.items), [["yes", "no"], ["continue", "commit and push", "retry", "skip"]])
        XCTAssertEqual(claude.harness.map(\.command), ["/model", "/effort", "/compact", "/resume"])
        XCTAssertEqual(claude.keys.filter(\.danger).map(\.label), ["Ctrl D", "Ctrl Z"])
        // An older core (no route) gets exactly what a newer one ships.
        let fallback = HerdrOperatorRowsDTO.shipped(agent: "claude")
        XCTAssertEqual(fallback.quick, claude.quick)
        XCTAssertEqual(fallback.keys, claude.keys)
        XCTAssertEqual(fallback.harness, claude.harness)

        let shell = try fixture("herdr-operator-rows-shell.json", as: HerdrOperatorRowsDTO.self)
        XCTAssertNil(shell.agent)
        XCTAssertEqual(shell.quick.map(\.items), [["y", "n"]])
        XCTAssertEqual(HerdrOperatorRowsDTO.shipped(agent: nil).quick, shell.quick)
        XCTAssertEqual(shell.harness, [])
        XCTAssertEqual(HerdrOperatorRowsDTO.shipped(agent: "codex").harness.map(\.command), ["/model", "/compact", "/resume"])
    }

    func testTheOperatorsRowsReplaceAndCarryTheirWordsAndWarnings() throws {
        let rows = try fixture("herdr-operator-rows-operator.json", as: HerdrOperatorRowsDTO.self)
        XCTAssertEqual(rows.quick.map(\.title), ["bestätigen", "häufig"])
        XCTAssertTrue(rows.quick.allSatisfy(\.isOperator))
        XCTAssertEqual(rows.harness.map { HerdrHarnessWords.title($0) }, ["Status", "clear"])
        XCTAssertEqual(rows.harness.map(\.confirm), [false, true], "a shipped dangerous command keeps its second tap")
        XCTAssertEqual(rows.commands.map(\.command), ["/statusline", "/standup", "/clear"])
        // The first file with a problem is the one the dock talks about.
        let warning = try XCTUnwrap(rows.warning)
        XCTAssertEqual(warning.file, "keys.toml")
        XCTAssertEqual(warning.warning.code, "operator_rows_dropped")
    }

    func testShippedRowsAreWordedInTheReadersLanguage() throws {
        let claude = try fixture("herdr-operator-rows.json", as: HerdrOperatorRowsDTO.self)
        XCTAssertEqual(claude.quick.map { HerdrHarnessWords.title($0) }, [Strings.herdrQuickConfirm, Strings.herdrQuickCommon])
        XCTAssertEqual(claude.harness.map { HerdrHarnessWords.title($0) },
                       [Strings.herdrHarnessModel, Strings.herdrHarnessEffort, Strings.herdrHarnessCompact,
                        Strings.herdrHarnessResume])
        for word in [Strings.herdrQuick, Strings.herdrTapAgain, Strings.herdrWaiting, Strings.hintHerdr,
                     Strings.herdrSentLight, Strings.herdrZoomFit, Strings.herdrZoomActual] {
            XCTAssertFalse(word.isEmpty)
        }
    }

    func testPresetsBesideTheKeysRowSkipWhatAFixedKeyAlreadySends() throws {
        let claude = try fixture("herdr-operator-rows.json", as: HerdrOperatorRowsDTO.self)
        XCTAssertEqual(claude.presets.map(\.label), ["Ctrl U", "Ctrl R", "Ctrl L", "Ctrl Z"])
        XCTAssertEqual(claude.presets.map(HerdrPresetFace.face), ["^U", "^R", "^L", "^Z"])
        let rows = try fixture("herdr-operator-rows-operator.json", as: HerdrOperatorRowsDTO.self)
        // An operator's own row keeps its own words.
        XCTAssertEqual(rows.presets.map(HerdrPresetFace.face), ["Back", "Quit"])
        XCTAssertEqual(rows.presets.map(\.danger), [false, true])
    }

    func testTheAgentNameIsWhatCoreAccepts() {
        XCTAssertEqual(HerdrPaneKind.agentName(agent: " Claude-Code "), "claude-code")
        for bad in ["", "a b", "../x", "-x", "claudé", String(repeating: "a", count: 41)] {
            XCTAssertNil(HerdrPaneKind.agentName(agent: bad), bad)
        }
        XCTAssertEqual(HerdrPaneKind.family("claude-code"), "claude")
        XCTAssertEqual(HerdrPaneKind.family("codex"), "codex")
        XCTAssertEqual(HerdrPaneKind.family("pi-dev"), "pi")
    }

    func testASecondTapIsAskedForOnlyWithinTheWindow() {
        let armed = HerdrArmed(id: "key:Ctrl Z", until: Date().addingTimeInterval(HerdrArmed.window))
        XCTAssertTrue(armed.holds("key:Ctrl Z"))
        XCTAssertFalse(armed.holds("key:Ctrl D"))
        XCTAssertFalse(armed.holds("key:Ctrl Z", now: Date().addingTimeInterval(HerdrArmed.window + 1)))
    }

    // MARK: - Short replies

    func testAShortReplyProvedByItsLineSaysSentWithoutTheTick() throws {
        let short = try fixture("herdr-text-short.json", as: HerdrTextResultDTO.self)
        XCTAssertEqual(short.proof, "line")
        XCTAssertTrue(short.lightProof)
        let long = try fixture("herdr-text.json", as: HerdrTextResultDTO.self)
        XCTAssertEqual(long.proof, "tail")
        XCTAssertFalse(long.lightProof)
        let notSeen = try fixture("herdr-text-not-seen.json", as: HerdrTextResultDTO.self)
        XCTAssertFalse(notSeen.lightProof)
        XCTAssertFalse(Strings.herdrSentLight.contains("✓"))
        XCTAssertTrue(Strings.herdrSent.contains("✓"))
    }

    // MARK: - Names, not ids

    func testAPaneIsNamedByItsTitleFolderOrPlaceNeverItsID() throws {
        let json = """
        {"revision": 1, "workspaces": [{"id": "w1", "focused": true, "tabs": [
          {"id": "w1:t1", "focused": true, "zoomed": false, "panes": [
            {"id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1", "title": "Claude Code", "cwd": "/home/alex/work",
             "focused": true, "zoomed": false, "agent": {"name": "claude", "kind": "claude", "status": "blocked"},
             "agent_status": "blocked", "revision": 1},
            {"id": "w1:p2", "tab_id": "w1:t1", "workspace_id": "w1", "title": null, "cwd": "/home/alex/omodachi",
             "focused": false, "zoomed": false, "agent": null, "revision": 1},
            {"id": "w1:p3", "tab_id": "w1:t1", "workspace_id": "w1", "title": " ", "cwd": null,
             "focused": false, "zoomed": false, "agent": null, "revision": 1}]}]}]}
        """
        let value = try JSONDecoder().decode(HerdrLayoutDTO.self, from: Data(json.utf8))
        XCTAssertEqual(value.name(of: "w1:p1"), "Claude Code")
        XCTAssertEqual(value.name(of: "w1:p2"), "omodachi")
        XCTAssertEqual(value.name(of: "w1:p3"), Strings.herdrPaneNumbered("3"))
        for pane in value.panes { XCTAssertFalse(value.name(of: pane.id).contains(pane.id)) }
        XCTAssertTrue(value.pane("w1:p1")?.isWaiting == true)
        XCTAssertFalse(value.pane("w1:p2")?.isWaiting == true)
        XCTAssertEqual(value.pane("w1:p1")?.agentName, "claude")
    }

    // MARK: - Hints

    func testAHintDismissedOnThisDeviceStaysDismissed() {
        let suite = "herdr4-hints-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let hints = OnceHints(defaults: defaults)
        XCTAssertTrue(hints.shows(.herdr))
        XCTAssertTrue(hints.shows(.tour))
        hints.dismiss(.herdr)
        XCTAssertFalse(hints.shows(.herdr))
        XCTAssertTrue(hints.shows(.tour))
        XCTAssertFalse(OnceHints(defaults: defaults).shows(.herdr), "remembered")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Fit to width

    private func fitView() -> (HerdrFitView, HerdrTerminalView) {
        let terminal = HerdrTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400),
                                         font: OmodachiTheme.uiFont(size: HerdrStore.fontSize))
        let view = HerdrFitView(terminal: terminal)
        return (view, terminal)
    }

    /// The mirror holds the pane at its own size: SwiftTerm's grid is the
    /// pane's, whatever the phone's width, and the view zooms it to fit.
    func testAWidePaneIsHeldAtItsOwnSizeAndFittedToTheWidth() throws {
        let (view, terminal) = fitView()
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 560)
        view.setPaneSize((cols: 160, rows: 50))
        view.layoutIfNeeded()
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.getTerminal().cols, 160)
        XCTAssertEqual(terminal.getTerminal().rows, 50)
        let natural = try XCTUnwrap(view.naturalSize)
        let readable = HerdrFitView.readablePoints / HerdrStore.fontSize
        XCTAssertEqual(view.fitScale, max(402 / natural.width, readable), accuracy: 0.001)
        XCTAssertEqual(view.zoomScale, view.fitScale, accuracy: 0.001)
        XCTAssertEqual(view.zoomMode, .fit)
        // A pinch can still show the whole pane at once.
        XCTAssertLessThanOrEqual(view.minimumZoomScale, 402 / natural.width + 0.001)

        // Double tap: 1:1, and back.
        view.toggleZoom()
        XCTAssertEqual(view.zoomMode, .actual)
        view.toggleZoom()
        XCTAssertEqual(view.zoomMode, .fit)
        XCTAssertEqual(terminal.getTerminal().cols, 160, "zooming never changes the grid")
    }

    /// A pane narrower than the screen is drawn 1:1, not blown up.
    func testANarrowPaneIsNeverEnlarged() {
        let (view, _) = fitView()
        view.frame = CGRect(x: 0, y: 0, width: 1194, height: 800)
        view.setPaneSize((cols: 60, rows: 20))
        view.layoutIfNeeded()
        XCTAssertEqual(view.fitScale, 1, accuracy: 0.0001)
    }

    /// Take keyboard: no pane size, the terminal fills the view at 1:1 — the
    /// size `control` puts on the PTY while it is held.
    func testWithoutAPaneSizeTheTerminalFillsTheView() throws {
        let (view, terminal) = fitView()
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 560)
        view.setPaneSize((cols: 160, rows: 50))
        view.layoutIfNeeded()
        view.setPaneSize(nil)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertEqual(terminal.frame.size, view.bounds.size)
        let fill = try XCTUnwrap(view.fillGeometry)
        XCTAssertLessThan(fill.cols, 160)
        XCTAssertGreaterThan(fill.cols, 20)
    }
}
