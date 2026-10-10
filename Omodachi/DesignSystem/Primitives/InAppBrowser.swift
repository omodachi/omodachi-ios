import SafariServices
import SwiftUI
import UIKit

/// LITE-1c: a web page opened over the app in Apple's own Safari view.
///
/// Used for Odomo only. There is no API that adds a web app to the Home
/// Screen, but on iOS 26 and 27 the Safari view's Share sheet offers "Add to
/// Home Screen" with "Open as Web App" on, and what it adds opens standalone
/// (its own `com.apple.webapp` process, no Safari chrome) — the kind of web
/// app that may ask for push. So the person stays in the app, adds Odomo, and
/// closes the view with its own Close button.
///
/// It is the system's browser, presented the way the system presents it — not
/// a panel drawn as a sheet (A-55). Its bars take the host theme's colours.
@MainActor enum InAppBrowser {
    /// `false` when there is nothing to present over, or the URL is not one
    /// the Safari view can show; the caller then hands the URL to Safari.
    ///
    /// LITE-1d: `onClose` runs when the person closes the view (its Close
    /// button, or the swipe), so a caller can read again what may have
    /// changed while it was up — Odomo's notifications, for one.
    @discardableResult
    static func open(_ url: URL, onClose: (@MainActor () -> Void)? = nil) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let top = topController() else { return false }
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        let browser = SFSafariViewController(url: url, configuration: configuration)
        browser.dismissButtonStyle = .close
        browser.preferredBarTintColor = UIColor(OmodachiTheme.barBackground)
        browser.preferredControlTintColor = UIColor(OmodachiTheme.accent)
        browser.modalPresentationStyle = .fullScreen
        if let onClose {
            let watcher = CloseWatcher(onClose)
            browser.delegate = watcher
            // The delegate is weak; the view keeps its watcher alive.
            objc_setAssociatedObject(browser, &CloseWatcher.key, watcher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        top.present(browser, animated: true)
        return true
    }

    @MainActor private final class CloseWatcher: NSObject, @MainActor SFSafariViewControllerDelegate {
        nonisolated(unsafe) static var key: UInt8 = 0
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { action() }
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
