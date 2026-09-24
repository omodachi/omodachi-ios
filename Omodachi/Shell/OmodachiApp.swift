import SwiftUI
import UIKit

@main
struct OmodachiApp: App {
    @StateObject private var home: HomeStore
    @StateObject private var stores: SurfaceStores
    @StateObject private var sessions: SessionStore
    @StateObject private var trust: HostTrustCoordinator

    init() {
        let defaults = DevelopmentLaunch.defaults()
        // PAIR-5: before anything reads a record, so the three cases are about
        // records that are already there when the Shell wakes up.
        DevelopmentLaunch.seedPairingFixture(defaults: defaults)
        let trust = HostTrustCoordinator()
        let home = HomeStore(defaults: defaults)
        let stores = SurfaceStores(home: home)
        home.onStateApplied = { [weak stores] in stores?.refreshShortcutContext() }
        _trust = StateObject(wrappedValue: trust)
        _home = StateObject(wrappedValue: home)
        _stores = StateObject(wrappedValue: stores)
        _sessions = StateObject(wrappedValue: SessionStore(defaults: defaults, trust: trust))
    }

    var body: some Scene {
        WindowGroup {
            ShellView()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .environmentObject(home)
                .environmentObject(stores)
                .environmentObject(sessions)
                .environmentObject(trust)
                .task { DevelopmentLaunch.configure(home: home) }
        }
    }
}

/// The Shell (ARCH-1 §1.3): one bar, one panel area, and — only while a session
/// is running — the picture with an overlay over it.
///
/// It decides nothing about how anything looks. Its whole job is:
///
/// * put the bar on a long edge and the panel area in the rest (A-02, A-49);
/// * ask `PanelRegistry` which panel the router says is current, and draw it;
/// * keep the picture and its overlay in the two states `SurfaceRouter` allows;
/// * hand the host's `panel.summon` to the router, which decides whether that
///   is an open, a switch or a dismissal (A-59);
/// * put a modal gate in front of everything when there is one (N-30 rev 5).
struct ShellView: View {
    @EnvironmentObject private var home: HomeStore
    @EnvironmentObject private var stores: SurfaceStores
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var trust: HostTrustCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var registry = PanelRegistry()
    @StateObject private var router: SurfaceRouter
    @StateObject private var remote = RemoteSessionController()
    @StateObject private var directory = PairedHostDirectory()
    /// PAIR-5 §2. Asks every host this device thinks it is paired with whether
    /// that is still true, before the Panel is allowed to be about it.
    @StateObject private var gate = HostCredentialGate()
    @State private var placement = NativeBarPlacement()
    @State private var windowInsets = EdgeInsets()
    @State private var windowSize = CGSize.zero
    @State private var preferences = ShellPreferences.load()

    init() {
        let registry = PanelRegistry()
        _registry = StateObject(wrappedValue: registry)
        _router = StateObject(wrappedValue: SurfaceRouter(registry: registry))
    }

    /// N-19 / N-30 rev 5: the unpaired first screen is a gate, not a panel. It
    /// has no bar, because there is no host for a bar to be about.
    ///
    /// PAIR-5 §2. Both halves of this condition are records in the app
    /// container — `omodachi.pairedHosts.v1` and `omodachi.profile.v1` — and a
    /// record is not a credential: it survives the host revoking this device
    /// and it survives `simctl keychain reset`, which is exactly how AGENT-2
    /// §9.4 ended up in a Panel it could not leave. `HostCredentialGate` is
    /// what keeps them honest: a host that refuses this device loses its
    /// record, and then this reads true again on its own.
    ///
    /// The `--ui-testing` clause is the hermetic run drawing the Panel over
    /// mock data with no host of its own. A launch that threw a credential away
    /// is never that run, so the clause cannot hide a rejection.
    private var needsPairing: Bool {
        // STORE-1 §1: the demo is the Panel over the demo profile, entered
        // from this very gate, and leaving it is how the gate comes back.
        if home.demoActive { return false }
        guard directory.records.isEmpty, home.profile.companionURL.isEmpty else { return false }
        if gate.discardedCredential { return true }
        let arguments = ProcessInfo.processInfo.arguments
        return !arguments.contains("--ui-testing") || arguments.contains("--unpaired")
    }

