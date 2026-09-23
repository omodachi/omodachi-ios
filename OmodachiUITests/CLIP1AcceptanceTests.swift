import UIKit
import XCTest

/// CLIP-1's acceptance walk against a real host: the Keybindings list without
/// the five rows nothing can run, ⑥'s two new switches, and one clipboard
/// round trip in each direction.
///
/// The host is a side-by-side `omodachid` on `omarchy` port 8199, running this
/// branch, reached through an SSH tunnel — the installed host service is the
/// one Leo uses and this spec does not install over it.
///
/// Disabled without `OMODACHI_CLIP1_ACCEPTANCE`, and it refuses any simulator
/// the spec did not name: these drive a machine somebody else is using.
@MainActor final class CLIP1AcceptanceTests: XCTestCase {
    private let authorizedDevices = ["D4E1349E-E808-437B-BD09-D6D8275AAD2C"]

    private func application() throws -> XCUIApplication {
        #if OMODACHI_CLIP1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("CLIP-1 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 900
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("CLIP-1 acceptance is disabled; build with OMODACHI_CLIP1_ACCEPTANCE")
        #endif
    }

    private func capture(_ name: String, _ screenshot: XCUIScreenshot) {
        let shot = XCTAttachment(screenshot: screenshot)
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

    /// One-time: the manual host entry plus the real handshake, approved on the
    /// host with `omodachi-host --socket <side> pair approve <id>`.
    func testAPairWithTheSideBySideHost() throws {
        let app = try application()
        if app.buttons["open-setup"].waitForExistence(timeout: 20) { return }
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30),
                      "an unpaired app is the host list and nothing else")
        // The side-by-side host does not advertise itself (`--discovery off`),
        // so it is typed in. Manual add starts the handshake directly.
        let manual = app.descendants(matching: .any)["connect-add-manual"]
        XCTAssertTrue(appears(manual, seconds: 30), "the host list has no manual entry")
        manual.tap()
        let field = app.textFields["connect-manual-field"]
        XCTAssertTrue(appears(field, seconds: 15))
        field.tap()
        field.typeText(ProcessInfo.processInfo.environment["OMODACHI_CLIP1_HOST"] ?? "127.0.0.1:8199")
        capture("clip1-host-entry", XCUIScreen.main.screenshot())
        app.descendants(matching: .any)["connect-manual-submit"].tap()
        XCTAssertTrue(appears(app.buttons["open-setup"], seconds: 300),
                      "approve the request on the host with `pair approve <id>`")
    }

    /// §1. The list the host publishes 227 rows for shows 222, and ⑥'s switch
    /// brings the other five back, greyed.
    func testBTheFiveRowsAreNotInTheList() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60),
                      "CLIP-1 needs a paired host; run testAPairWithTheSideBySideHost first")
        // Portrait folds ① behind the segmented control (A-54); landscape puts
        // the two halves side by side. Either way, this is the half we want.
        let segment = app.descendants(matching: .any)["panel-segment-keybindings"]
        if appears(segment, seconds: 20) { segment.tap() }
        let search = app.descendants(matching: .any)["shortcut-search"]
        XCTAssertTrue(appears(search, seconds: 60), "the keybindings half never loaded")
        search.tap()
        search.typeText("Universal")
        Thread.sleep(forTimeInterval: 2)
        capture("clip1-keybindings-hidden", XCUIScreen.main.screenshot())
        XCTAssertFalse(app.staticTexts["Universal copy"].exists,
                       "a row nothing here can run is not in the list")

        app.buttons["open-setup"].tap()
        let toggle = app.descendants(matching: .any)["settings-show-unrunnable"]
        XCTAssertTrue(appears(toggle, seconds: 30), "⑥ has no Keybindings switch")
        toggle.tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["open-setup"].tap()
        if appears(segment, seconds: 20) { segment.tap() }
        Thread.sleep(forTimeInterval: 2)
        capture("clip1-keybindings-shown", XCUIScreen.main.screenshot())
        XCTAssertTrue(appears(app.staticTexts["Universal copy"], seconds: 20),
                      "the switch puts them back")
    }

    /// §2. ⑥'s clipboard section, and the one thing a screenshot can prove
    /// about it: that both switches are named and the host's half is reported.
    func testCTheClipboardSection() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60))
        app.buttons["open-setup"].tap()
        let control = app.descendants(matching: .any)
            .matching(identifier: "settings-clipboard-sync").firstMatch
        XCTAssertTrue(appears(control, seconds: 30), "⑥ has no clipboard section")
        app.swipeUp()
        // The segment's own label, in the language the walk launched in.
        let both = app.buttons["双向"].firstMatch   // non-copy: the zh-Hans segment label
        XCTAssertTrue(appears(both, seconds: 20), "the clipboard chooser has no third answer")
        both.tap()
        Thread.sleep(forTimeInterval: 4)
        capture("clip1-settings-clipboard", XCUIScreen.main.screenshot())
    }

    /// The host copied something. The device cannot show the text — a
    /// clipboard is not a thing to print on a settings page — so what it shows
    /// is that something arrived: ⑥'s `已同步` line counts it.
    ///
    /// The runner cannot read the pasteboard itself: iOS refuses a background
    /// process (`PBErrorDomain 13`), which is exactly the restriction the whole
    /// coordinator is built around. The counter is the observable.
    func testDTheHostsCopyArrivesHere() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60))
        app.buttons["open-setup"].tap()
        let counts = app.descendants(matching: .any)["settings-clipboard-counts"]
        XCTAssertTrue(appears(counts, seconds: 30), "⑥ does not count what moved")
        // The operator runs `wl-copy` on the host inside this window.
        let deadline = Date().addingTimeInterval(180)
        var value = ""
        while Date() < deadline {
            app.swipeUp()
            value = counts.label.isEmpty ? (counts.value as? String ?? "") : counts.label
            if !value.hasPrefix("收到 0") { break }   // non-copy: the zh-Hans counter prefix
            Thread.sleep(forTimeInterval: 3)
        }
        capture("clip1-settings-counts", XCUIScreen.main.screenshot())
        XCTAssertFalse(value.hasPrefix("收到 0"), "nothing arrived from the host: \(value)")
    }

    /// And the other way, with a copy this device really made inside the app.
    ///
    /// iOS hands back content the app itself put on the pasteboard and refuses
    /// content it did not (`clipboard.push stopped reason=read_refused` — a
    /// whole round of this walk found that priming the simulator's pasteboard
    /// from outside is not the same thing). So the text is typed into ①'s
    /// search field and copied with ⌘A ⌘C, which is a person copying something
    /// on their iPad, and then ⑥'s Send button pushes it.
    func testETheDevicesCopyReachesTheHost() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60))
        let segment = app.descendants(matching: .any)["panel-segment-keybindings"]
        if appears(segment, seconds: 20) { segment.tap() }
        let search = app.descendants(matching: .any)["shortcut-search"]
        XCTAssertTrue(appears(search, seconds: 60))
        search.tap()
        let typed = ProcessInfo.processInfo.environment["OMODACHI_CLIP1_SEND"] ?? "omodachi-clip1-typed"
        search.typeText(typed)
        Thread.sleep(forTimeInterval: 1)
        search.typeKey("a", modifierFlags: .command)
        search.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 2)

        app.buttons["open-setup"].tap()
        let send = app.descendants(matching: .any)["settings-clipboard-send"]
        for _ in 0..<12 where !send.exists { app.swipeUp(); Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(appears(send, seconds: 20), "⑥ has no Send control")
        send.tap()
        // If iOS does ask, a person taps Allow Paste; so does this.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for source in [app, springboard] {
            let alert = source.alerts.firstMatch
            guard appears(alert, seconds: 6) else { continue }
            capture("clip1-paste-alert", XCUIScreen.main.screenshot())
            alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
            break
        }
        let counts = app.descendants(matching: .any)["settings-clipboard-counts"]
        for _ in 0..<12 where !counts.exists { app.swipeUp(); Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(appears(counts, seconds: 30))
        var value = ""
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            value = counts.label.isEmpty ? (counts.value as? String ?? "") : counts.label
            if !value.hasSuffix("送出 0") { break }   // non-copy: the zh-Hans counter suffix
            Thread.sleep(forTimeInterval: 3)
        }
        capture("clip1-after-push", XCUIScreen.main.screenshot())
        XCTAssertFalse(value.hasSuffix("送出 0"), "nothing was sent to the host: \(value)")
    }
}
