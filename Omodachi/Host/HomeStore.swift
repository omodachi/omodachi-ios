import Foundation
import Combine

enum CompanionConnectionState: String, Sendable {
    case disconnected, connecting, connected, reconnecting, suspended, unavailable
    /// PAIR-5 §2. The host did not answer. It is not a fault of this device's
    /// credential and it is not something to settle — the dot goes grey, ①
    /// says so in one row with a retry on it, and the connection keeps trying.
    case offline
}

struct CompanionConnectionDiagnostics: Codable, Sendable {
    let connected: Bool
    let hostSource: String?
    let hostName: String?
    let instanceID: String?
    let stateRevision: Int?
    let deliveredEventCursor: Int
    let catalogRevision: String?
    let defaultAgentReady: Bool?
    let herdrAvailable: Bool?
}

/// One host connection, one host snapshot. `latestState` is the only truth:
/// `state`, `menu` and `barModel` are rebuilt from it in `apply` and nowhere
/// else, so there is no second copy to drift.
@MainActor final class HomeStore: ObservableObject {
    @Published var state = HostState()
    @Published private(set) var barModel = HostBarModel.unavailable
    @Published private(set) var menu = MockCatalog.roots
    @Published private(set) var hostWakeState: HostWakeStateDTO?
    @Published var wakingDesktop = false
    /// What the host said about the thing that was just asked of it. It is
    /// **not** a status line — connection state is the bar's dot and nothing
    /// else — and it is never an error row under the menu: it becomes the one
    /// 26-high toast (A-12).
    ///
    /// The verdict is the one the action already reported, when it reported
    /// one: the words change, not the outcome. With no action in flight there
    /// is no verdict to print, so the row is plain.
    @Published var notice: String? {
        didSet {
            guard let notice, !notice.isEmpty else { return }
            reportToast(PanelToast(stage: panelToast?.stage ?? .message, label: notice))
        }
    }
    @Published var profile: HostProfile { didSet { if oldValue != profile { saveProfile() } } }
    /// STORE-1 §1. The demo is on (`Host/DemoHost.swift`). It is never stored:
    /// a relaunch is back at the host list.
    @Published var demoActive = false
    /// The profile the demo stood in for, put back when it ends.
    var demoReturnProfile: HostProfile?
    @Published var askText = ""
    @Published var submitting = false
    @Published var workspaceLayoutOffer: WorkspaceLayoutOffer?
    @Published var workspaceLayoutBusy = false
    @Published var workspaceLayoutRetry: WorkspaceLayoutSelection?
    @Published var companionConnected = false
    /// PERF-4 §1: the square the user tapped, held until the host's own
    /// snapshot agrees with it or the host refuses. A workspace switch used to
    /// appear on the bar only after `select` returned *and* a full snapshot had
    /// been re-read — ten seconds on the real host. The bar moves on the tap
    /// and rolls back if the host says no.
    @Published private(set) var optimisticWorkspace: Int?
    var optimisticWorkspaceTask: Task<Void, Never>?
    @Published var connectionState: CompanionConnectionState = .disconnected
    /// PAIR-5 §2. The last attempt found nobody home. It stays true across the
    /// bounded reconnect — which flips `connectionState` between .reconnecting
    /// and .offline every few seconds — so the one row ① draws about it does
    /// not blink, and the dot stays grey rather than strobing.
    @Published var hostOffline = false
    /// Exact host-prepared Agent target retained for Ask-agent navigation.
    /// This is metadata only; it never contains prompt text or terminal output.
    @Published var preparedAgentDescriptor: SessionDescriptor?
    /// Set when a paired host presents a certificate that is not the pinned one.
    @Published var certificateChange: (observed: String, pinned: String)?
    /// PAIR-5 §2. The host answered 401/403, or this device has no credential
    /// for it at all. The Shell hands this to `HostCredentialGate`, which drops
    /// everything this device holds for that account and falls back to the host
    /// list; nothing in the Panel is allowed to display it as a resting state.
    var onCredentialRejected: ((String) -> Void)?
    /// `herdr.layout.changed {revision}` is core's two-second projection of the
    /// owned session (`docs/herdr.md`). The payload is not carried here: the
    /// snapshot is the reading that cannot be wrong, so the surface re-reads
    /// `GET /v1/herdr/layout` when this moves.
    @Published private(set) var herdrLayoutRevision = 0
    func noteHerdrLayoutChanged() { herdrLayoutRevision &+= 1 }

