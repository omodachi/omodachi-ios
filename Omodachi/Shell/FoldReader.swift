import SwiftUI
import UIKit

/// DUO-1. Reports where an open foldable's fold runs through the window, or
/// nil. iOS 27.1 tells an App the hinge's status (`UIHingeInteraction`); the
/// fold itself is placed across the middle of the display (`FoldLine.middle`).
/// A device without a hinge, a closed one, and an App built with an SDK older
/// than 27.1 all read nil, which leaves every layout on its width rule.
///
/// Sized to the window, like `WindowInteractionInsetsReader`, so a turn or a
/// fold lays it out again and it reads the display afresh.
struct FoldReader: UIViewRepresentable {
    let changed: (FoldLine?) -> Void
    /// DUO-1 round 2: the hinge itself — open (or half open), closed, or nil
    /// where there is none — for Remote's one unfold re-plan.
    var hinge: (Bool?) -> Void = { _ in }

    func makeUIView(context: Context) -> Reader {
        let view = Reader()
        view.changed = changed
        view.hinge = hinge
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: Reader, context: Context) {
        uiView.changed = changed
        uiView.hinge = hinge
        uiView.publish()
    }

    final class Reader: UIView {
        var changed: ((FoldLine?) -> Void)?
        var hinge: ((Bool?) -> Void)?
        private var state: OMHingeState = .unavailable
        private var observing = false
        private var last: FoldLine??

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, !observing {
                observing = OMObserveHinge(self) { [weak self] state in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.state = state
                        let open: Bool? = state == .unavailable ? nil : Self.isOpen(state)
                        self.hinge?(open)
                        self.publish()
                    }
                }
            }
            publish()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publish()
        }

        func publish() {
            guard let window else { return }
            var value: FoldLine?
            if Self.isOpen(state) || Self.fixture {
                let screen = window.windowScene?.screen ?? window.screen
                value = .middle(of: window.convert(screen.bounds, from: screen.coordinateSpace))
            }
            guard last != .some(value) else { return }
            last = .some(value)
            DispatchQueue.main.async { [weak self] in self?.changed?(value) }
        }

        nonisolated static func isOpen(_ state: OMHingeState) -> Bool {
            state == .partiallyOpen || state == .fullyOpen
        }

        /// A UI test cannot open a hinge (XCUIDevice has no fold), so
        /// `--fold-fixture` makes any simulator read as an open foldable whose
        /// fold runs across the middle of its screen.
        static var fixture: Bool {
            #if DEBUG && targetEnvironment(simulator)
            let arguments = ProcessInfo.processInfo.arguments
            return arguments.contains("--ui-testing") && arguments.contains("--fold-fixture") // non-copy: launch flags
            #else
            return false
            #endif
        }
    }
}
