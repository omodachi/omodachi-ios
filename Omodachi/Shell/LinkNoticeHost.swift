import SwiftUI

/// LINKS-1: the one line a tapped link leaves behind — "Opening it on the
/// computer…", why a file was not opened, or that a page is only served to
/// the computer itself, with "Open on the computer" beside it. It is the
/// opener's own state, so it is drawn wherever the panel area is, over the
/// picture's summoned layer too.
///
/// POLISH-U: it floats over the panel instead of sitting above it in the
/// stack, at the top of the panel's *content*: the region the panel marks with
/// `linkNoticeRegion()` (the Agent's transcript, Herdr's mirror), else just
/// under the header strip every panel opens with (one control row and its
/// rule). So the header, its face and Herdr's workspace strip stay whole, and
/// nothing moves when it comes and goes.
struct LinkNoticeHost: View {
    @ObservedObject var links: LinkOpener

    /// A panel's header strip: one row of controls and the rule under it.
    static let headerClearance: CGFloat = NativeBarMetrics.hit + NativeBarMetrics.edgeRule

    var body: some View {
        if let notice = links.notice {
            LinkNoticeBar(kind: kind(notice.kind), text: notice.text,
                          actionTitle: notice.offer == nil ? nil : Strings.linkOpenOnComputer,
                          action: { if let offer = notice.offer { links.openOffer(offer) } },
                          dismiss: { links.dismiss() })
                .padding(.horizontal, OmodachiTheme.space("lg"))
                .padding(.vertical, OmodachiTheme.space("md"))
                .transition(.opacity)
        }
    }

    private func kind(_ value: LinkOpener.Notice.Kind) -> LinkNoticeBar.Kind {
        switch value {
        case .working: .working
        case .info: .info
        case .problem: .problem
        }
    }
}

extension View {
    /// The link notice over this panel: at the top of the region it marked,
    /// else under its header strip.
    func linkNotice(_ links: LinkOpener) -> some View {
        overlayPreferenceValue(LinkNoticeRegionKey.self) { region in
            GeometryReader { proxy in
                let rect = region.map { proxy[$0] }
                LinkNoticeHost(links: links)
                    .frame(width: rect?.width ?? proxy.size.width)
                    .offset(x: rect?.minX ?? 0, y: rect?.minY ?? LinkNoticeHost.headerClearance)
            }
        }
    }
}
