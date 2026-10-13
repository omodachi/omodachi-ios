import Foundation
import SwiftTerm
import Combine
import UIKit
import os

/// POLISH-U: a frame whose size is not the grid's (see `feed`).
private let herdrGridLog = Logger(subsystem: "app.omodachi", category: "herdr.grid") // non-copy

/// The Herdr surface's whole model: the grid it draws, the pane it is showing,
/// and the one stream behind that pane.
///
/// Herdr is reached through core's official bridge, not SSH. Nothing here
/// starts a shell, attaches a session or injects a key binding: the grid comes
/// from `GET /v1/herdr/layout`, the screen comes from `observe`, and every
/// control is a route.
///
/// HERDR-3, the Collie way: **the phone never takes the pane.** The screen is
/// a read-only mirror (`observe`, which does not touch the PTY); keys, the
/// composer and "Type" are one-shot `/keys` and `/text` calls that take no
/// controller and resize nothing. HERDR-5 removed "Take keyboard": watching at
/// the pane's own size, a full-screen program such as vim is shown as it is
/// and Type drives it, so `control` (and its 409 / take-over / size restore)
/// is no longer opened by the App at all.
@MainActor final class HerdrStore: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
    enum Connection: Equatable, Sendable {
        case idle
        case connecting
        /// Read-only. Many devices may watch the same pane.
        case observing
        case retrying(attempt: Int)
        case unavailable(String)

        var isLive: Bool { self == .observing }
    }

    @Published private(set) var layout: HerdrLayoutDTO?
    /// HERDR-2 §2: the host's sessions, and the one this device is on. The
    /// owned `omodachi` session is the default; the user's own sessions are
    /// listed because that is where their work actually is.
    @Published private(set) var sessions: [HerdrSessionDTO] = []
    @Published private(set) var selectedSession: String?
    @Published private(set) var ownedSession: String?
    @Published private(set) var switchingSession = false
    @Published private(set) var selected: String?
    @Published private(set) var connection: Connection = .idle
    @Published private(set) var loadingLayout = false
    /// The one line of copy the surface shows. It is either core's own reason
    /// or a sentence this client owns — never host terminal output.
    @Published var notice: String?
    @Published private(set) var columns = 80
    @Published private(set) var rows = 24

    // MARK: HERDR-5 state
    /// The stopped session being started (the switcher's spinner and words).
    @Published private(set) var startingSession: String?
    /// The new-session card is open under the switcher.
    @Published var newSessionOpen = false
    /// OVERVIEW-1: the "Needs you" list is open under the switcher.
    @Published var overviewOpen = false
    /// A create in flight, and what the card says when one failed.
    @Published private(set) var creatingSession = false
    @Published var newSessionError: String?

    // MARK: HERDR-6 state
    /// The new-workspace card is open under the switcher.
    @Published private(set) var newWorkspaceOpen = false
    @Published var recentFolders: [HerdrFolderDTO] = []
    @Published var commonFolders: [HerdrFolderDTO] = []
    @Published var loadingFolders = false
    /// The card's one-level browser, when it is open.
    @Published private(set) var folderBrowse: HerdrFolderBrowseDTO?
    @Published private(set) var browsingFolders = false
    @Published private(set) var showHiddenFolders = false
    @Published private(set) var creatingWorkspace = false
    @Published var newWorkspaceError: String?
    /// The first pane of a workspace this device just made: the next layout
    /// that has it lands on it (this device's own view; the computer stays).
    private(set) var pendingWorkspacePane: String?
    private var foldersTask: Task<Void, Never>?

    // MARK: HERDR-11 state
    /// The folders starred on this host, and what a new workspace may start
    /// with. Both stay empty with a core from before HERDR-11, and then the
    /// card shows no stars and no Start row.
    @Published var favouriteFolders: [HerdrFolderDTO] = []
    @Published var launchers: [HerdrLauncherDTO] = []
    /// Whether this host keeps favourites at all (a HERDR-11 core).
    @Published var favouritesSupported = false
    /// The launcher the card will start; nil is a plain shell. Remembered.
    @Published var chosenLauncher: String?
    /// The mirror is not known to be current: no word from the host or from
    /// the watching socket for a few seconds. It is dimmed, with when it was.
    @Published var mirrorStale = false
    /// When the mirror was last known to be the pane's screen (a frame, or a
    /// pong on its socket).
    @Published var mirrorSeenAt: Date?
    /// The host answers, Herdr on it does not.
    @Published private(set) var herdrDown = false
    var layoutETag: String?
    var layoutAgain = false
    var staleTask: Task<Void, Never>?
    var lastStaleRestart = Date.distantPast
    var networkReturnsSeen = 0

    // MARK: HERDR-3 state
    /// "Type into terminal": keystrokes go to `/keys`. Never persisted; off
    /// when the pane, the panel or the app changes.
    @Published private(set) var typing = false
    /// What the composer says under itself after a send.
    @Published private(set) var sendState: HerdrSendState = .idle
    /// One draft per pane, in memory only.
    @Published private var drafts: [String: String] = [:]
    /// Counts key sends, so the keys row can tick a haptic on each.
    @Published private(set) var keyTicks = 0
    /// Typing turns itself off after this long without a key.
    static let typingIdleLimit: Duration = .seconds(300)

    // MARK: HERDR-9 state
    /// The choices the pane is asking for right now (a menu or a yes-or-no
    /// question), read off the screen the mirror shows.
    @Published private(set) var choices: HerdrChoices?
    /// The choices that were just answered: the strip waits for the screen
    /// to move on rather than taking a second tap at the same question.
    @Published private(set) var answeredSignature: String?
    /// The keys that just went to the pane, shown for a moment so a person
    /// knows they arrived (Type, the composer's pass-through, a choice).
    @Published private(set) var echo: [HerdrKeyEcho] = []
    private var echoSerial = 0
    private var echoTask: Task<Void, Never>?
    private var choicesTask: Task<Void, Never>?
    private var answeredTask: Task<Void, Never>?
    /// How long an echo stays.
    static let echoLifetime: Duration = .milliseconds(1500)
    /// Tests and the simulator's UI fixture take the writes here instead of
    /// a host. Never set in the shipped app.
    var writeOverride: (@MainActor (String, HerdrWrite) -> Void)?
    /// The UI fixture's record of what went out (`HerdrChoicesFixture`).
    @Published var fixtureSent: [String] = []

    /// HERDR-10, the UI fixture only: the grid's size, read by the test.
    var fixtureGridLine: String {
        "grid \(terminal.getTerminal().cols)x\(terminal.getTerminal().rows)" // non-copy: a test line
    }

    /// The UI fixture: the pane on show draws `text` as its new screen, the
    /// way a pane answers a key.
    func showFixtureScreen(_ text: String) {
        demoScreen = text
        terminal.getTerminal().resetToInitialState()
        terminal.feed(byteArray: Array(text.utf8)[...])
        refreshWrap(immediately: true)
        refreshChoices(immediately: true)
    }

    // MARK: HERDR-4 state
    /// The Quick dock, key presets and harness segment for the pane on screen
    /// (`GET /v1/herdr/operator-rows`). What ships until core has answered.
    @Published private(set) var operatorRows: HerdrOperatorRowsDTO = .shipped(agent: nil)
    @Published private(set) var quickOpen = false
    /// HERDR-8: on a phone held upright the keys rows are folded behind a
    /// Keys toggle in the bar; this is whether they are out.
    @Published private(set) var keysOpen = false
    /// A `danger` / `confirm` row tapped once: the second tap fires it.
    @Published private(set) var armed: HerdrArmed?
    /// The zoom the screen settled at (fit to width, 1:1, or a pinch).
    @Published private(set) var zoom: HerdrFitView.Zoom = .fit
    /// HERDR-8: how the mirror shows the pane — wrapped text, the grid fitted
    /// to the width, or the grid at its own size. Chosen per kind of pane and
    /// remembered (`HerdrMirrorPreference`).
    @Published private(set) var mirrorMode: HerdrMirrorMode = .fit
    /// HERDR-8: the pane is showing a full-screen program (vim, htop), so Wrap
    /// shows the grid instead and says why in one line.
    @Published private(set) var fullScreenFallback = false
    /// Wrap was chosen on purpose while a full-screen program was up.
    private var wrapForced = false
    /// The cursor is showing (Herdr's `?25h` / `?25l`), for the wrap view.
    private var cursorVisible = true
    private var wrapTask: Task<Void, Never>?
    var mirrorPreference = HerdrMirrorPreference(defaults: AppDefaults.shared)
    private var rowsTask: Task<Void, Never>?
    /// The agent the rows on hand were read for (nil = a shell).
    private var rowsFor: String??
    private var armTask: Task<Void, Never>?

    unowned let home: HomeStore
    private var stream: HerdrPaneStream?
    private var streamMode: HerdrStreamMode = .observe
    private var retryTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// HERDR-2 §1. The layout used to be read exactly once per appearance, so
    /// a read that landed before the host connection was up left the surface
    /// on `.unavailable` with nothing to ask again: `herdr.layout.changed`
    /// only fires when the projection *moves*, and a quiet session never does.
    private var layoutRetryTask: Task<Void, Never>?
    private var layoutAttempt = 0
    private var sessionTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var attempt = 0
    /// §1.1: after every (re)connect the screen is repainted from a `full`
    /// frame. An increment that arrives before one has nothing to apply to, so
    /// it is dropped rather than painted onto a stale buffer.
    private var awaitingFullFrame = true
    private var generation = UUID()
    /// Writes into panes go one at a time, in the order they were made, so a
    /// key typed after a paste cannot overtake it.
    private var writeQueue: [(pane: String, write: HerdrWrite,
                              done: (@MainActor (Result<HerdrTextResultDTO?, Error>) -> Void)?)] = []
    private var writing = false
    /// Type mode's keystrokes, gathered for one run-loop tick.
    private var typedBytes: [UInt8] = []
    private var typedFlushScheduled = false
    private var typingIdleTask: Task<Void, Never>?
    private var sentClearTask: Task<Void, Never>?
    /// A new tab was asked for in this workspace; the panes it already had.
    private var pendingNewTab: (workspace: String, known: Set<String>)?
    var appeared = false
    /// SwiftUI mounts the replacement before it unmounts the original, so a
    /// layout change arrives as `onAppear` followed by the *old* view's
    /// `onDisappear`. Counting them is what keeps that from tearing down a
    /// stream the user never left.
    private var appearances = 0
    /// The geometry the current stream was started with. SwiftTerm reports its
    /// real size after the socket is already opening, so the two are reconciled
    /// on `opened` rather than left at the 80×24 the view was born with.
    private var openedWith: (cols: Int, rows: Int) = (80, 24)

    /// ④ has no size control of its own; the pane's geometry is the host's.
    static let fontSize: CGFloat = 13

    lazy var terminal: HerdrTerminalView = {
        // POLISH-U: no scrollback, and the terminal never scrolls itself.
        // `observe` sends the pane's *screen*: lines Herdr's frames push off
        // the top are not history, they are leftovers of a redraw. SwiftTerm's
        // view is a scroll view of its own, so with a scrollback a vertical
        // pan on the mirror at Actual size scrolled *it* into those leftovers
        // (and froze it there while codex kept writing), and following the
        // bottom it rested half a row into them - the stale rows and codex's
        // live redraws then landed on the same screen: the "garbled" mirror.
        // The fit view does all the panning; the terminal is exactly the
        // pane's screen, `contentOffset` zero, always.
        let view = HerdrTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400),
                                     font: OmodachiTheme.uiFont(size: Self.fontSize),
                                     options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 0))
        view.isScrollEnabled = false
        view.scrollsToTop = false
        // TERM-1. The initialiser takes one font; the cascade needs all four.
        TerminalFont.apply(to: view, size: Self.fontSize)
        view.terminalDelegate = self
        view.inputAccessoryView = nil
        view.optionAsMetaKey = true
        view.accessibilityIdentifier = "herdr-terminal"
        // HERDR-3: tapping the mirror no longer raises a keyboard (or takes
        // the pane). It accepts input only while Type or Take keyboard is on.
        view.inputAllowed = false
        view.onFirstResponder = { [weak self] active in self?.firstResponderChanged(active) }
        // ⌘[ ⌘], listed in the iPad's ⌘ overlay — now they act.
        view.onSemanticAction = { [weak self] action in self?.run(action) }
        // LINKS-1: a link the program marked (OSC 8) is underlined and opens
        // on a tap; the default `.hover` needs a pointer a finger never is.
        view.linkHighlightMode = .always
        TerminalPalette.apply(to: view)
        return view
    }()

    /// HERDR-4: the terminal inside the view that fits a wide pane to the
    /// panel's width (pinch, pan, double tap), never resizing the pane.
    lazy var fitView: HerdrFitView = {
        let view = HerdrFitView(terminal: terminal)
        view.onZoomChanged = { [weak self] zoom, _ in self?.zoom = zoom }
        // HERDR-8: a double tap steps through Wrap, Fit and Actual.
        view.onDoubleTap = { [weak self] point in self?.cycleMirror(around: point) }
        // HERDR-5: a tap on the mirror puts the composer's keyboard away -
        // on an iPhone there is no other way to, short of leaving the panel.
        // LINKS-1: and a tap on a link opens it.
        view.onSingleTap = { [weak self] point in self?.mirrorTapped(at: point) }
        return view
    }()

    /// HERDR-8: the pane's rows as text that fits the phone.
    lazy var wrapView: HerdrWrapView = {
        let view = HerdrWrapView(fontSize: Self.fontSize)
        view.onDoubleTap = { [weak self] in self?.cycleMirror(around: nil) }
        view.onSingleTap = { [weak self] in self?.mirrorTapped(at: nil) }
        view.onLink = { [weak self] raw in
            if let target = LinkTarget.classify(raw) { self?.openLink(target) }
        }
        view.onWidthChanged = { [weak self] in self?.refreshWrap(immediately: true) }
        return view
    }()

    /// HERDR-8: the grid and the wrapped text, one of them showing.
    lazy var mirrorView: HerdrMirrorView = HerdrMirrorView(fit: fitView, wrap: wrapView)

    init(home: HomeStore) {
        self.home = home
        chosenLauncher = HerdrLauncherPreference(defaults: home.defaults).launcher
        super.init()
        attachments = AttachmentTray(
            uploader: { [weak self] in
                guard let self else { throw CompanionHostError.notConnected }
                if self.home.demoActive { return DemoAttachmentUploader() }
                return try self.home.chatClient(for: self.home.profile.companionURL)
            },
            target: { [weak self] in UploadTarget(kind: "herdr", session: self?.selectedSession, pane: self?.selected) },
            readDraft: { [weak self] in self?.draft ?? "" },
            writeDraft: { [weak self] in self?.draft = $0 })
        // The composer's Send reads the tray, so a chip that finished
        // uploading has to redraw what observes this store.
        attachmentsWatch = attachments.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// ATTACH-1: the chips above the composer, for the selected pane's draft.
    /// Another pane drops them (and their files).
    private(set) var attachments: AttachmentTray!
    private var attachmentsWatch: AnyCancellable?

    // MARK: - Layout

    /// STORE-6 §A3. The demo's session, grid and pane text, read once; `nil`
    /// whenever the demo is not on, which is every path below but these.
    var demoData: DemoHost.Herdr? {
        guard home.demoActive else { cachedDemo = nil; return nil }
        if cachedDemo == nil { cachedDemo = DemoHost.herdr() }
        return cachedDemo
    }
    private var cachedDemo: DemoHost.Herdr?

    var workspaces: [HerdrWorkspaceDTO] { layout?.workspaces ?? [] }
    var selectedPane: HerdrPaneDTO? { selected.flatMap { layout?.pane($0) } }
    var selectedWorkspaceID: String? { selected.flatMap { layout?.workspace(of: $0)?.id } }

    /// The lightweight bar's status line for this surface (§3).
    var barStatus: String {
        switch connection {
        case .idle: "idle"
        case .connecting: "connecting"
        case .observing: "observing"
        case .retrying(let attempt): "reconnecting \(attempt)"
        case .unavailable: "unavailable"
        }
    }

    var barTitle: String { selected.flatMap { layout?.name(of: $0) } ?? "Herdr" } // non-copy: the product's name

    /// HERDR-4: the pane on screen as a person names it (title, folder,
    /// agent, or "Pane 2") — never Herdr's `w1:p2`.
    var selectedPaneName: String { selected.flatMap { layout?.name(of: $0) } ?? "" }

    /// SwiftUI remounts this view for reasons that have nothing to do with the
    /// user leaving — a size-class change, the Panel folding — and each remount
    /// is an `onDisappear` that released the stream followed by an `onAppear`.
    /// So appearing reopens the pane it was already on rather than assuming a
    /// fresh surface.
    func appear() {
        appearances += 1
        appeared = true
        refreshLayout()
        refreshSessions()
        if selected != nil, !connection.isLive, stream == nil { openStream() }
        startStaleWatch()
    }

    func disappear() {
        appearances -= 1
        guard appearances <= 0 else { return }
        appearances = 0
        appeared = false
        stopTyping()
        releaseStream()
        retryTask?.cancel(); retryTask = nil
        loadTask?.cancel(); loadTask = nil
        layoutRetryTask?.cancel(); layoutRetryTask = nil
        sessionTask?.cancel(); sessionTask = nil
        staleTask?.cancel(); staleTask = nil
        mirrorStale = false
        connection = .idle
    }

    /// The host connection came up (or went away) while this surface was on
    /// screen. A surface that failed its one read has to be told, because the
    /// failure it is sitting on is not a Herdr failure at all.
    func hostConnectionChanged(connected: Bool) {
        guard appeared else { return }
        layoutRetryTask?.cancel(); layoutRetryTask = nil
        layoutAttempt = 0
        guard connected else { return }
        refreshLayout()
        refreshSessions()
        refreshRows(force: true)
        // HERDR-3: coming back from the background, the app reconnects to the
        // host after the scene is already active, so the mirror is reopened
        // here too — otherwise it sits on its last frame.
        if selected != nil, mirrorIsDown { reopenAfterBackground() }
    }

    /// HERDR-11 §4: `herdr.layout.changed` for some session. Only this
    /// panel's own session is worth a read; nil is a core that did not say.
    func layoutChanged(session: String?) {
        guard Self.layoutEventIsMine(session: session, mine: selectedSession ?? ownedSession) else { return }
        refreshLayout()
    }

    static func layoutEventIsMine(session: String?, mine: String?) -> Bool {
        guard let session else { return true }
        return mine == nil || session == mine
    }

    /// The host said the projection moved. The snapshot is the reading that
    /// cannot be wrong, so the client re-reads it rather than patching.
    func refreshLayout() {
        guard appeared else { return }
        guard loadTask == nil else {
            // HERDR-11: a change that arrives mid-read gets a read of its own,
            // instead of being dropped with nothing to ask again.
            layoutAgain = true
            return
        }
        if let demo = demoData {
            apply(demo.layout)
            return
        }
        let current = generation
        loadingLayout = layout == nil
        let known = layout == nil ? nil : layoutETag
        loadTask = Task { [weak self] in
            defer {
                if let self {
                    self.loadTask = nil
                    if self.layoutAgain { self.layoutAgain = false; self.refreshLayout() }
                }
            }
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                // HERDR-11 §4: `304` when this device already has this revision.
                let (value, etag) = try await client.herdrLayout(etag: known)
                guard self.generation == current, self.appeared else { return }
                self.herdrDown = false
                self.layoutETag = etag
                if let value { self.apply(value) } else { self.loadingLayout = false }
            } catch {
                guard self.generation == current, self.appeared else { return }
                self.loadingLayout = false
                self.layoutETag = nil
                // HERDR-11 §3: the host answered and said Herdr does not -
                // that is a cause of its own, said in the panel's banner.
                let down = (error as? HerdrRequestError).map { $0.code == "herdr_unavailable" && $0.status == 503 } ?? false
                self.herdrDown = down && self.home.health.isLive
                if self.layout == nil { self.connection = .unavailable(Self.message(error)) }
                // A stopped session says so, with its Start, instead.
                if self.selectedSessionStopped == nil, !self.herdrDown { self.notice = Self.message(error) }
                // HERDR-5: a session that stopped under the panel shows up
                // as stopped (with its Start item) instead of a stale list.
                self.refreshSessions()
                self.scheduleLayoutRetry()
            }
        }
    }

    /// §1: a failed read asks again. The same bounded backoff the stream uses,
    /// so a host that is down is not hammered and a host that comes back is
    /// picked up without the user having to leave the surface and return.
    private func scheduleLayoutRetry() {
        guard appeared, layoutRetryTask == nil else { return }
        layoutAttempt += 1
        let delay = HerdrReconnectPolicy.delay(attempt: layoutAttempt)
        let current = generation
        layoutRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.generation == current, self.appeared, !Task.isCancelled else { return }
            self.layoutRetryTask = nil
            self.refreshLayout()
        }
    }

    // MARK: - Sessions

    var sessionTitle: String { selectedSession ?? ownedSession ?? "Herdr" }

    /// HERDR-5: the session on screen, when the host says it is stopped.
    var selectedSessionStopped: String? {
        guard let name = selectedSession, let row = sessions.first(where: { $0.name == name }), !row.running
        else { return nil }
        return name
    }

    /// The list is read on entry and after every switch. It is cheap — one
    /// `herdr session list` plus one snapshot per session on the host — and it
    /// is the only thing that knows a session appeared or stopped.
    func refreshSessions() {
        guard appeared, sessionTask == nil else { return }
        if let demo = demoData {
            sessions = demo.sessions.sessions
            selectedSession = demo.sessions.selected
            ownedSession = demo.sessions.owned
            return
        }
        let current = generation
        sessionTask = Task { [weak self] in
            defer { self?.sessionTask = nil }
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                let value = try await client.herdrSessions()
                guard self.generation == current, self.appeared else { return }
                self.sessions = value.sessions
                self.selectedSession = value.selected
                self.ownedSession = value.owned
                self.showStoppedIfSo()
            } catch {
                // A listing this client could not read is not a reason to say
                // anything: the layout below it already reports the host.
                guard self.generation == current, self.appeared else { return }
                if self.sessions.isEmpty { self.selectedSession = nil }
            }
        }
    }

    /// Switching session throws away everything that belonged to the old one —
    /// the stream, the grid and the emulator's buffer — because none of it is
    /// true of the new session, and a stale screen under a new name is worse
    /// than an empty one.
    func selectSession(_ name: String) {
        guard name != selectedSession, !switchingSession, demoData == nil else { return }
        switchSession(to: name) { client in
            let value = try await client.herdrSelectSession(name)
            return (value.selected, value.owned)
        }
    }

    /// HERDR-5: the session on screen was stopped on the computer. Its last
    /// picture is not true any more, so it goes, and the stage offers Start
    /// (the layout keeps being asked for, so one started at the desk shows up).
    private func showStoppedIfSo() {
        guard selectedSessionStopped != nil, !switchingSession else { return }
        // "Not answering" was about this: the stage says stopped instead.
        notice = nil
        connection = .idle
        guard layout != nil || selected != nil else { return }
        stopTyping()
        releaseStream()
        selected = nil
        layout = nil
        terminal.getTerminal().resetToInitialState()
        wrapView.reset()
        wrapTask?.cancel(); wrapTask = nil
    }

    /// HERDR-5: a stopped session in the switcher. core starts it on the
    /// computer with no window (Herdr brings its workspaces back) and moves
    /// this device into it, so the panel lands there in one go.
    func startSession(_ name: String) {
        guard !switchingSession else { return }
        guard demoData == nil else { notice = Strings.demoHerdrControls; return }
        startingSession = name
        switchSession(to: name) { client in
            let value = try await client.herdrStartSession(name)
            return (value.selected, value.owned)
        }
    }

    /// HERDR-5: "New session…". The card stays open, with the reason in
    /// words, when core says no; it closes once the panel is in the new one.
    func openNewSession() {
        guard demoData == nil else { notice = Strings.demoHerdrControls; return }
        cancelNewWorkspace()
        overviewOpen = false
        newSessionError = nil
        newSessionOpen = true
    }

    func cancelNewSession() {
        newSessionOpen = false
        newSessionError = nil
    }

    func createSession(_ typed: String) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !creatingSession, !switchingSession else { return }
        guard demoData == nil else { notice = Strings.demoHerdrControls; return }
        guard CompanionHostClient.isNewHerdrSession(name) else {
            newSessionError = ReasonText.message("invalid_session_name", domain: .herdr) // non-copy: a reason code
            return
        }
        if sessions.contains(where: { $0.name == name }) {
            newSessionError = ReasonText.message("herdr_session_exists", domain: .herdr) // non-copy: a reason code
            return
        }
        creatingSession = true
        newSessionError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                let value = try await client.herdrCreateSession(name)
                self.creatingSession = false
                self.newSessionOpen = false
                self.landIn(value.selected, owned: value.owned)
            } catch {
                self.creatingSession = false
                self.newSessionError = Self.message(error)
            }
        }
    }

    // MARK: - HERDR-6: a new workspace in a folder

    /// "New workspace…": the card under the switcher, with the folders core
    /// offers. No folders (an older core, Herdr not answering) still leaves
    /// the path field.
    func openNewWorkspace() {
        overviewOpen = false
        if demoData != nil, let fixture = HERDR11Fixture.folders {
            // HERDR-11, simulator UI runs only: the card over fixture folders.
            newSessionOpen = false
            newWorkspaceError = nil
            folderBrowse = nil
            newWorkspaceOpen = true
            applyFolders(fixture)
            return
        }
        guard demoData == nil else { notice = Strings.demoHerdrControls; return }
        newSessionOpen = false
        newWorkspaceError = nil
        folderBrowse = nil
        showHiddenFolders = false
        newWorkspaceOpen = true
        loadingFolders = true
        foldersTask?.cancel()
        foldersTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                let value = try await client.herdrFolders()
                guard !Task.isCancelled, self.newWorkspaceOpen else { return }
                self.applyFolders(value)
            } catch {
                guard !Task.isCancelled, self.newWorkspaceOpen else { return }
                if (error as? HerdrRequestError)?.status != 404 { self.newWorkspaceError = Self.message(error) }
            }
            self.loadingFolders = false
        }
    }

    func cancelNewWorkspace() {
        foldersTask?.cancel(); foldersTask = nil
        newWorkspaceOpen = false
        newWorkspaceError = nil
        folderBrowse = nil
        loadingFolders = false
        browsingFolders = false
    }

    /// One level of a folder. Opening a folder is choosing it: the card's
    /// path becomes what the browser shows (`display`, returned here).
    @discardableResult
    func browseFolder(_ path: String, hidden: Bool? = nil) async -> String? {
        let typed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.folderProblem(typed) {
            newWorkspaceError = ReasonText.message(problem, domain: .herdr)
            return nil
        }
        browsingFolders = true
        newWorkspaceError = nil
        defer { browsingFolders = false }
        do {
            let client = try home.chatClient(for: home.profile.companionURL)
            let value = try await client.herdrFolders(under: typed, hidden: hidden ?? showHiddenFolders)
            guard newWorkspaceOpen, let browse = value.browse else { return nil }
            folderBrowse = browse
            showHiddenFolders = browse.hidden
            return browse.display
        } catch {
            if newWorkspaceOpen { newWorkspaceError = Self.message(error) }
            return nil
        }
    }

    func closeFolderBrowser() { folderBrowse = nil }

    /// Create: a workspace in that folder, in the session on screen; the
    /// panel lands on its first pane. The card stays, with core's reason in
    /// words, when core says no.
    func createWorkspace(path: String, name: String) {
        guard !creatingWorkspace, !switchingSession else { return }
        // HERDR-11: an empty folder is the home folder.
        let folder = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let launch = launchers.first { $0.command == chosenLauncher }
        if demoData != nil, HERDR11Fixture.folders != nil {
            fixtureSent.append("create cwd=\(folder.isEmpty ? "~" : folder) launch=\(launch?.command ?? "-")") // non-copy: a test line
            cancelNewWorkspace()
            return
        }
        guard demoData == nil else { notice = Strings.demoHerdrControls; return }
        if let problem = (folder.isEmpty ? nil : Self.folderProblem(folder)) ?? Self.workspaceNameProblem(label) {
            newWorkspaceError = ReasonText.message(problem, domain: .herdr)
            return
        }
        guard let session = selectedSession ?? ownedSession else {
            newWorkspaceError = ReasonText.message("herdr_unavailable", domain: .herdr) // non-copy: a reason code
            return
        }
        creatingWorkspace = true
        newWorkspaceError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                let value = try await client.herdrCreateWorkspace(session: session, cwd: folder,
                                                                  name: label.isEmpty ? nil : label,
                                                                  launch: launch?.command)
                self.creatingWorkspace = false
                self.cancelNewWorkspace()
                if value.selected != self.selectedSession {
                    self.landIn(value.selected, owned: value.owned)
                }
                self.pendingWorkspacePane = value.workspace.pane
                // HERDR-11: a launcher that could not be typed leaves a shell;
                // that is said once, and nothing else is tried.
                if let launched = value.launch, !launched.sent, let launch {
                    self.notice = Strings.herdrLaunchNotSent(launch.label)
                } else {
                    self.notice = nil
                }
                self.refreshLayout()
                self.refreshSessions()
            } catch {
                self.creatingWorkspace = false
                self.newWorkspaceError = Self.message(error)
            }
        }
    }

    /// The card's own early words, the codes core would answer with.
    static func folderProblem(_ path: String) -> String? {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.count > 4096 || value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return "invalid_folder" // non-copy: a reason code
        }
        return nil
    }

    static func workspaceNameProblem(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.unicodeScalars.count > 64 || value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return "invalid_workspace_name" // non-copy: a reason code
        }
        return nil
    }

    /// The panel moved to a session core has already selected for it.
    private func landIn(_ name: String, owned: String) {
        resetForSession()
        selectedSession = name
        ownedSession = owned
        notice = nil
        refreshLayout()
        refreshSessions()
    }

    private func resetForSession() {
        stopTyping()
        releaseStream()
        layoutRetryTask?.cancel(); layoutRetryTask = nil
        layoutAttempt = 0
        generation = UUID()
        selected = nil
        layout = nil
        layoutETag = nil
        awaitingFullFrame = true
        terminal.getTerminal().resetToInitialState()
        wrapView.reset()
        wrapTask?.cancel(); wrapTask = nil
    }

    private func switchSession(to name: String,
                               _ call: @escaping @MainActor (CompanionHostClient) async throws -> (String, String)) {
        stopTyping()
        releaseStream()
        layoutRetryTask?.cancel(); layoutRetryTask = nil
        layoutAttempt = 0
        generation = UUID()
        selected = nil
        layout = nil
        connection = .connecting
        switchingSession = true
        awaitingFullFrame = true
        terminal.getTerminal().resetToInitialState()
        wrapView.reset()
        wrapTask?.cancel(); wrapTask = nil
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                let (selected, owned) = try await call(client)
                guard self.generation == current else { return }
                self.selectedSession = selected
                self.ownedSession = owned
                self.switchingSession = false
                self.startingSession = nil
                self.notice = nil
                self.refreshLayout()
                self.refreshSessions()
            } catch {
                guard self.generation == current else { return }
                self.switchingSession = false
                self.startingSession = nil
                self.connection = .unavailable(Self.message(error))
                self.notice = Self.message(error)
                self.refreshSessions()
            }
        }
    }

    func apply(_ value: HerdrLayoutDTO) {
        layout = value
        loadingLayout = false
        layoutRetryTask?.cancel(); layoutRetryTask = nil
        layoutAttempt = 0
        if let session = value.session { selectedSession = session }
        if connection == .unavailable("") { connection = .idle }
        if case .unavailable = connection { connection = .idle }
        // HERDR-6: a workspace this device just made - show its pane, without
        // asking the computer to look at it too.
        if let wanted = pendingWorkspacePane, value.pane(wanted) != nil {
            pendingWorkspacePane = nil
            select(wanted)
            return
        }
        guard let current = selected, value.pane(current) != nil else {
            // The pane we were on is gone (someone closed it, here or there).
            // Fall to whatever Herdr says is focused rather than to nothing.
            select(value.preferredPane)
            return
        }
        // A tab this device just made: show its pane, without asking the
        // computer to look at it too.
        if let pending = pendingNewTab,
           let fresh = value.workspaces.first(where: { $0.id == pending.workspace })?
            .tabs.flatMap(\.panes).first(where: { !pending.known.contains($0.id) }) {
            pendingNewTab = nil
            select(fresh.id)
            return
        }
        // HERDR-4: the pane changed size on the computer (a window resized):
        // the mirror follows it, still at the pane's own size.
        updateFit()
        if streamMode == .observe, stream != nil, let pane = paneGeometry, pane != openedWith { sendResize(pane) }
        refreshRows()
    }

    // MARK: - Selection

    /// HERDR-3: choosing a pane here never moves the computer. It used to call
    /// `pane.focus`, which switches the desktop's pane, tab and workspace under
    /// whoever is sitting there; HERDR-5 took away "Show on the computer", the
    /// last thing that asked for it, so the App never calls it now.
    func select(_ pane: String?) {
        guard pane != selected else {
            // Same pane: this is a re-entry, not a change. Reopen only if the
            // stream is actually gone.
            if pane != nil, !connection.isLive, stream == nil { openStream() }
            return
        }
        stopTyping()
        releaseStream()
        attachments.discard()
        selected = pane
        // HERDR-11: a pane's "last update" is that pane's.
        mirrorSeenAt = nil
        mirrorStale = false
        awaitingFullFrame = true
        sendState = .idle
        choices = nil
        answeredSignature = nil
        echo = []
        quickOpen = false
        armed = nil
        terminal.getTerminal().resetToInitialState()
        // HERDR-10: the wrapped text is this pane's from the first frame on,
        // never the last pane's; a selection on the grid goes too.
        wrapView.reset()
        wrapTask?.cancel(); wrapTask = nil
        fitView.clearSelection()
        fitView.resetZoom()
        zoom = .fit
        // HERDR-8: the mode this kind of pane was last shown in.
        mirrorMode = mirrorPreference.mode(agent: HerdrPaneKind.agentName(selectedPane))
        wrapForced = false
        fullScreenFallback = false
        cursorVisible = true
        if mirrorMode == .actual { fitView.setZoom(.actual) }
        applyMirror()
        updateFit()
        refreshRows()
        guard pane != nil else { connection = .idle; return }
        openStream()
    }

    /// HERDR-3: a workspace tapped here is chosen here. It used to run
    /// `herdr workspace focus`, which moved the computer's screen the same way
    /// `pane.focus` did; now it shows that workspace's own pane — the focused
    /// one in its active tab, else its first — and the computer stays put.
    func selectWorkspace(_ id: String) {
        guard let workspace = layout?.workspaces.first(where: { $0.id == id }) else { return }
        let active = workspace.tabs.first { $0.id == workspace.activeTabID } ?? workspace.tabs.first
        let pane = active?.panes.first(where: \.focused) ?? active?.panes.first
            ?? workspace.tabs.flatMap(\.panes).first
        if let pane { select(pane.id) }
    }

    // MARK: - Streaming

    private func openStream() {
        let mode = HerdrStreamMode.observe
        guard let pane = selected else { return }
        if let demo = demoData {
            // The demo's pane is text the app carries, painted once, read-only.
            streamMode = .observe
            awaitingFullFrame = false
            terminal.getTerminal().resetToInitialState()
            // HERDR-9: drawn at the pane's own size, as a real frame is, so
            // its rows are the rows the choices are read from.
            if let size = paneGeometry, size.cols != terminal.getTerminal().cols || size.rows != terminal.getTerminal().rows {
                terminal.getTerminal().resize(cols: size.cols, rows: size.rows)
            }
            demoScreen = demo.screens[pane] ?? ""
            terminal.feed(byteArray: Array(demoScreen.utf8)[...])
            connection = .observing
            mirrorSeen()
            refreshWrap(immediately: true)
            refreshChoices(immediately: true)
            return
        }
        guard let client = try? home.chatClient(for: home.profile.companionURL) else {
            connection = .unavailable(Strings.hostErrorNotConnected)
            return
        }
        stream?.stop()
        streamMode = mode
        awaitingFullFrame = true
        connection = .connecting
        let value = HerdrPaneStream(client: client, pane: pane, mode: mode, takeover: false)
        stream = value
        // HERDR-4: observe opens at the pane's own size, so a wide desktop
        // pane is never cut to the phone's width; the view fits it instead.
        let geometry = paneGeometry ?? HerdrGeometry.clamp(cols: columns, rows: rows)
        openedWith = geometry
        // HERDR-10: the grid is the pane's size before the first frame, not
        // whatever the view's layout has made of it so far.
        if let size = paneGeometry, size.cols != terminal.getTerminal().cols || size.rows != terminal.getTerminal().rows {
            terminal.getTerminal().resize(cols: size.cols, rows: size.rows)
        }
        let current = generation
        value.start(cols: geometry.cols, rows: geometry.rows) { [weak self, weak value] event in
            // A stream being released (its release frame still on the way)
            // is no longer this surface's: only the current one may act.
            guard let self, let value, self.stream === value,
                  self.generation == current, self.selected == pane else { return }
            self.handle(event, pane: pane, mode: mode)
        }
    }

    private func handle(_ event: HerdrPaneStream.Event, pane: String, mode: HerdrStreamMode) {
        switch event {
        case .opened:
            attempt = 0
            connection = .observing
            mirrorSeen()
            let current = paneGeometry ?? HerdrGeometry.clamp(cols: columns, rows: rows)
            if current != openedWith { sendResize(current) }
        case .controlInUse:
            // Only `control` is ever refused with 409, and the App no longer
            // opens it (HERDR-5); a watcher has nothing to be refused.
            break
        case .alive:
            mirrorSeen()
        case .message(let message):
            mirrorSeen()
            switch message {
            case .frame(let frame): feed(frame)
            case .closed(let reason):
                notice = reason.map { Strings.herdrStreamClosed($0) } ?? notice
                scheduleReconnect()
            case .other: break
            }
        case .ended:
            scheduleReconnect()
        }
    }

    func feed(_ frame: HerdrFrame) {
        // A frame drawn for another size than the grid holds lands on the
        // wrong cells: Herdr places every row (and every wide character) by
        // absolute position, so on a narrower grid a long row wraps onto the
        // next and a CJK character past the edge drops to the next row's
        // first cell (HERDR-10, Leo's garbled Chinese mirror). Observe opens
        // at the pane's size and the view holds exactly that, so this should
        // never happen; when it does, the frame's own size wins: the grid is
        // put back to it, and an increment - which only redraws what changed
        // - is not painted onto cells that moved; a full frame is asked for.
        let grid = terminal.getTerminal()
        if let width = frame.width, let height = frame.height, width != grid.cols || height != grid.rows {
            herdrGridLog.error("frame \(width)x\(height) full=\(frame.full) on a \(grid.cols)x\(grid.rows) grid") // non-copy
            let size = HerdrGeometry.clamp(cols: width, rows: height)
            grid.resize(cols: size.cols, rows: size.rows)
            if !frame.full {
                requestRepaint()
                return
            }
        }
        if frame.full {
            let first = awaitingFullFrame
            awaitingFullFrame = false
            terminal.feed(byteArray: frame.bytes[...])
            noteCursor(frame.bytes)
            // HERDR-4: the first picture of a pane shows where its cursor is.
            if first, fitView.zoomMode != .custom { fitView.revealCursor() }
            refreshWrap(immediately: first)
            refreshChoices(immediately: first)
            return
        }
        // An increment before the first full frame has no base; asking for one
        // is cheaper than painting nonsense.
        guard !awaitingFullFrame else { return }
        terminal.feed(byteArray: frame.bytes[...])
        noteCursor(frame.bytes)
        refreshWrap()
        refreshChoices()
    }

    // MARK: - Wrap (HERDR-8)

    /// The last `?25h` / `?25l` in a frame says whether the cursor shows.
    private func noteCursor(_ bytes: [UInt8]) {
        let show: [UInt8] = [0x1b, 0x5b, 0x3f, 0x32, 0x35, 0x68], hide: [UInt8] = [0x1b, 0x5b, 0x3f, 0x32, 0x35, 0x6c]
        guard bytes.count >= 6 else { return }
        var index = bytes.count - 6
        while index >= 0 {
            if bytes[index] == 0x1b, bytes[index + 4] == 0x35 {
                let slice = Array(bytes[index..<(index + 6)])
                if slice == show { cursorVisible = true; return }
                if slice == hide { cursorVisible = false; return }
            }
            index -= 1
        }
    }

    /// Whether the wrapped text is what is showing right now.
    var showsWrap: Bool { mirrorMode == .wrap && (!fullScreenFallback || wrapForced) }

    /// What the chip on the mirror says.
    /// HERDR-12: a phone has no Actual size, so its grid is always "Fit to
    /// width" here, a pinch included.
    var mirrorLabel: String {
        if showsWrap { return Strings.herdrZoomWrap }
        return zoom == .actual && !mirrorPreference.phone ? Strings.herdrZoomActual : Strings.herdrZoomFit
    }

    /// What the chip does, for VoiceOver: the phone's two modes or the iPad's three.
    var mirrorHint: String { mirrorPreference.phone ? Strings.herdrMirrorHintPhone : Strings.herdrMirrorHint }

    /// Re-read the grid into the wrap view, at most every 80 ms while frames
    /// stream. Only when the mode is Wrap: the grid modes draw themselves.
    func refreshWrap(immediately: Bool = false) {
        guard mirrorMode == .wrap, selected != nil else { return }
        if immediately {
            wrapTask?.cancel(); wrapTask = nil
            rebuildWrap()
            return
        }
        guard wrapTask == nil else { return }
        wrapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.wrapTask = nil
            self.rebuildWrap()
        }
    }

    private func rebuildWrap() {
        let grid = HerdrGrid.read(terminal.getTerminal(), cursorVisible: cursorVisible, wrapFlags: screenFlows)
        let result = HerdrWrap.layout(grid, width: wrapView.columns, agent: HerdrPaneKind.agentName(selectedPane) != nil)
        if fullScreenFallback != result.fullScreen { fullScreenFallback = result.fullScreen }
        applyMirror()
        if showsWrap { wrapView.show(result) }
    }

    private func applyMirror() {
        let wrap = showsWrap
        if mirrorView.showsWrap != wrap { mirrorView.showsWrap = wrap }
    }

    /// Double tap, or the chip: Wrap → Fit → Actual → Wrap on an iPad, Wrap ↔
    /// Fit on an iPhone (HERDR-12). The choice is remembered for this kind of
    /// pane. From a full-screen program's grid, Wrap is still one step away,
    /// on purpose.
    func cycleMirror(around point: CGPoint?) {
        guard selected != nil else { return }
        let phone = mirrorPreference.phone
        let current: HerdrMirrorMode = showsWrap ? .wrap : (fitView.zoomMode == .actual && !phone ? .actual : .fit)
        let next = current.next(phone: phone)
        mirrorPreference.remember(next, agent: HerdrPaneKind.agentName(selectedPane))
        show(next, around: point, chosen: true)
    }

    /// DUO-1 round 2. An open foldable (the iPhone Duo's inner screen) shows
    /// the mirror the iPad's way — Actual size in the cycle, Fit to width by
    /// default — and a closed one the phone's way. Decided by the hinge the
    /// Shell reads (`FoldReader`), never by the model; the type size is not
    /// touched. A kind of pane with a remembered choice keeps it (a phone
    /// shows a remembered Actual size as Fit, as before).
    func setFoldOpen(_ open: Bool) {
        let phone = HerdrMirrorPreference.devicePhone && !open
        guard phone != mirrorPreference.phone else { return }
        mirrorPreference = HerdrMirrorPreference(defaults: mirrorPreference.defaults, phone: phone)
        guard selected != nil else { return }
        show(mirrorPreference.mode(agent: HerdrPaneKind.agentName(selectedPane)), around: nil, chosen: false)
    }

    /// Puts the mirror in `mode`. `chosen`: the person picked it just now
    /// (the chip or a double tap), so Wrap shows even over a full-screen program.
    private func show(_ mode: HerdrMirrorMode, around point: CGPoint?, chosen: Bool) {
        mirrorMode = mode
        switch mode {
        case .wrap:
            wrapForced = chosen
            fitView.setZoom(.fit)
            applyMirror()
            // HERDR-10: a selection left in the text from before would hold
            // this fresh screen back.
            wrapView.clearSelection()
            rebuildWrap()
            wrapView.scrollToBottom()
        case .fit:
            wrapForced = false
            fitView.setZoom(.fit)
            applyMirror()
        case .actual:
            wrapForced = false
            applyMirror()
            fitView.setZoom(.actual, around: point)
        }
        zoom = fitView.zoomMode
    }

    // MARK: - Choices (HERDR-9)

    /// Read the screen for a menu or a yes-or-no question, at most every
    /// 80 ms while frames stream. In every mirror mode: the grid is the same.
    func refreshChoices(immediately: Bool = false) {
        guard selected != nil else { return }
        if immediately {
            choicesTask?.cancel(); choicesTask = nil
            readChoicesNow()
            return
        }
        guard choicesTask == nil else { return }
        choicesTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.choicesTask = nil
            self.readChoicesNow()
        }
    }

    // MARK: - Copy output (HERDR-10)

    /// Collie's "Copy output": what the pane shows, as text, in one tap - the
    /// way to copy that does not race codex's redraws. Hard wraps are undone
    /// as Wrap undoes them; a full-screen program's rows are copied as they
    /// are.
    func copyOutput() {
        guard selected != nil else { notice = Strings.herdrNoSelectedPane; return }
        let text = outputText()
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        notice = Strings.herdrCopyOutputDone
    }

    func outputText() -> String {
        let grid = HerdrGrid.read(terminal.getTerminal(), cursorVisible: false, wrapFlags: screenFlows)
        let agent = HerdrPaneKind.agentName(selectedPane) != nil
        let result = HerdrWrap.layout(grid, width: max(8, grid.cols), agent: agent)
        var lines: [String]
        if result.fullScreen {
            lines = HerdrChoiceReader.rows(grid)
        } else {
            lines = result.blocks.flatMap { block -> [String] in
                switch block {
                case .text(let runs, _), .rule(let runs): [runs.map(\.text).joined()]
                case .wide(let rows): rows.map { $0.map(\.text).joined() }
                case .blank: [""]
                }
            }.map(HerdrChoiceReader.trimEnd)
        }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The choices on the screen this instant.
    func currentChoices() -> HerdrChoices? {
        let grid = HerdrGrid.read(terminal.getTerminal(), cursorVisible: cursorVisible)
        return HerdrChoiceReader.read(HerdrChoiceReader.rows(grid), cursorRow: grid.cursor?.y)
    }

    private func readChoicesNow() {
        let fresh = currentChoices()
        if fresh != choices { choices = fresh }
        // The screen moved on from the question that was answered.
        if let answered = answeredSignature, fresh?.signature != answered {
            answeredSignature = nil
            answeredTask?.cancel(); answeredTask = nil
        }
    }

    /// What VoiceOver says for the echo.
    var echoSpoken: String { echo.map(\.spoken).joined(separator: ", ") }

    /// The strip is waiting for the screen to move on after a tap.
    var choicesAnswered: Bool { answeredSignature != nil && answeredSignature == choices?.signature }

    /// A tap on the strip. The screen is read again first, and the keys go
    /// only if it is still the question that was on show (Collie's dialog
    /// guard): a different dialog in the same shape is refused, never
    /// answered.
    func answer(_ choice: HerdrChoice) {
        guard let shown = choices, let option = shown.options.first(where: { $0.id == choice.id }),
              option.keys == choice.keys else { return }
        guard sendChoiceKeys(option.keys, shown: shown) else { return }
        // HERDR-10: codex's notes box is open now; the note is written in
        // the composer, and its Return submits the answer with it.
        if option.opensNote { composerFocusRequests &+= 1 }
    }

    /// HERDR-10: bumped when the composer should take the keyboard (a
    /// question card's notes box was just opened from the strip).
    @Published private(set) var composerFocusRequests = 0

    /// The strip's Esc, when the menu offers it.
    func answerEscape() {
        guard let shown = choices, shown.escape else { return }
        sendChoiceKeys(["Escape"], shown: shown)
    }

    @discardableResult
    private func sendChoiceKeys(_ keys: [String], shown: HerdrChoices) -> Bool {
        guard let pane = selected else { notice = Strings.herdrNoSelectedPane; return false }
        guard !choicesAnswered else { return false }
        let fresh = currentChoices()
        guard let fresh, fresh.signature == shown.signature,
              fresh.options.map(\.keys) == shown.options.map(\.keys) else {
            choices = fresh
            notice = Strings.herdrChoicesChanged
            return false
        }
        guard demoData == nil || writeOverride != nil else { notice = Strings.demoHerdrControls; return false }
        keyTicks &+= 1
        answeredSignature = shown.signature
        answeredTask?.cancel()
        // A question that stays on screen (the TUI did not take the key) can
        // be answered again after a moment.
        answeredTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.answeredSignature == shown.signature else { return }
            self.answeredSignature = nil
        }
        say(keys)
        enqueue(.keys(keys), pane: pane)
        return true
    }

    // MARK: - Keys straight to the pane (HERDR-9)

    /// The composer is empty: no words and no chips. Its editing keys then
    /// go to the pane (REMOTE-INPUT-2b's rule).
    var composerEmpty: Bool { draft.isEmpty && attachments.isEmpty }

    /// One key from the empty composer (⌫, Return, an arrow, Tab, Esc, a
    /// ctrl chord on a hardware keyboard): one `/keys` call.
    func passKey(_ key: String) {
        guard let pane = selected else { notice = Strings.herdrNoSelectedPane; return }
        guard demoData == nil || writeOverride != nil else { notice = Strings.demoHerdrControls; return }
        keyTicks &+= 1
        if typing { touchTyping() }
        say([key])
        enqueue(.keys([key]), pane: pane)
    }

    /// Show what just went to the pane, briefly.
    private func say(_ keys: [String]) {
        say(items: keys.map { (HerdrKeyEcho.face($0), HerdrKeyEcho.spoken($0)) })
    }

    private func say(items: [(face: String, spoken: String)]) {
        guard !items.isEmpty else { return }
        let now = Date()
        for item in items {
            echoSerial &+= 1
            echo.append(HerdrKeyEcho(id: echoSerial, face: item.face, spoken: item.spoken, at: now))
        }
        if echo.count > HerdrKeyEcho.maximum { echo.removeFirst(echo.count - HerdrKeyEcho.maximum) }
        echoTask?.cancel()
        echoTask = Task { [weak self] in
            try? await Task.sleep(for: Self.echoLifetime)
            guard let self, !Task.isCancelled else { return }
            self.echo = []
        }
    }

    /// Exponential backoff, and **no command is ever re-run**: a reconnect asks
    /// Herdr to repaint, which the fresh stream's first `full` frame does.
    private func scheduleReconnect() {
        guard appeared, selected != nil, retryTask == nil else { return }
        stream?.stop()
        attempt += 1
        connection = .retrying(attempt: attempt)
        let delay = HerdrReconnectPolicy.delay(attempt: attempt)
        let current = generation
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.generation == current, self.appeared, !Task.isCancelled else { return }
            self.retryTask = nil
            self.openStream()
        }
    }

    /// Leaving a pane closes its watching stream.
    private func releaseStream() {
        retryTask?.cancel(); retryTask = nil
        if let old = stream {
            Task { await old.release(restoring: nil) }
        }
        stream = nil
        attempt = 0
        terminal.inputAllowed = typing
        if !typing, terminal.isFirstResponder { terminal.resignFirstResponder() }
    }

    private func firstResponderChanged(_ active: Bool) {
        // Putting the keyboard away is how a person says "stop typing".
        if !active, typing { stopTyping() }
    }

    /// HERDR-5: a single tap on the mirror. While Type is on the terminal
    /// holds the keyboard on purpose (its Stop is on screen); otherwise the
    /// keyboard up is the composer's, and a tap on the screen puts it away.
    func mirrorTapped(at point: CGPoint? = nil) {
        // HERDR-9: a tap on the screen puts the keyboard away, Type's too, and
        // that is the end of Type (Leo: it stayed on after an answer).
        if typing {
            stopTyping()
            return
        }
        // LINKS-1 §3: watching, a single tap on a link opens it; anywhere else
        // it is still the tap that puts the keyboard away.
        if let point, let target = TerminalLinkHit.target(in: terminal, at: point, bareNames: true) {
            openLink(target)
            return
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// LINKS-1: where every link in this pane goes. The pane and session are
    /// what core checks a path against (it must be on that pane's screen).
    var links: LinkOpener?

    func openLink(_ target: LinkTarget) {
        guard let pane = selected else { return }
        links?.open(target, from: .herdr(pane: pane, session: selectedSession))
    }

    // MARK: - Type into terminal (HERDR-3)

    func toggleTyping() { typing ? stopTyping() : startTyping() }

    func startTyping() {
        guard selected != nil else { notice = Strings.herdrNoSelectedPane; return }
        guard demoData == nil else { notice = Strings.demoHerdrControls; return }
        typing = true
        terminal.inputAllowed = true
        terminal.becomeFirstResponder()
        touchTyping()
    }

    /// `notice` is said when typing stopped on its own (idle), never when the
    /// person pressed Stop.
    func stopTyping(notice: String? = nil) {
        flushTyped()
        typingIdleTask?.cancel(); typingIdleTask = nil
        guard typing else { return }
        typing = false
        terminal.inputAllowed = false
        if terminal.isFirstResponder { terminal.resignFirstResponder() }
        if let notice { self.notice = notice }
    }

    private func touchTyping() {
        typingIdleTask?.cancel()
        typingIdleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.typingIdleLimit)
            guard let self, !Task.isCancelled, self.typing else { return }
            self.stopTyping(notice: Strings.herdrTypingIdleOff)
        }
    }

    private func typed(_ bytes: [UInt8]) {
        typedBytes += bytes
        touchTyping()
        guard !typedFlushScheduled else { return }
        typedFlushScheduled = true
        // One run-loop tick of keystrokes becomes one request.
        DispatchQueue.main.async { [weak self] in self?.flushTyped() }
    }

    private func flushTyped() {
        typedFlushScheduled = false
        guard !typedBytes.isEmpty, let pane = selected else { typedBytes = []; return }
        let encoded = HerdrKeyEncoder.writes(from: typedBytes)
        typedBytes = []
        say(items: encoded.writes.flatMap(HerdrKeyEcho.items))
        for write in encoded.writes { enqueue(write, pane: pane) }
        if encoded.dropped > 0 { notice = ReasonText.message("herdr_key_unsupported", domain: .herdr) }
    }

    // MARK: - Keys row and composer (HERDR-3)

    /// One key cap from the keys row: one `/keys` call, with or without Type.
    func send(key cap: HerdrKeyCap) {
        guard let pane = selected else { notice = Strings.herdrNoSelectedPane; return }
        guard demoData == nil || writeOverride != nil else { notice = Strings.demoHerdrControls; return }
        keyTicks &+= 1
        if typing { touchTyping() }
        say([cap.key])
        enqueue(.keys([cap.key]), pane: pane)
    }

    /// HERDR-10: a draft belongs to a pane *in a session*. Herdr's pane ids
    /// (`w1:p1`) repeat in every session, so keyed by the id alone a draft
    /// written in one session showed up in another's pane.
    private func draftKey(_ pane: String) -> String { (selectedSession ?? "") + "\u{1F}" + pane }

    /// The selected pane's draft. Each pane keeps its own while the app runs.
    var draft: String {
        get { selected.flatMap { drafts[draftKey($0)] } ?? "" }
        set {
            guard let selected else { return }
            drafts[draftKey(selected)] = newValue
            if case .notSubmitted = sendState { sendState = .idle }
            if case .failed = sendState { sendState = .idle }
        }
    }

    var canSendDraft: Bool {
        selected != nil && sendState != .sending && !attachments.isUploading
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.hasReady)
    }

    /// The composer's Send: the text, and Enter only once core has seen it
    /// arrive on the pane's screen (`/text` with `submit`).
    func sendDraft() {
        guard let pane = selected else { notice = Strings.herdrNoSelectedPane; return }
        // The demo has no computer; the UI fixture takes the writes itself.
        guard demoData == nil || writeOverride != nil else { notice = Strings.demoHerdrControls; return }
        // Return is the submit, and core is the one that presses it.
        let text = draft.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // ATTACH-1: an upload still going holds Send until it is done.
        if attachments.isUploading { attachments.say(Strings.attachWait); return }
        let refs = attachments.refs
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !refs.isEmpty,
              sendState != .sending else { return }
        guard text.utf8.count <= Self.maximumTextBytes else {
            sendState = .failed(message: ReasonText.message("herdr_text_too_long", domain: .herdr))
            return
        }
        sentClearTask?.cancel()
        sendState = .sending
        let key = draftKey(pane)
        let typed = drafts[key] ?? text
        // HERDR-10: codex's notes box is open (the strip's "None of the
        // above" opened it). Herdr calls the agent blocked on its question
        // now, and core types no submitted reply into a blocked pane (an
        // approval would read the letters as shortcuts) - but this box is
        // the one place the words should go, and the screen says it has the
        // keyboard. So: the words, then Enter, which submits the answer.
        if refs.isEmpty, HerdrChoiceReader.notesOpen(HerdrChoiceReader.rows(
            HerdrGrid.read(terminal.getTerminal(), cursorVisible: false))) {
            enqueue(.text(text, submit: false), pane: pane)
            say(["Enter"])
            enqueue(.keys(["Enter"]), pane: pane) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    if self.drafts[key] == typed { self.drafts[key] = "" }
                    if self.selected == pane { self.sendState = .sent }
                    self.sentClearTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(4))
                        guard let self, !Task.isCancelled, self.sendState == .sent else { return }
                        self.sendState = .idle
                    }
                case .failure(let error):
                    if self.selected == pane { self.sendState = .failed(message: Self.message(error)) }
                }
            }
            return
        }
        let write: HerdrWrite = refs.isEmpty ? .text(text, submit: true) : .attached(text, attachments: refs)
        enqueue(write, pane: pane) { [weak self] result in
            // The chips go once core typed their paths; the draft goes only if
            // it is still what was sent.
            if case .success(let value) = result, value?.delivered == true, !refs.isEmpty {
                self?.attachments.clear()
            }
            self?.finishSend(result, pane: pane, clearDraftIf: (key, typed))
        }
    }

    func dismissSendState() { sendState = .idle }

    /// core's cap, checked here so the refusal is immediate and says why.
    static let maximumTextBytes = 16 * 1024

    private func enqueue(_ write: HerdrWrite, pane: String,
                         done: (@MainActor (Result<HerdrTextResultDTO?, Error>) -> Void)? = nil) {
        if let writeOverride {
            writeOverride(pane, write)
            done?(.success(nil))
            return
        }
        writeQueue.append((pane, write, done))
        pump()
    }

    private func pump() {
        guard !writing, !writeQueue.isEmpty else { return }
        writing = true
        let item = writeQueue.removeFirst()
        Task { [weak self] in
            guard let self else { return }
            let result: Result<HerdrTextResultDTO?, Error>
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                switch item.write {
                case .keys(let keys):
                    try await client.herdrKeys(pane: item.pane, keys: keys)
                    result = .success(nil)
                case let .text(text, submit):
                    result = .success(try await client.herdrText(pane: item.pane, text: text, submit: submit))
                case let .attached(text, refs):
                    result = .success(try await client.herdrText(pane: item.pane, text: text, submit: true,
                                                                 attachments: refs))
                }
            } catch {
                result = .failure(error)
            }
            if let done = item.done {
                done(result)
            } else if case .failure(let error) = result, self.selected == item.pane {
                self.notice = Self.message(error)
            }
            self.writing = false
            self.pump()
        }
    }

    // MARK: - Fit to width (HERDR-4)

    /// The selected pane's own size on the computer, from the layout. Watching
    /// asks for exactly this, so nothing is cut and the PTY is never touched.
    var paneGeometry: (cols: Int, rows: Int)? {
        guard let size = selectedPane?.size, let cols = size.cols, let rows = size.rows, cols > 0, rows > 0
        else { return nil }
        return HerdrGeometry.clamp(cols: cols, rows: rows)
    }

    /// The view holds the pane at its own size (and zooms it).
    private func updateFit() {
        fitView.setPaneSize(paneGeometry)
    }

    /// Double tap's twin: the small Wrap / Fit / 1:1 chip on the mirror.
    func toggleZoom() { cycleMirror(around: nil) }

    /// Whether the mirror can change how it shows the pane: wrapping always
    /// can; the grid zooms only with the pane's size known.
    var zoomable: Bool { selected != nil && (paneGeometry != nil || mirrorMode == .wrap) }

    // MARK: - Quick dock, presets, harness (HERDR-4)

    /// The rows for the pane on screen, read again when the pane's kind
    /// changes, when the dock opens (an operator's edit shows up there), and
    /// on a reconnect. A core without the route gets what ships.
    func refreshRows(force: Bool = false) {
        let agent = HerdrPaneKind.agentName(selectedPane)
        guard force || rowsFor != .some(agent) else { return }
        rowsFor = .some(agent)
        if demoData != nil || selected == nil {
            operatorRows = .shipped(agent: agent)
            return
        }
        rowsTask?.cancel()
        let current = generation
        rowsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                let value = try await client.herdrOperatorRows(agent: agent)
                guard !Task.isCancelled, self.generation == current, self.rowsFor == .some(agent) else { return }
                self.operatorRows = value
            } catch {
                guard !Task.isCancelled, self.generation == current, self.rowsFor == .some(agent) else { return }
                // An older core, or none reachable: what ships is still right.
                if self.operatorRows.agent != agent || self.operatorRows.sources.isEmpty { self.operatorRows = .shipped(agent: agent) }
                self.rowsFor = nil
            }
        }
    }

    func toggleKeys() { keysOpen.toggle() }

    func toggleQuick() {
        quickOpen.toggle()
        armed = nil
        if quickOpen {
            stopTyping()
            refreshRows(force: true)
        }
    }

    /// The dock's one line about the operator's files, when one has a problem.
    var operatorWarning: String? {
        guard let (file, warning) = operatorRows.warning else { return nil }
        return warning.code == "operator_file_unparsed" // non-copy: a contract code
            ? Strings.herdrOperatorUnparsed(file) : Strings.herdrOperatorDropped(file)
    }

    /// The presets beside the keys row: core's rows, less any that send
    /// exactly what a fixed key already sends (^C, ^D).
    var presetKeys: [HerdrOperatorRowsDTO.Key] { operatorRows.presets }

    func isArmed(_ id: String) -> Bool { armed?.holds(id) == true }

    /// The first tap on a row that asks for two: arm it for a moment.
    private func needsSecondTap(_ id: String, _ asks: Bool) -> Bool {
        guard asks else { return false }
        if isArmed(id) {
            armed = nil
            armTask?.cancel()
            return false
        }
        armed = HerdrArmed(id: id, until: Date().addingTimeInterval(HerdrArmed.window))
        armTask?.cancel()
        armTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HerdrArmed.window))
            guard let self, !Task.isCancelled, self.armed?.id == id else { return }
            self.armed = nil
        }
        return true
    }

    /// A Quick reply: typed and submitted with the composer's proof.
    func sendQuick(_ text: String) {
        quickOpen = false
        submit(text)
    }

    /// A harness button: the bare command, and the agent's own picker opens.
    func send(harness row: HerdrOperatorRowsDTO.Harness) {
        guard !needsSecondTap("harness:" + row.command, row.confirm) else { return } // non-copy
        quickOpen = false
        submit(row.command)
    }

    /// An operator command: sent, or, when it takes an argument, put in the
    /// composer to finish.
    func run(command row: HerdrOperatorRowsDTO.Command) {
        guard !needsSecondTap("command:" + row.command, row.confirm) else { return } // non-copy
        quickOpen = false
        if row.argHint != nil {
            draft = row.command + " "
            return
        }
        submit(row.command)
    }

    /// A key preset: all its chords in one `/keys` call, in order.
    func send(preset row: HerdrOperatorRowsDTO.Key) {
        guard let pane = selected else { notice = Strings.herdrNoSelectedPane; return }
        guard demoData == nil else { notice = Strings.demoHerdrControls; return }
        guard !needsSecondTap("key:" + row.label, row.danger) else {
            // The cap keeps its size (a row of keys must not jump); the line
            // above says what the second tap is for.
            notice = Strings.herdrTapAgainToSend(row.label)
            return
        }
        if row.danger { notice = nil }
        keyTicks &+= 1
        enqueue(.keys(row.keys), pane: pane)
    }

    /// Text with Enter only on proof, for anything that is not the draft.
    private func submit(_ text: String) {
        guard let pane = selected else { notice = Strings.herdrNoSelectedPane; return }
        guard demoData == nil else { notice = Strings.demoHerdrControls; return }
        guard sendState != .sending else { return }
        sentClearTask?.cancel()
        sendState = .sending
        enqueue(.text(text, submit: true), pane: pane) { [weak self] result in
            self?.finishSend(result, pane: pane, clearDraftIf: nil)
        }
    }

    /// What the line under the composer says after a send.
    private func finishSend(_ result: Result<HerdrTextResultDTO?, Error>, pane: String,
                            clearDraftIf sent: (key: String, text: String)?) {
        switch result {
        case .success(let value):
            if value?.submitted == true {
                if let sent, drafts[sent.key] == sent.text { drafts[sent.key] = "" }
                guard selected == pane else { sendState = .idle; return }
                sendState = value?.lightProof == true ? .sentLight : .sent
                sentClearTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(value?.lightProof == true ? 6 : 4))
                    guard let self, !Task.isCancelled, self.sendState == .sent || self.sendState == .sentLight else { return }
                    self.sendState = .idle
                }
            } else if selected == pane {
                sendState = .notSubmitted(reason: value?.reason ?? "not_seen") // non-copy: a reason code
            }
        case .failure(let error):
            if selected == pane { sendState = .failed(message: Self.message(error)) }
        }
    }

    // MARK: - Background

    /// The app is going to the background: nothing keeps typing.
    func sceneMovedToBackground() {
        stopTyping()
    }

    func sceneBecameActive() {
        guard appeared, selected != nil, mirrorIsDown else { return }
        reopenAfterBackground()
    }

    /// No stream, or one that has given up — not one that is still opening.
    private var mirrorIsDown: Bool {
        if stream == nil { return true }
        switch connection {
        case .idle, .unavailable: return true
        default: return false
        }
    }

    /// HERDR-11 §3: the watching socket is replaced now - its path died, or
    /// the network came back - with no backoff and no command re-run.
    func restartStream() {
        guard appeared, selected != nil else { return }
        retryTask?.cancel(); retryTask = nil
        attempt = 0
        stream?.stop()
        stream = nil
        openStream()
    }

    private func reopenAfterBackground() {
        guard appeared, selected != nil, retryTask == nil else { return }
        stream?.stop()
        stream = nil
        openStream()
    }

    // MARK: - Controls

    func run(_ action: HerdrControlAction) {
        perform(HerdrControlMapper.request(action, layout: layout, selected: selected),
                confirmed: !action.confirms)
    }

    func perform(_ request: HerdrControlRequest, confirmed: Bool) {
        // STORE-6 §A3: moving between the demo's panes works; the controls
        // that would change a real session say what they do on one.
        if demoData != nil {
            switch request {
            case .select(let pane): select(pane)
            case .unsupported(let reason): notice = reason
            // HERDR-11: the UI fixture's card opens over fixture folders.
            case .newWorkspace where HERDR11Fixture.requested: openNewWorkspace()
            case .workspace, .pane, .newTab, .closeTab, .newWorkspace: notice = Strings.demoHerdrControls
            }
            return
        }
        switch request {
        case .unsupported(let reason):
            notice = reason
        case .select(let pane):
            select(pane)
        case .workspace(let id):
            call { try await $0.herdrSelectWorkspace(id) }
        case let .pane(pane, action):
            if case .close = action, pane == selected { releaseStream() }
            call { try await $0.herdrPaneAction(pane: pane, action: action) }
        case .newWorkspace:
            openNewWorkspace()
        case .newTab(let workspace):
            pendingNewTab = (workspace, Set(layout?.panes.map(\.id) ?? []))
            call { try await $0.herdrNewTab(workspace: workspace) }
        case let .closeTab(workspace, tab):
            if let selected, layout?.tab(of: selected)?.id == tab { releaseStream() }
            call { try await $0.herdrCloseTab(workspace: workspace, tab: tab) }
        }
    }

    private func call(_ body: @escaping @Sendable (CompanionHostClient) async throws -> HerdrActionResponseDTO) {
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                _ = try await body(client)
                guard self.generation == current else { return }
                self.notice = nil
                // The host's own projection is the result; re-read rather than
                // predicting what the action did to the grid.
                self.refreshLayout()
            } catch {
                guard self.generation == current else { return }
                self.notice = Self.message(error)
                self.refreshLayout()
            }
        }
    }

    static func message(_ error: Error) -> String {
        if let herdr = error as? HerdrRequestError { return herdr.userMessage }
        if let companion = error as? CompanionHostError { return companion.errorDescription ?? ReasonText.unknown("", domain: .host) }
        return ReasonText.unknown("", domain: .herdr)
    }

    /// Repaint from the host theme and the host monospace face (§3).
    ///
    /// HERDR-10: SwiftUI calls this from `updateUIView` on every update of
    /// the panel - a key's echo, the choices strip coming or going, a letter
    /// typed in the composer, the connection settling. It used to set the
    /// faces every time, and setting them makes SwiftTerm measure its grid
    /// again from the view's `frame` (`resetFont`). Under the fit view's zoom
    /// that frame is the *scaled* size, so on an iPhone, where a desktop pane
    /// is drawn smaller than 1:1, every update cut the grid to about half the
    /// pane's columns and rows; Herdr's next frames, drawn for the pane's own
    /// size, then landed on the wrong cells (Leo's garbled Chinese mirror,
    /// and the question card the choices strip could no longer read). On an
    /// iPad the same pane fits at 1:1, frame and bounds agree, and nothing
    /// moved - which is why only the phone showed it.
    ///
    /// Now the faces are set only when the theme or the fonts change (the
    /// revision), measured at 1:1, and if the grid moved anyway it is put
    /// back and repainted.
    func applyAppearance(revision: Int? = nil) {
        if let revision {
            guard revision != appearanceRevision else { return }
            appearanceRevision = revision
        }
        applyFaces()
        TerminalPalette.apply(to: terminal)
        // HERDR-8: the wrapped text is drawn from the same theme and faces.
        if revision != nil {
            wrapView.restyle()
            refreshWrap(immediately: true)
        }
    }
    private var appearanceRevision: Int?

    /// The host's faces on the terminal, without moving its grid.
    private func applyFaces() {
        let grid = terminal.getTerminal()
        let before = (cols: grid.cols, rows: grid.rows)
        // `resetFont` divides `frame` by the cell; zoomed, `frame` is the
        // scaled size. At the identity transform it is the view's own.
        let transform = terminal.transform
        terminal.transform = .identity
        TerminalFont.apply(to: terminal, size: Self.fontSize)
        terminal.transform = transform
        // A face with another cell size does move it (the view's size holds
        // a different number of cells); the fit view then lays the terminal
        // out again at the pane's columns and rows, and the screen, reflowed
        // twice on the way, is asked for again.
        let moved = grid.cols != before.cols || grid.rows != before.rows
        fitView.setNeedsLayout()
        fitView.layoutIfNeeded()
        // The grid is the size Herdr draws the pane at, whatever the faces
        // or the layout made of it.
        guard selected != nil else { return }
        let target = paneGeometry ?? before
        let resized = grid.cols != target.cols || grid.rows != target.rows
        if resized { grid.resize(cols: target.cols, rows: target.rows) }
        guard moved || resized else { return }
        herdrGridLog.error("faces moved the grid \(before.cols)x\(before.rows); the pane is \(target.cols)x\(target.rows)") // non-copy
        requestRepaint()
    }

    func dismissNotice() { notice = nil }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if typing {
            typed(Array(data))
            return
        }
        notice = Strings.herdrReadOnly
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0, newCols != columns || newRows != rows else { return }
        Task { [weak self] in
            guard let self else { return }
            self.columns = newCols
            self.rows = newRows
            self.resizeTask?.cancel()
            let current = self.generation
            self.resizeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled, self.generation == current, self.stream != nil else { return }
                // HERDR-4: watching, the size asked for is the pane's own, not
                // whatever the view happens to hold mid-layout.
                if self.streamMode == .observe, self.paneGeometry != nil { return }
                self.sendResize(HerdrGeometry.clamp(cols: newCols, rows: newRows))
            }
        }
    }

    /// `observe` reads no stdin on 0.8.2, so the bridge restarts that stream
    /// at the new size and the next frame is a full one.
    private func sendResize(_ geometry: (cols: Int, rows: Int)) {
        guard stream != nil, geometry != openedWith else { return }
        openedWith = geometry
        awaitingFullFrame = true
        stream?.send(.observeResize(cols: geometry.cols, rows: geometry.rows))
    }

    /// HERDR-10: the grid's cells cannot be trusted any more (it was resized
    /// under the stream), so ask for the whole screen again. The bridge
    /// answers any resize by restarting `observe`, whose first frame is a
    /// full one - at the same size, nothing on the computer changes.
    /// Increments are dropped until it arrives.
    private func requestRepaint() {
        // The demo (and the UI fixture) has no stream: it paints its screen
        // again itself.
        if demoData != nil {
            repaintRequests += 1
            terminal.getTerminal().resetToInitialState()
            terminal.feed(byteArray: Array(demoScreen.utf8)[...])
            refreshWrap(immediately: true)
            refreshChoices(immediately: true)
            return
        }
        guard !awaitingFullFrame else { return }
        awaitingFullFrame = true
        repaintRequests += 1
        stream?.send(.observeResize(cols: openedWith.cols, rows: openedWith.rows))
    }
    /// How many times the screen was asked for again (tests).
    private(set) var repaintRequests = 0
    /// The demo's screen for the pane on show (what it paints again).
    private var demoScreen = ""
    /// REL2-POLISH-2: the demo (and the UI fixture) paints its screen as text
    /// the terminal lays out itself, so SwiftTerm's wrap flags say which rows
    /// it wrapped. Herdr's frames place every row and leave them all unset.
    private var screenFlows: Bool { demoData != nil }

    func setTerminalTitle(source: TerminalView, title: String) {} // Titles come from the layout, not the stream.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    /// SwiftTerm's own tap on a marked link, while typing (the mirror is the
    /// first responder then, and SwiftTerm handles the tap itself).
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let target = LinkTarget.classify(link) { openLink(target) }
    }
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
}

