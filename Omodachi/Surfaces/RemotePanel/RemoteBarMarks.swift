import SwiftUI

/// MENU-2 / A-67. Our mark, drawn over the host bar's Omarchy logo.
///
/// This is what retires `com.omodachi.menu`. The clone existed for one reason:
/// so that a tap on the Omarchy logo, from the iPad, could become a recall of
/// panel ①. It paid for that by owning the `menu` kind — which no other menu
/// replacement can then use — by rewriting the user's `shell.json` on install,
/// and by having to be kept in step with upstream.
///
/// Nothing on the host is needed for it. Core publishes where that logo is on
/// the output the session owns (`state.bar.geometry`), and this view puts
/// **our** mark on top of it, on this device, above the stream. Being above
/// the stream is the whole mechanism: UIKit gives the tap to the topmost view
/// that wants it, so this one square answers locally and everything around it
/// passes through to the picture untouched. No gesture on the picture changes,
/// no touch is withheld or replayed, and the host's own bar keeps working for
/// whoever is at the machine.
///
/// **Only the logo.** The Omodachi plugin's own slot moves with every other
/// widget beside it, so nothing is drawn over it and a tap there reaches the
/// host's own icon in both modes. What that icon does during a takeover is the
/// plugin's decision, taken where a local mouse click meets the same rule.
///
/// The rectangle is a fraction of the host's output, so it follows the picture
/// through letterboxing, rotation, a resize and any encoder resolution the host
/// picks. `pictureSize` is the decoded stream, laid out aspect-fit and centred —
/// which is what both backends do (`VideoDecoderRenderer.layoutVideo` and
/// `OMVNCRemoteView.videoRect`), and the one place that is stated here so the
/// mark cannot drift from the picture under it.
struct RemoteBarMarks: View {
    let hitTest: RemoteBarHitTest
    /// The decoded stream, in pixels. Empty means there is no picture yet.
    let pictureSize: CGSize
    let tapped: (RemoteBarHitTest.Target) -> Void

    var body: some View {
        GeometryReader { proxy in
            let video = RemoteBarHitTest.aspectFit(pictureSize, in: proxy.size)
            ZStack(alignment: .topLeading) {
                mark(.logo, in: video)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-bar-marks")
    }

    /// The mark is exactly the size of the icon it covers, and deliberately not
    /// one point larger. A-01's 44 does not apply here: this square has to line
    /// up with something on somebody else's bar, and the only directions it
    /// could grow in are the screen edge and the next widget along — which this
    /// app does not locate and must not take touches from. A picture drawn
    /// small enough for the mark to be hard to hit is a picture in which the
    /// host's own icon is exactly as hard to hit, which is the honest answer.
    @ViewBuilder private func mark(_ target: RemoteBarHitTest.Target, in video: CGRect) -> some View {
        if let rect = hitTest.rect(for: target, videoRect: video), rect.width >= 8, rect.height >= 8 {
            // Study 01's rule holds over the picture too: the mark is
            // monochrome and takes the theme's foreground, never a colour of
            // its own. It is the app's own symbol — the thing the host's
            // Omarchy logo stands in for from this device.
            Tap(fill: OmodachiTheme.background) { tapped(target) } label: {
                OmodachiSymbol.view(size: max(8, min(rect.width, rect.height) * 0.68))
                    .foregroundStyle(OmodachiTheme.text)
                    .frame(width: rect.width, height: rect.height)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityLabel(Strings.remoteMarkPanel)
            .accessibilityIdentifier("remote-mark-logo")
        }
    }
}
