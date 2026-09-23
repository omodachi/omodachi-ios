import SwiftUI

/// The registry's other half: which view a `PanelID` is.
///
/// It is one `switch` on purpose. N-38 wants the *list* of panels to be data —
/// so that a shell plugin synced from the host can add a row — and this is the
/// place a future factory would be looked up instead. What it must not become
/// is a second navigation model: there is one panel on screen, this builds it,
/// and nothing here decides which one.
struct PanelHost: View {
    let id: PanelID
    @ObservedObject var router: SurfaceRouter
    @ObservedObject var remote: RemoteSessionController
    @ObservedObject var directory: PairedHostDirectory
    @Binding var preferences: ShellPreferences

    @EnvironmentObject private var home: HomeStore
    @EnvironmentObject private var stores: SurfaceStores
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var registry: PanelRegistry

    var body: some View {
        switch id {
        case .menu:
            MenuPanelView(router: router, directory: directory, preferences: preferences)
        case .remote:
            RemotePanelView(router: router, controller: remote,
                            profile: home.profile, hostName: home.state.hostName)
        case .agent:
            AgentPanelView(store: stores.chat())
        case .herdr:
            HerdrPanelView(store: stores.herdr())
        case .ssh:
            SSHPanelView()
        case .settings:
            SettingsPanelView(directory: directory, registry: registry,
                              preferences: $preferences, router: router, remote: remote)
        case .notifications:
            NotificationsPanelView()
        }
    }
}
