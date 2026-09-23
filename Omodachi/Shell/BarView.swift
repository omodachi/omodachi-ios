import SwiftUI

/// The app's one bar (A-49). Not Omarchy's bar ported: Omarchy's bar is a
/// configuration that lives on a physical screen, and this one is our own
/// controller, on whichever long edge *this* device is holding (A-02).
///
/// Three segments, in the host's own order (`Bar.qml`'s `layout.left / center /
/// right`):
///
/// * **left** — the Omodachi logo (panel ①), the 6px connection dot (A-37) and
///   the workspaces. The workspaces stay here in portrait too; Leo: "侧边反而比
///   横向控件更充足".
/// * **centre** — empty, except under Remote, where it is A-60's five quick
///   actions. It is the only segment whose contents depend on context.
/// * **right** — the panel entries the registry has enabled (A-50). This is the
///   only place in the app they appear.
///
/// What is *not* here is as decided as what is: no clock, battery, network,
/// volume, tray, weather, keyboard layout or updates (A-49's table), no focused
/// window and no indicator segment (A-53).
///
/// ICON-1 asked whether the focused window should come back here now that the
/// host publishes its icon (`state.focus.icon`). It should not, twice over:
/// `NavigationUITests` asserts `bar-focus` does not exist — A-49/A-50/A-52
/// deleted it — and Leo's own `~/.config/omarchy/shell.json` has no
/// `omarchy.active-window` in any segment, so there is no host item to be
/// consistent with. The icon is published and carried
/// (`HostBarModel.focusedApp`) for whatever surface wants it; this bar does
/// not.
struct BarView: View {
    @EnvironmentObject private var home: HomeStore
    @EnvironmentObject private var registry: PanelRegistry
    @ObservedObject var router: SurfaceRouter

    let edge: HostBarPosition
    var contentInsets = EdgeInsets()
    /// The bar's own long edge, already minus what the window reserves.
    let available: CGFloat
    /// A-60. Empty off Remote; five while a session is up.
    var quickActions: [QuickActionState] = []
    let onQuickAction: (QuickAction) -> Void
    /// The badge style (Study 04 §7 open question 1), read from Settings.
    var badgeStyle: BarBadgeStyle = .dot
    /// What each entry has to say for itself: a badge and a dot.
    var status: (PanelID) -> (badge: BarBadge, dot: ThemeColorRole?, value: String?) = { _ in (.none, nil, nil) }

    @State private var overflowOpen = false

    private var vertical: Bool { NativeBarMetrics.isVertical(edge) }
    private var workspaces: [BarWorkspace] { NativeWorkspacePolicy.visible(home.barModel.workspaces) }
    private var occupied: Set<Int> {
        Set(workspaces.filter { $0.occupied == true || $0.active == true }.map(\.id))
    }
    private var plan: BarMetrics.Plan {
        BarMetrics.plan(available: available, workspaces: workspaces.map(\.id), occupied: occupied,
                        entries: registry.barEntries.count,
                        actions: quickActions.map(\.action))
    }

    var body: some View {
        let plan = plan
        BarSurface(edge: edge, contentInsets: contentInsets) {
            leading(plan)
        } centre: {
            centre(plan)
        } trailing: {
            trailing
        }
        .overlay(alignment: vertical ? .bottomLeading : .bottomTrailing) {
            if overflowOpen, !plan.overflowActions.isEmpty { overflowRow(plan) }
        }
    }

    // MARK: - Left

    @ViewBuilder private func leading(_ plan: BarMetrics.Plan) -> some View {
        BarSlot(state: router.panel == .menu && router.panelAreaVisible ? .selected : .idle,
                label: Strings.barLogoLabel,
                value: router.panel == .menu && router.panelAreaVisible ? Strings.barLogoOpen : Strings.barLogoClosed,
                identifier: "open-panel", vertical: vertical,
                action: { router.tapLogo() }) {
            OmodachiSymbol.view(size: NativeBarMetrics.glyph)
        }
        BarConnectionDot(role: connectionRole, label: connectionLabel, vertical: vertical)
        workspaceSegment(plan)
    }

