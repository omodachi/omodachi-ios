import SwiftUI
import UIKit

/// Read the actual window's hardware-safe margins for controls while the root
/// canvas and Remote media use the full window. Keyboard safe area is untouched.
struct WindowInteractionInsetsReader: UIViewRepresentable {
    let changed: (EdgeInsets) -> Void
    let windowChanged: (CGSize) -> Void
    func makeUIView(context: Context) -> Reader {
        let view = Reader(); view.changed = changed; view.windowChanged = windowChanged; return view
    }
    func updateUIView(_ uiView: Reader, context: Context) {
        uiView.changed = changed; uiView.windowChanged = windowChanged; uiView.publish()
    }
    final class Reader: UIView {
        var changed: ((EdgeInsets) -> Void)?
        var windowChanged: ((CGSize) -> Void)?
        private var lastWindowSize: CGSize?
        private var last: UIEdgeInsets?
        override func didMoveToWindow() { super.didMoveToWindow(); publish() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); publish() }
        override func layoutSubviews() { super.layoutSubviews(); publish() }
        func publish() {
            guard let window else { return }
            let size = window.bounds.size
            if size != lastWindowSize {
                lastWindowSize = size
                DispatchQueue.main.async { [weak self] in self?.windowChanged?(size) }
            }
            let value = window.safeAreaInsets
            guard value != last else { return }
            last = value
            DispatchQueue.main.async { [weak self] in
                self?.changed?(.init(top: value.top, leading: value.left, bottom: value.bottom, trailing: value.right))
            }
        }
    }
}
