import Combine
import CoreGraphics
import Foundation
import RemoteInputCore
import UIKit

/// Drives the one Remote session a host can have: create, connect a backend,
/// stream, resize on rotation, release. The host owns the transaction; this
/// controller owns the client half of it and nothing else.
///
/// `idle -> creating -> connecting -> streaming -> resizing -> stopping -> idle`,
/// plus `failed(reason)`. There is no rollback machine, no lease epoch and no
/// connection generation: the session's `revision` is the only ordering.
@MainActor final class RemoteSessionController: ObservableObject {
    enum Phase: Equatable {
        case idle, creating, connecting, streaming, resizing, stopping
        case failed(String)
        var isBusy: Bool { self != .idle && !isFailed }
        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    @Published private(set) var phase: Phase = .idle {
        // REMOTE-2 item 1: a phase that moved without anyone asking is the
        // first thing to look at when a session disappears, and it was not
        // readable from outside before.
        didSet {
            guard oldValue != phase else { return }
            RemoteSessionTrace.phase("\(phase)", streaming: isStreaming, panelVisible: panelVisible)
        }
    }
    @Published private(set) var session: RemoteSessionDTO? {
        didSet { if oldValue?.id != session?.id { typingNoticeShown = false } }
    }
    @Published private(set) var capabilities: RemoteCapabilitiesDTO? {
        // TAIL-2 P2-2: over a relayed tailnet path a Sunshine stream someone
        // picked anyway is held to a rate the relay can carry.
        didSet {
            sunshine?.relayedRoad = capabilities?.relayedTailnet ?? false
            if oldValue?.text_input != capabilities?.text_input {
                applyTyping()
                // REMOTE-INPUT-2: the limits and whether the field can be used.
                composer.apply(capabilities?.text_input)
            }
        }
    }
    /// Kept on screen across a resize until the new backend's first frame lands.
    @Published private(set) var retainedFrame: UIImage?
    @Published private(set) var message = ""
    @Published private(set) var decoded = ""
    @Published private(set) var pairingPIN: String?
    @Published private(set) var sunshinePaired = false
    /// What the in-app Sunshine pairing is waiting on, in the words of the
    /// thing the user has to do next.
    @Published private(set) var pairingStatus = ""
    @Published var mode: RemoteMode = .extend
    @Published var backend: RemoteBackend = .sunshine
    /// N-22: the entry screen asks what the user wants to do; which backend
    /// does it is "高级", and `.auto` is the host's answer rather than this
    /// client's constant (Study 03 open question 5).
    @Published var backendChoice: RemoteBackendChoice = .auto {
        didSet {
            guard oldValue != backendChoice else { return }
            preferences.backend = backendChoice
            preferences.save()
            let resolved = backendChoice.resolve(capabilities)
            if resolved != backend { changeBackend(to: resolved) }
        }
    }
    /// N-25: only meaningful under takeover, default off, and the card next to
    /// it writes out what it costs when this device drops off the network.
    @Published var lockLocalInput = false
    /// SPEC-I §1.2: who is holding the host, when a create was refused for it.
    @Published private(set) var sessionOwner: RemoteRequestError.Owner?
    @Published var logicalLongEdge = 1280
    /// REMOTE-SAFE-1: which corners of this window are the display's rounded
    /// ones, as the window last reported them.
    private(set) var displayCorners = DisplayCorners.square
    private(set) var preferences = RemotePreferences.load()
    /// STREAM-1. This device's own point on the host's quality table.
    @Published private(set) var streamChoice = RemoteStreamChoice.load()
    /// STREAM-1. The live numbers, in their own object so a view that shows
    /// them is the only thing that redraws once a second.
    let streamMonitor = RemoteStreamMonitor()
    /// STREAM-1 §3. The `自动` walker; reset for every session.
    private var adaptive = RemoteAdaptiveQuality()
    /// A rate change asked for while the picture was not streaming (it was
    /// connecting or resizing). It is spent on the next frame.
    private var pendingRequality = false
    /// Operator-only (`RemoteOperatorSupport.streamSequence`): the walk, once.
    private var operatorStreamRun: Task<Void, Never>?
    @Published var relativeTouchpad = NativePointerPreference.relativeTouchpad() {
        didSet {
            guard oldValue != relativeTouchpad else { return }
            NativePointerPreference.save(relativeTouchpad: relativeTouchpad)
            sunshine?.client.touchpadMode = relativeTouchpad
        }
    }

    private(set) var sunshine: SunshineBackendDriver?
    private(set) var vnc: VNCBackendDriver?
    /// Tests inject one driver and one service; production builds both backends
    /// from the profile and talks to the real host client.
    private let injectedDriver: RemoteBackendDriver?
    private let injectedService: (any RemoteSessionServing)?
    var driver: RemoteBackendDriver? {
        if let injectedDriver { return injectedDriver }
        if backend == .vnc { return vnc }
        return sunshine
    }

    init(service: (any RemoteSessionServing)? = nil, driver: RemoteBackendDriver? = nil,
         heartbeatInterval: Duration = .seconds(10), backgroundGrace: Duration = .seconds(20),
         streamSettle: Duration? = nil) {
        injectedService = service
        injectedDriver = driver
        self.heartbeatInterval = heartbeatInterval
        self.backgroundGrace = backgroundGrace
        // A test's in-memory host has no fork to wait for; it says so by
        // injecting a service, or names its own settle time.
        self.streamSettle = streamSettle ?? (service == nil ? .seconds(3) : .zero)
        client = service
        mode = preferences.mode
        backendChoice = preferences.backend
        backend = preferences.backend.resolve(nil)
        wireComposer()
        if let driver { bind(driver) }
    }

    /// Remembered per device, so the entry screen opens on what this iPad was
    /// last used for rather than on a constant.
    func rememberMode(_ value: RemoteMode) {
        mode = value
        preferences.mode = value
        preferences.save()
    }

    func apply(preferences value: RemotePreferences) {
        preferences = value
        value.save()
        mode = value.mode
        backendChoice = value.backend
    }

    private var profile: HostProfile?
    private var pin: HostPin?
    private let mediaPairing = SunshinePairingFlow()
    private var client: (any RemoteSessionServing)?
    /// TAIL-2: the road `client` was built for; nil for an injected client.
    private var clientRoad: URL?
    var run = UUID()
    private var heartbeat: Task<Void, Never>?
    private var resizeDebounce: Task<Void, Never>?
    /// The geometry the session is planned for (and the next one will be).
    private var viewport: CGSize = .zero
    private var orientation = "landscape_left"
    /// ROTATE-1 (Leo, 2026-10-05: "拓展模式不动啊，只有接管模式动"). The window
    /// as it last really was, kept apart from `viewport` while an extend
    /// session holds its geometry through a turn, so the next session is
    /// planned for the window it actually opens in.
    private var windowReading: (size: CGSize, orientation: String)?
    /// DUO-1 round 2: the hinge of a foldable, and the moment it last opened
    /// from closed (`RemoteUnfold`).
    private var unfold = RemoteUnfold()
    /// How long after the hinge opens the window it opens onto may still
    /// re-plan an extend session. Long enough for the window to settle on the
    /// inner screen; a test shortens it.
    var unfoldWindow: Duration = .seconds(3)
    /// The host's own rate preference. It is a planning input, never a local
    /// default: without it the request carries this client's own ceiling.
    private var hostQuality: RemoteHostPreferences.Quality?
    /// STREAM-1. The whole `GET /v1/preferences` answer: the presets and the
    /// custom range the picker offers, and the host's own row name.
    @Published private(set) var hostPreferences: RemoteHostPreferences?
    private var hasFrame = false
    var panelVisible = false
    /// A-43. Published so the quick action reads "已弹出" when it is up.
    /// REMOTE-INPUT-2: it is also whether the compose bar is up — the bar is
    /// the keyboard's top row, in the field's mode and in Keys mode alike.
    @Published private(set) var keyboardVisible = false
    /// REMOTE-INPUT-2. The compose bar's draft, switches and send.
    let composer = RemoteComposer()
    /// MENU-2. Where the host's own bar is, as core measured it on the output
    /// this session owns. `RemoteBarMarks` puts our mark on top of the Omarchy
    /// logo from this; `nil` means there is nothing on the bar to cover and
    /// the picture is bare, exactly as before.
    @Published private(set) var barHitTest: RemoteBarHitTest?
    /// MENU-2. The decoded stream, so the mark places itself in the same
    /// aspect-fit rectangle the picture under it is drawn into.
    @Published private(set) var pictureSize: CGSize = .zero
    /// MENU-2 / A-67. The corner handle, offered only when the picture carries
    /// no mark: no geometry at all, or a logo the host could not locate — a bar
    /// the user has hidden, most of all.
    var needsCornerHandle: Bool { hasSession && barHitTest?.geometry.hasTargets != true }

    /// Publish the host's bar geometry for this session.
    ///
    /// Only while there is a session: core measures the bar on the output the
    /// session owns and publishes nothing otherwise, and a picture with no
    /// session is not a picture at all (N-32). Nothing here interprets a
    /// rectangle — a geometry with no logo in it draws no mark, and the whole
    /// picture goes to the host exactly as it did before MENU-2.
    func applyBarGeometry(_ geometry: HostBarGeometry?) {
        lastBarGeometry = geometry
        var next: RemoteBarHitTest?
        if let geometry, geometry.hasTargets, hasSession {
            next = RemoteBarHitTest(geometry: geometry)
        }
        guard next != barHitTest else { return }
        barHitTest = next
        RemoteSessionTrace.barGeometry(output: next?.geometry.output ?? geometry?.output ?? "none",
                                       logo: next?.fractions(for: .logo))
    }

    /// The last thing core said, kept so the answer can be taken again when
    /// the session itself arrives. The state frame and the session's own
    /// creation response race, and a geometry that lost that race would
    /// otherwise wait for the *next* change to the host's bar — which on a
    /// machine nobody is touching could be the whole session.
    private var lastBarGeometry: HostBarGeometry?
    /// Operator-only replay, at most one per session.
    private var operatorGestureRun: Task<Void, Never>?
    private var operatorTypingRun: Task<Void, Never>?