    let defaults: UserDefaults
    let clientFactory: @MainActor (CompanionHostConfiguration, String?) -> any CompanionServing
    let pinStore: HostPinStore
    var client: (any CompanionServing)?
    var connectionGeneration = UUID()
    var streamTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var refreshNeeded = false
    var connectionWanted = false
    var foreground = true
    var reconnectAttempts = 0
    var connectionStarted = Date()
    var lastRefresh = Date.distantPast
    var lastCursor = 0
    var instanceID: String?
    var catalogRevision: String?
    var catalogEntries: [CatalogEntryDTO] = []
    /// PERF-5. The rows whose invocation the host has not answered yet. It is
    /// set before the request goes out, so the row says "on its way" on the
    /// same frame as the tap rather than after a round trip, and the panel's
    /// 26pt toast is no longer the only thing that moves.
    @Published var pendingEntryIDs: Set<String> = []
    /// PERF-5. One line per row, for the last invocation of it that failed:
    /// the host's own code. It survives the state re-read that follows the
    /// failure - that read is what would otherwise wipe the only explanation
    /// the user got - and is cleared when the row is tapped again or the
    /// presentation is reset.
    @Published var rowFailures: [String: String] = [:]
    /// MENU-4 / A-68. The one row waiting for its second tap, and until when.
    @Published var armedConfirm: ConfirmArm?
    var armTask: Task<Void, Never>?
    var latestDefaultAgent: DefaultAgentCapabilityDTO?
    var latestState: HostStateDTO?
    var onStateApplied: (() -> Void)?
    /// The one host recall this client acts on. The router consumes it and
    /// clears it, so a Panel the user then closed is not reopened by a stale
    /// value (`Host/HostWireTypes.swift` `PanelSummon`).
    @Published var panelSummon: PanelSummon?
    /// REMOTE-4. The last `remote.session.changed` the host published, handed
    /// to the Remote controller so a backend core rebuilt under a live session
    /// is a reconnect rather than an ending.
    @Published var remoteSessionChange: RemoteSessionChange?
    /// The Panel's query, results and last action result live on the store, so
    /// collapsing it or switching columns keeps them (N-09, A-31).
    @Published var panelQuery = ""
    @Published var searchResults: [MenuItem]?
    @Published var panelToast: PanelToast?
    /// The host's own notifications, mirrored while this device holds the event
    /// stream (`Notifications/NotificationState.swift`).
    @Published var notifications = HostNotificationList()
    /// The newest one, for the 26-high row on the lightweight bar (A-12).
    @Published var notificationToast: HostNotification?
    /// The last `voice.transcript` event. The dictation stop response is the
    /// authority for the device that spoke; this is the copy that survives a
    /// lost response.
    @Published var voiceTranscript: VoiceTranscriptEvent?
    /// AUTH-1. Whether this device may answer the host's password prompts, and
    /// the one prompt it is answering right now. It hangs off the store because
    /// the prompt can arrive while any surface is up, including the Remote
    /// picture, and because Settings ⑥ owns the switch that turns it on.
    let approvals = HostApprovalCoordinator()
    /// CLIP-1. This device's half of the clipboard switch, and the bridge that
    /// carries the text. It hangs off the store for the same reason approvals
    /// do: the host's clipboard can change while any surface is up, and
    /// Settings ⑥ owns the switch.
    let clipboard = ClipboardSyncCoordinator()

    /// The id this device paired under. It is minted once at first pairing and
    /// then never changes, because it is what the host's device registry, its
    /// Sunshine grant and — since AUTH-1 — its approval key are all keyed on.
    /// It is also one of the signed fields, so reading it from anywhere else
    /// would silently break every signature.
    static func companionDeviceID(defaults: UserDefaults = AppDefaults.shared) -> String {
        let key = "omodachi.deviceID.v1"
        if let value = defaults.string(forKey: key), PairingClient.validDeviceID(value) { return value }
        let value = "ios-" + UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }
    var searchTask: Task<Void, Never>?
    var toastTask: Task<Void, Never>?
    var notificationToastTask: Task<Void, Never>?
    let fontInstaller = HostFontInstaller()
    var backgroundDigest: String?

