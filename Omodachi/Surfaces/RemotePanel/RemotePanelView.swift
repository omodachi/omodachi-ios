import SwiftUI

/// Panel ② — Remote (A-56 "read and choose", A-57, N-32).
///
/// Two states and no third: **no session** is the two intent cards and the
/// collapsed backend row; **a session** is the card that says what is running
/// and where ending it will take you. There is no × and no back arrow — tapping
/// the Remote entry again is what puts panel ① back (A-55).
///
/// The picture is not in here. It is the Shell's other stage, and N-32 is
/// explicit that it does not exist without a session: the old `RemoteScreen`
/// drew these same two cards over a black full-screen surface, which is how
/// Leo ended a session and was left looking at "只有一个 remote 菜单".
struct RemotePanelView: View {
    @ObservedObject var router: SurfaceRouter
    @ObservedObject var controller: RemoteSessionController
    let profile: HostProfile
    let hostName: String

    @EnvironmentObject private var home: HomeStore

    var body: some View {
        GeometryReader { proxy in
            PanelArea(Strings.panelRemote, identifier: "remote-entry-page") {
                // UX-2 §3. The session is the controller's `session`, never a
                // cache of it and never the panel's own memory: Leo summoned
                // this panel from a running picture and it offered him "Start
                // taking over". `router.stage == .picture` is the second half
                // of the same truth — the stage only exists while a session
                // does (N-32) — so the two cannot disagree about whether there
                // is something to go back to.
                if controller.hasSession || router.stage == .picture {
                    sessionCard(narrow: PanelMeasure.isNarrow(proxy.size.width))
                } else {
                    RemoteEntryCards(controller: controller, hostName: hostName,
                                     narrow: PanelMeasure.isNarrow(proxy.size.width),
                                     onStart: start)
                }
            }
        }
        .onAppear { controller.configure(profile: profile) }
        .onChange(of: profile) { _, next in controller.configure(profile: next) }
        .onChange(of: controller.phase) { _, phase in
            // The picture opens as soon as the host has accepted a session, not
            // when the first frame lands: the decoder draws into the stage's
            // render view, and that view is only in a window while the stage is
            // on screen. Waiting for a frame first is a deadlock.
            switch phase {
            case .connecting, .resizing, .streaming: router.enterPicture()
            default: break
            }
        }
    }

    /// N-32: `returnTo` is taken here — at the press, not when this panel opened.
    private func start() {
        router.rememberReturn()
        controller.start()
    }

    /// A-57. Four lines and two actions. "结束后回到" is the real destination,
    /// read off the router, not a promise.
    @ViewBuilder private func sessionCard(narrow: Bool) -> some View {
        SessionCard(title: Strings.remoteSessionRunning(controller.mode.title),
                    status: controller.isStreaming ? Strings.remoteStepConnected : nil,
                    lines: lines, narrow: narrow, identifier: "remote-session-card") {
            FlowButton(title: Strings.remoteResume, kind: .primary) { router.resumePicture() }
                .accessibilityIdentifier("remote-resume")
            InlineConfirm(title: Strings.remoteEnd(controller.mode.title),
                          confirmTitle: Strings.actionConfirmEnd,
                          identifier: "remote-end") {
                controller.stop()
            }
        }
        .padding(OmodachiTheme.rowPaddingX)
        if !controller.message.isEmpty {
            InlineError(message: controller.message, identifier: "remote-message")
        }
    }

    private var lines: [(String, String)] {
        var rows: [(String, String)] = [(Strings.remoteSessionHost, hostName)]
        if !controller.decoded.isEmpty {
            rows.append((Strings.remoteSessionBackend, "\(controller.backend.title) · \(controller.decoded)"))
        } else {
            rows.append((Strings.remoteSessionBackend, controller.backend.title))
        }
        rows.append((Strings.remoteSessionState, controller.statusText))
        rows.append((Strings.remoteSessionReturnTo, router.returnTo.title))
        return rows
    }
}