    /// Our mark was tapped. The host is told nothing about it: the mark is an
    /// ordinary view above the stream, so the tap never reached the picture —
    /// no touch is withheld, replayed, or half-sent.
    func barMarkTapped(_ target: RemoteBarHitTest.Target) {
        RemoteSessionTrace.barMark("logo", rect: barHitTest?.fractions(for: target))
        onPanel?(target.source)
    }
    // MARK: - A-64: the picture's own gestures

    /// N-37. What each of the four gestures resolves to on this host right now.
    /// Settings ⑥ prints it; the picture is told which of them to listen for.
    @Published private(set) var gestureBindings = RemoteGestureBindings()
    /// GEST-1 §3. The 26-high row that says what a gesture just did. One at a
    /// time, and it goes away by itself.
    @Published private(set) var gestureToast: PanelToast?
    private var gestureToastTask: Task<Void, Never>?
    /// The Shell runs the row a gesture resolved to; this object never holds a
    /// host client for it, exactly as it never holds one for a panel summon.
    var onGesture: ((RemotePictureGesture) -> Void)?

    func applyGestureBindings(_ value: RemoteGestureBindings) {
        guard value != gestureBindings else { return }
        gestureBindings = value
        let registered = value.registered
        sunshine?.setRegisteredGestures(registered)
        vnc?.setRegisteredGestures(registered)
        RemoteSessionTrace.gestureBindings(value.bindings
            .map { "\($0.gesture)=\($0.row == nil ? "none" : "bound")" }.joined(separator: " "))
    }

    /// A-12's rules, on the picture. `accepted` stays until the host settles
    /// it; `applied` and `failed` go away after two seconds, the same two the
    /// Panel's own row uses.
    func reportGestureToast(_ toast: PanelToast) {
        gestureToast = toast
        gestureToastTask?.cancel()
        guard toast.stage != .accepted else { return }
        let id = toast.id
        gestureToastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.gestureToast?.id == id else { return }
            self.gestureToast = nil
        }
    }

    func settleGestureToast(id: UUID, stage: PanelToast.Stage, detail: String?) {
        guard var toast = gestureToast, toast.id == id else { return }
        toast.stage = stage
        toast.detail = detail
        reportGestureToast(toast)
    }

    /// A-60: the only quick action that depends on the backend, and the host
    /// says which. `capabilities.backends.vnc.audio` is `false` on a real
    /// install — RFB over a WebSocket has no audio channel — and the Sunshine
    /// leg publishes nothing, which means yes. Until capabilities have arrived
    /// this falls back to what the two backends are.
    var backendHasAudio: Bool {
        capabilities.map { $0.carriesAudio(backend) } ?? (backend == .sunshine)
    }
    /// Whether the host's sound is being played on this device right now.
    @Published private(set) var hostAudioOn = false
    var panelActions = RemotePanelActionQueue()
    var presentation: UInt64 = 0
    /// The last stage a backend reported, so a failure names where it happened
    /// rather than only that it happened.
    private(set) var lastStage = ""
    /// The connection attempt that started this pairing is resumed once the
    /// pairing lands, so a user who asked for a session gets the session.
    private var pairedResumesSession = false
    /// REMOTE-PAIR-1: how many times the automatic renewal has been tried
    /// again by itself. One more try, then the manual button.
    private(set) var automaticRenewalRetries = 0

    /// REMOTE-2 item 1. The host releases a session whose client stops beating
    /// within its TTL, so while `session != nil` the beat has to go out — and
    /// nothing about what the app is *showing* may reach it. MERGE-1 §8 found
    /// sessions dying one TTL after the overlay opened; the rule that replaces
    /// that behaviour is written here and enforced in `beginHeartbeat`:
    ///
    /// * the overlay, the Panel, the soft keyboard, the input gate, a resize,
    ///   a lost frame and a failed beat never stop it;
    /// * only `release()` stops it, and `release()` happens only when the user
    ///   ends the session, when the host says the session is gone, when a
    ///   backend failure ends it, or when the app has really been in the
    ///   background for `backgroundGrace`.
    private let heartbeatInterval: Duration
    /// How long the app may be out of the foreground before its session is
    /// given back. A momentary `.inactive` — a notification banner, the app
    /// switcher, a system sheet — must not cost the user their desktop, and a
    /// real background must not cost the host an output for a whole TTL.
    private let backgroundGrace: Duration
    private var backgroundRelease: Task<Void, Never>?
    private let ttlSeconds: Double = 60
    /// Beats sent since this session started, for the test and the trace.
    private(set) var heartbeatCount = 0
    /// True while the beat loop is alive. A session with this false is the
    /// MERGE-1 §8 bug itself, so it is assertable from outside.
    private(set) var heartbeatRunning = false

    /// UX-2 §2 / A-59. The picture asking for a panel, with the source that
    /// asked: `keyboard` is ⌘⇧M, `keyboard_settings` is ⌘⇧,, `accessibility`
    /// is VoiceOver's custom action. No touch gesture is on this list.
    var onPanel: ((String) -> Void)?
    var isStreaming: Bool { phase == .streaming && hasFrame }
    /// A-41. There is a session to end: the host accepted one and it has not
    /// been released. The picture need not be up — a session whose stream
    /// dropped still holds the host's output and still has to be endable.
    var hasSession: Bool { session != nil }
    var inputReady: Bool { isStreaming && retainedFrame == nil && !panelVisible }
    /// INPUT-2: one expression of what the session wants, applied from every
    /// place that can move it. The backend decides when it can honour it; this
    /// side never has to guess whether "now" is the right moment to ask.
    func applyInputPolicy() { driver?.setInputEnabled(inputReady) }
    var statusText: String {
        switch phase {
        case .idle: Strings.remoteStatusIdle
        case .creating: Strings.remoteStatusCreating
        case .connecting: Strings.remoteStatusConnecting
        case .streaming: hasFrame ? Strings.remoteStatusStreaming : Strings.remoteStatusWaitingFrame
        case .resizing: Strings.remoteStatusResizing
        case .stopping: Strings.remoteStatusStopping
        case .failed(let reason): reason
        }
    }

    // MARK: - Configuration

    func configure(profile: HostProfile) {
        guard self.profile != profile else { return }
        guard injectedDriver == nil else { self.profile = profile; return }
        let changed = self.profile?.companionURL != profile.companionURL || self.profile?.hostname != profile.hostname
        self.profile = profile
        guard changed else { return }
        composer.configure(host: profile.companionURL.isEmpty ? nil : HostAccount.canonical(profile.companionURL))
        pin = HostPinStore().load(account: HostAccount.canonical(profile.companionURL))
        mediaPairing.cancel()
        sunshine = nil; vnc = nil; capabilities = nil; sunshinePaired = false; pairingPIN = nil; pairingStatus = ""
        pairedResumesSession = false
        guard !profile.mock, !profile.companionURL.isEmpty else { return }
        (sunshine, vnc) = RemoteBackendFactory.make(
            profile: profile, relativeTouchpad: relativeTouchpad,
            socket: { [weak self] path in
                guard let self else { throw CompanionHostError.notConnected }
                return try await self.vncSocket(path: path)
            })
        sunshine.map(bind); vnc.map(bind)
        sunshine?.onPairing = { [weak self] event in self?.receivePairing(event) }
        sunshine?.client.panelHandler = { [weak self] source in
            Task { @MainActor in self?.onPanel?(source) }
        }
        // A-62 / A-60: the three-finger tap and the bar's keyboard action are
        // the same switch, so the bar reports the keyboard that is on screen.
        sunshine?.client.keyboardHandler = { [weak self] visible in
            Task { @MainActor in self?.keyboardGestureReported(visible) }
        }
        mediaPairing.onProgress = { [weak self] value in self?.pairingStatus = value }
        mediaPairing.onFinished = { [weak self] paired in
            guard let self else { return }
            self.pairingFinished(paired: paired, retriable: self.mediaPairing.lastFailureRetriable)
        }
        mediaPairing.cancelService = { [weak self] attempt in
            guard let self else { throw CompanionHostError.notConnected }
            return try await self.mediaClient().cancelMediaPairing(attemptID: attempt)
        }
        Task { await refreshCapabilities() }
    }

    /// The authenticated, certificate-pinned socket the VNC bridge rides. It is
    /// created from the same client every other Remote call uses, so there is
    /// one identity and one pinned certificate on this path.
    private func vncSocket(path: String) async throws -> URLSessionWebSocketTask {
        try await mediaClient().makeVNCSocket(path: path)
    }

    private func mediaClient() async throws -> CompanionHostClient {
        guard let client = try await connectedClient() as? CompanionHostClient else {
            throw CompanionHostError.notConnected
        }
        return client
    }

    private func bind(_ driver: RemoteBackendDriver) {
        driver.onStage = { [weak self] stage in
            guard let self else { return }
            self.lastStage = stage
            guard self.phase == .connecting || self.phase == .resizing else { return }
            self.message = stage
        }
        driver.onFailure = { [weak self] reason in
            guard let self else { return }
            let token = self.run
            let staged = self.lastStage.isEmpty ? reason : Strings.remoteFailureAtStage(reason, self.lastStage)
            Task { await self.backendFailed(staged, token: token) }
        }
        driver.onFirstFrame = { [weak self] pixels, rect in
            self?.firstFrame(pixels: pixels, rect: rect)
        }
        // REMOTE-6. WayVNC changes the size it serves one update into a
        // scale-2 session. That is a geometry change, not a failure and not a
        // session event: nothing here ends the session, releases it, dials it
        // again or leaves the picture, because none of those is what happened.
        if let vnc = driver as? VNCBackendDriver {
            vnc.onFramebufferResize = { [weak self] from, to in
                guard let self else { return }
                // `from` is zero for the size the server opened at, which
                // WayVNC often abandons before a single frame is on screen.
                // Both sizes are recorded either way, because "the picture is
                // soft" and "the picture changed size" are indistinguishable
                // afterwards without them.
                let opening = from.width == 0 || from.height == 0
                RemoteSessionTrace.framebuffer(
                    session: self.session?.id ?? "-", event: opening ? "server_opened" : "server_resized",
                    pixels: opening ? "\(to.width)x\(to.height)"
                                    : "\(from.width)x\(from.height)->\(to.width)x\(to.height)")
                guard !opening, self.phase == .streaming || self.phase == .connecting else { return }
                self.message = Strings.remoteFramebufferResizing
            }
        }
        // A-64. The picture recognised one of its own gestures. Nothing is
        // decided here: the Shell owns the host client that runs the row.
        driver.onGesture = { [weak self] gesture in
            guard let self else { return }
            RemoteSessionTrace.gesture("\(gesture)",
                row: self.gestureBindings[gesture]?.row == nil ? "none" : "bound", outcome: "recognised")
            self.onGesture?(gesture)
        }
        driver.setRegisteredGestures(gestureBindings.registered)
        configureTyping(driver)
        // REMOTE-INPUT-2: three fingers ask the session which keyboard.
        driver.setKeyboardTapHandler { [weak self] in self?.keyboardTapped() }
        if let sunshine = driver as? SunshineBackendDriver {
            sunshine.onStats = { [weak self] stats in self?.receiveStats(stats) }
        }
    }

