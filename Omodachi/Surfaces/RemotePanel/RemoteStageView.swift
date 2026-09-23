import SwiftUI
import UIKit

/// A-58. **The picture has no native chrome.** The desktop in the stream carries
/// Omarchy's own bar, and that bar is the bar: its two Omodachi icons are
/// intercepted by the plugins and come back as `panel.summon` (A-59).
///
/// What used to be here — a 56pt edge strip with three controls, then an edge
/// pan that summoned an overlay — is gone. Leo's reading of the strip on a real
/// iPad was "一个没有意义的侧边栏", and the pan was a second way to do what the
/// host's own bar already does.
///
/// Three things are still native, and only three:
///
/// * the gestures (A-64), which reach catalog rows the host already has;
/// * a self-dismissing hint on the first frame (A-12);
/// * the Shell's 26-high toast, which is drawn by the Shell, not here (A-58's
///   one exception).
struct RemoteStageView: View {
    @ObservedObject var controller: RemoteSessionController
    let profile: HostProfile
    /// MENU-2 / A-67. Our mark over the host bar's Omarchy logo was tapped.
    /// The Shell decides what it means (panel ①); this view's only business is
    /// that the mark sits exactly on the picture it is covering, which is why
    /// it is drawn here and not beside it.
    var onBarMark: (RemoteBarHitTest.Target) -> Void = { _ in }

    @State private var touchHint: String?
    @State private var touchHintShown = false

    var body: some View {
        ZStack {
            OmodachiTheme.pictureLetterbox.ignoresSafeArea()
            picture
                .ignoresSafeArea(.container)
                // A-61: the keyboard is a layer over the picture. It does not
                // shrink the canvas, so the host is never asked to re-plan.
                .ignoresSafeArea(.keyboard)
        }
        .overlay(alignment: .bottom) {
            if let touchHint {
                Text(touchHint)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.text)
                    .padding(.horizontal, OmodachiTheme.space("xxl"))
                    .frame(height: OmodachiTheme.controlHeight)
                    .background(OmodachiTheme.background.opacity(0.9))
                    .overlay(Rectangle().stroke(OmodachiTheme.border,
                                                lineWidth: OmodachiTheme.controlBorderWidth))
                    // A-11: clear of the home-indicator exclusion zone.
                    .padding(.bottom, 44)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityIdentifier("remote-touch-hint")
            }
        }
        .overlay(alignment: .top) { reconnectBanner }
        .background(OmodachiTheme.pictureLetterbox.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { controller.configure(profile: profile) }
        .onChange(of: profile) { _, next in controller.configure(profile: next) }
        .onChange(of: controller.isStreaming) { _, streaming in showTouchHint(streaming) }
    }

    /// The live picture carries its own identifier so a test can wait on "the
    /// stream is up" without a control being added to the picture to do it.
    private var picture: some View {
        ZStack {
            canvas
            // MENU-2 / A-67. Our mark shares the canvas's own rectangle by
            // construction: it is in the same ZStack, so the aspect-fit it
            // computes is the aspect-fit the picture under it was laid out
            // with. Being above the stream is the whole mechanism — UIKit gives
            // that one square its tap and gives the picture everything else, so
            // no touch is intercepted, withheld or replayed.
            if let hit = controller.barHitTest, controller.pictureSize.width > 0,
               controller.retainedFrame == nil {
                RemoteBarMarks(hitTest: hit, pictureSize: controller.pictureSize, tapped: onBarMark)
            }
            if let image = controller.retainedFrame {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OmodachiTheme.pictureLetterbox)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Strings.remoteRetainedFrame)
                    .accessibilityIdentifier("remote-retained-frame")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.remotePicture)
        .accessibilityIdentifier(controller.isStreaming ? "remote-live-picture" : "remote-picture-waiting")
    }

    /// REMOTE-4. The host reconfigured its displays under a session it still
    /// holds. The picture keeps its last frame and this one line says why it is
    /// not moving; the session is never ended and the Shell never routes away
    /// from the picture, which is exactly what used to happen instead.
    @ViewBuilder private var reconnectBanner: some View {
        switch controller.reconnection {
        case .none:
            EmptyView()
        case .inFlight:
            banner(Strings.remoteHostReconfiguring, retry: false)
        case .stalled(let reason):
            banner(reason, retry: true)
        }
    }

    private func banner(_ text: String, retry: Bool) -> some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            Text(text)
                .font(OmodachiTheme.font("body-small"))
                .foregroundStyle(OmodachiTheme.text)
            if retry {
                // A-01: the retry keeps the app's own 44 pt minimum, which is
                // what decides this banner's height.
                TextTap(Strings.remoteHostReconfigureRetry, role: .accent, bordered: true) {
                    controller.retryReconnect()
                }
                .accessibilityIdentifier("remote-reconnect-retry")
            }
        }
        .padding(.horizontal, OmodachiTheme.space("xxl"))
        .frame(minHeight: NativeBarMetrics.hit)
        .background(OmodachiTheme.background.opacity(0.9))
        .overlay(Rectangle().stroke(OmodachiTheme.border, lineWidth: OmodachiTheme.controlBorderWidth))
        .padding(.top, OmodachiTheme.space("xl"))
        .accessibilityIdentifier("remote-reconnect-banner")
    }

    /// Once per session, on the first frame, for four seconds.
    private func showTouchHint(_ streaming: Bool) {
        guard streaming, !touchHintShown else { return }
        touchHintShown = true
        let pointer = controller.relativeTouchpad
            ? Strings.remoteTouchHintTouchpad : Strings.remoteTouchHintDirect
        withAnimation { touchHint = Strings.remoteTouchHintRest(pointer) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            withAnimation { touchHint = nil }
        }
    }

    @ViewBuilder private var canvas: some View {
        RemoteViewportReader(changed: controller.viewportChanged,
                             orientationLock: controller.rotationLocked) {
            if controller.backend == .vnc, let vnc = controller.vnc {
                VNCBackendCanvas(adapter: vnc.adapter)
            } else if let sunshine = controller.sunshine {
                SunshineCanvas(client: sunshine.client)
            } else {
                OmodachiTheme.pictureLetterbox
            }
        }
    }
}