    var companionClient: (any CompanionServing)? { companionConnected ? client : nil }
    /// Subscription metadata only; an HTTP refresh must not advance this cursor.
    var eventResumePosition: (cursor: Int, instanceID: String?) { (lastCursor, instanceID) }
    var stateRevision: Int? { latestState?.revision }
    var focusTargetToken: String? { latestState?.focus?.targetToken }
    var workspaceRows: [(id: Int, canSelect: Bool, selectEntryID: String?)] {
        (latestState?.workspace?.items ?? []).map { item in
            (item.id, barModel.workspaces.contains { $0.id == item.id && $0.canSelect }, item.selectEntryID)
        }
    }
    var flattened: [MenuItem] { menu.flatMap(\.all) }
    var connectionDiagnostics: CompanionConnectionDiagnostics {
        .init(connected: companionConnected, hostSource: latestState?.host?.source, hostName: latestState?.host?.name,
              instanceID: instanceID, stateRevision: latestState?.revision, deliveredEventCursor: lastCursor,
              catalogRevision: catalogRevision, defaultAgentReady: latestDefaultAgent?.readyToAttach,
              herdrAvailable: latestState?.herdr?.available)
    }

    init(defaults: UserDefaults = .standard,
         credentials: any CompanionCredentialProviding = CompanionCredentialStore(),
         pinStore: HostPinStore = HostPinStore(),
         clientFactory: (@MainActor (CompanionHostConfiguration, String?) -> any CompanionServing)? = nil,
         autoConnect: Bool = true) {
        self.defaults = defaults
        self.pinStore = pinStore
        self.clientFactory = clientFactory ?? { CompanionHostClient(configuration: $0, credentials: credentials, pinnedFingerprint: $1) }
        profile = defaults.data(forKey: "omodachi.profile.v1").flatMap { try? JSONDecoder().decode(HostProfile.self, from: $0) } ?? HostProfile()
        resetPresentation()
        if autoConnect, !profile.mock, !profile.companionURL.isEmpty {
            Task { [weak self] in await self?.connectCompanion() }
        }
    }

    // MARK: - Presentation

    func apply(_ snapshot: CompanionSnapshot, establishingCursor: Bool = false) {
        guard apply(snapshot.state, establishingCursor: establishingCursor) else { return }
        latestDefaultAgent = snapshot.state.agent?.defaultAgent ?? snapshot.capabilities.defaultAgent
        applyCatalog(snapshot.catalog)
        if let count = snapshot.herdr.agentCount { state.herdrAgentCount = count }
        else if snapshot.herdr.serverRunning == true { state.herdrAgentCount = snapshot.herdr.agents.count }
    }

    @discardableResult
    func apply(_ snapshot: HostStateDTO, establishingCursor: Bool = false) -> Bool {
        if establishingCursor {
            lastCursor = snapshot.eventCursor ?? 0
            instanceID = snapshot.instanceID
        } else {
            // A state GET reports the global hub cursor, including events this
            // device cannot see. It must not replace the subscription's cursor.
            if let latestState, snapshot.revision < latestState.revision { return false }
        }
        latestState = snapshot
        workspaceLayoutOffer = makeWorkspaceLayoutOffer(snapshot)
        hostWakeState = snapshot.wake
        latestDefaultAgent = snapshot.agent?.defaultAgent ?? latestDefaultAgent
        if let name = snapshot.host?.name, !name.isEmpty { state.hostName = name }
        state.online = companionConnected && snapshot.host?.connected == true
        state.workspace = optimisticWorkspace
            ?? snapshot.workspace?.active.flatMap { $0 > 0 ? $0 : nil } ?? 0
        state.occupiedWorkspaces = Set((snapshot.workspace?.items ?? []).filter { $0.occupied == true }.map(\.id))
        state.focusWindow = snapshot.focus?.displayName ?? "—"
        state.streamState = snapshot.remote?.state ?? "Disconnected"
        state.defaultAgentKind = latestDefaultAgent?.configuredKind ?? latestDefaultAgent?.omarchyDefaultAgent
        state.agentStatus = AgentStatus(rawValue: snapshot.agent?.status.rawValue ?? "unknown") ?? .unknown
        state.herdrAgentCount = snapshot.herdr?.agentCount
        state.toggles = snapshot.toggles
        // ARCH-1 §5 #17: one reader for Do Not Disturb, and it is the snapshot.
        // A host too old to publish it leaves the last reading alone rather
        // than claiming "off".
        if let dnd = snapshot.notifications?.dnd { notifications.dnd = dnd }
        if let catalog = snapshot.catalog { applyCatalog(catalog) }
        else { for item in flattened { if let value = item.checked { state.toggles[item.id] = value } } }
        rebuildBar()
        onStateApplied?()
        return true
    }