    /// N-16 / `Workspaces.qml 20–31`: the fixed five plus whatever exists. The
    /// ladder may shorten the collection (A-60) but never folds it into a panel.
    @ViewBuilder private func workspaceSegment(_ plan: BarMetrics.Plan) -> some View {
        let rows = workspaces.filter { plan.workspaces.contains($0.id) }
        let buttons = BarWorkspaceButtons(
            workspaces: rows, vertical: vertical,
            // A-66 (UX-2 §4): the square runs on the host, so the picture
            // comes back as soon as it has been asked.
            onSelect: { id in
                Task { await home.workspace(id) }
                router.invokedHostAction()
            },
            onMoveFocusedWindow: { id in Task { await home.moveFocusedWindow(to: id) } })
        if plan.scrollsWorkspaces {
            // Study 04 §7 open question 2. One screen in the whole study cannot
            // hold the bar, and this is the least bad thing to give: the entries
            // and the centre stay put and the squares scroll.
            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                if vertical { VStack(spacing: 0) { buttons } } else { HStack(spacing: 0) { buttons } }
            }
            .accessibilityLabel(Strings.barWorkspaces)
        } else if vertical {
            VStack(spacing: 0) { buttons }.accessibilityLabel(Strings.barWorkspaces)
        } else {
            HStack(spacing: 0) { buttons }.accessibilityLabel(Strings.barWorkspaces)
        }
    }

    private var connectionRole: ThemeColorRole {
        // PAIR-5 §2: a host that is not answering is grey for as long as that
        // is true, including while the bounded reconnect is between tries.
        if home.hostOffline { return .muted }
        switch home.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .unavailable: return .red
        // PAIR-5 §2: a host that is simply not there is grey. Red is reserved
        // for a host that answered and this device could not use the answer.
        case .disconnected, .suspended, .offline: return .muted
        }
    }

    private var connectionLabel: String {
        switch home.connectionState {
        case .connected: Strings.barConnectionConnected
        case .connecting: Strings.barConnectionConnecting
        case .reconnecting: Strings.barConnectionReconnecting
        case .unavailable: Strings.barConnectionUnavailable
        case .offline: Strings.barConnectionOffline
        case .suspended: Strings.barConnectionSuspended
        case .disconnected: Strings.barConnectionDisconnected
        }
    }

    // MARK: - Centre

    @ViewBuilder private func centre(_ plan: BarMetrics.Plan) -> some View {
        ForEach(plan.visibleActions) { action in
            if let state = quickActions.first(where: { $0.action == action }) {
                quickSlot(state, extent: plan.centreSlot)
            }
        }
        if !plan.overflowActions.isEmpty {
            BarSlot(icon: Icon.more, state: overflowOpen ? .selected : .idle,
                    label: Strings.barMore,
                    value: plan.overflowActions.map(\.title).joined(separator: "、"),
                    identifier: "quick-more", extent: plan.centreSlot, vertical: vertical,
                    action: { overflowOpen.toggle() })
        }
    }

    private func quickSlot(_ state: QuickActionState, extent: CGFloat) -> some View {
        BarSlot(icon: state.action.icon(on: state.on),
                state: state.enabled ? (state.on ? .selected : .idle) : .unavailable,
                label: state.action.title,
                value: state.action.value(on: state.on, enabled: state.enabled, reason: state.reason),
                identifier: "quick-\(state.action.rawValue)",
                extent: extent, vertical: vertical,
                action: { onQuickAction(state.action) })
    }

    /// A-60's `…`: a 26-high row inside the bar, gone the moment a panel opens.
    private func overflowRow(_ plan: BarMetrics.Plan) -> some View {
        let row = ForEach(plan.overflowActions) { action in
            if let state = quickActions.first(where: { $0.action == action }) {
                quickSlot(state, extent: 26)
            }
        }
        return Group {
            if vertical { VStack(spacing: 0) { row } } else { HStack(spacing: 0) { row } }
        }
        .background(OmodachiTheme.barBackground)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder,
                                          lineWidth: OmodachiTheme.controlBorderWidth))
        .offset(x: vertical ? NativeBarMetrics.thickness : 0,
                y: vertical ? 0 : -NativeBarMetrics.thickness)
        .accessibilityIdentifier("quick-overflow")
        .onChange(of: router.panel) { _, _ in overflowOpen = false }
    }

    // MARK: - Right

    @ViewBuilder private var trailing: some View {
        ForEach(registry.barEntries) { entry in
            let reading = status(entry.id)
            BarSlot(state: router.panel == entry.id && router.panelAreaVisible ? .selected : .idle,
                    badge: reading.badge, dot: reading.dot,
                    label: entry.title, value: reading.value,
                    identifier: identifier(for: entry.id),
                    vertical: vertical,
                    action: { router.tapEntry(entry.id) }) {
                // ③ and ④ are windows onto somebody else's product, so they
                // carry that vendor's own mark, monochromed to the bar's
                // foreground like every other glyph in this row.
                BrandGlyph(mark: entry.brand(provider: home.state.defaultAgentKind),
                           fallback: entry.icon, points: NativeBarMetrics.glyph)
            }
        }
    }

    /// The identifiers the acceptance walk and the UI tests reach for. They are
    /// the entry's own name, not its position, so turning one off does not
    /// renumber the rest.
    private func identifier(for id: PanelID) -> String {
        switch id {
        case .menu: "open-panel"
        case .remote: "open-remote"
        case .agent: "open-agent"
        case .herdr: "open-herdr"
        case .ssh: "open-ssh"
        case .settings: "open-setup"
        case .notifications: "open-notifications"
        }
    }
}

/// Puts the bar on one edge and the content in the rest, for any of the four
/// edges, without each caller repeating the switch.
struct BarEdgeLayout<Bar: View, Content: View>: View {
    let edge: HostBarPosition
    @ViewBuilder var bar: () -> Bar
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch edge {
        case .top: VStack(spacing: 0) { bar(); content() }
        case .bottom: VStack(spacing: 0) { content(); bar() }
        case .left: HStack(spacing: 0) { bar(); content() }
        case .right: HStack(spacing: 0) { content(); bar() }
        }
    }
}
