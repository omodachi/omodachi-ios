import SwiftUI
import UIKit

/// Read the actual window's hardware-safe margins for controls while the root
/// canvas and Remote media use the full window. Keyboard safe area is untouched.
struct WindowInteractionInsetsReader: UIViewRepresentable {
    let changed: (EdgeInsets) -> Void
    /// The window's size, and which of its corners are the display's rounded
    /// ones (REMOTE-SAFE-1) — both change only when the window does — and the
    /// side column the Remote picture keeps clear of (DUO-1 round 2).
    let windowChanged: (CGSize, DisplayCorners, RemotePictureColumn) -> Void
    func makeUIView(context: Context) -> Reader {
        let view = Reader(); view.changed = changed; view.windowChanged = windowChanged
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: Reader, context: Context) {
        uiView.changed = changed; uiView.windowChanged = windowChanged; uiView.publish()
    }
    final class Reader: UIView {
        var changed: ((EdgeInsets) -> Void)?
        var windowChanged: ((CGSize, DisplayCorners, RemotePictureColumn) -> Void)?
        private var lastWindowSize: CGSize?
        private var lastCorners: DisplayCorners?
        private var lastColumn: RemotePictureColumn?
        private var last: UIEdgeInsets?
        override func didMoveToWindow() { super.didMoveToWindow(); publish() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); publish() }
        override func layoutSubviews() { super.layoutSubviews(); publish() }
        func publish() {
            guard let window else { return }
            let size = window.bounds.size
            let corners = Self.corners(of: window)
            let column = RemotePictureColumn.measure(left: window.safeAreaInsets.left, right: window.safeAreaInsets.right)
            if size != lastWindowSize || corners != lastCorners || column != lastColumn {
                lastWindowSize = size
                lastCorners = corners
                lastColumn = column
                DispatchQueue.main.async { [weak self] in self?.windowChanged?(size, corners, column) }
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

/// HERDR-5. How much of the window the software keyboard actually covers, from
/// UIKit's own keyboard notifications, for the panels stage.
///
/// The panels used to take SwiftUI's keyboard safe area, and that area does
/// not always come back to zero. Measured on the iOS 27 simulator: with a
/// hardware keyboard connected, focusing a field shows only the small floating
/// input-assistant bar and UIKit reports a zero-height keyboard, yet the whole
/// panel stage (the left rail too) kept 89 points of empty space above the
/// bottom; after an iPad's "Hide keyboard" it kept 101. The keyboard
/// notifications are the ground truth here: a keyboard that is hidden, floating
/// or zero high covers nothing, and a docked one covers from its top edge down.
/// `willHide` always means zero — on iOS 27 its end frame repeats the shown
/// keyboard's.
struct KeyboardOverlapReader: UIViewRepresentable {
    let changed: (CGFloat, Double) -> Void
    func makeUIView(context: Context) -> Reader { let view = Reader(); view.changed = changed; return view }
    func updateUIView(_ uiView: Reader, context: Context) { uiView.changed = changed }

    final class Reader: UIView {
        var changed: ((CGFloat, Double) -> Void)?
        private var visible = false
        private var last: CGFloat = 0
        private var observers: [NSObjectProtocol] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else { return }
            for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification,
                         UIResponder.keyboardWillChangeFrameNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] note in
                    let name = note.name
                    let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                    let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                    MainActor.assumeIsolated { self?.handle(name, end: end, duration: duration) }
                })
            }
        }

        private func handle(_ name: Notification.Name, end: CGRect?, duration: Double) {
            if name == UIResponder.keyboardWillHideNotification { visible = false }
            else if name == UIResponder.keyboardWillShowNotification { visible = true }
            var value: CGFloat = 0
            if visible, let end, let window {
                value = Self.overlap(keyboard: window.convert(end, from: window.screen.coordinateSpace),
                                     window: window.bounds)
            }
            guard value != last else { return }
            last = value
            changed?(value, duration)
        }

        /// A docked keyboard's cover of the window: from its top edge to the
        /// window's bottom. Zero for one with no height, one that does not
        /// reach the bottom edge (floating, undocked or split on an iPad), and
        /// one outside the window.
        nonisolated static func overlap(keyboard: CGRect, window: CGRect) -> CGFloat {
            guard keyboard.height > 0, keyboard.intersects(window),
                  keyboard.maxY >= window.maxY - 1 else { return 0 }
            return max(0, window.maxY - keyboard.minY)
        }
    }
}
