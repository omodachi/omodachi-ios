import SwiftUI

/// Panel ① — the Omarchy menu and the Keybindings list (N-31, A-54, N-39).
///
/// They are two halves of one panel, not two destinations: **landscape puts
/// them side by side, portrait folds them behind a segmented control that lives
/// in the 44-high title row** (rev 4 — that row used to cost its own 44, which
/// on a phone is three menu rows).
///
/// rev 5 adds the necessary condition A-54 was missing: side by side needs the
/// orientation *and* a panel area at least 360 + 5 + 420 = 785 wide, because
/// `UIRequiresFullScreen=false` means a landscape window can be 320 points wide
/// under Stage Manager. Portrait always folds, even at the iPad's 790, so that
/// turning the device does something predictable.
///
/// Each half has its own `PINNED` group at the top (N-39), its own search and
/// its own scroll (A-31).
struct MenuPanelView: View {
    @ObservedObject var router: SurfaceRouter
    @ObservedObject var directory: PairedHostDirectory
    /// CLIP-1 §1. Only one field is read — whether the rows the host says
    /// cannot run here are in the list — and it is read rather than bound
    /// because this panel never writes a preference; ⑥ does.
    var preferences = ShellPreferences()
    @EnvironmentObject private var home: HomeStore
    @EnvironmentObject private var stores: SurfaceStores
    @EnvironmentObject private var sessions: SessionStore
    @Environment(\.horizontalSizeClass) private var horizontal
    /// SHELL-FIX-1: which way up is the window's answer, not this panel's.
    @Environment(\.windowSize) private var windowSize
    /// DUO-1: the fold of an open foldable, nil elsewhere.
    @Environment(\.fold) private var fold

    @State private var editingMenuPins = false
    @State private var editingKeyPins = false
    @State private var pins: [PanelPin] = []
    /// STORE-6 §A3: the demo's pins live in a suite of their own that entering
    /// the demo seeds (`DemoHost.seedPins`), filed under an id no computer has.
    private var store: PanelPinStore { home.demoActive ? DemoHost.pinStore : PanelPinStore() }

    private var hostID: String {
        home.demoActive ? DemoHost.pinHostID : home.hostPin?.hostID ?? home.profile.companionURL
    }