    /// TAIL-2 P2-2. The capabilities carry the road the asking device is on —
    /// whether its tailnet path is relayed — and that changes under a live
    /// connection. The entry re-reads them each time it appears and after a
    /// reconnect or a road change, but never under a session, whose backend
    /// is already chosen.
    func refreshEntryCapabilities() async {
        guard session == nil, !phase.isBusy else { return }
        await refreshCapabilities()
    }

    func refreshCapabilities() async {
        guard let client = try? await connectedClient() else { return }
        capabilities = try? await client.remoteCapabilities()
        hostQuality = (try? await client.remoteHostPreferences())?.quality
        guard let capabilities else { return }
        // `.auto` is whatever the host says it is; an explicit choice is only
        // overridden when the host reports that backend cannot run at all.
        // REMOTE-FIX-1: from the choice, not from the backend a previous read
        // fell back to - an explicit Sunshine comes back once it can run.
        backend = backendChoice.effective(capabilities)
    }

    /// N-24: the exit for "somebody else has it". Core has no steal, so the
    /// button exists only for a session this same device left behind; anything
    /// else is shown with the owner's name and no button.
    var canReclaimSession: Bool {
        guard let sessionOwner else { return false }
        return sessionOwner.deviceID == Self.pairedDeviceID()
    }

    static func pairedDeviceID() -> String? {
        CompanionDeviceIdentity.stored()
    }

    func reclaimSession() {
        guard let owner = sessionOwner, canReclaimSession else { return }
        let token = run
        Task {
            guard let client = try? await connectedClient() else { return }
            _ = try? await client.releaseRemoteSession(id: owner.sessionID)
            guard run == token else { return }
            sessionOwner = nil
            phase = .idle
            start()
        }
    }

    func inspectSunshine() { sunshine?.inspect() }

    /// The end of one Sunshine pairing attempt.
    ///
    /// REMOTE-PAIR-1 §3: a renewal the app started by itself (the host said
    /// `media_pairing_required`) is not given up on at its first stumble. If it
    /// stopped on something a second try can get past it is tried once more,
    /// still by itself; only after that - or straight away, when what stopped
    /// it needs the person at the computer - does the repair card with its
    /// button come up, with the sentence that says what to do.
    func pairingFinished(paired: Bool, retriable: Bool) {
        sunshinePaired = paired
        pairingPIN = nil
        // The session is what the user asked for; the pairing was only its
        // precondition. Leaving them on the refusal that started it is how
        // a finished pairing still read as "尚未批准".
        if paired {
            automaticRenewalRetries = 0
            if pairedResumesSession { pairedResumesSession = false; start() }
            return
        }
        if pairedResumesSession, retriable, automaticRenewalRetries < 1 {
            automaticRenewalRetries += 1
            RemotePairingTrace.step("renew.retry", "attempt=\(automaticRenewalRetries)")
            // After the attempt that just ended has let go of the flow.
            Task { @MainActor [weak self] in
                guard let self, self.pairedResumesSession else { return }
                self.pairSunshine(renewing: true)
            }
            return
        }
        if phase == .idle || phase.isFailed {
            pairedResumesSession = false
            phase = .failed(pairingStatus.isEmpty ? Strings.remotePairingIncomplete : pairingStatus)
        }
    }

    /// Step 1 of the pairing: Moonlight generates the client certificate, hands
    /// out the PIN and issues the `getservercert` the fork suspends. The rest
    /// runs in `receivePairing` once that PIN exists.
    func pairSunshine() { pairSunshine(renewing: false) }

    /// `renewing` asks for the certificate exchange even when the fork already
    /// holds this client's certificate. Without it Moonlight answers "already
    /// paired" *before* `getservercert`, so no request ever reaches the host
    /// and there is nothing for the operator to approve — while core, which
    /// binds per device rather than per certificate, keeps refusing the
    /// session. (Sunshine exposes no unpair on its streaming ports, so the
    /// fork's side cannot be dropped from here.)
    func pairSunshine(renewing: Bool) {
        guard !mediaPairing.isRunning else { return }
        // POLISH-R item 5: a pairing that is starting is not a pairing that
        // is done, whatever the last attempt ended as.
        sunshinePaired = false
        pairingPIN = nil
        pairingStatus = renewing
            ? Strings.remotePairingRenewing
            : Strings.remotePairingStarting
        sunshine?.pair(renewing: renewing)
    }

    /// POLISH-R item 5. Whether the Remote panel shows ⑦, the Sunshine
    /// certificate repair, whose headline is "Sunshine has not approved this
    /// device". LINKS-1 caught it printed over "Sunshine pairing is done": a
    /// pairing finished, the session it resumed then failed for some other
    /// reason (the stream, the network), and the failure plus the leftover
    /// pairing status was enough to bring the repair card back. A finished
    /// pairing is never a reason for it; the failure is told on the entry,
    /// in its own words, instead.
    var showsSunshineRepair: Bool {
        if pairingPIN != nil { return true }
        return phase.isFailed && !pairingStatus.isEmpty && !sunshinePaired
    }

    func cancelSunshinePairing() {
        mediaPairing.cancel()
        pairedResumesSession = false
        pairingPIN = nil
        pairingStatus = ""
    }

    /// Steps 2-4: find this certificate's pending request on the fork, hand the
    /// PIN to core's bridge, and follow the attempt to `paired`. The user
    /// approves the device once on the host and types nothing.
    ///
    /// REMOTE-5: internal rather than private so a test can drive the one rule
    /// this whole path exists for — a pairing that lands resumes the session
    /// the refusal interrupted. The only caller in the app is still the
    /// Moonlight half's `onPairing`.
    func receivePairing(_ event: SunshinePairingEvent) {
        RemotePairingTrace.step("moonlight.event", "event=\(event.traceName) attempt_in_flight=\(mediaPairing.isRunning)")
        let decision = SunshinePairingMapping.decide(event, attemptInFlight: mediaPairing.isRunning)
        RemotePairingTrace.step("moonlight.decision", decision.traceName)
        switch decision {
        case .ignore:
            return
        case .succeeded:
            sunshinePaired = true; pairingPIN = nil; pairingStatus = Strings.mediaPairingDone
            if pairedResumesSession { pairedResumesSession = false; start() }
            return
        case .note(let text):
            pairingPIN = nil; pairingStatus = text
            return
        case .stop(let reason):
            mediaPairing.cancel()
            pairingPIN = nil; pairingStatus = reason
            pairedResumesSession = false
            phase = .failed(reason)
            return
        case .renew:
            // The fork still holds this certificate while the host holds no
            // binding for it. The attempt started off the PIN is chasing a
            // request that will never be registered, so end it first, then pair
            // again without the fork's side — that request the operator really
            // can approve.
            mediaPairing.cancel()
            pairSunshine(renewing: true)
            return
        case .show(let issued):
            pairingPIN = issued
        }
        let pin = pairingPIN ?? ""
        // The host binds a pairing to this exact fingerprint and refuses
        // anything that is not 64 lowercase hex, so check it here rather than
        // sending a malformed binding and reporting the host's refusal.
        let fingerprint = sunshine?.client.currentClientCertificateSHA256() ?? ""
        guard fingerprint.count == 64, fingerprint.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            pairingStatus = Strings.remoteFingerprintUnusable
            return
        }
        let flow = mediaPairing
        Task { [weak self] in
            guard let self, let client = try? await self.mediaClient() else {
                self?.pairingStatus = Strings.hostErrorNotConnected
                return
            }
            flow.start(pin: pin, fingerprint: fingerprint, service: client)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard phase == .idle || phase.isFailed, let profile, !profile.mock else { return }
        guard viewport.width >= 64, viewport.height >= 64 else { message = Strings.remoteWaitingViewport; return }
        let token = UUID(); run = token
        if operatorStreamRun == nil, let first = RemoteOperatorSupport.streamSequence.first {
            setStreamChoice(first.choice)
        }
        phase = .creating; message = ""; hasFrame = false; retainedFrame = nil; decoded = ""; sessionOwner = nil
        reconnection = .none; reconnectAttempts = 0; reconnectCycles = 0
        Task {
            do {
                let client = try await connectedClient()
                // A session planned before the host's preference arrived would
                // stream this client's ceiling for its whole life; the resize
                // path never revisits a rate the user did not ask to change.
                if hostQuality == nil || hostPreferences == nil {
                    let answer = try? await client.remoteHostPreferences()
                    hostPreferences = answer
                    hostQuality = answer?.quality
                }
                // REMOTE-SAFE-1: whether the host takes the corners is in its
                // capabilities; a start that raced their first read asks once.
                if capabilities == nil {
                    capabilities = try? await client.remoteCapabilities()
                }
                adaptive = RemoteAdaptiveQuality()
                pendingRequality = false
                let body = RemoteCreateRequest(backend: backend, mode: mode, geometry: geometry(),
                                               placement: preferences.placement,
                                               lockLocalInput: mode == .takeover && lockLocalInput,
                                               ttlSeconds: ttlSeconds)
                let created = try await createReclaimingOwnLeftover(body, using: client)
                guard run == token else { _ = try? await client.releaseRemoteSession(id: created.id); return }
                RemoteGeometryTrace.planned(created)
                RemoteSessionTrace.codec(session: created.id, backend: created.backend.rawValue,
                                         planned: created.profile?.codec ?? "-",
                                         declared: RemoteDecoderSupport.codecs)
                session = created
                beginHeartbeat(token: token)
                try await connectBackend(created, token: token)
            } catch let error as RemoteRequestError where error.code == "media_pairing_required" {
                RemotePairingTrace.step("start.media_pairing_required", "backend=\(backend.rawValue) cert=\(sunshine?.client.currentClientCertificateSHA256() ?? "-")")
                // The host refused before it touched anything: it holds no
                // streaming certificate bound to this device. That is a step,
                // not a dead end, so take it here instead of telling the user
                // to go and do something on the host — and do not leave the
                // refusal on screen as a failure, because "尚未批准" belongs to
                // a request that really is waiting, never to the moment before
                // one exists.
                await release(message: "", token: token)
                pairedResumesSession = true
                automaticRenewalRetries = 0
                pairSunshine(renewing: true)
            } catch let error as RemoteRequestError where error.isSessionExists {
                // Who, not "somebody". The card can then offer the one exit
                // that is actually available to this device.
                sessionOwner = error.owner
                await fail(error.userMessage, token: token)
            } catch {
                await fail(Self.describe(error), token: token)
            }
        }
    }

