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
        let sessions = SessionStore(defaults: defaults, trust: trust)
        // TAIL-2 P0-4: every dial, a restored session's included, goes where
        // this host's terminal is now.
        sessions.hostResolver = { [weak home] stored in home?.resolveSSHHost(stored) ?? stored }
        _sessions = StateObject(wrappedValue: sessions)
        // NOTIFY-2: the notification delegate is the app's, set before the
        // first scene so a tap that launched the app is not lost, and the
        // alerts read the host connection's events whatever panel is up.
        AttentionNotifier.shared.install()
        home.attention = AttentionNotifier.shared
        // TUTORIAL-1: a UI-test launch asks for the tour by name.
        home.tour.startsByItself = DevelopmentLaunch.tourStartsByItself()
    }

    var body: some Scene {
        WindowGroup {
            // REMOTE-INPUT-2: the compose bar's UI-test harness (simulator,
            // DEBUG, an explicit launch flag); never in a release build.
            if RemoteComposeHarnessLaunch.requested {
                RemoteComposeHarnessLaunch.view()
            } else {
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
    /// HERDR-5: what the soft keyboard really covers (`KeyboardOverlapReader`).
    @State private var keyboardOverlap: CGFloat = 0
    @State private var windowSize = CGSize.zero
    /// DUO-1: the fold of an open foldable (`FoldReader`), nil elsewhere.
    @State private var fold: FoldLine?
    /// DUO-1 round 2: the side column the Remote picture keeps clear of.
    @State private var pictureColumn = RemotePictureColumn.none
    @State private var preferences = ShellPreferences.load()
    /// NOTIFY-2: the app's own alerts (for the Agent badge and the tap).
    @ObservedObject private var attention = AttentionNotifier.shared
    /// NOTIFY-2: the seconds the event stream is kept after leaving the front.
    @State private var grace = BackgroundGrace()
    /// NOTIFY-2: a tap on a Herdr alert, waiting for the surface to be ready.
    @State private var landing: Task<Void, Never>?

    init() {
        let registry = PanelRegistry()
        _registry = StateObject(wrappedValue: registry)
        _router = StateObject(wrappedValue: SurfaceRouter(registry: registry))
        // TUTORIAL-1 (WEB-14's finding): the bar starts on the edges this
        // device chose last time, from the hold menu or from Settings.
        let preferences = ShellPreferences.load()
        _preferences = State(initialValue: preferences)
        var placement = NativeBarPlacement()
        placement.preferences = preferences.barEdges
        _placement = State(initialValue: placement)
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
        // TAIL-3b I1: universal links and the omodachi:// scheme both arrive
        // here (LITE-0 §2: SwiftUI hands a universal link to onOpenURL).
        .onOpenURL { openLink($0) }
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
        .background(keyboardReader)
        .background(foldReader)
        // HERDR-5: the panels clear the keyboard UIKit says is on screen
        // (`SafeAreaLayoutPolicy.stage(…, keyboard:)`), not SwiftUI's keyboard
        // safe area, which kept a band of empty space after the keyboard went
        // away.
        //
        // POLISH-R item 7: the picture stage ignores it too. It used to keep
        // the keyboard safe area here, so this GeometryReader — and with it the
        // picture — came out shorter by the keyboard (on Leo's iPad with a
        // hardware keyboard, by the thin shortcuts bar: "the screen shrinks a
        // little"). `RemoteStageView.ignoresSafeArea(.keyboard)` cannot undo a
        // parent that already gave the space away, so the shorter rectangle
        // reached the viewport reader, and whether the host was then asked to
        // re-plan depended on a race with `keyboardVisible`. The keyboard is a
        // layer over the picture: the stage is the window, always, and the
        // summoned panel clears the keyboard itself, like the panels stage.
        .ignoresSafeArea([.container, .keyboard])
        // NOTIFY-1: a decision from an alert that could not be sent says why,
        // once, over whatever the tap landed on.
        .overlay(alignment: .top) { attentionNotice }
        // SHELL-FIX-1: every orientation decision below reads the window,
        // never the keyboard-avoided rectangle a panel is drawn in.
        .environment(\.windowSize, windowSize)
        .environment(\.fold, fold)
        // TUTORIAL-1: the tour reads where the bar and its entries are
        // (`tourAnchor`) and draws over the whole window, the bar included.
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            TourHost(tour: home.tour, router: router, registry: registry, anchors: anchors,
                     edge: placement.edge, insets: windowInsets)
        }
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
            // OVERVIEW-1: the list's Agent row lands on the Agent panel.
            stores.openPanel = { present($0) }
            configureLinks()
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
            // NOTIFY-2: where a tap lands, and whether a banner would only
            // repeat what is already on screen.
            attention.isShowing = { target in isShowing(target) }
            attention.onPermissionChanged = {
                Task { await home.reportPresence(foreground: UIApplication.shared.applicationState != .background) }
            }
            attention.onOpen = { target in route(target.link) }
            openOperatorRemoteIfAuthorized()
            await resolveGestureBindings()
        }
        .onChange(of: home.profile) { _, profile in
            registry.hostID = profile.companionURL
            openOperatorRemoteIfAuthorized()
        }
        .onChange(of: scenePhase) { _, phase in apply(phase) }
        // TUTORIAL-1 (WEB-14's finding): Settings' two Bar edge rows and the
        // bar's own hold menu write the same preference; the bar follows it.
        .onChange(of: preferences.barEdges) { _, edges in placement.apply(edges) }
        // LINKS-1: a link's line belongs to the panel it was tapped in.
        .onChange(of: router.panel) { _, _ in stores.links.panelChanged() }
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
        // TAIL-2 P2-2: a reconnect or a road change can turn a direct tailnet
        // path into a relayed one (or back); the Remote entry's answer about
        // it is read again rather than kept from the first configure.
        .onChange(of: home.road) { _, road in
            guard road != nil else { return }
            Task { await remote.refreshEntryCapabilities() }
        }
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
                .padding(SafeAreaLayoutPolicy.stage(edge: placement.edge, window: windowInsets,
                                                    keyboard: keyboardOverlap))
        }
        .padding(.bottom, SafeAreaLayoutPolicy.keyboardLift(keyboardOverlap))
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
            // REMOTE-INPUT-2: exactly the window, never "as large as the
            // stack". A panel summoned while a keyboard is still sliding away
            // is taller than what is left above the keyboard, and with
            // `maxHeight: .infinity` the picture grew with the stack (402×890…
            // 962 in a 402×874 window on the host run) — a size a takeover
            // would have re-planned the host's output for.
            // DUO-1 round 2: beside a side column the system keeps, not under
            // it (`RemotePictureColumn`); the column itself is letterbox.
            OmodachiTheme.pictureLetterbox
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
            RemoteStageView(controller: remote, profile: home.profile,
                            onBarMark: { remote.barMarkTapped($0) })
                .frame(width: pictureColumn.picture(size).width, height: size.height)
                .padding(.leading, pictureColumn.leading)
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
                        .padding(SafeAreaLayoutPolicy.stage(edge: placement.edge, window: windowInsets,
                                                            keyboard: keyboardOverlap))
                        .background(OmodachiTheme.background)
                }
                .padding(.bottom, SafeAreaLayoutPolicy.keyboardLift(keyboardOverlap))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("remote-panel-overlay")
            } else {
                remoteToast.padding(remoteToastInsets)
                cornerHandle
                composeBar
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: router.overlayVisible)
    }

    /// REMOTE-INPUT-2. The keyboard's top row: the compose field and Send,
    /// the keys row and the two switches. An overlay on the keyboard's top
    /// edge (or the bottom of the window when a hardware keyboard leaves no
    /// keyboard on screen): the picture under it keeps its size, so the host
    /// never re-plans for it (A-61).
    @ViewBuilder private var composeBar: some View {
        if remote.keyboardVisible, remote.hasSession {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RemoteComposeBar(controller: remote)
                    .padding(.leading, windowInsets.leading)
                    .padding(.trailing, windowInsets.trailing)
                    .padding(.bottom, keyboardOverlap > 0 ? 0 : windowInsets.bottom)
                    .background(OmodachiTheme.barBackground)
            }
            .padding(.bottom, SafeAreaLayoutPolicy.keyboardLift(keyboardOverlap))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
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
                status: entryStatus,
                edgeMenu: AnyView(edgeChoices))
        .environmentObject(registry)
        .tourAnchor(TourStep.bar.anchor)
    }

    /// A-60. The centre exists only while a session does.
    private var quickActions: [QuickActionState] {
        guard router.stage == .picture || remote.hasSession else { return [] }
        return QuickActionContext(
            hasSession: remote.hasSession,
            keyboardVisible: remote.keyboardVisible,
            relativeTouchpad: remote.relativeTouchpad,
            backendHasAudio: remote.backendHasAudio,
            hostAudioAllowed: preferences.hostAudioPlayback,
            hostAudioOn: remote.hostAudioOn).states()
    }

    private func perform(_ action: QuickAction) {
        switch action {
        case .keyboard:
            remote.toggleKeyboard(closingOverlay: { router.dismissOverlay() })
        case .pointerMode:
            remote.relativeTouchpad.toggle()
        case .hostAudio:
            remote.setHostAudio(!remote.hostAudioOn)
        }
    }

    /// NOTIFY-2 (RESEARCH-2 §4 #8). The Agent chat keeps its approval list
    /// current only while the Agent panel is up; off it the list froze and the
    /// badge with it. So off the panel the count is what the host's own
    /// `agent.changed` says: one approval waiting, or none.
    private var agentApprovalsPending: Int {
        let chat = stores.chat()
        if chat.isObserving { return chat.model.approvals.filter(\.isPending).count }
        if home.profile.mock || home.demoActive { return chat.model.approvals.filter(\.isPending).count }
        return attention.agentStatus == "waiting_on_approval" ? 1 : 0 // non-copy: wire value
    }

    /// A-58 rev 5 / D-17: what each entry says about itself.
    private func entryStatus(_ id: PanelID) -> (badge: BarBadge, dot: ThemeColorRole?, value: String?) {
        switch id {
        case .remote:
            let live = remote.hasSession
            return (.none, live ? .accent : nil, live ? Strings.badgeLive : nil)
        case .agent:
            let pending = agentApprovalsPending
            // NOTIFY-1: finished with nobody looking is a quiet dot, never a count.
            let unseen = pending == 0 && attention.unseen?.agent == true
            return (preferences.badgeStyle.badge(count: pending, role: .yellow),
                    pending > 0 ? .red : unseen ? .accent : nil,
                    pending > 0 ? Strings.badgePendingApprovals(Format.count(pending)) : unseen ? Strings.badgeUnseen : nil)
        case .herdr:
            // OVERVIEW-1: a red count of the panes waiting for you, in every
            // session (blocked only: finished is never a count).
            let waiting = home.overviewShown.herdrNeedsYou
            // NOTIFY-1: an agent in Herdr finished and nobody has had its pane open.
            let unseen = attention.unseen.map { !$0.herdr.isEmpty } ?? false
                || home.overviewShown.rows.contains { $0.source == .herdr && $0.state == .done }
            return (preferences.badgeStyle.badge(count: waiting, role: .red),
                    waiting > 0 ? .red : unseen ? .accent : nil,
                    waiting > 0 ? Strings.badgeNeedsYou(Format.count(waiting)) : unseen ? Strings.badgeUnseen : nil)
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
                // POLISH-U: the link notice lies over the panel's content,
                // under its header - never above it in the stack, where it
                // pushed the panel down and, with the keyboard up or a phone
                // on its side, squeezed the panel until its composer had no
                // height at all.
                .linkNotice(stores.links)
                // HERDR-11 §3: the one connection clock, over every panel.
                .overlay(alignment: .top) {
                    ConnectionBanner(health: home.health, message: home.healthMessage,
                                     retry: { home.retryConnectionNow() })
                        .padding(.top, OmodachiTheme.space("sm"))
                        .padding(.horizontal, OmodachiTheme.space("lg"))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: home.health)
                }
        }
    }

    /// LINKS-1. The opener decides; the Shell is what can present the Safari
    /// view, route the app's own links and start and show Remote.
    private func configureLinks() {
        let links = stores.links
        links.hooks.client = {
            guard !home.profile.mock, !home.demoActive else { return nil }
            return try? home.chatClient(for: home.profile.companionURL)
        }
        links.hooks.roads = {
            HostLocalLinks(current: home.road ?? home.hostRoad, known: home.hostPin?.roads ?? [],
                           hostName: home.profile.hostname)
        }
        // Never Safari itself: the page opens over the app (LINKS-1 §1).
        links.hooks.presentWeb = { url in InAppBrowser.open(url) }
        links.hooks.routeApp = { url in openLink(url) }
        links.hooks.openSystem = { url in UIApplication.shared.open(url) }
        links.hooks.hasRemoteSession = { remote.hasSession }
        links.hooks.extendIsDefault = { remote.mode == .extend }
        links.hooks.startRemote = {
            guard !home.profile.mock, !home.demoActive, !remote.hasSession else { return false }
            // The same press as the Remote entry's card: ending the session
            // comes back to the panel the link was tapped in (N-32).
            router.rememberReturn()
            router.show(.remote)
            remote.configure(profile: home.profile)
            remote.start()
            return remote.phase.isBusy
        }
        links.hooks.waitForRemote = { limit in
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                switch remote.phase {
                case .connecting, .streaming, .resizing: return true
                case .idle, .failed: return false
                case .creating, .stopping: break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        links.hooks.showRemotePanel = { router.show(.remote) }
        links.hooks.showPicture = { router.resumePicture() }
        // SSH: web addresses only — the terminal may be another machine.
        sessions.openWebLink = { url in links.open(.web(url), from: .ssh) }
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
        } else if agentApprovalsPending > 0 {
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
            windowChanged: { size, corners, column in
                windowSize = size
                pictureColumn = column
                placement.update(width: size.width, height: size.height, reason: .windowGeometry)
                // A-61: the *window* is the viewport. The soft keyboard shrinks
                // the safe area, not the window, so it can never reach this and
                // can never make the host re-plan its output. DUO-1 round 2:
                // less a side column the system keeps (`RemotePictureColumn`).
                let picture = column.picture(size)
                remote.viewportChanged(size: picture,
                                       orientation: picture.width >= picture.height ? "landscape_left" : "portrait", // non-copy: wire value
                                       corners: column.corners(corners), source: "window") // non-copy: a trace source
            })
        // TUTORIAL-1: as large as the window, not 0×0. A 0×0 view gets no
        // layout pass when the window turns, and an iPad's safe area is the
        // same either way up, so an iPad rotated with the app open kept a
        // portrait bar in landscape. At the window's size it is laid out
        // again on every turn, and that is when it reads the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false).accessibilityHidden(true)
    }

    /// DUO-1. As large as the window, for the same reason as the insets
    /// reader: a fold or a turn lays it out again.
    private var foldReader: some View {
        FoldReader(changed: { fold = $0 }, hinge: { remote.hingeChanged(open: $0) })
            .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false).accessibilityHidden(true)
    }

    private var keyboardReader: some View {
        KeyboardOverlapReader { overlap, duration in
            RemoteSessionTrace.composeBar("keyboard_overlap=\(Int(overlap))") // non-copy: a trace value
            withAnimation(.easeOut(duration: duration)) { keyboardOverlap = overlap }
        }
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
        if foreground {
            // Back before the grace ran out: the stream is still open, so core
            // is told the app is in front again; otherwise the reconnect says it.
            let kept = grace.cancel()
            Task {
                await home.setForeground(true)
                sessions.setForeground(true)
                await attention.refreshPermission()
                if kept { await home.reportPresence(foreground: true) }
            }
            return
        }
        // NOTIFY-2 (was TAIL-3b I3). Core no longer learns "the App left" from
        // the stream closing: presence says it, at once. The stream is kept
        // for the seconds iOS allows, so an alert can still ring in them, and
        // then closed with a close frame as before.
        sessions.setForeground(false)
        grace.begin(announce: { await home.reportPresence(foreground: false) },
                    close: { await home.setForeground(false) })
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

    /// TAIL-3b I1. A link names a host by its id; only this device's own
    /// paired list answers it. An unknown one is a sentence, never a pairing.
    private func openLink(_ url: URL) {
        guard let link = AppLink.parse(url) else { return }
        route(link)
    }

    /// NOTIFY-2. A link and a notification tap land the same way: on that
    /// computer, on its Agent panel or its Herdr surface, and for Herdr on
    /// that session and pane.
    private func route(_ link: AppLink) {
        // ODOMO-CARD: a link from Odomo naming a paired host says Odomo is on
        // this device for it; the Notifications card stops offering it.
        if let hostID = OdomoOffer.learnsHere(from: link, records: directory.records,
                                              onMac: ProcessInfo.processInfo.isiOSAppOnMac) {
            AppLinkTrace.note("link from odomo host=\(hostID.suffix(6))") // non-copy: a log line
            home.learnOdomoHere(hostID)
        }
        let current = home.profile.mock || home.profile.companionURL.isEmpty ? nil : home.profile.companionURL
        switch link.resolve(records: directory.records, current: current) {
        case .home:
            // LITE-1c: "Get the app" / "Open the app" with no host: the app
            // comes to the front at home (①), or on the first screen.
            AppLinkTrace.note("link app") // non-copy: a log line
            home.linkMessage = nil
            if !needsPairing, !router.hasSession { router.show(.menu) }
        case .unknownHost:
            AppLinkTrace.note("link \(link.target.rawValue) unknown-host") // non-copy: a log line
            // Said where it stays readable: on the first screen, or at the
            // top of ①, until it is dismissed or another link lands.
            home.linkMessage = Strings.linkUnknownHost
            if !needsPairing { router.show(.menu) }
        case let .open(record, target):
            AppLinkTrace.note("link \(target.rawValue) host=\(record.hostID.suffix(6))") // non-copy: a log line
            home.linkMessage = nil
            if home.demoActive { exitDemo() }
            let elsewhere = HostAccount.canonical(record.account) != HostAccount.canonical(home.profile.companionURL)
            if elsewhere, router.hasSession, target == .agent || target == .herdr {
                // The picture is another computer's: its Agent or Herdr would
                // be the wrong place, and a Remote session is not ended by a tap.
                home.linkMessage = Strings.attentionAfterRemote(record.hostName.isEmpty ? record.account : record.hostName)
                present(.menu)
                return
            }
            if elsewhere, !router.hasSession {
                var profile = home.profile
                profile.companionURL = record.account
                profile.mock = false
                if !record.hostName.isEmpty { profile.hostname = record.hostName }
                home.profile = profile
                Task { await home.connectCompanion() }
            }
            switch target {
            case .agent: present(.agent)
            case .herdr:
                present(.herdr)
                if let session = link.session {
                    landing?.cancel()
                    landing = Task { await HerdrLanding.land(store: stores.herdr(), home: home,
                                                             session: session, pane: link.pane) }
                }
            default: router.show(target == .remote ? .remote : .menu)
            }
        }
    }

    /// Over the picture, a panel is the summoned layer; otherwise it is the panel.
    private func present(_ panel: PanelID) {
        if router.stage == .picture { router.openOverlay(panel) } else { router.show(panel) }
    }

    @ViewBuilder private var attentionNotice: some View {
        if let notice = attention.notice {
            HStack(alignment: .top, spacing: 10) {
                Text(notice)
                    .font(OmodachiTheme.bodyFont("body-small"))
                    .foregroundStyle(OmodachiTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("attention-notice-text")
                Spacer(minLength: 0)
                FlowButton(title: Strings.whereDone, kind: .secondary) { attention.notice = nil }
                    .frame(maxWidth: 110)
                    .accessibilityIdentifier("attention-notice-done")
            }
            .padding(12)
            .background(ZStack { OmodachiTheme.background; OmodachiTheme.normalFill })
            .overlay(alignment: .leading) { Rectangle().fill(OmodachiTheme.accent).frame(width: 3) }
            .padding(.horizontal, 12)
            .padding(.top, max(12, windowInsets.top))
            .frame(maxWidth: 560)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("attention-notice")
        }
    }

    /// NOTIFY-2: the person is already looking at exactly this place, on this
    /// computer, so a banner would only say it twice.
    private func isShowing(_ target: AttentionTarget) -> Bool {
        guard router.stage == .panels || router.overlayVisible,
              home.hostPin?.hostID == target.hostID else { return false }
        switch target.kind {
        case .agentApproval, .agentNeedsInput, .agentFinished:
            return router.panel == .agent
        case .herdrBlocked, .herdrFinished:
            let herdr = stores.herdr()
            return router.panel == .herdr && herdr.selectedSession == target.session && herdr.selected == target.pane
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