/// SwiftTerm owns IME, selection, Ctrl/Option and the arrows. Three things are
/// added: the app-layer ⌘ combinations (§1.2 — they must not swallow a
/// terminal key), a signal for when this view gains or loses the keyboard, and
/// (HERDR-3) a gate: the mirror takes the keyboard only while Type or Take
/// keyboard is on, so a tap to read is never a tap to type.
final class HerdrTerminalView: TerminalView {
    var onFirstResponder: ((Bool) -> Void)?
    var onSemanticAction: ((HerdrControlAction) -> Void)?
    var inputAllowed = false

    override var canBecomeFirstResponder: Bool { inputAllowed && super.canBecomeFirstResponder }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(title: HerdrControlAction.previousPane.title, action: #selector(previousPane),
                         input: "[", modifierFlags: [.command]),
            UIKeyCommand(title: HerdrControlAction.nextPane.title, action: #selector(nextPane),
                         input: "]", modifierFlags: [.command])
        ]
    }

    @objc private func previousPane() { onSemanticAction?(.previousPane) }
    @objc private func nextPane() { onSemanticAction?(.nextPane) }

    @discardableResult override func becomeFirstResponder() -> Bool {
        let value = super.becomeFirstResponder()
        if value { onFirstResponder?(true) }
        return value
    }

    @discardableResult override func resignFirstResponder() -> Bool {
        let value = super.resignFirstResponder()
        if value { onFirstResponder?(false) }
        return value
    }
}
