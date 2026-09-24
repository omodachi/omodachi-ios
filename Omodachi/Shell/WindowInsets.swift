import SwiftUI
import UIKit

/// Read the actual window's hardware-safe margins for controls while the root
/// canvas and Remote media use the full window. Keyboard safe area is untouched.
struct WindowInteractionInsetsReader: UIViewRepresentable {
    let changed: (EdgeInsets) -> Void
    /// The window's size, and which of its corners are the display's rounded
    /// ones (REMOTE-SAFE-1) — both change only when the window does.
    let windowChanged: (CGSize, DisplayCorners) -> Void
    func makeUIView(context: Context) -> Reader {
        let view = Reader(); view.changed = changed; view.windowChanged = windowChanged; return view
    }
    func updateUIView(_ uiView: Reader, context: Context) {
        uiView.changed = changed; uiView.windowChanged = windowChanged; uiView.publish()
    }
    final class Reader: UIView {
        var changed: ((EdgeInsets) -> Void)?
        var windowChanged: ((CGSize, DisplayCorners) -> Void)?
        private var lastWindowSize: CGSize?
        private var lastCorners: DisplayCorners?
        private var last: UIEdgeInsets?
        override func didMoveToWindow() { super.didMoveToWindow(); publish() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); publish() }
        override func layoutSubviews() { super.layoutSubviews(); publish() }
        func publish() {
            guard let window else { return }
            let size = window.bounds.size
            let corners = Self.corners(of: window)
            if size != lastWindowSize || corners != lastCorners {
                lastWindowSize = size
                lastCorners = corners
                DispatchQueue.main.async { [weak self] in self?.windowChanged?(size, corners) }
            }
            let value = window.safeAreaInsets
            guard value != last else { return }
            last = value
            DispatchQueue.main.async { [weak self] in
                self?.changed?(.init(top: value.top, leading: value.left, bottom: value.bottom, trailing: value.right))
            }
        }

        /// REMOTE-SAFE-1. This device's model, never `_displayCornerRadius`.
        /// The simulator reports the host Mac's architecture from `uname`, so
        /// it names the simulated model in its environment instead.
        static var modelIdentifier: String {
            if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
            var info = utsname()
            uname(&info)
            return withUnsafeBytes(of: &info.machine) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }

        static func corners(of window: UIWindow) -> DisplayCorners {
            let screen = window.windowScene?.screen ?? window.screen
            // The home indicator sits on the bottom edge in every orientation
            // of a Face-ID-class device; a home-button device has no inset there.
            let radius = DisplayCorners.radius(model: modelIdentifier,
                                               isPad: window.traitCollection.userInterfaceIdiom == .pad,
                                               homeIndicatorInset: window.safeAreaInsets.bottom,
                                               nativePixels: screen.nativeBounds.size)
            let frame = window.convert(window.bounds, to: screen.coordinateSpace)
            return DisplayCorners.window(frame: frame, screen: screen.bounds, radius: radius)
        }
    }
}
