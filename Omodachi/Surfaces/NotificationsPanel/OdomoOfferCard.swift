import SwiftUI

/// LITE-1d. Odomo, offered where people look for notifications.
///
/// The app tells you things only while it is open; Odomo, the computer's own
/// web app on the Home Screen, is how the computer reaches a locked phone. So
/// the top of ⑦ says that once, in one sentence, with the button that opens
/// Odomo in the Safari view over the app (whose Share sheet adds it to the
/// Home Screen) and the hint for what to do there.
///
/// It goes when a device of this computer gets Odomo's pushes (core's
/// `odomo.push_devices`), when Odomo is known to be on this device for this
/// computer (ODOMO-CARD: a link from Odomo said so), or after "Hide" for this
/// computer — the switch in Settings › Notifications brings it back. Without Tailscale on the computer there is no Odomo, and the
/// card says so instead of disappearing, with the way to Tailscale.
struct OdomoOfferCard: View {
    @EnvironmentObject private var home: HomeStore
    /// "Use Tailscale for <computer>…" lands on the move in Settings.
    var onMove: () -> Void
    @Environment(\.openURL) private var openURL
    /// "Hide" was pressed on this visit: the card says where it went, once,
    /// in its place (a toast is panel ①'s, not this page's).
    @State private var putAway = false

    var body: some View {
        let state = home.odomoState
        // Only while it is still hidden: the switch in Settings may have
        // brought it back with this page still alive (iPad shows both).
        if putAway, home.odomoOfferDismissed() {
            Text(Strings.odomoCardHidden(Strings.panelSettings, Strings.panelNotifications))
                .font(OmodachiTheme.bodyFont("body-small"))
                .foregroundStyle(OmodachiTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .padding(.vertical, OmodachiTheme.space("lg"))
                .accessibilityIdentifier("odomo-card-hidden")
        } else if OdomoOffer.showsCard(state, dismissed: home.odomoOfferDismissed(), here: home.odomoOnThisDevice()) {
            HStack(spacing: 0) {
                Rectangle().fill(OmodachiTheme.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Strings.odomoCardTitle(DeviceWord.current))
                        .font(OmodachiTheme.bodyFont("subtitle"))
                        .foregroundStyle(OmodachiTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    sentence(Strings.odomoCardWhy(Strings.odomoName, DeviceWord.current), color: OmodachiTheme.secondaryText)
                    switch state {
                    case .off(let url, _):
                        sentence(Strings.odomoRowDetail(Strings.odomoName), color: OmodachiTheme.tertiaryText)
                        HStack(spacing: 8) {
                            FlowButton(title: Strings.odomoCardOpen(Strings.odomoName)) { open(url) }
                                .accessibilityIdentifier("odomo-card-open")
                            hide
                        }
                        .padding(.top, 4)
                    default:
                        sentence(Strings.odomoNone(Strings.odomoName, Strings.odomoName), color: OmodachiTheme.tertiaryText)
                            .accessibilityIdentifier("odomo-card-none")
                        if home.hostRoad?.kind.isTailscale == true {
                            sentence(Strings.odomoNoneTailscale(Strings.odomoName), color: OmodachiTheme.tertiaryText)
                            HStack(spacing: 8) { hide }.padding(.top, 4)
                        } else {
                            HStack(spacing: 8) {
                                FlowButton(title: Strings.errLanAwayGo(home.state.hostName)) { onMove() }
                                    .accessibilityIdentifier("odomo-card-move")
                                hide
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(12)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(OmodachiTheme.normalFill)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notifications-odomo-card")
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.vertical, OmodachiTheme.space("lg"))
        }
    }

    /// ODOMO-CARD: the quiet button hides the card for this computer.
    private var hide: some View {
        FlowButton(title: Strings.odomoCardHide, kind: .ghost) {
            home.dismissOdomoOffer()
            putAway = true
        }
            .frame(maxWidth: 140)
            .accessibilityIdentifier("odomo-card-hide")
    }

    private func sentence(_ text: String, color: Color) -> some View {
        Text(text)
            .font(OmodachiTheme.bodyFont("body-small"))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ url: URL) {
        let opened = InAppBrowser.open(url) { Task { await home.refreshOdomo() } }
        if !opened { openURL(url) }
    }
}
