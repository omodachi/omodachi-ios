import SwiftUI

/// Panel ⑤ — SSH (A-56 "work surface", A-57, A-63).
///
/// A-57 applies here as much as to Remote: with sessions open the panel is the
/// sessions. A-63 settles what it is with none — Leo: "为什么 ssh 还需要有个
/// open terminal 的界面". Entering a panel *is* the ensure. There was a page
/// here that said "这台设备还没有开 SSH 会话。" and offered a button to do the
/// one thing the user had already asked for by opening the panel; it is gone,
/// with its two strings. Opening ⑤ dials the paired host, shows one 26-high
/// progress row while it does, and lands in the shell.
///
/// The reconnect affordance is kept for the one state that needs a decision: a
/// session that failed or ended, where `TerminalContent` draws a line saying
/// what a reconnect would be and the control that does it.
struct SSHPanelView: View {
    @EnvironmentObject private var home: HomeStore
    @EnvironmentObject private var sessions: SessionStore
    @State private var selected: UUID?

    private var runtimes: [TerminalRuntime] { sessions.runtimes }

    var body: some View {
        Group {
            if let id = selected ?? runtimes.first?.id, sessions.runtime(id: id) != nil {
                TerminalSurface(runtimeID: id,
                                onSelectSession: { selected = $0 })
            } else {
                // The one frame between entering and the runtime existing.
                // D-15: it spins because something really is in flight.
                ProgressRow(title: Strings.sshConnecting(home.sshProfile.hostname),
                            identifier: "ssh-connecting")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(OmodachiTheme.background)
            }
        }
        .onAppear {
            if selected == nil { selected = runtimes.first?.id }
            // A-63: no question, no button. The panel is the request.
            if selected == nil || sessions.runtime(id: selected!) == nil { open() }
        }
    }

    private func open() {
        let runtime = sessions.create(SurfaceRouteTargets.shell(host: home.sshProfile,
                                                                title: Strings.sshTerminal, argv: []))
        selected = runtime.id
    }
}