    var body: some View {
        GeometryReader { proxy in
            let landscape = PanelMeasure.isLandscape(window: windowSize, area: proxy.size)
            let sideBySide = PanelMeasure.sideBySide(landscape: landscape, width: proxy.size.width)
            // DUO-1: an open foldable divides ① at the fold (variant B).
            let split = PanelMeasure.foldSplit(fold, panel: proxy.frame(in: .global))
            Group {
                if let split {
                    foldHalves(split, size: proxy.size)
                } else if sideBySide {
                    HStack(spacing: 0) {
                        menuHalf(width: PanelMeasure.menuColumn, showsSegments: false)
                            .frame(width: PanelMeasure.menuColumn)
                        Rectangle().fill(OmodachiTheme.border)
                            .frame(width: NativeBarMetrics.edgeRule)
                            .accessibilityHidden(true)
                        keybindingsHalf(showsSegments: false)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    switch router.column {
                    case .menu: menuHalf(width: proxy.size.width, showsSegments: true)
                    case .keybindings: keybindingsHalf(showsSegments: true)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-panel")
        .task { reloadPins() }
        .onChange(of: home.profile) { _, _ in reloadPins() }
        .onChange(of: home.demoActive) { _, _ in reloadPins() }
        .onChange(of: home.menu) { _, _ in refreshLabels() }
    }

    // MARK: - DUO-1: the halves at the fold

    /// The menu in one half of the screen and Keybindings in the other, with
    /// the rule on the fold. Each half is the same view as side by side, so its
    /// search, pins and scroll are its own.
    @ViewBuilder private func foldHalves(_ split: FoldSplit, size: CGSize) -> some View {
        let rule = NativeBarMetrics.edgeRule
        switch split {
        case .columns(let lead):
            HStack(spacing: 0) {
                menuHalf(width: lead - rule / 2, showsSegments: false)
                    .frame(width: max(0, lead - rule / 2))
                Rectangle().fill(OmodachiTheme.border)
                    .frame(width: rule)
                    .accessibilityHidden(true)
                keybindingsHalf(showsSegments: false)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - The menu half

    private func menuHalf(width: CGFloat, showsSegments: Bool) -> some View {
        PanelArea(shape: .workSurface, identifier: "menu-half") {
            hostSwitcher
        } accessory: {
            if showsSegments { segments } else { EmptyView() }
        } content: {
            VStack(spacing: 0) {
                Field(placeholder: Strings.menuSearch, text: $home.panelQuery,
                      identifier: "panel-search")
                    .onChange(of: home.panelQuery) { _, value in home.searchCatalog(value) }
                offlineRow
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !searching {
                            PinnedGroup(editing: $editingMenuPins,
                                        isEmpty: resolvedMenuPins.isEmpty,
                                        identifier: "pinned-menu",
                                        emptyHint: Strings.pinnedEmptyMenuHint) {
                                ForEach(resolvedMenuPins) { row in
                                    pinnedMenuRow(row)
                                }
                            }
                        }
                        MenuTree(items: menuItems, query: home.panelQuery,
                                 searchResults: searching ? home.searchResults : nil,
                                 editing: editingMenuPins,
                                 isPinned: { store.isPinned(pin(for: $0)) },
                                 onTogglePin: { togglePin(for: $0) },
                                 onRoute: route)
                    }
                    .padding(.bottom, OmodachiTheme.space("xxl"))
                }
                .scrollDismissesKeyboard(.interactively)
                if let toast = home.panelToast { PanelToastView(toast: toast).padding(.bottom, 5) }
            }
        }
    }

    /// PAIR-5 §2. The host did not answer. This is the *only* thing ① says
    /// about a connection that is not up: there is no "authorization is not
    /// connected" to sit in any more, because a host that refuses this device
    /// takes the Panel away instead of leaving a sentence under the menu.
    ///
    /// TAIL-3b: and it says *why*, by the host's road. A Tailscale host while
    /// this device has no Tailscale address is about this device (E01); a
    /// Wi-Fi host is only reachable on its Wi-Fi, and the one-time move to
    /// Tailscale is offered right here (E02). Never a silent other road.
    @ViewBuilder private var offlineRow: some View {
        // TAIL-3b I1: a link named a computer this device is not paired with.
        if let message = home.linkMessage {
            InlineError(message: message, identifier: "panel-link-unknown") {
                FlowButton(title: Strings.whereDone, kind: .secondary) { home.linkMessage = nil }
            }
        }
        if home.hostOffline {
            let name = home.state.hostName
            let retry = FlowButton(title: Strings.actionRetry, kind: .secondary) {
                Task { await home.connectCompanion() }
            }
            switch home.hostRoad?.kind.isTailscale {
            case true? where !TailscaleAddress.isUp:
                NoticeBlock(title: Strings.errTsOffTitle(DeviceWord.current), detail: Strings.errTsOffBody(name),
                            identifier: "panel-host-offline") { retry }
            case false?:
                NoticeBlock(title: Strings.errLanAwayTitle(name), detail: Strings.errLanAwayBody,
                            identifier: "panel-host-offline") {
                    FlowButton(title: Strings.errLanAwayGo(name)) {
                        home.pendingMoveAccount = HostAccount.canonical(home.profile.companionURL)
                        router.show(.settings)
                    }
                    .accessibilityIdentifier("panel-host-move")
                    retry.frame(maxWidth: 110)
                }
            default:
                NoticeBlock(title: Strings.errAsleepTitle(name), detail: Strings.errAsleepBody,
                            identifier: "panel-host-offline") { retry }
            }
        }
    }

    /// N-26 rev 5: the host switcher is the panel's title, and it is **dimmed
    /// while a Remote session is up** — switching host under a session would
    /// leave the stream pointing at a machine the rest of the app has left.
    @ViewBuilder private var hostSwitcher: some View {
        if directory.records.count > 1 || !directory.records.isEmpty {
            HostSwitcher(title: home.state.hostName,
                         records: directory.records,
                         locked: router.hasSession,
                         road: home.hostRoad,
                         wide: horizontal == .regular,
                         onSelect: switchHost)
        } else {
            PanelTitle(home.state.hostName)
        }
    }

    // MARK: - The Keybindings half

    private func keybindingsHalf(showsSegments: Bool) -> some View {
        PanelArea(shape: .workSurface, identifier: "keybindings-half") {
            PanelTitle(Strings.panelKeybindings)
        } accessory: {
            if showsSegments { segments } else { EmptyView() }
        } content: {
            KeybindingsView(store: stores.shortcut(),
                            showsUnrunnable: preferences.showsUnrunnableKeybindings,
                            focusSearchOnAppear: router.focusKeybindingsSearch,
                            editing: $editingKeyPins,
                            pins: resolvedKeyPins,
                            isPinned: { store.isPinned(pin(forShortcut: $0)) },
                            onTogglePin: { toggleShortcutPin($0) })
        }
    }

    /// A-54: 28 high inside a 44 hit area, at the right end of the title row.
    private var segments: some View {
        HStack(spacing: 0) {
            ForEach(PanelColumn.allCases) { column in
                Tap(selected: router.column == column,
                    fill: router.column == column ? OmodachiTheme.selectedFill : .clear,
                    action: { router.column = column }) {
                    HStack(spacing: OmodachiTheme.space("md")) {
                        Glyph(column.icon, step: "icon-small")
                        Text(column.title)
                            .font(OmodachiTheme.font("body", weight: router.column == column ? .semibold : .regular))
                    }
                    .foregroundStyle(router.column == column ? OmodachiTheme.selectedText : OmodachiTheme.muted)
                    .padding(.horizontal, OmodachiTheme.space("xxl"))
                    .frame(height: OmodachiTheme.controlHeight - 2)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("panel-segment-\(column.rawValue)")
                .accessibilityLabel(column.title)
                .accessibilityAddTraits(router.column == column ? [.isSelected] : [])
            }
        }
        .frame(height: OmodachiTheme.controlHeight)
        .background(OmodachiTheme.normalFill)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
        .frame(height: NativeBarMetrics.hit)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel-segments")
    }

    // MARK: - Pins

    private var searching: Bool {
        !home.panelQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var menuItems: [MenuItem] { home.menu }

    private var resolvedMenuPins: [ResolvedPin<MenuItem>] {
        let live = Dictionary(home.flattened.map { ($0.pinKey, $0) }, uniquingKeysWith: { first, _ in first })
        return pins.filter { $0.kind == .menu }.map { ResolvedPin(pin: $0, target: live[$0.stableKey]) }
    }

    private var resolvedKeyPins: [ResolvedPin<ShortcutEntry>] {
        let live = Dictionary((stores.shortcut().model.snapshot?.entries ?? []).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        return pins.filter { $0.kind == .keybinding }.map { ResolvedPin(pin: $0, target: live[$0.stableKey]) }
    }

    @ViewBuilder private func pinnedMenuRow(_ row: ResolvedPin<MenuItem>) -> some View {
        if let item = row.target {
            MenuActionRow(item: item, pinned: true, editing: editingMenuPins,
                          onTogglePin: { togglePin(for: item) }, onRoute: route)
        } else {
            // rev 5: a pin whose target is gone is drawn from its snapshot,
            // dimmed, and says why — it is never removed behind the user's back.
            Row(title: row.pin.label, detail: Strings.menuGone,
                icon: Icon.warning, enabled: false,
                identifier: "pin-tombstone-\(row.pin.stableKey)", action: { }) {
                Tap(action: { pins = store.toggle(row.pin) }) {
                    Glyph(Icon.pinFilled, step: "icon-small")
                        .foregroundStyle(OmodachiTheme.selectedText)
                        .frame(width: NativeBarMetrics.hit, height: RowHeight.detail)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Strings.pinnedUnpin(row.pin.label))
                .accessibilityIdentifier("unpin-\(row.pin.stableKey)")
            }
        }
    }

    private func pin(for item: MenuItem) -> PanelPin {
        PanelPin(hostID: hostID, kind: .menu, stableKey: item.pinKey, label: item.label)
    }

    private func pin(forShortcut entry: ShortcutEntry) -> PanelPin {
        PanelPin(hostID: hostID, kind: .keybinding, stableKey: entry.id, label: entry.label)
    }

    private func togglePin(for item: MenuItem) { pins = store.toggle(pin(for: item)) }
    private func toggleShortcutPin(_ entry: ShortcutEntry) { pins = store.toggle(pin(forShortcut: entry)) }

    private func reloadPins() { pins = store.pins(hostID: hostID); refreshLabels() }

    /// Keep the snapshot fresh while the row still exists, so a tombstone shows
    /// the last name the host really used.
    private func refreshLabels() {
        store.refresh(hostID: hostID, kind: .menu,
                      resolved: Dictionary(home.flattened.map { ($0.pinKey, $0.label) },
                                           uniquingKeysWith: { first, _ in first }))
        pins = store.pins(hostID: hostID)
    }

    // MARK: - Routing

    private func switchHost(_ record: PairedHostRecord) {
        guard !router.hasSession, record.account != home.profile.companionURL else { return }
        var profile = home.profile
        profile.companionURL = record.account
        profile.mock = false
        if !record.hostName.isEmpty { profile.hostname = record.hostName }
        home.profile = profile
        Task { await home.connectCompanion() }
    }

    /// The menu's own rows. The four Omodachi surface rows are gone from it
    /// (N-30): they are bar entries now, and a row that opens a panel would be
    /// the second way to the same place.
    private func route(_ item: MenuItem) {
        guard let current = home.flattened.first(where: { $0.id == item.id }), current.enabled else {
            home.reportToast(.init(stage: .failed, label: item.label, detail: Strings.menuNoLongerAvailable))
            return
        }
        // MENU-4 / A-68. A row that changes the machine is armed by its first
        // tap and sent by the second. Arming is not an invocation, so under
        // Remote the panel stays up (A-66 fires only once the call goes out).
        guard home.passesConfirm(current) else { return }
        Task {
            guard current.route == "terminal" || current.route.hasPrefix("native:") else {
                await home.invoke(current)
                // A-66 (UX-2 §4). The call has gone out, so under Remote the
                // machine is what the user wants to look at. A refusal keeps
                // the panel: the reason is drawn on the row that refused.
                if home.rowFailures[current.id] == nil { router.invokedHostAction() }
                return
            }
            guard let prepared = await home.prepareAction(current) else { return }
            switch prepared.route {
            case "native:agent": router.show(.agent)
            case "native:herdr": router.show(.herdr)
            case "native:panel": router.show(.menu)
            case "terminal":
                guard let argv = prepared.terminalArgv, !argv.isEmpty else {
                    home.reportToast(.init(stage: .failed, label: prepared.label, detail: Strings.menuNoTerminalTarget))
                    return
                }
                let descriptor = home.sshDescriptor(title: prepared.label, argv: argv)
                guard descriptor.kind != .herdr else { router.show(.herdr); return }
                _ = sessions.create(descriptor)
                router.show(.ssh)
            default:
                home.notice = NativeRoutePolicy.unavailableMessage
            }
        }
    }

}

/// N-26. "Which computer am I on" is answered where the user is already
/// looking, and the answer opens the list of the others.
///
/// TAIL-3b H-A: the name has the first line to itself (it shrinks to 85%, then
/// cuts in the middle: `workst…desk`), and the road is the second line — one
/// blue "Tailscale" or one yellow "This Wi-Fi only"; on an iPad, with the name
/// it is reached by beside it. TAIL-2's chip beside the name, which left the
/// name about seven characters on an iPhone, is gone.
struct HostSwitcher: View {
    let title: String
    let records: [PairedHostRecord]
    /// N-26 rev 5: no host switching while a Remote session owns the machine.
    let locked: Bool
    /// The road this host is set to, connected or not.
    var road: HostRoad? = nil
    /// iPad: room for the address beside the road word.
    var wide = false
    let onSelect: (PairedHostRecord) -> Void

    var body: some View {
        Menu {
            ForEach(records) { record in
                TextTap(record.hostName) { onSelect(record) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(OmodachiTheme.font("heading"))
                        .kerning(-0.2)
                        .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("panel-host-name")
                    Glyph(Icon.chevronDown, step: "icon-small")
                        .foregroundStyle(OmodachiTheme.secondaryText)
                    // N-26: the control itself is the report — dimmed, with its
                    // chevron dead — and the chip beside it is a label, not a
                    // sentence explaining the rule. The reason a screen reader
                    // needs is on `accessibilityValue`.
                    if locked { StateChip(text: Strings.menuHostLocked) }
                }
                if let road {
                    RoadLine(road: road, showsAddress: wide, size: 12)
                        .accessibilityIdentifier("panel-host-road")
                }
            }
            .frame(minHeight: NativeBarMetrics.hit)
            .contentShape(Rectangle())
            .opacity(locked ? 0.45 : 1)
        }
        .disabled(locked)
        .accessibilityLabel(Strings.menuHostCurrent)
        .accessibilityValue(locked ? Strings.menuHostLockedValue(title)
                            : [title, road.map(HostRoadWords.a11y)].compactMap { $0 }.joined(separator: " · "))
        .accessibilityIdentifier("panel-host-switcher")
    }
}
