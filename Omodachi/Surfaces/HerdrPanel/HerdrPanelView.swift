import SwiftTerm
import SwiftUI
import UIKit

/// Study 01 §05. A touch development bench, not a terminal with a grid bolted
/// on: the left column is the workspace → pane grid, the right is the selected
/// pane's screen, and under it (HERDR-3) the composer and the bar with Type,
/// the keys row and the labelled More menu.
///
/// What is deliberately absent: the global Omarchy keybindings list (A-21 —
/// that belongs to the Panel), and any way for a tap to take the pane. The
/// screen is a mirror; typing is one-shot `/keys` and `/text` (HERDR-5: there
/// is no `control` any more), and a tap on it puts the keyboard away.
struct HerdrSurface: View {
    @ObservedObject var store: HerdrStore
    @EnvironmentObject private var home: HomeStore
    @EnvironmentObject private var stores: SurfaceStores
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.scenePhase) private var scenePhase
    /// DUO-1 round 2: an open foldable shows the mirror the iPad's way.
    @Environment(\.fold) private var fold
    @State private var closing: (action: HerdrControlAction, request: HerdrControlRequest)?
    /// The composer and the bar together; the terminal leaves this much room.
    @State private var bottomHeight: CGFloat = NativeBarMetrics.hit
    /// HERDR-9: the soft keyboard is up (it covers part of the window).
    @State private var keyboardUp = false

    /// The column is the study's narrow grid rail; below this the grid folds to
    /// the top strip (iPhone portrait, and an iPad in a narrow split view).
    private static let gridWidth: CGFloat = 248
    private static let foldBelow: CGFloat = 700

    var body: some View {
        GeometryReader { proxy in
            let folded = horizontal == .compact || proxy.size.width < Self.foldBelow
            ZStack(alignment: .bottom) {
                Group {
                    VStack(spacing: 0) {
                        // HERDR-9 (Collie's use-keyboard: the keyboard took
                        // the pixels, so the keyboard may spend them): on a
                        // phone with the keyboard up, the session and pane
                        // rows step aside so the mirror keeps rows to read.
                        if !compactChrome(folded) {
                            HerdrSessionSwitcher(store: store)
                            rule
                            // OVERVIEW-1: everything that wants you, under the switcher.
                            if store.overviewOpen {
                                HerdrOverviewCard(store: store, overview: home.overviewShown, open: open,
                                                  listHeight: min(320, max(120, proxy.size.height * 0.45 - 80)))
                                rule
                            }
                        }
                        if store.newSessionOpen {
                            HerdrNewSessionCard(store: store)
                            rule
                        }
                        if store.newWorkspaceOpen {
                            HerdrNewWorkspaceCard(store: store)
                            rule
                        }
                        // POLISH-U: a link's notice lies over the top of the
                        // mirror, never over the session switcher or the
                        // workspaces and panes.
                        if folded {
                            if !compactChrome(folded) {
                                HerdrPaneStrip(store: store, overview: home.overviewShown)
                                rule
                            }
                            stage.linkNoticeRegion()
                        } else {
                            HStack(spacing: 0) {
                                HerdrGridColumn(store: store, overview: home.overviewShown).frame(width: Self.gridWidth)
                                Rectangle().fill(OmodachiTheme.border)
                                    .frame(width: NativeBarMetrics.edgeRule).accessibilityHidden(true)
                                stage.linkNoticeRegion()
                            }
                        }
                    }
                }
                // REL2-POLISH-1: the column above the composer is exactly
                // this panel's height, never more. On an iPhone on its side
                // with the keyboard up there are ~130 points left, and a
                // notice row (the demo's "these buttons…" after Type, an
                // error) plus the room the stage keeps for the composer and
                // the bar asked for more than that; the column then grew the
                // ZStack past the panel, and the composer and the bar - laid
                // on the ZStack's bottom - went down under the keyboard. Held
                // to the panel, what does not fit is the column's own bottom,
                // which lies under the composer anyway: the mirror gives way,
                // the controls stay on the keyboard's top edge.
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .clipped()
                // A-13 said the content ignores the keyboard so the terminal
                // is covered rather than resized. That reason is gone: since
                // HERDR-4 the grid is the pane's own size inside the fit view
                // (and Wrap is text), so the mirror getting shorter changes
                // nothing but what is in view — no `terminal.resize`, no
                // observe restart, the PTY untouched (ADR 0008). HERDR-9:
                // so the mirror now ends above the composer and the keyboard,
                // and the pane's newest rows — its input line — stay in view
                // (Leo: the keyboard covered them). The bar keeps SwiftUI's
                // own avoidance: on the keyboard's top edge, else on the Home
                // indicator.
                VStack(spacing: 0) {
                    if store.selected != nil { HerdrInputArea(store: store, keyboardUp: keyboardUp) }
                    HerdrControlBar(store: store,
                                    onConfirm: { closing = ($0, $1) })
                }
                // VERIFY-1: measured directly. The preference this used to
                // send never arrived (the inset stayed at the bar's 44
                // points), so the composer, the keys and the Quick dock lay
                // over the mirror's last rows - on the real host, over
                // codex's approval dialog while Quick was open.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
            }
        }
        .background(OmodachiTheme.background)
        .background(KeyboardOverlapReader { overlap, _ in keyboardUp = overlap > 0 }
            .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true))
        // HERDR-9: the simulator's UI fixture says what went out, for the test.
        .overlay(alignment: .topLeading) {
            if HerdrChoicesFixture.requested || HERDR11Fixture.requested {
                // HERDR-10: and the grid's size, which must stay the pane's.
                Text(verbatim: (store.fixtureSent + [store.fixtureGridLine]).joined(separator: "\n"))
                    .font(OmodachiTheme.font("caption"))
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("herdr-fixture-sent")
            }
        }
        .onAppear { store.appear() }
        .onChange(of: fold != nil, initial: true) { _, open in store.setFoldOpen(open) }
        .onDisappear { store.disappear() }
        // HERDR-3: nothing types into a pane from a phone in a pocket, and a
        // taken keyboard goes back to the computer at once.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.sceneMovedToBackground() }
            else if phase == .active { store.sceneBecameActive() }
        }
        // core's two-second projection of the owned session: the client
        // re-reads the snapshot, it never patches its own copy.
        // HERDR-11 §4: only this panel's own session is worth a read.
        .onChange(of: home.herdrLayoutRevision) { _, _ in store.layoutChanged(session: home.herdrLayoutSession) }
        // HERDR-2 §1: the connection coming up is the other thing that makes a
        // failed read worth repeating. Without it a surface entered during the
        // connect stays on its one failure, because `herdr.layout.changed`
        // fires only when the projection moves and a quiet session never does.
        .onChange(of: home.companionConnected) { _, connected in
            store.hostConnectionChanged(connected: connected)
        }
        .confirmationDialog(closing?.action == .closeTab ? Strings.herdrCloseTabTitle : Strings.herdrClosePaneTitle,
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible) {
            TextTap(closing?.action == .closeTab ? Strings.herdrActionCloseTab : Strings.herdrClosePane,
                    destructive: true) {
                if let request = closing?.request { store.perform(request, confirmed: true) }
                closing = nil
            }
            TextTap(Strings.actionCancel, destructive: false) { closing = nil }
        } message: {
            Text(closing?.action == .closeTab ? Strings.herdrCloseTabDetail : Strings.herdrClosePaneDetail)
        }
    }

    /// OVERVIEW-1: one tap goes there - the Agent panel, or that session and
    /// pane here (HERDR-2's switch, then the pane; NOTIFY-2's landing waits
    /// for each fact before it acts on it).
    private func open(_ row: OverviewRow) {
        store.overviewOpen = false
        switch row.source {
        case .agent:
            stores.openPanel?(.agent)
        case .herdr:
            guard let session = row.session else { return }
            if session == store.selectedSession {
                // A pane that just closed is simply not there; its row goes
                // with the next reading.
                if let pane = row.paneID, store.layout?.pane(pane) != nil { store.select(pane) }
            } else {
                Task { await HerdrLanding.land(store: store, home: home, session: session, pane: row.paneID) }
            }
        }
    }

    /// A phone with its keyboard up for the composer or Type (not for the
    /// new-session or new-workspace card, whose fields sit in that chrome).
    private func compactChrome(_ folded: Bool) -> Bool {
        folded && keyboardUp && !store.newSessionOpen && !store.newWorkspaceOpen
    }

    private var rule: some View {
        Rectangle().fill(OmodachiTheme.border)
            .frame(height: NativeBarMetrics.edgeRule).accessibilityHidden(true)
    }

    private var showsFullScreenNote: Bool {
        store.mirrorMode == .wrap && store.fullScreenFallback && !store.showsWrap
    }

    /// HERDR-8: Wrap, Fit or Actual; a tap goes to the next. HERDR-12: Wrap
    /// or Fit on a phone.
    private var zoomChip: some View {
        TextTap(store.mirrorLabel,
                step: "caption", bordered: true,
                minimumHeight: OmodachiTheme.controlHeight, action: store.toggleZoom)
            .background(OmodachiTheme.background.opacity(0.85))
            .accessibilityHint(store.mirrorHint)
            .accessibilityIdentifier("herdr-zoom")
    }

    @ViewBuilder private var stage: some View {
        VStack(spacing: 0) {
            if store.herdrDown {
                // HERDR-11 §3: the computer answers and Herdr on it does not -
                // the third cause, named, with Try again.
                ConnectionBanner(health: .lost(.herdrDown),
                                 message: ConnectionHealth.lost(.herdrDown).message(host: home.state.hostName),
                                 retry: { store.refreshLayout() })
                    .padding(.horizontal, OmodachiTheme.space("lg"))
                    .padding(.vertical, OmodachiTheme.space("sm"))
            }
            if let notice = store.notice {
                HerdrNoticeRow(text: notice) { store.dismissNotice() }
            }
            if store.selected != nil, !keyboardUp || horizontal != .compact {
                // HERDR-4 §3.4: once per device, until it is put away.
                // HERDR-8: on a phone it is short and shows on one visit.
                OnceHintBanner(hints: home.hints, hint: .herdr,
                               text: store.mirrorPreference.phone ? Strings.hintHerdrPhone
                                   : horizontal == .compact ? Strings.hintHerdrCompact : Strings.hintHerdr,
                               once: horizontal == .compact)
            }
            if store.selected == nil, let stopped = store.selectedSessionStopped {
                // HERDR-5: the session on screen stopped on the computer; the
                // one thing to do about it is right here.
                ContentUnavailableView {
                    Label(Strings.herdrSessionStopped, systemImage: "pause.circle")
                } description: {
                    Text(Strings.herdrSessionStartDetail)
                } actions: {
                    FlowButton(title: Strings.herdrSessionStart(stopped), kind: .primary,
                               enabled: store.startingSession == nil) { store.startSession(stopped) }
                        .accessibilityIdentifier("herdr-session-start-here")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selected == nil {
                ContentUnavailableView {
                    Label(Strings.herdrNoPanes, systemImage: "rectangle.split.2x2")
                } description: {
                    Text(store.loadingLayout ? Strings.herdrLoadingLayout : Strings.herdrNoPanesDetail)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                // HERDR-8: Wrap is chosen but the pane runs a full-screen
                // program, so its screen is shown as it is - said once, in one
                // line. DUO-1 round 2: in a row of its own above the mirror,
                // with the chip at its end. Laid over the mirror it ran under
                // the chip on a narrow phone and hid the mirror's top rows.
                if showsFullScreenNote {
                    HStack(spacing: OmodachiTheme.space("sm")) {
                        Text(Strings.herdrFullScreenNote)
                            .font(OmodachiTheme.font("caption"))
                            .foregroundStyle(OmodachiTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("herdr-fullscreen-note")
                        if store.zoomable { zoomChip }
                    }
                    .padding(.leading, OmodachiTheme.space("md"))
                    .padding(.trailing, OmodachiTheme.space("sm"))
                    .padding(.vertical, OmodachiTheme.space("xs"))
                    .frame(minHeight: OmodachiTheme.controlHeight)
                    .background(OmodachiTheme.background)
                }
                HerdrTerminalRepresentable(store: store,
                                           appearanceRevision: OmodachiTheme.appearanceRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    // HERDR-11 §3: a mirror not known to be current is dimmed
                    // and says when it last was.
                    .opacity(store.mirrorStale ? 0.45 : 1)
                    .overlay(alignment: .top) {
                        if let label = store.mirrorStaleLabel {
                            Text(label)
                                .font(OmodachiTheme.font("caption", weight: .semibold))
                                .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                                .lineLimit(1)
                                .padding(.horizontal, OmodachiTheme.space("md"))
                                .frame(minHeight: 26)
                                .background(OmodachiTheme.background.opacity(0.9))
                                .padding(.top, OmodachiTheme.space("sm"))
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("herdr-mirror-stale")
                        }
                    }
                    // HERDR-4: what the mirror is showing, and the other way
                    // to see it (the double tap's twin, findable by eye).
                    // DUO-1 round 2: over the mirror only when the note is
                    // not up; with the note it sits in the note's row.
                    .overlay(alignment: .topTrailing) {
                        if store.zoomable && !showsFullScreenNote {
                            zoomChip.padding(OmodachiTheme.space("sm"))
                        }
                    }
                    // HERDR-9: the keys that just went in, for a moment.
                    .overlay(alignment: .bottomTrailing) {
                        HerdrKeyEchoStrip(echo: store.echo, spoken: store.echoSpoken)
                            .padding(OmodachiTheme.space("sm"))
                            .allowsHitTesting(false)
                            .animation(.easeOut(duration: 0.2), value: store.echo)
                    }
                }
            }
        }
        .padding(.bottom, bottomHeight)
    }
}

/// The terminal view lives on the store, so leaving the surface and coming
/// back does not rebuild the emulator or lose the buffer. HERDR-4: it sits
/// inside the view that fits a wide pane to this width (`HerdrFitView`).
struct HerdrTerminalRepresentable: UIViewRepresentable {
    let store: HerdrStore
    /// §3: the terminal's colours and face come from `/v1/theme` and
    /// `/v1/fonts`. Carrying the revision in makes this view a dependency of
    /// both, so `theme.changed` repaints the emulator in place.
    let appearanceRevision: Int
    func makeUIView(context: Context) -> HerdrMirrorView { store.mirrorView }
    func updateUIView(_ view: HerdrMirrorView, context: Context) {
        store.applyAppearance(revision: appearanceRevision)
    }
    static func dismantleUIView(_ view: HerdrMirrorView, coordinator: ()) { view.fit.terminal.resignFirstResponder() }
}

/// HERDR-2 §2. Which of the host's Herdr sessions this panel is looking at.
///
/// The owned `omodachi` session is where every device starts and is marked as
/// such; the user's own sessions are listed because that is where their work
/// actually is. HERDR-5: a stopped one is not a dead grey line any more — its
/// item is "Start <name>", with a line saying what that does, and it lands the
/// panel there; and the last item makes a new session. One that is running but
/// not answering stays listed and disabled, with the reason in the caption.
struct HerdrSessionSwitcher: View {
    @ObservedObject var store: HerdrStore
    @EnvironmentObject private var home: HomeStore

    var body: some View {
        HStack(spacing: OmodachiTheme.space("md")) {
            Menu {
                ForEach(store.sessions) { session in
                    if session.running {
                        // OVERVIEW-1: each session says what in it wants you.
                        if let counts = OverviewWords.counts(home.overviewShown.counts(session: session.name)) {
                            LabelledMenuItem(title: session.name, detail: counts,
                                             symbol: session.name == store.selectedSession ? "checkmark" : nil) { // non-copy: an SF Symbol name
                                store.selectSession(session.name)
                            }
                            .disabled(!session.readable)
                            .accessibilityIdentifier("herdr-session-\(session.name)")
                        } else {
                            TextTap(session.name, selected: session.name == store.selectedSession,
                                    enabled: session.readable) {
                                store.selectSession(session.name)
                            }
                            .accessibilityIdentifier("herdr-session-\(session.name)")
                        }
                    } else {
                        LabelledMenuItem(title: Strings.herdrSessionStart(session.name),
                                         detail: Strings.herdrSessionStartDetail, symbol: "play") { // non-copy: an SF Symbol name
                            store.startSession(session.name)
                        }
                        .accessibilityIdentifier("herdr-session-start-\(session.name)")
                    }
                }
                Divider()
                LabelledMenuItem(title: Strings.herdrSessionNew, detail: Strings.herdrSessionNewDetail,
                                 symbol: "plus") { store.openNewSession() } // non-copy: an SF Symbol name
                    .accessibilityIdentifier("herdr-new-session-open")
            } label: {
                HStack(spacing: OmodachiTheme.space("sm")) {
                    Text(verbatim: store.sessionTitle)
                        .font(OmodachiTheme.font("body", weight: .semibold))
                        .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                        .lineLimit(1).truncationMode(.middle)
                    Glyph(Icon.chevronDown, step: "icon-small")
                        .foregroundStyle(OmodachiTheme.secondaryText)
                }
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .frame(minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
            }
            .disabled(store.sessions.isEmpty || store.switchingSession)
            .accessibilityLabel(Strings.herdrSession)
            .accessibilityValue(store.sessionTitle)
            .accessibilityIdentifier("herdr-session-switcher")

            if store.startingSession != nil {
                ProgressRow(title: detail, identifier: "herdr-session-starting")
            } else {
                Text(detail)
                    .font(OmodachiTheme.font("caption"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .lineLimit(1)
                    .accessibilityIdentifier("herdr-session-detail")
            }
            Spacer(minLength: 0)
            // OVERVIEW-1: what wants you, everywhere; a tap opens the list.
            HerdrOverviewSummary(store: store, overview: home.overviewShown)
                .padding(.trailing, OmodachiTheme.space("sm"))
        }
        .frame(height: NativeBarMetrics.hit)
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
    }

    /// One caption, and it is about the session on screen: what core owns, how
    /// big it is, or why it cannot be read.
    private var detail: String {
        if let starting = store.startingSession { return Strings.herdrSessionStarting(starting) }
        if store.switchingSession { return Strings.herdrSessionSwitching }
        guard let current = store.sessions.first(where: { $0.name == store.selectedSession }) else { return "" }
        if !current.running { return Strings.herdrSessionStopped }
        if !current.readable { return Strings.herdrSessionUnreadable }
        if current.isEmpty { return Strings.herdrSessionEmpty }
        let shape = Strings.herdrSessionShape(Format.count(current.workspaces ?? 0),
                                              Format.count(current.panes ?? 0),
                                              Format.count(current.agents ?? 0))
        return current.owned ? Strings.pair(Strings.herdrSessionOwned, shape) : shape
    }
}

/// HERDR-5: "New session…". A card under the switcher, not a sheet (A-55: a
/// panel fills the panel area): a name, Create, and core's refusal in words.
/// Creating lands the panel in the new session, started in the computer's
/// home folder.
struct HerdrNewSessionCard: View {
    @ObservedObject var store: HerdrStore
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            Text(Strings.herdrNewSessionTitle)
                .font(OmodachiTheme.font("body", weight: .semibold))
                .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
            Text(Strings.herdrNewSessionDetail)
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(OmodachiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Field(placeholder: Strings.herdrNewSessionPlaceholder, text: $name, icon: nil,
                  identifier: "herdr-new-session-name", focusOnAppear: true,
                  onSubmit: { store.createSession(name) }, asciiOnly: true)
            if let error = store.newSessionError {
                Text(error)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.current.color(.red))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("herdr-new-session-error")
            }
            HStack(spacing: OmodachiTheme.space("lg")) {
                if store.creatingSession {
                    ProgressRow(title: Strings.herdrNewSessionCreating, identifier: "herdr-new-session-creating")
                } else {
                    FlowButton(title: Strings.herdrNewSessionCreate, kind: .primary,
                               enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                        store.createSession(name)
                    }
                    .accessibilityIdentifier("herdr-new-session-create")
                    FlowButton(title: Strings.actionCancel, kind: .ghost) { store.cancelNewSession() }
                        .accessibilityIdentifier("herdr-new-session-cancel")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(OmodachiTheme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmodachiTheme.normalFill)
        .onChange(of: name) { _, _ in store.newSessionError = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-new-session")
    }
}

/// HERDR-6: "New workspace…". A card under the switcher like the new-session
/// one (A-55: no sheet): the recent and common folders, a one-level browser,
/// the path itself and an optional name. Opening a folder in the browser is
/// choosing it. Create lands the panel on the new workspace's first pane —
/// this device's own view; the computer's screen stays where it is.
struct HerdrNewWorkspaceCard: View {
    @ObservedObject var store: HerdrStore
    @State private var path = ""
    @State private var name = ""
    /// The lists scroll inside the card, so a long one never pushes the
    /// pane off the panel.
    private static let listHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("md")) {
            Text(Strings.herdrNewWorkspaceTitle)
                .font(OmodachiTheme.font("body", weight: .semibold))
                .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
            Text(Strings.herdrNewWorkspaceDetail(store.sessionTitle))
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(OmodachiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: OmodachiTheme.space("md")) {
                // A path is typed letter by letter, not composed: a Chinese
                // IME turns `h6test` into a candidate. A folder with a name in
                // another script is a tap away in the browser below.
                Field(placeholder: Strings.herdrNewWorkspacePathPlaceholder, text: $path, icon: nil,
                      identifier: "herdr-new-workspace-path",
                      onSubmit: { store.createWorkspace(path: path, name: name) }, asciiOnly: true)
                    .accessibilityLabel(Strings.herdrNewWorkspacePath)
                TextTap(Strings.herdrNewWorkspaceBrowse, bordered: true, enabled: !store.browsingFolders) {
                    open(path.trimmingCharacters(in: .whitespaces).isEmpty ? "~" : path) // non-copy: the home folder
                }
                .accessibilityIdentifier("herdr-new-workspace-browse")
            }
            if let browse = store.folderBrowse {
                browser(browse)
            } else {
                suggestions
            }
            Field(placeholder: Strings.herdrNewWorkspaceNamePlaceholder, text: $name, icon: nil,
                  identifier: "herdr-new-workspace-name",
                  onSubmit: { store.createWorkspace(path: path, name: name) })
                .accessibilityLabel(Strings.herdrNewWorkspaceName)
            // HERDR-11 §1: what the new workspace starts with - a shell, or one
            // of the host's launchers. No launchers (an older core, none
            // installed): no row.
            if !store.launchers.isEmpty { launchRow }
            if let error = store.newWorkspaceError {
                Text(error)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.current.color(.red))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("herdr-new-workspace-error")
            }
            HStack(spacing: OmodachiTheme.space("lg")) {
                if store.creatingWorkspace {
                    ProgressRow(title: Strings.herdrNewSessionCreating, identifier: "herdr-new-workspace-creating")
                } else {
                    // HERDR-11: an empty folder is the home folder.
                    FlowButton(title: createTitle, kind: .primary) {
                        store.createWorkspace(path: path, name: name)
                    }
                    .accessibilityIdentifier("herdr-new-workspace-create")
                    FlowButton(title: Strings.actionCancel, kind: .ghost) { store.cancelNewWorkspace() }
                        .accessibilityIdentifier("herdr-new-workspace-cancel")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(OmodachiTheme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmodachiTheme.normalFill)
        .onChange(of: path) { _, _ in store.newWorkspaceError = nil }
        .onChange(of: name) { _, _ in store.newWorkspaceError = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-new-workspace")
    }

    private func open(_ target: String, hidden: Bool? = nil) {
        Task {
            if let display = await store.browseFolder(target, hidden: hidden) { path = display }
        }
    }

    private var chosen: HerdrLauncherDTO? { store.launchers.first { $0.command == store.chosenLauncher } }

    private var createTitle: String {
        chosen.map { Strings.herdrNewWorkspaceCreateAndStart($0.label) } ?? Strings.herdrNewSessionCreate
    }

    /// HERDR-11 §1: Shell · codex · claude, one of them chosen.
    private var launchRow: some View {
        VStack(alignment: .leading, spacing: OmodachiTheme.space("xs")) {
            Text(Strings.herdrNewWorkspaceStart)
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(OmodachiTheme.secondaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OmodachiTheme.space("sm")) {
                    TextTap(Strings.herdrNewWorkspaceStartShell, selected: store.chosenLauncher == nil, bordered: true,
                            minimumHeight: OmodachiTheme.controlHeight) { store.chooseLauncher(nil) }
                        .accessibilityAddTraits(store.chosenLauncher == nil ? [.isSelected] : [])
                        .accessibilityIdentifier("herdr-launch-shell")
                    ForEach(store.launchers) { launcher in
                        TextTap(launcher.label, selected: store.chosenLauncher == launcher.command, bordered: true,
                                minimumHeight: OmodachiTheme.controlHeight) { store.chooseLauncher(launcher.command) }
                            .accessibilityAddTraits(store.chosenLauncher == launcher.command ? [.isSelected] : [])
                            .accessibilityIdentifier("herdr-launch-\(launcher.label)")
                    }
                }
            }
            Text(Strings.herdrNewWorkspaceStartDetail)
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(OmodachiTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-launch-row")
    }

    private var suggestions: some View {
        ScrollView {
            // HERDR-11: a plain stack - the same folder is in two sections
            // (favourite and recent), which a lazy stack shows only once.
            // The lists are short (12 + 8 + 6 rows at most).
            VStack(alignment: .leading, spacing: 0) {
                if store.loadingFolders {
                    ProgressRow(title: Strings.herdrNewWorkspaceLoading, identifier: "herdr-folders-loading")
                }
                // HERDR-11 §1: the starred folders first.
                if !store.favouriteFolders.isEmpty {
                    caption(Strings.herdrNewWorkspaceFavourites)
                    ForEach(store.favouriteFolders) { folder in
                        row(folder.display, current: folder.display == path,
                            identifier: "herdr-folder-favourite-\(folder.display)", star: folder) { path = folder.display }
                    }
                }
                if !store.recentFolders.isEmpty {
                    caption(Strings.herdrNewWorkspaceRecent)
                    ForEach(store.recentFolders) { folder in
                        row(folder.display, current: folder.display == path,
                            identifier: "herdr-folder-recent-\(folder.display)", star: folder) { path = folder.display }
                    }
                }
                if !store.commonFolders.isEmpty {
                    caption(Strings.herdrNewWorkspaceCommon)
                    ForEach(store.commonFolders) { folder in
                        row(folder.display, current: folder.display == path,
                            identifier: "herdr-folder-common-\(folder.display)", star: folder) { path = folder.display }
                    }
                }
            }
        }
        .frame(maxHeight: Self.listHeight)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("herdr-folder-suggestions")
    }

    private func browser(_ browse: HerdrFolderBrowseDTO) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OmodachiTheme.space("md")) {
                TextTap(Strings.herdrNewWorkspaceUp, bordered: true,
                        enabled: browse.parent != nil && !store.browsingFolders) {
                    if let parent = browse.parent { open(parent.path) }
                }
                .accessibilityIdentifier("herdr-folder-up")
                Text(verbatim: browse.display)
                    .font(OmodachiTheme.font("body-small"))
                    .lineLimit(1).truncationMode(.head)
                    .accessibilityIdentifier("herdr-folder-here")
                Spacer(minLength: 0)
                SquareToggle(isOn: Binding(get: { store.showHiddenFolders },
                                           set: { open(browse.path, hidden: $0) }),
                             label: Strings.herdrNewWorkspaceHidden, identifier: "herdr-folder-hidden")
                Text(Strings.herdrNewWorkspaceHidden)
                    .font(OmodachiTheme.font("caption"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Tap(action: store.closeFolderBrowser) {
                    Glyph(Icon.close)
                        .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel(Strings.herdrNewWorkspaceCloseBrowser)
                    .accessibilityIdentifier("herdr-folder-browser-close")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(browse.dirs) { folder in
                        row(folder.name, current: false, identifier: "herdr-folder-\(folder.name)") { open(folder.path) }
                    }
                    if browse.dirs.isEmpty { caption(Strings.herdrNewWorkspaceEmpty) }
                    if browse.truncated { caption(Strings.herdrNewWorkspaceTruncated) }
                }
            }
            .frame(maxHeight: Self.listHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .overlay(Rectangle().stroke(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-folder-browser")
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(OmodachiTheme.font("caption"))
            .foregroundStyle(OmodachiTheme.secondaryText)
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .padding(.top, OmodachiTheme.space("sm"))
    }

    private func row(_ title: String, current: Bool, identifier: String, star: HerdrFolderDTO? = nil,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Tap(selected: current, action: action) {
                HStack(spacing: OmodachiTheme.space("md")) {
                    Glyph(symbol: "folder", points: OmodachiTheme.fontSize("icon-small")) // non-copy: an SF Symbol name
                        .foregroundStyle(OmodachiTheme.secondaryText)
                    Text(verbatim: title)
                        .font(OmodachiTheme.font("body"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .frame(minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier(identifier)
            // HERDR-11 §1: a star, only where the host keeps favourites.
            if let star, store.favouritesSupported {
                let on = store.isFavourite(star)
                Tap(action: { store.toggleFavourite(star) }) {
                    Glyph(symbol: on ? "star.fill" : "star", points: OmodachiTheme.fontSize("icon-small")) // non-copy: SF Symbol names
                        .foregroundStyle(on ? OmodachiTheme.accent : OmodachiTheme.secondaryText)
                        .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(on ? Strings.herdrNewWorkspaceUnfavourite : Strings.herdrNewWorkspaceFavourite)
                .accessibilityValue(star.display)
                .accessibilityIdentifier("\(identifier)-star")
            }
        }
    }
}

/// HERDR-6: the small "+" that ends the workspaces (strip and column).
struct HerdrNewWorkspaceTap: View {
    @ObservedObject var store: HerdrStore
    var wide = false

    var body: some View {
        Tap(bordered: !wide, action: store.openNewWorkspace) {
            HStack(spacing: OmodachiTheme.space("md")) {
                Glyph(symbol: "plus", points: OmodachiTheme.fontSize("icon-small")) // non-copy: an SF Symbol name
                if wide {
                    Text(Strings.herdrActionNewWorkspace)
                        .font(OmodachiTheme.font("caption"))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(OmodachiTheme.secondaryText)
            .padding(.horizontal, wide ? OmodachiTheme.rowPaddingX : OmodachiTheme.space("lg"))
            .frame(minWidth: wide ? nil : NativeBarMetrics.hit, minHeight: wide ? NativeBarMetrics.hit : OmodachiTheme.controlHeight,
                   alignment: .leading)
            .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .frame(height: NativeBarMetrics.hit)
        .accessibilityLabel(Strings.herdrActionNewWorkspace)
        .accessibilityHint(Strings.herdrActionNewWorkspaceDetail)
        .accessibilityIdentifier("herdr-workspace-new")
    }
}

// MARK: - Grid

/// iPad landscape: workspaces and their panes as rows. Selected is `selected`
/// fill; a pane carrying an agent shows the agent's kind and Herdr's own status
/// word next to a dot (§1.3).
struct HerdrGridColumn: View {
    @ObservedObject var store: HerdrStore
    /// OVERVIEW-1: the workspaces' and panes' marks.
    var overview: OverviewReading = .empty

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.workspaces) { workspace in
                    HerdrWorkspaceHeader(workspace: workspace,
                                         active: workspace.id == store.selectedWorkspaceID,
                                         mark: overview.worst(session: store.selectedSession, workspace: workspace.id)) {
                        store.selectWorkspace(workspace.id)
                    }
                    ForEach(workspace.tabs) { tab in
                        if workspace.tabs.count > 1 { HerdrTabLabel(tab: tab) }
                        ForEach(tab.panes) { pane in
                            HerdrPaneRow(pane: pane, name: store.layout?.name(of: pane.id) ?? "",
                                         selected: pane.id == store.selected,
                                         unseen: overview.row(session: store.selectedSession, pane: pane.id)?.state == .done) {
                                store.select(pane.id)
                            }
                        }
                    }
                }
                if store.workspaces.isEmpty {
                    Text(store.loadingLayout ? Strings.herdrLoading : Strings.herdrNoWorkspace)
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .padding(OmodachiTheme.rowPaddingX)
                }
                if store.selectedSessionStopped == nil {
                    HerdrNewWorkspaceTap(store: store, wide: true)
                }
            }
        }
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-grid")
    }
}

struct HerdrWorkspaceHeader: View {
    let workspace: HerdrWorkspaceDTO
    let active: Bool
    /// OVERVIEW-1: the most urgent state of its panes, or nil.
    var mark: OverviewRow.State? = nil
    let onSelect: () -> Void

    var body: some View {
        Tap(action: onSelect) {
            HStack(spacing: OmodachiTheme.space("md")) {
                OverviewMark(state: mark)
                Text(workspace.number.map(String.init) ?? workspace.id)
                    .font(OmodachiTheme.font("body", weight: .semibold))
                    .frame(minWidth: 18)
                Text(workspace.label ?? "")
                    .font(OmodachiTheme.font("caption"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if workspace.focused {
                    Text(Strings.herdrFocused).font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.accent)
                }
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(height: NativeBarMetrics.hit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .control(selected: active)
        .accessibilityValue(mark.map(OverviewWords.chipLabel) ?? "")
        .accessibilityIdentifier("herdr-workspace-\(workspace.id)")
    }
}

struct HerdrTabLabel: View {
    let tab: HerdrTabDTO
    var body: some View {
        HStack(spacing: OmodachiTheme.space("sm")) {
            Text(Strings.herdrTab(tab.label ?? tab.id))
            if tab.zoomed { Text(Strings.herdrZoomed).foregroundStyle(OmodachiTheme.accent) }
        }
        .font(OmodachiTheme.font("caption"))
        .foregroundStyle(OmodachiTheme.secondaryText)
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.top, OmodachiTheme.space("sm"))
    }
}

/// HERDR-4: a row names the pane the way a person would — its title or
/// folder, then the agent and Herdr's status word — never Herdr's `w1:p2`;
/// and a pane that is waiting says so in words, not only in red.
struct HerdrPaneRow: View {
    let pane: HerdrPaneDTO
    let name: String
    let selected: Bool
    /// NOTIFY-1 / OVERVIEW-1: its agent finished and nobody has opened it since.
    var unseen = false
    let onSelect: () -> Void

    private var subtitle: String? {
        if let label = pane.agentLabel, !label.isEmpty { return label }
        if let tail = pane.cwdTail, tail != name { return tail }
        return nil
    }

    var body: some View {
        Tap(action: onSelect) {
            HStack(spacing: OmodachiTheme.space("md")) {
                // HERDR-7: an agent's pane shows a still marker in the colour
                // of its status words (the animated face is the Agent panel's
                // and the bar's); other panes keep the status square.
                if let marker = pane.marker {
                    HerdrAgentMarker(mark: marker.mark, role: marker.role)
                } else {
                    Rectangle().fill(OmodachiTheme.current.color(pane.status.role))
                        .frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name)
                        .font(OmodachiTheme.font("body"))
                        .lineLimit(1).truncationMode(.middle)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(OmodachiTheme.font("caption"))
                            .foregroundStyle(pane.agent == nil ? OmodachiTheme.muted
                                             : OmodachiTheme.current.color(pane.status.role))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if pane.isWaiting {
                    HerdrWaitingTag()
                }
                if unseen {
                    OverviewMark(state: .done)
                        .accessibilityIdentifier("herdr-unseen-\(pane.id)")
                }
                if pane.zoomed {
                    Glyph(symbol: "arrow.up.left.and.arrow.down.right", points: OmodachiTheme.fontSize("icon-small"))
                        .foregroundStyle(OmodachiTheme.accent)
                }
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(minHeight: NativeBarMetrics.hit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .control(selected: selected)
        .accessibilityIdentifier("herdr-pane-\(pane.id)")
        .accessibilityLabel(name + (subtitle.map { ", " + $0 } ?? "")
                            + (pane.face.map { ", " + AgentFaceWords.word($0) } ?? "")
                            + (unseen ? ", " + Strings.badgeUnseen : ""))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// iPhone portrait: the same rows, folded into one horizontally scrollable
/// strip of pane chips above the terminal.
struct HerdrPaneStrip: View {
    @ObservedObject var store: HerdrStore
    /// OVERVIEW-1: the workspaces' and panes' marks.
    var overview: OverviewReading = .empty

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                ForEach(store.workspaces) { workspace in
                    let mark = overview.worst(session: store.selectedSession, workspace: workspace.id)
                    Tap(action: { store.selectWorkspace(workspace.id) }) {
                        HStack(spacing: OmodachiTheme.space("sm")) {
                            // OVERVIEW-1: the most urgent of its panes.
                            OverviewMark(state: mark)
                            // HERDR-4: the workspace's own label, else its number.
                            Text(verbatim: workspace.label?.isEmpty == false ? workspace.label! : workspace.number.map(String.init) ?? "·")
                                .lineLimit(1)
                                .font(OmodachiTheme.font("caption", weight: .semibold))
                        }
                        .padding(.horizontal, OmodachiTheme.space("lg"))
                        .frame(height: OmodachiTheme.controlHeight)
                    }
                    .control(selected: workspace.id == store.selectedWorkspaceID, bordered: true)
                    .frame(height: NativeBarMetrics.hit)
                    .accessibilityValue(mark.map(OverviewWords.chipLabel) ?? "")
                    .accessibilityIdentifier("herdr-workspace-\(workspace.id)")

                    ForEach(workspace.tabs.flatMap(\.panes)) { pane in
                        Tap(action: { store.select(pane.id) }) {
                            HStack(spacing: OmodachiTheme.space("sm")) {
                                // HERDR-7: the same still marker as the rows.
                                if let marker = pane.marker {
                                    HerdrAgentMarker(mark: marker.mark, role: marker.role)
                                } else {
                                    Rectangle().fill(OmodachiTheme.current.color(pane.status.role))
                                        .frame(width: 6, height: 6)
                                }
                                Text(verbatim: pane.agentName ?? store.layout?.name(of: pane.id) ?? "")
                                    .font(OmodachiTheme.font("caption"))
                                    .lineLimit(1)
                                if pane.isWaiting { HerdrWaitingTag() }
                                // NOTIFY-1 / OVERVIEW-1: finished, not opened since.
                                if overview.row(session: store.selectedSession, pane: pane.id)?.state == .done {
                                    OverviewMark(state: .done)
                                        .accessibilityIdentifier("herdr-unseen-\(pane.id)")
                                }
                            }
                            .padding(.horizontal, OmodachiTheme.space("lg"))
                            .frame(height: OmodachiTheme.controlHeight)
                        }
                        .control(selected: pane.id == store.selected, bordered: true)
                        .frame(height: NativeBarMetrics.hit)
                        .accessibilityIdentifier("herdr-pane-\(pane.id)")
                        .accessibilityLabel((pane.agentName ?? store.layout?.name(of: pane.id) ?? "")
                                            + (pane.face.map { ", " + AgentFaceWords.word($0) } ?? "")
                                            + (overview.row(session: store.selectedSession, pane: pane.id)?.state == .done
                                               ? ", " + Strings.badgeUnseen : ""))
                        .accessibilityAddTraits(pane.id == store.selected ? [.isSelected] : [])
                    }
                }
                if store.selectedSessionStopped == nil {
                    HerdrNewWorkspaceTap(store: store)
                }
            }
            .padding(.horizontal, OmodachiTheme.space("sm"))
        }
        .frame(height: NativeBarMetrics.hit)
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-grid")
    }
}

struct HerdrNoticeRow: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: OmodachiTheme.space("md")) {
            Text(text).font(OmodachiTheme.font("body-small")).lineLimit(3)
                .accessibilityIdentifier("herdr-notice")
            Spacer(minLength: 0)
            Tap(action: onDismiss) { Glyph(symbol: "xmark") }
                .frame(width: NativeBarMetrics.hit, height: 32)
                .accessibilityLabel(Strings.actionDismiss)
                .accessibilityIdentifier("herdr-notice-dismiss")
        }
        .padding(.leading, OmodachiTheme.rowPaddingX)
        .padding(.vertical, OmodachiTheme.space("xs"))
        .frame(minHeight: 32)
        .background(OmodachiTheme.normalFill)
    }
}

/// HERDR-4 §3.3: "Waiting for you", on the row of a pane whose agent is
/// blocked — a word next to the red dot, not the colour alone.
struct HerdrWaitingTag: View {
    var body: some View {
        Text(Strings.herdrWaiting)
            .font(OmodachiTheme.font("caption", weight: .semibold))
            .foregroundStyle(OmodachiTheme.current.color(.red))
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("herdr-waiting")
    }
}
