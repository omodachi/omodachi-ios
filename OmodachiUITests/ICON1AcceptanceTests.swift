import XCTest

/// ICON-1's acceptance walk against the real `omarchy`: the Apps submenu with
/// real application icons in it, and the bar with the host's own Herdr and
/// agent glyphs on it.
///
/// Disabled without `OMODACHI_ICON1_ACCEPTANCE`, and it refuses any simulator
/// the spec did not name — these drive a machine somebody else is using.
@MainActor final class ICON1AcceptanceTests: XCTestCase {
    /// The one simulator ICON-1 names.
    private let authorizedDevices = ["BD431ECD-4DC6-4EE8-8183-7B0AA3B313EA"]

    private func application() throws -> XCUIApplication {
        #if OMODACHI_ICON1_ACCEPTANCE
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
            ?? ProcessInfo.processInfo.environment["OMODACHI_OPERATOR_DEVICE"]
        guard let device, authorizedDevices.contains(device) else {
            throw XCTSkip("ICON-1 refuses any simulator the spec did not name (saw \(device ?? "none"))")
        }
        continueAfterFailure = true
        executionTimeAllowance = 600
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
        #else
        throw XCTSkip("ICON-1 acceptance is disabled; build with OMODACHI_ICON1_ACCEPTANCE")
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

    /// One-time: the real pairing handshake, approved on the host with
    /// `omodachi-host pair approve <id>`.
    func testAPairWithTheRealHost() throws {
        let app = try application()
        if app.buttons["open-agent"].waitForExistence(timeout: 20) { return }
        XCTAssertTrue(app.otherElements["onboarding-gate"].waitForExistence(timeout: 30),
                      "an unpaired app is the host list and nothing else")
        // PAIR-5's walk: the discovered row starts the handshake. Typing the
        // address into "add manually" only files the host in the same list —
        // which is what the first ICON-1 run learned the slow way.
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no _omodachi._tcp instance was discovered")
        row.tap()
        XCTAssertTrue(appears(app.buttons["open-agent"], seconds: 300),
                      "approve the request on the host with `omodachi-host pair approve <id>`")
    }

    /// §1. The Apps submenu, with the host's real application icons in it.
    ///
    /// Each row is photographed on its own as well as the page, so the 36-wide
    /// glyph box can be cut out at a known place — MENU-1's lesson about not
    /// estimating a crop from a full-screen shot.
    func testBTheAppsSubmenuHasRealIcons() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60),
                      "ICON-1 needs a paired host; run testAPairWithTheRealHost first")
        let apps = app.descendants(matching: .any)["menu-apps"]
        XCTAssertTrue(appears(apps, seconds: 60), "the host's catalog never reached the panel")
        apps.tap()
        // The icons are fetched per row after the rows themselves arrive, so
        // the page is given time to fill rather than photographed on the first
        // frame. That it fills at all is the acceptance.
        Thread.sleep(forTimeInterval: 8)
        capture("icon1-apps-submenu", XCUIScreen.main.screenshot())
        var seen = 0
        for identifier in Self.appRows {
            let row = app.descendants(matching: .any)["menu-apps.\(identifier)"]
            guard row.exists else { continue }
            seen += 1
            if seen <= 12 { capture("icon1-row-\(identifier)", row.screenshot()) }
        }
        XCTAssertGreaterThanOrEqual(seen, 10, "§3 wants at least ten real application rows on screen")
    }

    /// §2. The bar, whose ③ and ④ now draw the host's own code points.
    func testCTheBarGlyphs() throws {
        let app = try application()
        XCTAssertTrue(appears(app.otherElements["home-panel"], seconds: 60))
        Thread.sleep(forTimeInterval: 2)
        capture("icon1-panel", XCUIScreen.main.screenshot())
        for identifier in ["open-agent", "open-herdr"] {
            let slot = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(slot.exists, "the bar must still carry \(identifier)")
            guard slot.exists else { continue }
            capture("icon1-bar-\(identifier)", slot.screenshot())
        }
    }

    /// The host's own `apps.*` ids, from `omodachi-host catalog` on `omarchy`.
    private static let appRows = [
        "aether", "Alacritty", "Basecamp", "chatgpt", "chromium", "cliamp", "Discord",
        "org.gnome.DiskUtility", "Docker", "org.gnome.Evince", "org.gnome.Nautilus", "foot",
        "google-chrome", "grok-bot", "HEY", "imv", "org.kde.kdenlive", "kitty",
        "libreoffice-calc", "libreoffice-impress", "libreoffice-writer", "localsend", "mpv",
        "com.moonlight_stream.Moonlight", "nvim", "com.obsproject.Studio", "obsidian",
        "omacalc", "omacut", "omawrite", "com.omodachi.host",
        "com.github.PintaProject.Pinta", "system-config-printer", "dev.lizardbyte.app.Sunshine",
        "dev.tensaku.Tensaku", "omarchy-touchbar-settings", "voxtype-configure", "WhatsApp",
        "X", "com.github.xournalpp.xournalpp", "YouTube", "Zoom",
    ]
}