    func applyCatalog(_ catalog: HostCatalogDTO) {
        catalogRevision = catalog.revision
        catalogEntries = catalog.entries
        menu = HostMenu.build(from: catalog.entries)
        traceMenu("catalog")
        for item in flattened { if let checked = item.checked { state.toggles[item.id] = checked } }
        rebuildBar()
    }

    /// The workspace to draw as current: the host's, unless a tap is still
    /// waiting for it to catch up.
    var shownWorkspace: Int? {
        guard let pending = optimisticWorkspace else { return latestState?.workspace?.active }
        return pending
    }

    func setOptimisticWorkspace(_ value: Int?) {
        optimisticWorkspaceTask?.cancel(); optimisticWorkspaceTask = nil
        optimisticWorkspace = value
        state.workspace = value ?? latestState?.workspace?.active.flatMap { $0 > 0 ? $0 : nil } ?? state.workspace
        rebuildBar()
        guard value != nil else { return }
        // A lost answer must not pin the bar to a lie for ever.
        let current = connectionGeneration
        optimisticWorkspaceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.connectionGeneration == current else { return }
            self.optimisticWorkspace = nil
            self.state.workspace = self.latestState?.workspace?.active ?? 0
            self.rebuildBar()
        }
    }

    func rebuildBar() {
        if let pending = optimisticWorkspace, latestState?.workspace?.active == pending {
            optimisticWorkspaceTask?.cancel(); optimisticWorkspaceTask = nil
            optimisticWorkspace = nil
        }
        guard companionConnected, let snapshot = latestState,
              let bar = snapshot.bar, let layout = bar.nativeLayout else { barModel = .unavailable; return }
        let focus = snapshot.focus
        let hasTarget = focus?.targetToken.map { !$0.isEmpty && $0.utf8.count <= 1024 } == true
        var seen = Set<Int>()
        let workspaces: [BarWorkspace]
        if let remote = snapshot.remoteBar, remote.active {
            // With Remote open the bar mirrors the remote desktop's workspaces,
            // and a tap acts on the session's own output (Study 04 A-64): core
            // pulls the workspace to `session.output_name` rather than moving
            // the physical screen.
            workspaces = (remote.workspaces ?? []).filter { $0.id > 0 && seen.insert($0.id).inserted }.map {
                BarWorkspace(id: $0.id, active: $0.active, occupied: $0.windows > 0, persistent: false,
                             canSelect: remote.sessionID != nil && remote.revision != nil, canMoveFocusedWindow: false)
            }
        } else {
            let pending = optimisticWorkspace
            workspaces = (snapshot.workspace?.items ?? []).filter { $0.id > 0 && seen.insert($0.id).inserted }.map { item in
                BarWorkspace(id: item.id,
                             active: pending == nil ? item.active : pending == item.id,
                             occupied: item.occupied,
                             persistent: item.persistent == true, canSelect: true,
                             canMoveFocusedWindow: hasTarget && barActionAvailable(item.moveFocusedEntryID))
            }
        }
        barModel = HostBarModel(available: true, layout: layout, workspaces: workspaces,
                                focusedApp: focus?.barFocus, geometry: bar.geometry?.native)
        PanelPerfTrace.bar(active: workspaces.first(where: { $0.active == true })?.id ?? 0,
                           source: optimisticWorkspace == nil ? "snapshot" : "optimistic")
    }

    /// PERF-4. How many rows would draw `不可用` after this rebuild.
    func traceMenu(_ cause: String) {
        let rows = flattened.filter(\.children.isEmpty)
        PanelPerfTrace.menu(total: rows.count, unavailable: rows.filter { !$0.enabled }.count, cause: cause)
    }

    func barActionAvailable(_ entryID: String?) -> Bool {
        guard let entryID, let entry = catalogEntries.first(where: { $0.id == entryID }) else { return false }
        return companionConnected && catalogRevision != nil && entry.visible == true
            && entry.descriptor?.supported == true && entry.descriptor?.ready == true && entry.descriptor?.route == "host"
    }

    /// The connection is down; the whole snapshot goes with it.
    ///
    /// It takes no message and prints none. The bar's dot is red and its
    /// VoiceOver value says `连不上`, which is the whole report — a sentence
    /// under the menu would be the N-33 status line again, and a permanent one,
    /// because nothing clears it.
    func markUnavailable(_ error: Error?) {
        workspaceLayoutOffer = nil; workspaceLayoutRetry = nil; workspaceLayoutBusy = false
        hostWakeState = nil; wakingDesktop = false
        companionConnected = false
        releaseHostIcons()
        hostOffline = Self.describesAnUnreachableHost(error)
        connectionState = hostOffline ? .offline : .unavailable
        state.online = false
        barModel = .unavailable
        state.agentStatus = .unknown
        state.herdrAgentCount = nil
        state.workspace = 0
        state.occupiedWorkspaces = []
        optimisticWorkspace = nil
        latestDefaultAgent = nil
        // PERF-4 §1: the menu and its toggles are the last thing the host
        // actually said, and they stay that way. Rebuilding them as "nothing
        // is available" turned every row grey the moment a refresh timed out —
        // which, with a host whose event loop was blocked for seconds at a
        // time, was most of the time. A row is only `不可用` because the host
        // said so; that a tap cannot be sent right now is the toast's job and
        // the dot's, not the row's. PAIR-5's offline row and MENU-1's
        // fallbacks both read the same menu, and both want it intact.
        traceMenu("markUnavailable")
        if let error, connectionState != .offline {
            notice = (error as? CompanionHostError)?.errorDescription ?? Strings.hostErrorUnreachable
        } else if connectionState == .offline {
            // The offline row in ① is the whole message, and it carries the
            // retry; a second sentence under the menu would be the resting
            // state PAIR-5 exists to remove.
            notice = nil
        }
    }

    /// Nobody answered, as opposed to somebody answering with a refusal. Only
    /// the first is "offline"; a 401 is a decision the host made.
    static func describesAnUnreachableHost(_ error: Error?) -> Bool {
        guard let error else { return false }
        if case CompanionHostError.transport = error { return true }
        return error is URLError
    }

    /// PAIR-5 §2. The two shapes of "this device is not authorized here": the
    /// host refused the credential, or there is no credential to send.
    static func describesACredentialRejection(_ error: Error) -> Bool {
        switch error as? CompanionHostError {
        case .unauthorized, .missingCredential, .notConnected: true
        default: false
        }
    }

    func saveProfile() {
        // STORE-1 §1: the demo profile is never written down.
        if !demoActive, let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: "omodachi.profile.v1") }
        connectionWanted = false
        stopActiveConnection()
        askText = ""
        notice = nil
        certificateChange = nil
        resetPresentation()
    }

    func resetPresentation() {
        state = HostState()
        barModel = .unavailable
        catalogRevision = nil; catalogEntries = []; latestState = nil; latestDefaultAgent = nil
        panelQuery = ""; searchResults = nil; panelToast = nil; panelSummon = nil
        notifications = HostNotificationList(); notificationToast = nil; voiceTranscript = nil
        notificationToastTask?.cancel(); notificationToastTask = nil
        searchTask?.cancel(); searchTask = nil; toastTask?.cancel(); toastTask = nil
        preparedAgentDescriptor = nil
        pendingEntryIDs = []; rowFailures = [:]; armedConfirm = nil; armTask?.cancel(); armTask = nil
        optimisticWorkspaceTask?.cancel(); optimisticWorkspaceTask = nil; optimisticWorkspace = nil
        lastCursor = 0; instanceID = nil
        state.hostName = profile.mock ? "Omarchy · Demo" : profile.hostname // non-copy: the demo fixture host
        state.online = profile.mock
        state.focusWindow = "—"
        state.streamState = "Disconnected"
        if profile.mock {
            menu = MockCatalog.roots
            if demoActive { applyDemoFixtures() }
        } else {
            state.workspace = 0; state.occupiedWorkspaces = []; state.toggles = [:]; menu = []
        }
    }

    func mockWorkspace(_ value: Int) { state.workspace = value }

    // MARK: - Actions

    // MARK: - Actions

    // N-39 rev 5 replaced this store's own pin list. The four surface tiles it
    // used to hold are bar entries now (A-50), and what a user pins is a menu
    // row or a keybinding, keyed by host and by a stable key rather than by a
    // catalog id that changes — `Host/PanelPins.swift`.

    func wakeDesktop() async {
        guard companionConnected, let client, !wakingDesktop else { return }
        let current = connectionGeneration
        wakingDesktop = true
        defer { if current == connectionGeneration { wakingDesktop = false } }
        do {
            _ = try await client.wakeDesktop()
            guard current == connectionGeneration else { return }
            await refreshCompanionState()
        } catch {
            guard current == connectionGeneration else { return }
            notice = (error as? CompanionHostError)?.errorDescription ?? Strings.hostWakeFailed
        }
    }

    func loadShortcuts() async throws -> ShortcutSnapshot {
        if demoActive, profile.mock { return try DemoHost.shortcuts() }
        guard companionConnected, let client else { throw ShortcutWireError.unavailableContext }
        return try await client.fetchShortcuts()
    }

    func runShortcut(_ request: ShortcutExecutionRequest) async throws -> ShortcutExecutionResult {
        guard companionConnected, let client, request.context.hostID == profile.companionURL else { throw ShortcutWireError.unavailableContext }
        let result = try await client.executeShortcut(request)
        await refreshCompanionState()
        return result
    }

    /// What pairing pinned for this endpoint: the host's own installation
    /// identity, its certificate and the endpoints it answers on.
    var hostPin: HostPin? {
        profile.companionURL.isEmpty ? nil : pinStore.load(account: HostAccount.canonical(profile.companionURL))
    }

    /// §2: the SSH surface dials the paired address with the account from
    /// Setup. `nil` means there is nothing to dial and the surface says so.
    var sshTarget: SSHTarget? { SSHTargetResolver.resolve(profile: profile, pin: hostPin) }

    /// The profile one SSH session should carry, with the resolved address
    /// written in. The profile id — and so the Keychain account holding the
    /// private key — does not move.
    var sshProfile: HostProfile {
        sshTarget.map { SSHTargetResolver.profile(profile, for: $0) } ?? profile
    }

    func chatClient(for hostID: String) throws -> CompanionHostClient {
        guard hostID == profile.companionURL, companionConnected, let real = client as? CompanionHostClient else {
            throw CompanionHostError.notConnected
        }
        return real
    }

    /// PERF-5. One line for a row that did not run, from the host's own code.
    ///
    /// Only the codes a person can act on get their own sentence. Anything
    /// else keeps the code itself rather than a friendlier sentence that says
    /// less: an unfamiliar word the user can quote is worth more than
    /// "something went wrong".
    static func rowFailure(code: String?) -> String {
        switch code {
        case "stale_catalog_revision", "stale_target", "menu_action_changed", "stale_binding":
            return Strings.menuFailedStale
        case "no_focused_window": return Strings.menuFailedNoFocus
        // MENU-4: the menu-action adapter's failures have sentences already.
        case .some(let value) where ReasonText.shared(value) != nil: return ReasonText.shared(value)!
        case .some(let value) where !value.isEmpty: return value
        default: return Strings.menuFailedRefused
        }
    }

    static func rowFailure(error: Error) -> String {
        guard let host = error as? CompanionHostError else { return Strings.menuFailedUnknown }
        switch host {
        case .staleTarget: return Strings.menuFailedStale
        case .notConnected, .transport: return Strings.menuFailedUnreachable
        case let .unavailable(code, _), let .blocked(code, _), let .mismatch(code, _):
            return rowFailure(code: code)
        default: return Strings.menuFailedRefused
        }
    }

    /// MENU-4 / A-68. Whether this tap is the one that sends `item`. A row the
    /// host marked `confirm` answers false on its first tap and arms itself;
    /// the arm lapses on its own after `ConfirmArm.window`.
    func passesConfirm(_ item: MenuItem, now: Date = Date()) -> Bool {
        let decision = ConfirmGate.tap(item.id, confirm: item.confirm, armed: armedConfirm, now: now)
        armTask?.cancel()
        armTask = nil
        armedConfirm = decision.armed
        if let armed = decision.armed {
            let wait = max(0, armed.until.timeIntervalSince(now))
            armTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self, self.armedConfirm == armed else { return }
                self.armedConfirm = nil
            }
        }
        return decision.send
    }

    func invoke(_ item: MenuItem) async {
        if item.id == WorkspaceLayoutRequest.entryID {
            notice = ReasonText.message("invalid_workspace_request", domain: .workspace); return
        }
        if profile.mock {
            if let value = state.toggles[item.id] { state.toggles[item.id] = !value }
            if let range = item.id.range(of: "omodachi.workspace.select."),
               let number = Int(item.id[range.upperBound...]), (1...10).contains(number) { state.workspace = number }
            reportToast(.init(stage: .applied, label: item.label, detail: "demo"))
            return
        }
        _ = await prepareAction(item)
    }

    /// Returns a freshly authorized terminal/native launch. Host mutations are
    /// reported separately and toggles only change after a fresh host snapshot.
    func prepareAction(_ item: MenuItem) async -> MenuItem? {
        if item.id == WorkspaceLayoutRequest.entryID { notice = ReasonText.message("invalid_workspace_request", domain: .workspace); return nil }
        if profile.mock { return item }
        guard companionConnected, let service = client, let revision = catalogRevision,
              let currentItem = flattened.first(where: { $0.id == item.id }), currentItem.enabled else {
            notice = ReasonText.message("route_unavailable", domain: .host)
            return nil
        }
        let current = connectionGeneration
        let clock = PanelPerfTrace.begin("actions.invoke", detail: "entry=\(item.id)")
        // PERF-5. The row is drawn as on its way here, before the request is
        // built, so what the tap changes on screen does not depend on how long
        // the host takes. `defer` is what guarantees it comes back off: an
        // error, a cancellation or a connection that moved underneath all land
        // there.
        rowFailures[item.id] = nil
        pendingEntryIDs.insert(item.id)
        PanelPerfTrace.mark(clock, "row-pending", detail: "entry=\(item.id)")
        defer { pendingEntryIDs.remove(item.id) }
        let toast = PanelToast(stage: .accepted, label: currentItem.label)
        reportToast(toast)
        do {
            let isWorkspaceMove = latestState?.workspace?.items?.contains { $0.moveFocusedEntryID == item.id } == true
            let focus = latestState?.focus
            if isWorkspaceMove, focus?.targetToken?.isEmpty != false {
                settleToast(id: toast.id, stage: .failed, detail: Strings.menuFailedNoFocus)
                notice = ReasonText.message("no_focused_window", domain: .workspace)
                return nil
            }
            let response = try await service.invoke(entryID: item.id, catalogRevision: revision, parameters: [:],
                                                    targetToken: isWorkspaceMove ? focus?.targetToken : nil,
                                                    stateRevision: latestState?.revision)
            guard current == connectionGeneration else { return nil }
            PanelPerfTrace.mark(clock, "host-answered", detail: "status=\(response.status.rawValue)")
            // PERF-5. The revision the host resolved this against, adopted
            // before anything else looks at it. It arrives ahead of the state
            // re-read below, which is the authority when it does arrive - this
            // is what carries the answer on the paths that never read state.
            if let resolved = response.catalogRevision { catalogRevision = resolved }
            if response.status == .prepared, let descriptor = response.descriptor,
               descriptor.supported, descriptor.ready != false, descriptor.entryID == item.id {
                var result = currentItem
                result.route = descriptor.route == "native" ? "native:\(descriptor.nativeView ?? "")" : descriptor.route // non-copy: a route id
                result.terminalArgv = descriptor.argv
                if descriptor.route == "terminal", descriptor.argv?.isEmpty != false {
                    settleToast(id: toast.id, stage: .failed, detail: Strings.hostNoTerminalTarget)
                    notice = Strings.hostNoTerminalTarget
                    return nil
                }
                settleToast(id: toast.id, stage: .applied, detail: "prepared")
                notice = nil
                return result
            }
            switch response.status {
            case .applied, .done: settleToast(id: toast.id, stage: .applied, detail: nil)
            case .accepted, .working: settleToast(id: toast.id, stage: .accepted, detail: nil)
            default:
                settleToast(id: toast.id, stage: .failed, detail: response.code)
                rowFailures[item.id] = Self.rowFailure(code: response.code)
            }
            notice = response.message
            await refreshCompanionState()
            PanelPerfTrace.mark(clock, "snapshot-applied")
        } catch {
            guard current == connectionGeneration else { return nil }
            PanelPerfTrace.mark(clock, "host-failed", detail: "\(error)")
            settleToast(id: toast.id, stage: .failed,
                        detail: (error as? CompanionHostError).map { _ in "refused" } ?? "unknown")
            rowFailures[item.id] = Self.rowFailure(error: error)
            notice = (error as? CompanionHostError)?.errorDescription ?? Strings.hostActionOutcomeUnknown
            if case CompanionHostError.staleTarget = error { await refreshCompanionState() }
        }
        return nil
    }

    func submitTask() async -> Bool {
        guard !submitting, !askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if profile.mock {
            guard state.agentStatus != .working, state.agentStatus != .blocked else { notice = ReasonText.message("agent_busy", domain: .agent); return false }
            state.agentStatus = .working
            askText = ""
            notice = Strings.agentTaskAccepted
            return true
        }
        guard companionConnected, let service = client else { notice = Strings.hostConnectFirst; return false }
        let current = connectionGeneration, text = askText
        submitting = true
        defer { submitting = false }
        do {
            let observed = try await service.fetchState()
            guard current == connectionGeneration, apply(observed) else { return false }
            if let reason = Self.taskBlockReason(observed.agent?.defaultAgent, status: observed.agent?.status) {
                notice = reason
                return false
            }
            guard let agentItem = flattened.first(where: { $0.id == "omodachi.agent" }),
                  let prepared = await prepareAction(agentItem), prepared.route == "terminal",
                  let argv = prepared.terminalArgv, !argv.isEmpty else {
                notice = Strings.agentNoAttachTarget
                return false
            }
            let target = SurfaceRouteTargets.shell(host: profile, title: "Agent", argv: argv)
            guard target.kind == .agent, !target.host.herdrSession.isEmpty, target.argv == argv else {
                notice = Strings.agentNoAttachTarget
                return false
            }
            let expectedPaneID = observed.agent?.paneID ?? observed.agent?.defaultAgent?.paneID
            let response = try await service.submitDefaultAgentTask(text, requestID: UUID().uuidString)
            guard current == connectionGeneration else { return false }
            guard response.agentID == "default", [.accepted, .working, .done].contains(response.status),
                  expectedPaneID == nil || response.paneID == expectedPaneID else {
                state.agentStatus = response.status == .blocked ? .blocked : .unknown
                notice = Strings.hostErrorDifferentAgentTarget
                return false
            }
            preparedAgentDescriptor = target
            if askText == text { askText = "" }
            notice = response.message
            state.agentStatus = .unknown
            // A POST acknowledgment is not proof of running/ready/completed state.
            if let refreshed = try? await service.fetchState(), current == connectionGeneration { apply(refreshed) }
            return true
        } catch {
            guard current == connectionGeneration else { return false }
            state.agentStatus = .unknown
            notice = (error as? CompanionHostError)?.errorDescription ?? Strings.agentTaskOutcomeUnknown
            // Never automatically retry a task mutation after an uncertain result.
            return false
        }
    }
}