    func stop() {
        let token = run
        Task { await release(message: "", token: token, cause: "user") }
    }

    /// A-43. One entry, two callers: the three-finger tap inside the picture
    /// and the overlay's keyboard button. The backend answers with the state it
    /// actually reached, so the button's label can never disagree with the
    /// keyboard that is (or is not) on screen.
    ///
    /// REMOTE-2 item 3: the button's contract is "a keyboard on the picture",
    /// and the picture is the one thing that may not be able to take first
    /// responder while the overlay is over it. So the raise is tried where the
    /// user asked for it first, and only if that answers "no" is the overlay
    /// closed and the want handed to `RemotePanelActionQueue`, which raises it
    /// on the next latched frame. The keyboard is what was asked for; the
    /// overlay is not.
    func toggleKeyboard(closingOverlay close: (() -> Void)? = nil) {
        guard let driver else { return }
        if keyboardVisible {
            hideKeyboard()
            return
        }
        // REMOTE-INPUT-2: the keyboard is the compose bar with this device's
        // own input method in its field. It needs no first responder from the
        // picture, so it comes up whatever the overlay was doing.
        if composer.usesField, hasSession {
            close?()
            showComposeField()
            return
        }
        driver.setComposeOwnsKeyboard(false)
        keyboardVisible = driver.toggleKeyboard()
        if keyboardVisible { RemoteSessionTrace.composeBar("shown mode=keys") }
        guard !keyboardVisible, hasSession else { return }
        close?()
        enqueuePanelAction(.keyboard)
    }

    /// REMOTE-INPUT-2. The bar comes up with the field holding the keyboard.
    private func showComposeField() {
        driver?.hideKeyboard()
        driver?.setComposeOwnsKeyboard(true)
        keyboardVisible = true
        composer.requestFocus()
        RemoteSessionTrace.composeBar("shown mode=field")
    }

    /// REMOTE-INPUT-2. Three fingers on the picture: the same switch as the
    /// bar's keyboard action, whichever keyboard that is.
    func keyboardTapped() {
        guard hasSession else { return }
        toggleKeyboard()
    }

    /// REMOTE-INPUT-2. ⌨ on the bar: the per-key keyboard (vim, shortcuts,
    /// games), or back to the field.
    func setKeysMode(_ on: Bool) {
        guard composer.keysMode != on else { return }
        composer.keysMode = on
        RemoteSessionTrace.composeBar("mode=\(on ? "keys" : "field")")
        guard keyboardVisible, let driver else { return }
        if composer.usesField {
            showComposeField()
        } else {
            composer.requestResign()
            driver.setComposeOwnsKeyboard(false)
            keyboardVisible = driver.toggleKeyboard()
            if !keyboardVisible, hasSession { enqueuePanelAction(.keyboard) }
        }
    }

    /// REMOTE-INPUT-2. The field let go of the keyboard without being asked
    /// (the iPad's own dismiss key, another responder): the bar goes with it,
    /// the draft stays.
    func composeFieldResigned() {
        guard keyboardVisible, composer.usesField else { return }
        RemoteSessionTrace.composeBar("hidden by=system")
        keyboardVisible = false
        driver?.setComposeOwnsKeyboard(false)
    }

    func hideKeyboard() {
        driver?.hideKeyboard()
        if keyboardVisible { RemoteSessionTrace.composeBar("hidden") }
        keyboardVisible = false
        panelActions.keyboardHidden()
        composer.requestResign()
        driver?.setComposeOwnsKeyboard(false)
        // A-61: the keyboard never moved the geometry, so there is nothing to
        // put back. The window will report its real rectangle on the next
        // layout pass, and if that is the same one it always was — which it is
        // — nothing is sent.
    }

    /// A-60: the host's own sound, played here. Turning it off stops this
    /// device playing; it does not touch the machine's volume.
    func setHostAudio(_ on: Bool) {
        guard backendHasAudio, let host = profile?.hostname, !host.isEmpty else { return }
        OMAudioController.shared.setPlaybackEnabled(on, muted: !on, volume: 1, forHost: host)
        hostAudioOn = on
    }

    /// A-43: the overlay's button cannot raise the keyboard itself — the
    /// picture is not taking interaction while the overlay is over it — so the
    /// want goes through `RemotePanelActionQueue`, and the queue reports back
    /// here when it has actually been honoured.
    func keyboardWasRaisedByQueue() { keyboardVisible = true }

    /// A-62. The gesture is the other half of the same toggle, and what it did
    /// is what the bar's quick action must say. It never touches the panel.
    func keyboardGestureReported(_ visible: Bool) {
        // REMOTE-INPUT-2: the picture's keyboard going away while the field
        // has the keyboard is the field taking it, not the bar closing.
        if !visible, composer.usesField, keyboardVisible { return }
        keyboardVisible = visible
        if !visible { panelActions.keyboardHidden() }
    }

    /// POLISH-R item 4. Leo killed the app in the middle of a session at
    /// 00:50 (host time) and could not start another one until the host
    /// expired the old one on its 60 s heartbeat (00:51:47): the new process
    /// was told "this device already has a session" and offered a button.
    /// One device runs one copy of this app with one scene, so a session the
    /// host says *this device* owns, and that this controller is not holding,
    /// is that dead process's leftover — nobody else can be using it. It is
    /// ended and the create asked again, once, without a question. A session
    /// owned by any other device still gets the occupied card.
    private func createReclaimingOwnLeftover(_ body: RemoteCreateRequest,
                                             using client: any RemoteSessionServing) async throws -> RemoteSessionDTO {
        do { return try await create(body, using: client) }
        catch let error as RemoteRequestError where error.isSessionExists {
            guard let owner = error.owner, let mine = Self.pairedDeviceID(), owner.deviceID == mine,
                  owner.sessionID != session?.id else { throw error }
            RemoteSessionTrace.release(session: owner.sessionID, cause: "reclaim-own-leftover", message: "")
            _ = try await client.releaseRemoteSession(id: owner.sessionID)
            return try await create(body, using: client)
        }
    }

    /// `remote.start` refuses while the host screensaver is up, because a
    /// screen being watched from an iPad would otherwise be blanked and locked
    /// underneath the stream. Wake it once from here rather than telling the
    /// user to go and touch the machine they are not sitting at.
    private func create(_ body: RemoteCreateRequest, using client: any RemoteSessionServing) async throws -> RemoteSessionDTO {
        do { return try await client.createRemoteSession(body) }
        catch let error as RemoteRequestError where error.code == "host_waking" {
            message = error.userMessage
            guard let companion = client as? CompanionHostClient, (try? await companion.wakeDesktop()) != nil else { throw error }
            try await Task.sleep(for: .seconds(1))
            return try await client.createRemoteSession(body)
        }
    }

    private func connectBackend(_ session: RemoteSessionDTO, token: UUID) async throws {
        guard let connection = session.connection else {
            throw RemoteRequestError(code: "session_not_ready", status: 409)
        }
        phase = .connecting
        hasFrame = false
        applyInputPolicy()
        // The host planned this session's rate against its own preference and
        // its encoder limits. The media leg streams that plan, not a constant.
        await driver?.connect(connection, profile: session.profile)
    }

