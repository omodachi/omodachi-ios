import Foundation
import SwiftTerm
import Combine
import UIKit

/// The Herdr surface's whole model: the grid it draws, the pane it is showing,
/// and the one stream behind that pane.
///
/// Herdr is reached through core's official bridge, not SSH. Nothing here
/// starts a shell, attaches a session or injects a key binding: the grid comes
/// from `GET /v1/herdr/layout`, the screen comes from
/// `observe`/`control`, and every control is one of the five routes.
@MainActor final class HerdrStore: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
    enum Connection: Equatable, Sendable {
        case idle
        case connecting
        /// Read-only. Many devices may watch the same pane.
        case observing
        /// Read-write. Herdr allows one controller per pane and so does core.
        case controlling
        case retrying(attempt: Int)
        case unavailable(String)

        var isLive: Bool { self == .observing || self == .controlling }
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

    private unowned let home: HomeStore
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
    private var encoder = HerdrInputEncoder()
    /// §1.1: after every (re)connect the screen is repainted from a `full`
    /// frame. An increment that arrives before one has nothing to apply to, so
    /// it is dropped rather than painted onto a stale buffer.
    private var awaitingFullFrame = true
    private var generation = UUID()
    private var wantsControl = false
    private var appeared = false
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
        let view = HerdrTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400),
                                     font: OmodachiTheme.uiFont(size: Self.fontSize),
                                     options: TerminalOptions(cursorStyle: .steadyBlock))
        // TERM-1. The initialiser takes one font; the cascade needs all four.
        TerminalFont.apply(to: view, size: Self.fontSize)
        view.terminalDelegate = self
        view.inputAccessoryView = nil
        view.optionAsMetaKey = true
        view.accessibilityIdentifier = "herdr-terminal"
        view.onFirstResponder = { [weak self] active in self?.wantsInput(active) }
        TerminalPalette.apply(to: view)
        return view
    }()

    init(home: HomeStore) {
        self.home = home
        super.init()
    }

    // MARK: - Layout

    var workspaces: [HerdrWorkspaceDTO] { layout?.workspaces ?? [] }
    var selectedPane: HerdrPaneDTO? { selected.flatMap { layout?.pane($0) } }
    var selectedWorkspaceID: String? { selected.flatMap { layout?.workspace(of: $0)?.id } }

    /// The lightweight bar's status line for this surface (§3).
    var barStatus: String {
        switch connection {
        case .idle: "idle"
        case .connecting: "connecting"
        case .observing: "observing"
        case .controlling: "control"
        case .retrying(let attempt): "reconnecting \(attempt)"
        case .unavailable: "unavailable"
        }
    }

    var barTitle: String { selectedPane?.displayTitle ?? "Herdr" }

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
        if selected != nil, !connection.isLive, stream == nil { openStream(mode: .observe) }
    }

    func disappear() {
        appearances -= 1
        guard appearances <= 0 else { return }
        appearances = 0
        appeared = false
        releaseStream()
        retryTask?.cancel(); retryTask = nil
        loadTask?.cancel(); loadTask = nil
        layoutRetryTask?.cancel(); layoutRetryTask = nil
        sessionTask?.cancel(); sessionTask = nil
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
    }

    /// The host said the projection moved. The snapshot is the reading that
    /// cannot be wrong, so the client re-reads it rather than patching.
    func refreshLayout() {
        guard appeared, loadTask == nil else { return }
        let current = generation
        loadingLayout = layout == nil
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                let value = try await client.herdrLayout()
                guard self.generation == current, self.appeared else { return }
                self.apply(value)
            } catch {
                guard self.generation == current, self.appeared else { return }
                self.loadingLayout = false
                if self.layout == nil { self.connection = .unavailable(Self.message(error)) }
                self.notice = Self.message(error)
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

    /// The list is read on entry and after every switch. It is cheap — one
    /// `herdr session list` plus one snapshot per session on the host — and it
    /// is the only thing that knows a session appeared or stopped.
    func refreshSessions() {
        guard appeared, sessionTask == nil else { return }
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
        guard name != selectedSession, !switchingSession else { return }
        releaseStream()
        layoutRetryTask?.cancel(); layoutRetryTask = nil
        layoutAttempt = 0
        generation = UUID()
        selected = nil
        layout = nil
        connection = .connecting
        switchingSession = true
        awaitingFullFrame = true
        wantsControl = false
        terminal.getTerminal().resetToInitialState()
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.home.chatClient(for: self.home.profile.companionURL)
                let value = try await client.herdrSelectSession(name)
                guard self.generation == current else { return }
                self.selectedSession = value.selected
                self.ownedSession = value.owned
                self.switchingSession = false
                self.notice = nil
                self.refreshLayout()
                self.refreshSessions()
            } catch {
                guard self.generation == current else { return }
                self.switchingSession = false
                self.connection = .unavailable(Self.message(error))
                self.notice = Self.message(error)
                self.refreshSessions()
            }
        }
    }

    private func apply(_ value: HerdrLayoutDTO) {
        layout = value
        loadingLayout = false
        layoutRetryTask?.cancel(); layoutRetryTask = nil
        layoutAttempt = 0
        if let session = value.session { selectedSession = session }
        if connection == .unavailable("") { connection = .idle }
        if case .unavailable = connection { connection = .idle }
        guard let current = selected, value.pane(current) != nil else {
            // The pane we were on is gone (someone closed it, here or there).
            // Fall to whatever Herdr says is focused rather than to nothing.
            select(value.preferredPane, focusHost: false)
            return
        }
    }

    // MARK: - Selection

    /// Tapping a pane is a focus on the host too (A-21: "能点的先点"), so the
    /// grid and the host's own idea of the focused pane do not drift apart.
    func select(_ pane: String?, focusHost: Bool = true) {
        guard pane != selected else {
            // Same pane: this is a re-entry, not a change. Reopen only if the
            // stream is actually gone, and never re-focus the host for it.
            if pane != nil, !connection.isLive, stream == nil { openStream(mode: .observe) }
            return
        }
        releaseStream()
        selected = pane
        awaitingFullFrame = true
        wantsControl = false
        terminal.getTerminal().resetToInitialState()
        guard let pane else { connection = .idle; return }
        if focusHost { perform(HerdrControlMapper.focus(pane: pane), confirmed: true) }
        openStream(mode: .observe)
    }

    func selectWorkspace(_ id: String) {
        perform(.workspace(id: id), confirmed: true)
    }

    // MARK: - Streaming

    private func openStream(mode: HerdrStreamMode) {
        guard let pane = selected else { return }
        guard let client = try? home.chatClient(for: home.profile.companionURL) else {
            connection = .unavailable(Strings.hostErrorNotConnected)
            return
        }
        stream?.stop()
        streamMode = mode
        awaitingFullFrame = true
        connection = .connecting
        let value = HerdrPaneStream(client: client, pane: pane, mode: mode)
        stream = value
        openedWith = HerdrGeometry.clamp(cols: columns, rows: rows)
        let current = generation
        value.start(cols: columns, rows: rows) { [weak self] event in
            guard let self, self.generation == current, self.selected == pane else { return }
            self.handle(event, pane: pane, mode: mode)
        }
    }

    private func handle(_ event: HerdrPaneStream.Event, pane: String, mode: HerdrStreamMode) {
        switch event {
        case .opened:
            attempt = 0
            connection = mode == .control ? .controlling : .observing
            let current = HerdrGeometry.clamp(cols: columns, rows: rows)
            if current != openedWith { sendResize(current) }
        case .controlInUse:
            // 409 arrives before the upgrade. Stay where we were — read-only —
            // and say who is in the way, because the user's next keystroke
            // would otherwise vanish without a word.
            notice = HerdrRequestError(code: "herdr_control_in_use", status: 409).userMessage
            wantsControl = false
            openStream(mode: .observe)
        case .message(let message):
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

    private func feed(_ frame: HerdrFrame) {
        if frame.full {
            awaitingFullFrame = false
            terminal.feed(byteArray: frame.bytes[...])
            return
        }
        // An increment before the first full frame has no base; asking for one
        // is cheaper than painting nonsense.
        guard !awaitingFullFrame else { return }
        terminal.feed(byteArray: frame.bytes[...])
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
            self.openStream(mode: self.wantsControl ? .control : .observe)
        }
    }

    /// Leaving a pane sends `terminal.release` and closes the socket, so Herdr
    /// does not carry a controller that is no longer there.
    private func releaseStream() {
        retryTask?.cancel(); retryTask = nil
        stream?.release()
        stream = nil
        attempt = 0
    }

    /// §1.1: the stream is read-only until the user actually wants to type.
    private func wantsInput(_ active: Bool) {
        guard selected != nil else { return }
        if active, streamMode == .observe {
            wantsControl = true
            openStream(mode: .control)
        } else if !active, streamMode == .control {
            wantsControl = false
            stream?.release()
            openStream(mode: .observe)
        }
    }

    // MARK: - Controls

    func run(_ action: HerdrControlAction) {
        perform(HerdrControlMapper.request(action, layout: layout, selected: selected),
                confirmed: !action.confirms)
    }

    func perform(_ request: HerdrControlRequest, confirmed: Bool) {
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
    func applyAppearance() {
        TerminalFont.apply(to: terminal, size: Self.fontSize)
        TerminalPalette.apply(to: terminal)
    }

    func dismissNotice() { notice = nil }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard streamMode == .control, connection == .controlling else {
            notice = Strings.herdrReadOnly
            return
        }
        guard let text = encoder.encode(Array(data)) else { return }
        stream?.send(.input(text: text))
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
                self.sendResize(HerdrGeometry.clamp(cols: newCols, rows: newRows))
            }
        }
    }

    /// `control` resizes in band; `observe` reads no stdin on 0.8.2, so the
    /// bridge restarts that stream and the next frame is a full one.
    private func sendResize(_ geometry: (cols: Int, rows: Int)) {
        guard stream != nil else { return }
        openedWith = geometry
        if streamMode == .control {
            stream?.send(.resize(cols: geometry.cols, rows: geometry.rows))
        } else {
            awaitingFullFrame = true
            stream?.send(.observeResize(cols: geometry.cols, rows: geometry.rows))
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {} // Titles come from the layout, not the stream.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
}

/// SwiftTerm owns IME, selection, Ctrl/Option and the arrows. Only two things
/// are added: the app-layer ⌘ combinations (§1.2 — they must not swallow a
/// terminal key), and a signal for when this view actually wants input, which
/// is what upgrades the stream from `observe` to `control`.
final class HerdrTerminalView: TerminalView {
    var onFirstResponder: ((Bool) -> Void)?
    var onSemanticAction: ((HerdrControlAction) -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(title: HerdrControlAction.previousPane.title, action: #selector(previousPane),
                         input: "[", modifierFlags: [.command]),
            UIKeyCommand(title: HerdrControlAction.nextPane.title, action: #selector(nextPane),
                         input: "]", modifierFlags: [.command]),
            UIKeyCommand(title: HerdrControlAction.splitRight.title, action: #selector(splitRight),
                         input: "d", modifierFlags: [.command]),
            UIKeyCommand(title: HerdrControlAction.splitDown.title, action: #selector(splitDown),
                         input: "d", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: HerdrControlAction.zoom.title, action: #selector(zoomPane),
                         input: "z", modifierFlags: [.command, .shift])
        ]
    }

    @objc private func previousPane() { onSemanticAction?(.previousPane) }
    @objc private func nextPane() { onSemanticAction?(.nextPane) }
    @objc private func splitRight() { onSemanticAction?(.splitRight) }
    @objc private func splitDown() { onSemanticAction?(.splitDown) }
    @objc private func zoomPane() { onSemanticAction?(.zoom) }

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
