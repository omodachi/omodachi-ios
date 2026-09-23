import XCTest

/// TERM-1's acceptance walk: the four kinds of character a real Omarchy shell
/// puts on a line, photographed in ⑤ and in ④ so they can be put beside the
/// host's own kitty drawing the same command.
///
/// A Nerd Font code point, a Han ideograph, an emoji and plain Latin, in one
/// `eza` listing under a starship prompt. Before this spec the first of those
/// was a box on every row, because the app registered the family
/// `fc-match monospace` answers — Nimbus Mono PS on this host — and asked
/// CoreText nothing further.
///
/// Disabled without `OMODACHI_TERM1_ACCEPTANCE`, and it refuses any simulator
/// the spec did not name: these drive a machine somebody else is using.
@MainActor final class TERM1AcceptanceTests: XCTestCase {
    /// The one simulator this spec created for itself, by udid.
    ///
    /// `xcodebuild` hands the runner `SIMULATOR_UDID` and nothing of the
    /// operator's own environment, so the list is written down here the way
    /// MENU-1 writes it down rather than passed in — and a name is never used,
    /// because a `name=` destination picks whatever device on this Mac answers
    /// to it, which is how a spec installs onto somebody else's simulator
    /// (INPUT-2 §6.5). This device was created for the TERM-1 run and deleted
    /// after it; a later run substitutes its own.
    private let authorizedDevices = ["A410E8B8-DD4A-4836-9B82-F122C2CA2CBA"]

    /// One command, run in a directory this test makes and this test deletes.
    ///
    /// `ls` is Omarchy's own alias — `eza -lh --group-directories-first
    /// --icons=auto` (`/usr/share/omarchy/default/bash/aliases:3`) — so the
    /// glyph in front of each name is the host's, not something the test chose.
    private let probe = """
    d=/tmp/omodachi-term1-$$ && rm -rf $d && mkdir -p $d/文档 && cd $d \
    && touch 说明.md 笔记😀.txt README.md && ls && echo "中文 😀 ok"

    """

    private func application() throws -> XCUIApplication {
        #if OMODACHI_TERM1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("TERM-1 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("TERM-1 acceptance is disabled; build with OMODACHI_TERM1_ACCEPTANCE")
        #endif
    }

    /// `XCUIScreen.main`, not `app.screenshot()`: the application's own
    /// screenshot comes out in the device's portrait frame even when the test
    /// has rotated it, so a landscape terminal arrives on its side.
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func appears(_ element: XCUIElement, seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return element.exists
    }

    func testAPairWithTheSideBySideDaemon() throws {
        let app = try application()
        let gate = app.otherElements["onboarding-gate"]
        if !gate.waitForExistence(timeout: 10) { return }
        let manual = app.buttons["connect-add-manual"]
        if manual.waitForExistence(timeout: 10) {
            manual.tap()
            let field = app.textFields["connect-manual-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_HOST"] ?? "127.0.0.1:8199")
            app.buttons["connect-manual-submit"].tap()
        }
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 300),
                      "approve the request with `omodachi-host --socket <side> pair approve <id>`")
    }

    /// ⑤. The whole point of the spec, in one screen.
    func testBTheSSHTerminalDrawsAllFourKindsOfCharacter() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60))
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["open-ssh"].waitForExistence(timeout: 20))
        app.buttons["open-ssh"].tap()

        let terminal = app.descendants(matching: .any)["terminal-emulator"]
        XCTAssertTrue(appears(terminal, seconds: 60), "⑤ opens a terminal on entry")
        // The dial, the host-key prompt and the login banner all land before a
        // prompt does; the assertion is on what is drawn, so it has to wait for
        // the shell rather than for the view.
        Thread.sleep(forTimeInterval: 20)
        capture("term1-ssh-01-prompt", app)

        terminal.tap()
        Thread.sleep(forTimeInterval: 3)
        app.typeText(probe)
        Thread.sleep(forTimeInterval: 8)
        capture("term1-ssh-02-listing", app)
    }

    /// ④, the same segment. It is a second renderer of the same buffer through
    /// the official Herdr bridge, and it used to show the same boxes.
    func testCTheHerdrPaneDrawsTheSameLine() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60))
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["open-herdr"].waitForExistence(timeout: 20))
        app.buttons["open-herdr"].tap()

        let terminal = app.descendants(matching: .any)["herdr-terminal"]
        for _ in 0..<6 {
            if terminal.exists { break }
            Thread.sleep(forTimeInterval: 10)
        }
        XCTAssertTrue(terminal.exists, "④ needs the omodachi Herdr session running on the host")
        guard terminal.exists else { capture("term1-herdr-00-no-pane", app); return }
        terminal.tap()
        Thread.sleep(forTimeInterval: 4)
        app.typeText(probe)
        Thread.sleep(forTimeInterval: 8)
        capture("term1-herdr-01-listing", app)
    }
}