    private func firstFrame(pixels: RemotePixels, rect: CGRect) {
        guard phase == .connecting || phase == .resizing || phase == .streaming, let session else { return }
        if !hasFrame { streamStartedAt = ContinuousClock.now }
        // REMOTE-6: not always the first. A backend whose framebuffer changed
        // size under it presents again, and everything below — the aspect-fit
        // the bar marks are placed in, what the host is told was presented,
        // the measurement in the diagnostics sheet — has to follow it.
        let again = hasFrame
        RemoteSessionTrace.framebuffer(session: session.id, event: again ? "presented_again" : "presented",
                                       pixels: "\(pixels.width)x\(pixels.height)")
        presentation &+= 1
        retainedFrame = nil
        hasFrame = true
        // REMOTE-4: a picture is what proves the last dial was worth making.
        reconnectCycles = 0
        reconnection = .none
        phase = .streaming
        message = ""
        decoded = "\(pixels.width) × \(pixels.height) · \(session.backend == .vnc ? "RFB" : (session.profile?.codec == "hevc" ? "HEVC" : "H.264"))" // non-copy: a measurement
        // MENU-2: the mark places itself in the picture's own aspect-fit
        // rectangle, which needs the decoded size and nothing else.
        pictureSize = CGSize(width: pixels.width, height: pixels.height)
        if barHitTest == nil, let pending = lastBarGeometry { applyBarGeometry(pending) }
        RemoteGeometryTrace.presented(pixels: pixels, rect: rect, viewport: viewport)
        applyInputPolicy()
        dispatchPanelAction()
        replayOperatorGesture()
        walkOperatorStream()
        typeOperatorText()
        if pendingRequality {
            pendingRequality = false
            requality(cause: "deferred")
        }
        if pendingViewportResize {
            pendingViewportResize = false
            if viewportDiffersFromPlan {
                let token = run
                Task { await resize(session: session, token: token) }
            }
        }
        let token = run
        Task { [weak self] in
            guard let self, let client = try? await self.connectedClient(), self.run == token else { return }
            let body = RemotePresentedRequest(revision: session.revision,
                video_rect_points: RemoteRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height),
                decoded_pixels: pixels)
            _ = try? await client.reportRemotePresented(id: session.id, body: body)
        }
    }

    // MARK: - REMOTE-INPUT-1: typing

    /// Whether a typing toast has been shown in this session; one is enough.
    private var typingNoticeShown = false

    private func applyTyping() {
        if let injectedDriver { configureTyping(injectedDriver); return }
        sunshine.map(configureTyping); vnc.map(configureTyping)
    }

    private func configureTyping(_ driver: RemoteBackendDriver) {
        let route = RemoteTypingRoute.from(capabilities)
        driver.configureTyping(route: route, deliver: { [weak self] text in
            await self?.typeOnHost(text) ?? .unavailable
        }, onUndelivered: { [weak self] outcome in
            self?.typingUndelivered(outcome)
        })
    }

    /// Text no key produces, typed by core. The text is never traced: only
    /// that it was asked for and how it went.
    private func typeOnHost(_ text: String) async -> RemoteHostTextOutcome {
        guard let session, phase == .streaming else { return .unavailable }
        do {
            _ = try await connectedClient().typeRemoteText(id: session.id, body: RemoteTextRequest(text: text))
            RemoteSessionTrace.typing(session: session.id, outcome: "typed", characters: text.count)
            return .typed
        } catch {
            let outcome = RemoteHostTextOutcome.from(error)
            RemoteSessionTrace.typing(session: session.id, outcome: outcome == .unavailable ? "unavailable" : "failed",
                                      characters: text.count)
            return outcome
        }
    }

    private func typingUndelivered(_ outcome: RemoteHostTextOutcome) {
        guard !typingNoticeShown else { return }
        typingNoticeShown = true
        reportGestureToast(PanelToast(stage: .message,
            label: outcome == .failed ? Strings.remoteTypingFailed : Strings.remoteTypingUnavailable))
    }

    // MARK: - REMOTE-INPUT-2: the compose bar

    private func wireComposer() {
        composer.currentSession = { [weak self] in self?.session?.id }
        composer.isReady = { [weak self] id in self?.composeReady(id) ?? false }
        composer.deliver = { [weak self] session, text, sendID in
            guard let self else { return .sessionGone }
            return await self.deliverCompose(session: session, text: text, sendID: sendID)
        }
    }

    /// A send goes out only while the picture of *its* session is live, so it
    /// is never typed blind, or into a session it was not pressed in.
    func composeReady(_ sessionID: String) -> Bool {
        session?.id == sessionID && isStreaming && reconnection == .none && !pausedForBackground
    }

    /// One attempt. The id is the press of Send; core types an id once.
    func deliverCompose(session sessionID: String, text: String, sendID: String) async -> RemoteComposeOutcome {
        guard session?.id == sessionID else { return .sessionGone }
        do {
            let client = try await connectedClient()
            _ = try await client.typeRemoteText(id: sessionID, body: RemoteTextRequest(text: text, id: sendID))
            return .typed
        } catch let error as RemoteRequestError {
            return Self.composeOutcome(error)
        } catch let error as CompanionHostError {
            if case .certificateChanged = error { return .refused(error.localizedDescription) }
            return .lost
        } catch {
            return .lost
        }
    }

    nonisolated static func composeOutcome(_ error: RemoteRequestError) -> RemoteComposeOutcome {
        switch error.code {
        case "session_not_ready": return .notReady
        case "session_not_found", "permission_denied": return .sessionGone
        case "remote_text_unavailable", "route_unavailable": return .refused(Strings.remoteTypingUnavailable)
        case "remote_text_failed": return .refused(Strings.remoteTypingFailed)
        case "invalid_request": return .refused(Strings.remoteComposeRefused)
        default:
            // A host that answered at all answered about this request; only a
            // server error might hide a typed text, and the id covers a retry.
            return error.status >= 500 ? .lost : .refused(error.userMessage)
        }
    }

    /// The bar's keys row, and the keys an empty field passes through.
    func passKey(usage: UInt16, down: Bool) {
        guard hasSession else { return }
        driver?.passKey(usage: usage, down: down)
    }

    func passChord(usage: UInt16, modifiers: RemoteModifiers) {
        guard hasSession else { return }
        driver?.passChord(usage: usage, modifiers: modifiers)
    }

    /// One tap of a key on the bar's keys row.
    func tapKey(_ cap: RemoteKeyCap) {
        if cap.modifiers.isEmpty {
            passKey(usage: cap.usage, down: true)
            passKey(usage: cap.usage, down: false)
        } else {
            passChord(usage: cap.usage, modifiers: cap.modifiers)
        }
    }

    /// Operator-only. See `RemoteOperatorSupport.typing`: the simulator's soft
    /// keyboard cannot be tapped key by key from outside, so an operator run
    /// feeds each string through the picture's own `insertText:` — the call a
    /// tap on the iOS keyboard makes — after its delay.
    private func typeOperatorText() {
        let steps = RemoteOperatorSupport.typing
        if RemoteOperatorSupport.typingInbox != nil, operatorTypingRun == nil {
            let token = run
            operatorTypingRun = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, self.run == token else { return }
                    guard let text = RemoteOperatorSupport.takeTypingInbox() else { continue }
                    RemoteSessionTrace.typing(session: self.session?.id ?? "-", outcome: "operator-injected",
                                              characters: text.count)
                    self.driver?.typeTextForOperator(text)
                }
            }
            return
        }
        guard !steps.isEmpty, operatorTypingRun == nil else { return }
        let token = run
        operatorTypingRun = Task { [weak self] in
            for step in steps {
                try? await Task.sleep(for: .seconds(step.seconds))
                guard !Task.isCancelled, let self, self.run == token else { return }
                RemoteSessionTrace.typing(session: self.session?.id ?? "-", outcome: "operator-injected",
                                          characters: step.text.count)
                self.driver?.typeTextForOperator(step.text)
            }
        }
    }

    /// Operator-only. See `RemoteOperatorSupport.streamSequence`.
    private func walkOperatorStream() {
        let steps = RemoteOperatorSupport.streamSequence
        guard steps.count > 1, operatorStreamRun == nil else { return }
        let token = run
        operatorStreamRun = Task { [weak self] in
            for index in 1..<steps.count {
                try? await Task.sleep(for: .seconds(steps[index - 1].seconds))
                guard !Task.isCancelled, let self, self.run == token else { return }
                self.setStreamChoice(steps[index].choice)
            }
        }
    }

    /// Operator-only. See `RemoteOperatorSupport.gesture`: a real iPad is the
    /// only thing that can make a three-finger swipe, so an operator run
    /// replays one into the arbiter three seconds after the picture is up and
    /// the rest of the path runs exactly as it does for a finger.
    private func replayOperatorGesture() {
        guard let raw = RemoteOperatorSupport.gesture,
              let gesture = RemotePictureGesture(rawValue: raw), operatorGestureRun == nil else { return }
        let token = run
        operatorGestureRun = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.run == token else { return }
            RemoteSessionTrace.gesture("\(gesture)", row: "operator-replay", outcome: "injected")
            self.driver?.replayGestureForOperator(gesture)
        }
    }

    // MARK: - Geometry

    /// UIKit reports intermediate sizes during a rotation. Only a size that has
    /// been stable for 300 ms is worth a host round trip.
    func viewportChanged(size: CGSize, orientation: String, corners: DisplayCorners? = nil, source: String = "stage") {
        // REMOTE-SAFE-1. Kept whatever happens below: the corners are a fact
        // about the window, and the next request that does go out uses them.
        if let corners { displayCorners = corners }
        guard size.width >= 64, size.height >= 64 else { return }
        if session != nil {
            RemoteSessionTrace.phase("viewport-reading source=\(source) window=\(size.width)x\(size.height) \(orientation) keyboard=\(keyboardVisible ? 1 : 0) phase=\(phase)", // non-copy: a trace value
                                     streaming: isStreaming, panelVisible: panelVisible)
        }
        windowReading = (size, orientation)
        // A-61 (rev 5, review item 1). **The soft keyboard is a layer over the
        // picture and never a geometry change.** REMOTE-2 measured what the old
        // behaviour cost: the keyboard coming up re-planned the host's output,
        // which re-arranged its workspaces and left the picture letterboxed —
        // the opposite of "the keyboard is just a local switch". A window whose
        // safe area shrank has not changed size, so nothing here may act on it.
        // (POLISH-R: A-60's rotation lock used to be a second refusal here. Leo
        // took it out; the system's own orientation lock does that job.)
        guard !keyboardVisible else {
            // Nothing is *held* here, because nothing really changed: the
            // window is the same window with a smaller safe area, and the
            // reading that arrived is an artefact of the keyboard rather than a
            // geometry. Remembering it would make putting the keyboard away
            // spend a resize on a rectangle that never existed.
            RemoteSessionTrace.phase("viewport-ignored keyboard=1", streaming: isStreaming,
                                     panelVisible: panelVisible)
            return
        }
        let changed = size != viewport
        // ROTATE-1. Only a takeover follows the device round. An extend
        // session is a second screen standing beside the computer's own: its
        // output keeps the geometry and the place it was planned with, and a
        // turn only fits that same picture into the turned window (the video
        // layer aspect-fits it; the next latched frame re-maps the pointer).
        // The rule sits here, where a re-plan is decided, rather than in what
        // detects a turn, so it holds whatever reports one.
        //
        // DUO-1 round 2 (Leo), the one exception: a foldable opened from
        // closed during an extend session re-plans once, to fill the inner
        // screen — unfolding is asking for the bigger screen. Only closed →
        // open, and only the window it opens onto (`unfoldWindow`): a turn
        // afterwards keeps the geometry again, and closing it keeps the
        // output, shown scaled in the outer screen as any turn is. A fold is
        // otherwise a turn: `replans(mode:unfolding:)`.
        if changed, let session,
           !Self.replans(mode: session.mode, unfolding: unfold.allows(now: .now)) {
            sunshine?.invalidateViewportGeometry()
            RemoteSessionTrace.phase("viewport-kept mode=\(session.mode.rawValue) window=\(Int(size.width))x\(Int(size.height))",
                                     streaming: isStreaming, panelVisible: panelVisible)
            return
        }
        viewport = size
        self.orientation = orientation
        sunshine?.invalidateViewportGeometry()
        // POLISH-R2: a turn while the stream is being dialled again (back from
        // the background, or a host reconfigure) is not dropped: the dial uses
        // the geometry the session already has, and the new one is planned
        // once, after its first frame.
        //
        // ROTATE-2 (Leo's iPad, 17:23 AEDT: "现在一旋转 remote 就崩了"): the
        // same holds while a re-plan is in flight. A second reading used to
        // start a second resize over the first one's half-dialled stream; the
        // stream the first one was opening failed under it, and a failure
        // during a resize ended the session. One turn is one re-plan: a
        // reading that arrives while the picture is being re-planned or
        // dialled is planned after that picture's first frame, if it still
        // differs from the plan then.
        if changed, session != nil, phase == .connecting || phase == .resizing {
            pendingViewportResize = true
            RemoteSessionTrace.phase("viewport-held phase=\(phase)", streaming: isStreaming, panelVisible: panelVisible)
            return
        }
        guard changed, session != nil, phase == .streaming else { return }
        resizeDebounce?.cancel()
        let token = run
        resizeDebounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, run == token, size == viewport else { return }
            // The session as it is now: an earlier re-plan moved its revision.
            guard let session = self.session else { return }
            // REMOTE-INPUT-2 host run: the keyboard sliding away reports a
            // few transient heights (864…873 in an 874 window) and then the
            // window again; "changed since the last reading" was true at the
            // end, so a takeover re-planned to the geometry it already had.
            // A re-plan is for a window that differs from the plan.
            RemoteSessionTrace.phase("viewport-settled window=\(self.viewport.width)x\(self.viewport.height) \(self.orientation) plan=\(self.plannedWindow.map { "\($0.size.width)x\($0.size.height) \($0.orientation)" } ?? "none")", // non-copy: a trace value
                                     streaming: self.isStreaming, panelVisible: self.panelVisible)
            guard self.viewportDiffersFromPlan else {
                RemoteSessionTrace.phase("viewport-settled-on-plan", streaming: self.isStreaming,
                                         panelVisible: self.panelVisible)
                return
            }
            await resize(session: session, token: token)
        }
    }

    /// ROTATE-1: whether a new window shape re-plans the host's output.
    nonisolated static func replans(mode: RemoteMode) -> Bool { replans(mode: mode, unfolding: false) }

    /// DUO-1 round 2: and while a foldable has just opened from closed, an
    /// extend session's too — once, for the window it opens onto.
    nonisolated static func replans(mode: RemoteMode, unfolding: Bool) -> Bool {
        mode == .takeover || unfolding
    }

    /// DUO-1 round 2. The Shell's hinge reading (`FoldReader`): nil where
    /// there is no hinge. A reading of the window that arrived before the
    /// hinge said it opened was held as an extend turn; it is read again now.
    func hingeChanged(open: Bool?) {
        guard unfold.hinge(open: open, now: .now, window: unfoldWindow) else { return }
        if session != nil {
            RemoteSessionTrace.phase("hinge-opened mode=\(mode.rawValue)", streaming: isStreaming, panelVisible: panelVisible)
        }
        if let reading = windowReading {
            viewportChanged(size: reading.size, orientation: reading.orientation, source: "unfold") // non-copy: a trace source
        }
    }

    /// Stop decoding and release input, ask the host for new geometry, reconnect
    /// with the connection it answers with, and keep the old image until the new
    /// backend produces a frame.
    /// `forWindow`: a re-plan for the window (a turn), which is dropped when
    /// the window ends up where the plan already is; a quality change is not.
    private func resize(session: RemoteSessionDTO, token: UUID, forWindow: Bool = true) async {
        guard phase == .streaming else {
            // ROTATE-2: never dropped — planned after the next first frame.
            pendingViewportResize = true
            return
        }
        // ROTATE-2, proven on the host (18:31 UTC+11): a held turn re-planned
        // 10 ms after the new stream's first frame. The Sunshine fork cannot
        // stop a stream that has not pinged yet; core's resize got
        // `409 session_not_stopped`, marked the session `failed`, and the
        // session was gone. A stream is given `streamSettle` before a re-plan
        // stops it.
        if let started = streamStartedAt, ContinuousClock.now < started + streamSettle {
            RemoteSessionTrace.phase("resize-waits-for-stream", streaming: isStreaming, panelVisible: panelVisible)
            try? await Task.sleep(until: started + streamSettle, clock: .continuous)
            guard run == token, phase == .streaming else {
                pendingViewportResize = true
                return
            }
            if forWindow, !viewportDiffersFromPlan {
                RemoteSessionTrace.phase("viewport-settled-on-plan", streaming: isStreaming, panelVisible: panelVisible)
                return
            }
        }
        guard let client = try? await connectedClient() else { return }
        phase = .resizing
        retainedFrame = driver?.retainedFrame
        hasFrame = false
        applyInputPolicy()
        await driver?.stop()
        guard run == token else { return }
        do {
            var expected = session.revision
            var updated: RemoteSessionDTO
            do {
                updated = try await client.resizeRemoteSession(id: session.id, body: .init(expectedRevision: expected, geometry: geometry()))
            } catch let error as RemoteRequestError where error.isStaleRevision {
                // A fast reverse rotation loses the race with its own first
                // request. Re-read the session and send the same geometry again.
                expected = try await client.remoteSession(id: session.id).revision
                updated = try await client.resizeRemoteSession(id: session.id, body: .init(expectedRevision: expected, geometry: geometry()))
            } catch let error as RemoteRequestError where error.isDynamicResolutionDenied {
                message = error.userMessage
                self.session = try await client.remoteSession(id: session.id)
                try await connectBackend(try requireSession(self.session), token: token)
                return
            }
            guard run == token else { return }
            RemoteGeometryTrace.planned(updated)
            self.session = updated
            try await connectBackend(updated, token: token)
        } catch let error as RemoteRequestError where error.code == "session_not_found" || error.status == 404 {
            await fail(Self.describe(error), token: token)
        } catch {
            // ROTATE-2: a turn never ends a session. The host still holds it;
            // dial it again as the host has it (REMOTE-4's reconnect, with its
            // own bounded window and retry).
            guard run == token else { return }
            RemoteSessionTrace.reconnect(session: session.id, attempt: 0, outcome: "resize-failed:\(Self.describe(error))")
            await reconnectInPlace(reason: Self.describe(error), token: token, cause: "resize-failure")
        }
    }

    func changeBackend(to next: RemoteBackend) {
        guard next != backend else { return }
        guard let session, phase == .streaming else { backend = next; return }
        let token = run
        Task {
            guard let client = try? await connectedClient() else { return }
            phase = .resizing
            retainedFrame = driver?.retainedFrame
            hasFrame = false
            applyInputPolicy()
            await driver?.stop()
            guard run == token else { return }
            do {
                let updated = try await client.switchRemoteBackend(
                    id: session.id, body: .init(expected_revision: session.revision, backend: next))
                backend = next
                self.session = updated
                try await connectBackend(updated, token: token)
            } catch {
                await fail(Self.describe(error), token: token)
            }
        }
    }

    /// REMOTE-INPUT-2. The window the host's output was last planned for
    /// (`geometry()` records it), so a reading that only returns to it is not
    /// a re-plan.
    private var plannedWindow: (size: CGSize, orientation: String)?
    /// Within a point: SwiftUI hands the same window back as 873.99997 after
    /// an animation, and that is not a new window. ROTATE-2: and by the
    /// window's shape, not the name of its landscape — the window reader says
    /// `landscape_left` for any landscape, the picture's reader says which.
    var viewportDiffersFromPlan: Bool {
        guard let plannedWindow else { return true }
        return abs(plannedWindow.size.width - viewport.width) >= 1
            || abs(plannedWindow.size.height - viewport.height) >= 1
            || plannedWindow.orientation.hasPrefix("portrait") != orientation.hasPrefix("portrait")
    }

    private func geometry() -> RemoteGeometryRequest {
        plannedWindow = (viewport, orientation)
        var quality = RemoteQuality.forBackend(backend).applying(hostQuality)
        let plan = RemoteRatePlan.resolve(streamChoice, tier: adaptive.tier, host: hostPreferences)
        if streamChoice.preset != .host {
            quality.fps = plan.fps
            quality.bitrate_kbps = plan.bitrateKbps
        }
        var request = RemoteGeometryRequest(viewport_points: .init(width: viewport.width, height: viewport.height),
                                            orientation: orientation, logical_long_edge: logicalLongEdge,
                                            quality: quality)
        request.quality_preset = plan.preset
        request.adaptive = plan.adaptive
        // REMOTE-SAFE-1 / 1b. Both modes: a takeover puts the whole desktop,
        // bar included, on the same device-shaped output, so its ends hit the
        // same corners. Only to a host that says it takes the field. Zeros are
        // sent, not omitted: a window that moved off the display's corners has
        // to be able to take back what an earlier request asked for.
        if capabilities?.bar_occlusion == true {
            request.bar_occlusion_points = barOcclusion()
        }
        RemoteGeometryTrace.request(request, mode: mode, backend: backend)
        return request
    }

    /// The corners' reach into each end of a bar of the host's thickness, in
    /// this device's points. The host's bar is `lastBarGeometry.bar` in the
    /// owned output's logical px once a session has one (the thinner side is
    /// the thickness); before that, Omarchy's own 26. One logical px is
    /// `viewport long edge / logicalLongEdge` points: the output is planned to
    /// exactly that long edge (`profile.py` requires it).
    func barOcclusion() -> RemoteBarOcclusion {
        let long = max(viewport.width, viewport.height)
        guard long > 0, logicalLongEdge > 0 else { return .init(top: 0, bottom: 0, left: 0, right: 0) }
        let pointsPerPixel = long / CGFloat(logicalLongEdge)
        var thickness = DisplayCorners.defaultBarThickness
        if let bar = lastBarGeometry?.bar, min(bar.width, bar.height) >= 1, min(bar.width, bar.height) <= 256 {
            thickness = min(bar.width, bar.height)
        }
        return displayCorners.barOcclusion(thickness: thickness * pointsPerPixel)
    }

    // MARK: - STREAM-1: presets, statistics, 自动

    /// ⑥ reads the host's table once when it is drawn, so the picker can say
    /// what each row is on *this* host before any session exists.
    func refreshHostPreferences() async {
        guard let client = try? await connectedClient(),
              let answer = try? await client.remoteHostPreferences() else { return }
        hostPreferences = answer
        hostQuality = answer.quality
    }

    /// ⑥'s picker. Saved for this device; applied to a running session in
    /// place (the same session, re-dialled at the new rates).
    func setStreamChoice(_ value: RemoteStreamChoice) {
        guard value != streamChoice else { return }
        let previous = streamChoice
        streamChoice = value
        value.save()
        if value.preset == .auto && previous.preset != .auto { adaptive = RemoteAdaptiveQuality() }
        RemoteSessionTrace.quality(session: session?.id ?? "-", preset: value.preset.rawValue,
                                   tier: value.preset == .auto ? adaptive.tier.wire : "-", cause: "user")
        // Only a change the host would plan differently is worth a re-dial.
        let before = RemoteRatePlan.resolve(previous, tier: adaptive.tier, host: hostPreferences)
        let after = RemoteRatePlan.resolve(value, tier: adaptive.tier, host: hostPreferences)
        guard before != after else { return }
        requality(cause: "user")
    }

    /// Re-plan the running session's rates. The host cannot change a running
    /// GameStream's frame rate or bitrate, so this is the resize path: stop,
    /// ask for the new plan on the same session, re-dial, keep the last frame
    /// up in between (STREAM-1 §2, the REMOTE-4 machinery).
    private func requality(cause: String) {
        guard let session, backend == .sunshine else { return }
        guard phase == .streaming else {
            if phase == .connecting || phase == .resizing { pendingRequality = true }
            return
        }
        let token = run
        Task { await resize(session: session, token: token, forWindow: false) }
        RemoteSessionTrace.quality(session: session.id, preset: streamChoice.preset.rawValue,
                                   tier: streamChoice.preset == .auto ? adaptive.tier.wire : "-",
                                   cause: "redial:\(cause)")
    }

    func receiveStats(_ stats: RemoteStreamStats) {
        guard phase == .streaming, let session else { return }
        streamMonitor.publish(stats, preset: streamChoice.preset, tier: adaptive.tier, session: session)
        RemoteSessionTrace.stats(session: session.id, line: stats.line)
        guard streamChoice.preset == .auto else { return }
        if case let .step(to: tier, why: why) = adaptive.observe(stats) {
            RemoteSessionTrace.quality(session: session.id, preset: "auto", tier: tier.wire, cause: "auto:\(why)")
            requality(cause: "auto")
        }
    }

    // MARK: - Heartbeat and teardown

    /// The beat, for as long as this run owns a session.
    ///
    /// Every early exit this loop used to have was a way for a live session to
    /// stop being fed: a client that could not be built, a beat that threw for
    /// a reason other than `session_not_found`, a `guard` on a published value
    /// that the overlay moves. The only exits now are "this run is over"
    /// (`release()` rolls `run`) and "the host says the session is gone".
    private func beginHeartbeat(token: UUID) {
        heartbeat?.cancel()
        heartbeatCount = 0
        heartbeatRunning = true
        let id = session?.id ?? "-"
        RemoteSessionTrace.heartbeatLoop("started", session: id)
        heartbeat = Task { [weak self] in
            defer {
                if let self {
                    self.heartbeatRunning = false
                    let live = self.run == token && self.session != nil
                    RemoteSessionTrace.heartbeatLoop(live ? "stopped-with-session" : "stopped",
                                                     session: self.session?.id ?? id,
                                                     reason: Task.isCancelled ? "cancelled" : "run-ended")
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.heartbeatInterval ?? .seconds(10))
                guard !Task.isCancelled, let self, self.run == token, let session = self.session else { return }
                do {
                    let client = try await self.connectedClient()
                    _ = try await client.heartbeatRemoteSession(id: session.id)
                    self.heartbeatCount += 1
                    RemoteSessionTrace.heartbeat(session: session.id, outcome: "ok", beat: self.heartbeatCount)
                } catch let error as RemoteRequestError where error.code == "session_not_found" {
                    RemoteSessionTrace.heartbeat(session: session.id, outcome: "session_not_found",
                                                 beat: self.heartbeatCount)
                    await self.fail(ReasonText.message("session_not_found", domain: .remote), token: token, cause: "host-session-gone")
                    return
                } catch {
                    // A refused or unreachable beat is a reason to beat again,
                    // not a reason to stop: the session is still the host's and
                    // still this client's to keep alive.
                    RemoteSessionTrace.heartbeat(session: session.id, outcome: "retry:\(error)",
                                                 beat: self.heartbeatCount)
                }
            }
        }
    }

    /// REMOTE-2 item 1. Coming back cancels a pending release; going away
    /// schedules one, `backgroundGrace` out, instead of ending the session on
    /// the first `.background` UIKit reports. The beat keeps going in the
    /// meantime, so a user who glanced at another app still has their desktop.
    func setForeground(_ active: Bool) {
        inForeground = active
        if active {
            if backgroundRelease != nil {
                backgroundRelease?.cancel(); backgroundRelease = nil
                RemoteSessionTrace.foreground(true, decision: "cancelled-pending-release")
            }
            resumeAfterBackground()
            return
        }
        guard phase != .idle || session != nil else { return }
        pauseForBackground()
        guard backgroundRelease == nil else { return }
        RemoteSessionTrace.foreground(false, decision: "release-in-\(backgroundGrace)")
        let token = run
        backgroundRelease = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.backgroundGrace)
            guard !Task.isCancelled, self.run == token else { return }
            self.backgroundRelease = nil
            await self.release(message: "", token: token, cause: "background")
        }
    }

    // MARK: - POLISH-R2: leaving the app is not a broken stream

    /// Whether the scene is in front. The stream is never dialled while it is
    /// not: iOS suspends a backgrounded app within seconds, and a dial that is
    /// suspended between its launch and its first ping leaves the host's
    /// Sunshine holding a stream nobody will ever ping (2026-10-05 09:47, host
    /// time: Leo switched apps, the App re-dialled in the background, the new
    /// stream died on "Initial Ping Timeout", and the release that followed
    /// could not stop it).
    private(set) var inForeground = true
    /// The stream was stopped because the app left the front; the session is
    /// still held on the host and is dialled again when the app comes back.
    private(set) var pausedForBackground = false
    /// A viewport change that arrived while the stream was being dialled.
    private var pendingViewportResize = false
    /// ROTATE-2. When the current stream's first frame landed, and how long a
    /// new stream gets before a re-plan may stop it (the fork's first ping).
    private var streamStartedAt: ContinuousClock.Instant?
    let streamSettle: Duration

    /// Leaving the front: end the stream now, cleanly, while the process still
    /// runs, so the host sees a disconnect rather than a client gone silent
    /// (which it notices only after its own timeout, and which the App would
    /// notice only after Moonlight's ten-second timeout: a black picture on
    /// return). The session itself stays; `backgroundRelease` decides that.
    private func pauseForBackground() {
        guard session != nil, phase != .stopping, !pausedForBackground else { return }
        guard phase == .streaming || phase == .connecting || phase == .resizing || reconnection == .inFlight else { return }
        pausedForBackground = true
        RemoteSessionTrace.foreground(false, decision: "stream-paused")
        retainedFrame = driver?.retainedFrame ?? retainedFrame
        hasFrame = false
        phase = .connecting
        applyInputPolicy()
        let task = UIApplication.shared.beginBackgroundTask(withName: "remote.pause") {}
        Task { [weak self] in
            await self?.driver?.stop()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// Back in front: dial the held session again at once.
    private func resumeAfterBackground() {
        guard pausedForBackground else { return }
        pausedForBackground = false
        guard session != nil, phase != .stopping else { return }
        RemoteSessionTrace.foreground(true, decision: "stream-resumed")
        let token = run
        reconnection = .none
        reconnectCycles = 0
        Task { await reconnectInPlace(reason: "", token: token, cause: "foreground") }
    }

    // MARK: - REMOTE-4: the host reconfigured itself under a live session

    /// What the picture says while the session is being dialled again.
    ///
    /// A `hyprctl reload` - which this host issues by itself on every output
    /// change, and which the official Display panel provokes by rewriting
    /// `monitors.lua` - can take the backend down under a session core still
    /// holds. Before REMOTE-4 the App treated that the way it treats any
    /// backend failure: end the session, drop the picture, land on panel ①.
    /// Leo did exactly that on 2026-09-22 and had to dial in again by hand.
    /// The session was never gone; only its stream was.
    enum Reconnection: Equatable {
        case none
        /// Dialling the same session again. The last frame stays on screen.
        case inFlight
        /// It did not come back inside the window. The reason, and a retry.
        case stalled(String)
    }

    @Published private(set) var reconnection: Reconnection = .none
    /// How long the host gets to finish reconfiguring itself before the user is
    /// told why the picture is still frozen. A reload settles in about a
    /// second; ten is the spec's ceiling on saying nothing.
    var reconnectWindow: Duration = .seconds(10)
    /// Attempts made in the current reconnect, for the trace and the test.
    private(set) var reconnectAttempts = 0
    /// Dials since the last frame. A backend that is broken rather than being
    /// rebuilt would otherwise fail, be dialled, fail again and never stop, so
    /// the picture coming back is what buys the next one.
    private(set) var reconnectCycles = 0
    private static let maxReconnectCycles = 3

    /// A backend that stopped is not by itself a session that ended.
    ///
    /// The host is the only authority on whether the session exists, so it is
    /// asked before anything is given up. A session it still holds is dialled
    /// again in place: same id, same revision chain, same picture on screen.
    private func backendFailed(_ reason: String, token: UUID) async {
        guard run == token, phase != .stopping else { return }
        // POLISH-R2: a stream that broke while the app is away is dialled
        // again when it comes back, never from the background.
        if !inForeground, session != nil {
            pausedForBackground = true
            RemoteSessionTrace.reconnect(session: session?.id ?? "-", attempt: 0, outcome: "deferred:background:\(reason)")
            await driver?.stop()
            return
        }
        // A resize stops the backend itself and reconnects on the host's new
        // geometry; that path owns its own failure. ROTATE-2: a failure that
        // lands while a resize is in flight is the stream the resize stopped
        // (or one a turn overtook) — it is the resize's, never the end of
        // the session.
        if phase == .resizing {
            RemoteSessionTrace.reconnect(session: session?.id ?? "-", attempt: 0, outcome: "ignored-during-resize:\(reason)")
            return
        }
        guard session != nil, reconnectCycles < Self.maxReconnectCycles else {
            await fail(reason, token: token, cause: "backend-failure")
            return
        }
        await reconnectInPlace(reason: reason, token: token, cause: "backend-failure")
    }

    /// The host told us it rebuilt something under this session.
    ///
    /// `remote.session.changed reason=host_reconfigured` is core saying it had
    /// to re-create the output and re-prepare the backend. The session id does
    /// not change, so neither does anything on this side except the connection.
    func hostSessionChanged(_ change: RemoteSessionChange) {
        guard let current = session, current.id == change.id, phase != .stopping else { return }
        RemoteSessionTrace.hostChange(session: change.id, revision: change.revision,
                                      state: change.state, reason: change.reason ?? "")
        if change.state == "released" || change.state == "failed" {
            let token = run
            let text = ReasonText.message(change.reason ?? "session_not_found", domain: .remote)
            Task { await fail(text, token: token, cause: "host-session-gone") }
            return
        }
        guard change.reason == "host_reconfigured" else { return }
        guard phase == .streaming || phase == .connecting || phase.isFailed else { return }
        let token = run
        Task { await reconnectInPlace(reason: "", token: token, cause: "host-reconfigured") }
    }

    /// The 重试 button on the stalled banner.
    func retryReconnect() {
        guard case .stalled = reconnection, session != nil else { return }
        let token = run
        Task { await reconnectInPlace(reason: "", token: token, cause: "user-retry") }
    }

    /// Dial the session the host still holds, without ending it.
    ///
    /// The session is never set to nil here, which is the whole point: the
    /// Shell routes away from the picture on `hasSession` going false (N-32),
    /// so anything that nils it lands the user back on panel ①.
    private func reconnectInPlace(reason: String, token: UUID, cause: String) async {
        guard run == token, phase != .stopping, let existing = session,
              reconnection != .inFlight else { return }
        reconnection = .inFlight
        reconnectAttempts = 0
        reconnectCycles += 1
        retainedFrame = driver?.retainedFrame
        hasFrame = false
        phase = .connecting
        message = Strings.remoteHostReconfiguring
        applyInputPolicy()
        // REMOTE-6: the cause alone does not say what went wrong. A backend
        // that stopped has a reason, and without it in the line the only way to
        // find out why a session re-dialled is to reproduce it.
        RemoteSessionTrace.reconnect(session: existing.id, attempt: 0,
                                     outcome: "started:\(cause)" + (reason.isEmpty ? "" : ":\(reason)"))
        await driver?.stop()
        let deadline = ContinuousClock.now.advanced(by: reconnectWindow)
        while run == token, ContinuousClock.now < deadline {
            if !inForeground {
                // Left again mid-dial: leave it for the return.
                pausedForBackground = true
                reconnection = .none
                RemoteSessionTrace.reconnect(session: existing.id, attempt: reconnectAttempts, outcome: "deferred:background")
                return
            }
            reconnectAttempts += 1
            let attempt = reconnectAttempts
            do {
                let client = try await connectedClient()
                let fresh = try await client.remoteSession(id: existing.id)
                guard run == token else { return }
                RemoteSessionTrace.reconnect(session: fresh.id, attempt: attempt,
                                             outcome: "state=\(fresh.state)/rev=\(fresh.revision)")
                if fresh.isTerminal {
                    await fail(ReasonText.message(fresh.reason ?? "session_not_found", domain: .remote),
                               token: token, cause: "host-session-gone")
                    return
                }
                if fresh.isReady, fresh.connection != nil {
                    session = fresh
                    RemoteGeometryTrace.planned(fresh)
                    try await connectBackend(fresh, token: token)
                    // Only once the dial itself went out: a `connect` that threw
                    // is another attempt, not the end of the banner.
                    reconnection = .none
                    return
                }
            } catch let error as RemoteRequestError where error.code == "session_not_found" || error.status == 404 {
                RemoteSessionTrace.reconnect(session: existing.id, attempt: attempt, outcome: "session_not_found")
                await fail(ReasonText.message("session_not_found", domain: .remote),
                           token: token, cause: "host-session-gone")
                return
            } catch {
                RemoteSessionTrace.reconnect(session: existing.id, attempt: attempt, outcome: "retry:\(error)")
            }
            try? await Task.sleep(for: reconnectPoll)
        }
        guard run == token, session != nil else { return }
        // Out of patience, not out of a session. The host still holds it, so
        // the user is told what happened and offered the one thing that helps.
        let text = reason.isEmpty ? Strings.remoteHostReconfigureStalled : reason
        reconnection = .stalled(text)
        phase = .failed(text)
        message = text
        RemoteSessionTrace.reconnect(session: existing.id, attempt: reconnectAttempts, outcome: "stalled")
    }

    /// Injected by the test so a ten-second window does not take ten seconds.
    var reconnectPoll: Duration = .milliseconds(500)

    private func fail(_ reason: String, token: UUID, cause: String = "failure") async {
        guard run == token else { return }
        await release(message: reason, token: token, cause: cause)
    }

    private func release(message reason: String, token: UUID, cause: String = "user") async {
        guard run == token, phase != .idle || session != nil else { return }
        streamMonitor.clear()
        RemoteSessionTrace.release(session: session?.id ?? "-", cause: cause, message: reason)
        run = UUID()
        phase = .stopping
        backgroundRelease?.cancel(); backgroundRelease = nil
        pausedForBackground = false
        pendingViewportResize = false
        heartbeat?.cancel(); heartbeat = nil
        resizeDebounce?.cancel(); resizeDebounce = nil
        panelActions.cancel()
        hasFrame = false
        applyInputPolicy()
        await driver?.stop()
        // Only while the host still holds this session for us: once it says
        // the session is gone, the fork's lease may already be somebody
        // else's, and their desktop app is not ours to end.
        if let session, session.backend == .sunshine, cause != "host-session-gone",
           let outcome = await driver?.endHostApp() {
            RemoteSessionTrace.release(session: session.id, cause: "\(cause).host-app", message: outcome)
            RemoteSessionTrace.sunshineQuit(session: session.id, outcome: outcome)
        }
        if let session {
            // REMOTE-2 item 1. This DELETE is what keeps the host from holding
            // an output for a whole TTL after the session is over, and it used
            // to be `try?` twice over: a failed release looked exactly like a
            // clean one, and the only symptom was the host noticing 60 s later.
            // One retry, and the outcome is on the record either way.
            var outcome = "released"
            do {
                _ = try await connectedClient().releaseRemoteSession(id: session.id)
            } catch {
                outcome = "retry-after:\(error)"
                do { _ = try await connectedClient().releaseRemoteSession(id: session.id) }
                catch { outcome = "failed:\(error) — the host will expire it after its TTL" } // non-copy: a trace value
            }
            RemoteSessionTrace.release(session: session.id, cause: "\(cause).delete", message: outcome)
        }
        session = nil
        // REMOTE-INPUT-2: no session, no bar. The draft stays for the next.
        if keyboardVisible {
            keyboardVisible = false
            composer.requestResign()
            driver?.setComposeOwnsKeyboard(false)
        }
        // ROTATE-1: an extend session held its geometry through a turn; the
        // next session is planned for the window as it is now.
        if let windowReading, windowReading.size != viewport {
            viewport = windowReading.size
            orientation = windowReading.orientation
        }
        retainedFrame = nil
        reconnection = .none
        // MENU-2: the mark belongs to the picture, and there is no picture.
        pictureSize = .zero
        applyBarGeometry(nil)
        hostAudioOn = false
        decoded = ""
        message = reason
        phase = reason.isEmpty ? .idle : .failed(reason)
    }

    func connectedClient() async throws -> any RemoteSessionServing {
        guard let profile, let endpoint = URL(string: profile.companionURL) else {
            if let client { return client }
            throw CompanionHostError.invalidEndpoint
        }
        // TAIL-3b. The Remote requests go down the host's one road, while
        // the credential stays where it is stored (the account).
        let account = HostAccount.canonical(profile.companionURL)
        let road = HostRoads.dialURL(account: account) ?? endpoint
        if let client, clientRoad == nil || clientRoad == road { return client }
        let created = CompanionHostClient(configuration: try CompanionHostConfiguration(endpoint: road, account: account),
                                          credentials: CompanionCredentialStore(),
                                          pinnedFingerprint: pin?.fingerprintSHA256)
        try await created.connect()
        client = created
        clientRoad = road
        // Moonlight's own requests before a session names an address
        // (inspection, pairing) follow the same road.
        sunshine?.follow(road: road.host)
        return created
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? RemoteRequestError { return failure.userMessage }
        if let failure = error as? CompanionHostError { return failure.errorDescription ?? Strings.remoteStartFailed }
        return Strings.remoteStartFailed
    }

}

/// A resize that the host refused on policy grounds leaves the session intact;
/// there is still a connection to reattach to.
private func requireSession(_ value: RemoteSessionDTO?) throws -> RemoteSessionDTO {
    guard let value else { throw RemoteRequestError(code: "session_not_found", status: 404) }
    return value
}

/// DUO-1 round 2. A foldable's hinge as Remote needs it: whether it just
/// opened from closed, and until when that may re-plan an extend session.
/// Opening from a reading that was not "closed" (the App started on the open
/// screen, or a device with no hinge) is not an unfold; closing ends it.
struct RemoteUnfold: Sendable {
    private(set) var open: Bool?
    private(set) var until: ContinuousClock.Instant?

    /// Takes a hinge reading; true when it is the hinge opening from closed.
    mutating func hinge(open next: Bool?, now: ContinuousClock.Instant, window: Duration) -> Bool {
        defer { open = next }
        guard next == true else { until = nil; return false }
        guard open == false else { return false }
        until = now + window
        return true
    }

    func allows(now: ContinuousClock.Instant) -> Bool { until.map { now < $0 } ?? false }
}