    var body: some View {
        Group {
            if needsPairing {
                // PAIR-5: the gate's one name. `ConnectionScreen` deliberately
                // no longer carries a second one — see the note at the bottom
                // of its body — so every walkthrough waits for the element
                // that is actually in the tree.
                ConnectionScreen(directory: directory, staleCredentialHosts: gate.discarded)
                    .environmentObject(home)
                    .accessibilityIdentifier("onboarding-gate")
            } else {
                paired
            }
        }
        .statusBarHidden(true).persistentSystemOverlays(.hidden)
        .background(OmodachiTheme.background.ignoresSafeArea())
        .foregroundStyle(OmodachiTheme.text)
        .preferredColorScheme(OmodachiTheme.current.mode == "light" ? .light : .dark)
        .tint(OmodachiTheme.accent)
        .environmentObject(registry)
        .environmentObject(directory)
        // PAIR-5 §2. One authenticated GET per remembered host, at launch, and
        // the same cleanup for a 401 that arrives later on the live connection.
        .task {
            home.onCredentialRejected = { [weak home] account in
                guard let home else { return }
                Task { await gate.hostRejected(account: account, directory: directory, home: home) }
            }
            await gate.check(directory: directory, home: home)
            // CORE-2 §1: a credential in its last week is renewed without
            // anyone seeing it - now, every time the app comes to the front
            // (`apply(_:)`), and every 12 hours for as long as it stays there.
            await gate.renewIfDue(directory: directory, home: home, force: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(HostCredentialGate.renewalInterval))
                guard !Task.isCancelled else { return }
                await gate.renewIfDue(directory: directory, home: home, force: true)
            }
        }
    }

    // MARK: - The two stages

    private var paired: some View {
        GeometryReader { proxy in
            Group {
                switch router.stage {
                case .panels: panelStage
                case .picture: pictureStage(size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(insetsReader)
        .ignoresSafeArea(.container)
        // N-30 rev 5. A certificate that changed, a pairing that expired, a
        // credential that stopped working: these are not places to go, they are
        // "you cannot go anywhere until this is settled". So they are the one
        // cover the Shell puts up over everything, the same shape as the
        // unpaired first screen — and ⑥'s host management is how you get back
        // to them afterwards.
        .fullScreenCover(item: Binding(get: { trust.request },
                                       set: { if $0 == nil { trust.resolve(accept: false) } })) { request in
            HostTrustView(challenge: request.challenge,
                          accept: { trust.resolve(accept: true) },
                          reject: { trust.resolve(accept: false) })
                .interactiveDismissDisabled()
                .statusBarHidden(true).persistentSystemOverlays(.hidden)
        }
        .task {
            stores.performLocalShortcut = performLocalShortcut
            stores.hostActionRan = { router.invokedHostAction() }
            // A-59 rev 5 / review #10. ⌘⇧M and ⌘⇧, are the hardware aliases
            // for the two icons on the host's own bar. They were wired to a
            // handler nobody had assigned, so both keys did nothing.
            // MENU-2 / A-67 adds one the picture answers itself: a tap on our
            // mark over the Omarchy logo is panel ①, which is the destination
            // the retired menu clone used to ask the host to recall. Panel ⑥
            // is not on this list — from the picture it is reached from our own
            // bar, and the host's own icon is the host's to answer.
            remote.onPanel = { source in
                router.consume(PanelSummon(sessionID: "", revision: 0,
                                           view: source == "keyboard_settings" ? .settings : .overview))
            }
            // A-64 / GEST-1. The picture recognises; the Shell runs the row,
            // because it is the only layer that holds both the host client and
            // the keybinding list the gesture is an alias of.
            remote.onGesture = { gesture in
                RemoteGestureRunner(home: home, shortcuts: stores.shortcut(), controller: remote).run(gesture)
            }
            registry.hostID = home.profile.companionURL
            openOperatorRemoteIfAuthorized()
            await resolveGestureBindings()
        }
        .onChange(of: home.profile) { _, profile in
            registry.hostID = profile.companionURL
            openOperatorRemoteIfAuthorized()
        }
        .onChange(of: scenePhase) { _, phase in apply(phase) }
        // N-09 / A-59: the host's three entries all arrive here as one
        // `panel.summon`, and the router decides what that means this time.
        .onChange(of: home.panelSummon) { _, summon in
            guard let summon else { return }
            router.consume(summon)
            home.panelSummon = nil
        }
        // REMOTE-4: the host rebuilt something under the session this device
        // is holding. The controller decides what that means; nothing here
        // routes on it, which is the point - the picture stays up.
        .onChange(of: home.remoteSessionChange) { _, change in
            guard let change else { return }
            remote.hostSessionChanged(change)
            home.remoteSessionChange = nil
        }
        // MENU-2: core measures the host's bar on the output this session owns,
        // and the picture uses it to answer the two icons locally.
        .onChange(of: home.barModel.geometry) { _, geometry in
            remote.applyBarGeometry(geometry)
        }
        // N-37. The alias follows the host: a workspace appearing or going away
        // and a fresh connection both change what the four gestures resolve to,
        // and a gesture with no row must stop being registered at that moment.
        //
        // Deliberately *not* `stateRevision`: that moves on every state frame,
        // and re-resolving an answer that has not changed on every frame is
        // work in the one place — the main actor, just after a tap — where the
        // app can least afford it. What the answer actually depends on is
        // whether the host is offering a selectable workspace at all.
        .onChange(of: home.barModel.workspaces.contains { $0.canSelect }) { _, _ in
            Task { await resolveGestureBindings() }
        }
        .onChange(of: home.companionConnected) { _, _ in Task { await resolveGestureBindings() } }
        .onChange(of: remote.hasSession) { _, live in
            router.hasSession = live
            Task { await resolveGestureBindings() }
            // N-32: the picture does not exist without a session, and all four
            // endings are this one.
            if !live, router.stage == .picture { router.endSession() }
        }
        .onChange(of: router.panelAreaVisible) { _, visible in
            // INPUT-2 is unchanged: the gate is closed for exactly as long as
            // something of ours is over the picture.
            remote.setPanelVisible(visible && router.stage == .picture)
        }
    }

    /// The app when nothing is streaming: a bar on a long edge, a panel in the
    /// rest, and A-12's toast beside the bar.
    private var panelStage: some View {
        BarEdgeLayout(edge: placement.edge) {
            bar
        } content: {
            panelArea
                .padding(SafeAreaLayoutPolicy.stage(edge: placement.edge, window: windowInsets))
        }
        .overlay(alignment: toastAlignment) {
            if let approval = home.approvals.request {
                // The same 26-high row the picture gets. It is not tappable:
                // the only way to answer is the system biometric sheet that is
                // already on screen, and a decline is that sheet's own cancel.
                RemoteToast(kind: .approval, message: approvalToastMessage(approval),
                            detail: Strings.approvalToastAsking) { }
                    .frame(maxWidth: 360)
                    .padding(toastInsets)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            } else if let row = home.notificationToast {
                HostNotificationToastView(notification: row)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(toastInsets)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: home.notificationToast)
    }

    /// A-58. The picture has no native chrome on it — with one exception, the
    /// 26-high toast, and one summoned layer: the bar plus a panel.
    private func pictureStage(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // MENU-2 / A-67: the picture carries our mark over the host bar's
            // Omarchy logo. It is a view above the stream, so it answers its own
            // tap and the picture keeps every other touch — including a tap on
            // the host's own Omodachi icon, which the host answers itself.
            RemoteStageView(controller: remote, profile: home.profile,
                            onBarMark: { remote.barMarkTapped($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(router.overlayVisible)

            if router.overlayVisible {
                // A-24/N-10: the host's own `[menu] scrim-alpha` behind the
                // layer, and the whole layer goes away on a tap on the picture.
                OmodachiTheme.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { router.dismissOverlay() }
                    .accessibilityLabel(Strings.remoteClosePanel)
                    .accessibilityIdentifier("panel-scrim")
                BarEdgeLayout(edge: placement.edge) {
                    bar
                } content: {
                    panelArea
                        .padding(SafeAreaLayoutPolicy.stage(edge: placement.edge, window: windowInsets))
                        .background(OmodachiTheme.background)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("remote-panel-overlay")
            } else {
                remoteToast.padding(remoteToastInsets)
                cornerHandle
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: router.overlayVisible)
    }

    /// MENU-2 / A-67. The fallback, and only the fallback.
    ///
    /// Our mark sits on the host bar's Omarchy logo, which is how
    /// `com.omodachi.menu` was retired. A bar the user has hidden leaves
    /// nowhere on the picture for it, and then the only ways back to a panel
    /// are a hardware keyboard and the host's own screen — which, in a takeover,
    /// is off. This is one 26 pt handle in the far corner, off by default,
    /// shown only when there is no mark on the picture.
    @ViewBuilder private var cornerHandle: some View {
        if preferences.cornerHandleWhenBarHidden, remote.needsCornerHandle {
            VStack { Spacer(); HStack { Spacer(); handleButton } }
                .padding(remoteToastInsets)
                .accessibilityIdentifier("remote-corner-handle")
        }
    }

    private var handleButton: some View {
        Tap(fill: OmodachiTheme.background) {
            router.consume(PanelSummon(sessionID: "", revision: 0, view: .overview))
        } label: {
            Glyph(symbol: Icon.menu.symbol, nerd: Icon.menu.nerd)
                .foregroundStyle(OmodachiTheme.text)
                .frame(width: 26, height: 26)
        }
        .accessibilityLabel(Strings.remoteCornerHandle)
    }

    // MARK: - Bar

    private var bar: some View {
        BarView(router: router,
                edge: placement.edge,
                contentInsets: SafeAreaLayoutPolicy.barContent(edge: placement.edge, window: windowInsets),
                available: SafeAreaLayoutPolicy.barExtent(edge: placement.edge, window: windowInsets,
                                                          size: windowSize),
                quickActions: quickActions,
                onQuickAction: perform,
                badgeStyle: preferences.badgeStyle,
                status: entryStatus)
        .environmentObject(registry)
        .contextMenu { edgeChoices }
    }

    /// A-60. The centre exists only while a session does.
    private var quickActions: [QuickActionState] {
        guard router.stage == .picture || remote.hasSession else { return [] }
        return QuickActionContext(
            hasSession: remote.hasSession,
            keyboardVisible: remote.keyboardVisible,
            rotationLocked: remote.rotationLocked,
            relativeTouchpad: remote.relativeTouchpad,
            backendHasAudio: remote.backendHasAudio,
            hostAudioAllowed: preferences.hostAudioPlayback,
            hostAudioOn: remote.hostAudioOn).states()
    }

    private func perform(_ action: QuickAction) {
        switch action {
        case .keyboard:
            remote.toggleKeyboard(closingOverlay: { router.dismissOverlay() })
        case .rotationLock:
            remote.toggleRotationLock()
        case .pointerMode:
            remote.relativeTouchpad.toggle()
        case .hostAudio:
            remote.setHostAudio(!remote.hostAudioOn)
        case .endSession:
            // A-57: ending is the session card's two-step confirmation, and this
            // is a shortcut *to* it — never a one-tap disconnect.
            router.openOverlay(.remote)
        }
    }

    /// A-58 rev 5 / D-17: what each entry says about itself.
    private func entryStatus(_ id: PanelID) -> (badge: BarBadge, dot: ThemeColorRole?, value: String?) {
        switch id {
        case .remote:
            let live = remote.hasSession
            return (.none, live ? .accent : nil, live ? Strings.badgeLive : nil)
        case .agent:
            let pending = stores.chat().model.approvals.filter(\.isPending).count
            return (preferences.badgeStyle.badge(count: pending, role: .yellow),
                    pending > 0 ? .red : nil,
                    pending > 0 ? Strings.badgePendingApprovals(Format.count(pending)) : nil)
        case .ssh:
            let dropped = sessions.runtimes.contains { $0.state == .failed || $0.state == .disconnected }
            return (.none, dropped ? .red : nil, dropped ? Strings.badgeDisconnected : nil)
        case .notifications:
            let unread = home.notifications.unreadCount
            return (preferences.badgeStyle.badge(count: unread, role: .accent), nil,
                    unread > 0 ? Strings.badgeUnread(Format.count(unread)) : nil)
        default:
            return (.none, nil, nil)
        }
    }

    @ViewBuilder private var edgeChoices: some View {
        if NativeBarMetrics.isVertical(placement.edge) {
            TextTap(Strings.barEdgeLeft) { chooseEdge(.left) }
            TextTap(Strings.barEdgeRight) { chooseEdge(.right) }
        } else {
            TextTap(Strings.barEdgeTop) { chooseEdge(.top) }
            TextTap(Strings.barEdgeBottom) { chooseEdge(.bottom) }
        }
    }

    private func chooseEdge(_ edge: HostBarPosition) {
        placement.choose(edge)
        preferences.barEdges = placement.preferences
        preferences.save()
    }

    // MARK: - Panel area

    /// A-55: one panel, filling the block. The registry owns which panels exist;
    /// this owns which one is on screen.
    private var panelArea: some View {
        VStack(spacing: 0) {
            // STORE-1 §1: on top of every panel for as long as the demo is on.
            if home.demoActive {
                DemoBanner(title: Strings.demoBanner, exitTitle: Strings.demoExit, exit: exitDemo)
            }
            PanelHost(id: router.panel, router: router, remote: remote,
                      directory: directory, preferences: $preferences)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// STORE-1 §1. The demo's SSH sessions are the demo's; they go with it,
    /// and the host list comes back.
    private func exitDemo() {
        let demo = sessions.runtimes.filter { $0.descriptor.host.mock && $0.descriptor.host.id == DemoHost.profileID }
        Task { for runtime in demo { await sessions.remove(runtime) } }
        home.exitDemo()
    }

    // MARK: - Remote's toast (A-58's one exception)

    @ViewBuilder private var remoteToast: some View {
        // GEST-1 §3. A gesture is something the user just did, so its row goes
        // above the three passive ones for the two seconds it is up. It is not
        // tappable: there is no panel it belongs to, and A-58 keeps the picture
        // free of anything that takes a touch it does not have to.
        if let toast = remote.gestureToast {
            PanelToastView(toast: toast)
                .allowsHitTesting(false)
                .transition(.opacity)
        } else if let approval = home.approvals.request {
            // AUTH-1 next: the host prompt this is about is blocking the very
            // desktop in the picture, and it expires on its own in under a minute.
            // `.approval`'s own tail says "tap to open Agent", which is the
            // wrong instruction for this one: the only way to answer is the
            // biometric sheet that is already on screen.
            RemoteToast(kind: .approval, message: approvalToastMessage(approval),
                        detail: Strings.approvalToastAsking) {
                router.openOverlay(.settings)
            }
        } else if let row = home.notificationToast {
            RemoteToast(kind: .notification, message: row.summary.isEmpty ? row.app : row.summary) {
                router.openOverlay(.notifications)
            }
        } else if stores.chat().model.approvals.contains(where: \.isPending) {
            RemoteToast(kind: .approval, message: Strings.remoteToastApprovalNeeded) {
                router.openOverlay(.agent)
            }
        } else if !home.companionConnected {
            RemoteToast(kind: .connection, message: Strings.remoteToastReconnecting(home.state.hostName)) {
                router.openOverlay(.remote)
            }
        }
    }

    /// What the 26-high row says while an approval is in flight. The host's own
    /// description of the prompt is drawn verbatim; the app's words are only
    /// the outcome, and only after there is one.
    private func approvalToastMessage(_ approval: HostApprovalRequest) -> String {
        switch home.approvals.stage {
        case .finished(.approved): return Strings.approvalToastApproved
        case .finished(.declined): return Strings.approvalToastDeclined
        case .finished(.timeout): return Strings.approvalToastTimeout
        case .failed(let message): return message
        default: return approval.detail
        }
    }

    private var remoteToastInsets: EdgeInsets {
        let gap = OmodachiTheme.space("sm")
        switch placement.edge {
        case .left: return .init(top: windowInsets.top + gap, leading: gap, bottom: 0, trailing: gap)
        case .right: return .init(top: windowInsets.top + gap, leading: gap, bottom: 0, trailing: gap)
        case .top: return .init(top: gap, leading: gap, bottom: 0, trailing: gap)
        case .bottom: return .init(top: windowInsets.top + gap, leading: gap, bottom: 0, trailing: gap)
        }
    }

    private var toastAlignment: Alignment {
        switch placement.edge {
        case .left: .topLeading
        case .right, .top: .topTrailing
        case .bottom: .bottomTrailing
        }
    }

    private var toastInsets: EdgeInsets {
        let bar = NativeBarMetrics.thickness + NativeBarMetrics.edgeRule
        switch placement.edge {
        case .left: return .init(top: windowInsets.top, leading: bar, bottom: 0, trailing: 0)
        case .right: return .init(top: windowInsets.top, leading: 0, bottom: 0, trailing: bar)
        case .top: return .init(top: bar, leading: 0, bottom: 0, trailing: windowInsets.trailing)
        case .bottom: return .init(top: 0, leading: 0, bottom: bar, trailing: windowInsets.trailing)
        }
    }

    // MARK: - Window

    private var insetsReader: some View {
        WindowInteractionInsetsReader(
            changed: { windowInsets = $0 },
            windowChanged: { size, corners in
                windowSize = size
                placement.update(width: size.width, height: size.height, reason: .windowGeometry)
                // A-61: the *window* is the viewport. The soft keyboard shrinks
                // the safe area, not the window, so it can never reach this and
                // can never make the host re-plan its output.
                remote.viewportChanged(size: size,
                                       orientation: size.width >= size.height ? "landscape_left" : "portrait", // non-copy: wire value
                                       corners: corners)
            })
        .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func apply(_ phase: ScenePhase) {
        let effect = SurfaceLifecyclePolicy.effects(phase == .active ? .active
                                                    : phase == .background ? .background : .inactive)
        if effect.disconnectRemote { remote.setForeground(false) }
        else if phase == .active { remote.setForeground(true) }
        // CLIP-1 §2. Coming to the front is the only moment iOS lets an app
        // read the pasteboard, so it is the only moment this device can push
        // one. The coordinator holds the request until the reconnect this same
        // transition starts has said whether the host wants it.
        if phase == .active { home.clipboard.appBecameActive() }
        // CORE-2 §1: coming to the front is one of the two moments a
        // credential is looked at (the other is the 12-hour timer).
        if phase == .active {
            Task { await gate.renewIfDue(directory: directory, home: home) }
        }
        guard let foreground = effect.foregroundConnections else { return }
        Task {
            await home.setForeground(foreground)
            sessions.setForeground(foreground)
        }
    }

    /// REMOTE-2 item 5. A keybinding row this app already has a control for runs
    /// that control, on this device. `false` means "not right now", and the row
    /// says so instead of doing nothing.
    /// N-37, evaluated. The keybinding list is the source for the two rows
    /// A-64 names, so it is loaded whether or not anyone has opened panel ①'s
    /// second half — a gesture that only worked after a visit to Keybindings
    /// would be a gesture nobody would find.
    private func resolveGestureBindings() async {
        let store = stores.shortcut()
        // A demo profile has no host to ask and no picture to gesture on, so
        // the list is left alone: the four gestures resolve to nothing, which
        // is exactly what ⑥ should say about a host that is not there.
        if !home.profile.mock {
            stores.refreshShortcutContext()
            if home.companionConnected, store.model.snapshot == nil, !store.model.loading {
                await store.refresh()
            }
        }
        remote.applyGestureBindings(RemoteGestureResolver.resolve(
            shortcuts: store.model.snapshot,
            workspacesSelectable: home.barModel.workspaces.contains { $0.canSelect }))
    }

    private func performLocalShortcut(_ capability: ShortcutGUIMap.Capability) -> Bool {
        switch capability {
        case .panel:
            router.consume(PanelSummon(sessionID: "", revision: 0, view: .overview))
            return true
        case .keybindings:
            router.consume(PanelSummon(sessionID: "", revision: 0, view: .keybindings))
            return true
        case let .workspace(id):
            guard home.companionConnected,
                  home.barModel.workspaces.contains(where: { $0.id == id && $0.canSelect }) else { return false }
            Task { await home.workspace(id) }
            return true
        }
    }

    private func openOperatorRemoteIfAuthorized() {
        if RemoteOperatorSupport.begin(profile: home.profile) {
            router.rememberReturn()
            router.enterPicture()
            remote.configure(profile: home.profile)
            remote.start()
        }
    }
}
