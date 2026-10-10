import XCTest

/// TAIL-3b. The first screen is the Tailscale page. "Add by name or
/// address…" is on the Wi-Fi road, behind "I don't use Tailscale" and W01's
/// "Look on this Wi-Fi" — and a LAN address typed on the Tailscale page is
/// refused (E04b), so the operator suites that pair by address walk there.
enum OnboardingNavigation {
    /// Walks to the Wi-Fi list when the first screen is up, and returns its
    /// "Add by name or address…" row (which may not exist: already paired).
    static func manualAdd(_ app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let lan = app.descendants(matching: .any)["lan-entry"]
        if lan.waitForExistence(timeout: timeout) {
            lan.tap()
            let go = app.descendants(matching: .any)["lan-go"]
            if go.waitForExistence(timeout: 3) { go.tap() }
        }
        return app.descendants(matching: .any)["connect-add-manual"]
    }
}