/// Reports the real presentation bounds and the window's interface orientation,
/// and holds A-60's rotation lock.
///
/// UIKit is the authority for both: SwiftUI's geometry lags a rotation by a
/// frame, and `supportedInterfaceOrientations` is the only lever that actually
/// stops one. The lock is session-scoped (`RemoteSessionController` clears it on
/// release), so this view never persists it.
private struct RemoteViewportReader<Content: View>: UIViewControllerRepresentable {
    let changed: (CGSize, String) -> Void
    let orientationLock: Bool
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> Host<Content> {
        let controller = Host(rootView: content())
        // The size this reports has to be the size the video view is given, or
        // the host is asked to plan a picture for a rectangle the picture is
        // never drawn into.
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .black
        controller.changed = changed
        controller.applyLock(orientationLock)
        return controller
    }

    func updateUIViewController(_ controller: Host<Content>, context: Context) {
        controller.changed = changed
        controller.rootView = content()
        controller.applyLock(orientationLock)
    }

    final class Host<Root: View>: UIHostingController<Root> {
        var changed: ((CGSize, String) -> Void)?
        private var last: CGSize = .zero
        private var lastOrientation = ""
        private var locked: UIInterfaceOrientationMask?

        override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            locked ?? .all
        }

        /// A-60 rev 5: lock the orientation the session is *currently* in.
        func applyLock(_ on: Bool) {
            let wanted: UIInterfaceOrientationMask? = on ? mask(for: view.window?.windowScene?.interfaceOrientation) : nil
            guard wanted != locked else { return }
            locked = wanted
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        private func mask(for orientation: UIInterfaceOrientation?) -> UIInterfaceOrientationMask {
            switch orientation {
            case .portrait: .portrait
            case .portraitUpsideDown: .portraitUpsideDown
            case .landscapeLeft: .landscapeLeft
            case .landscapeRight: .landscapeRight
            default: view.bounds.width >= view.bounds.height ? .landscape : .portrait
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let size = view.bounds.size
            let orientation = switch view.window?.windowScene?.interfaceOrientation {
            case .portrait: "portrait" // non-copy: wire value
            case .portraitUpsideDown: "portrait_upside_down"
            case .landscapeLeft: "landscape_left"
            case .landscapeRight: "landscape_right"
            default: size.width >= size.height ? "landscape_left" : "portrait" // non-copy: wire value
            }
            guard size != last || orientation != lastOrientation, size.width > 0, size.height > 0 else { return }
            last = size; lastOrientation = orientation
            changed?(size, orientation)
        }
    }
}

private struct SunshineCanvas: UIViewRepresentable {
    let client: OMRemoteClient
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        // SwiftUI calls `updateUIView` when the representable is re-evaluated,
        // not on every layout pass, so the container can take its real size
        // after the last update. Without this the render view keeps whatever
        // frame it had then - zero, when the stream connects before layout -
        // and the video is decoded into a rectangle with no area.
        client.renderView.frame = container.bounds
        client.renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(client.renderView)
        return container
    }
    func updateUIView(_ view: UIView, context: Context) {
        client.renderView.frame = view.bounds
    }
}
