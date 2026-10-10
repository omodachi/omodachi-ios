import Foundation

/// The host's `/v1` documents, decoded with `Codable` defaults. The host is the
/// machine the user owns and paired with; it is not a hostile server, so these
/// types describe the contract rather than defend against it.

public enum CompanionOperationStatus: String, Codable, Sendable {
    case accepted, prepared, failed, applied, rejected, idle, working, blocked, done, unknown, unavailable
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct HostWakeStateDTO: Decodable, Equatable, Sendable {
    public let screensaverActive: Bool
    public let displayAsleep: Bool
    public let locked: Bool?
    public let wakePending: Bool?
    public var needsWake: Bool { screensaverActive || displayAsleep || wakePending == true }
    enum CodingKeys: String, CodingKey {
        case screensaverActive = "screensaver_active", displayAsleep = "display_asleep", locked, wakePending = "wake_pending"
    }
}

public struct HostWakeResponseDTO: Decodable, Sendable {
    public let consumeTap: Bool
    enum CodingKeys: String, CodingKey { case consumeTap = "consume_tap" }
}

/// `state.remote_bar`: the live output and workspace projection Panel anchors on.
public struct RemoteBarStateDTO: Decodable, Equatable, Sendable {
    public struct Workspace: Decodable, Equatable, Sendable {
        public let id: Int
        public let windows: Int
        public let active: Bool
        public let remote: Bool
    }
    public let active: Bool
    public let sessionID: String?
    public let revision: String?
    public let workspaces: [Workspace]?
    enum CodingKeys: String, CodingKey { case active, sessionID = "session_id", revision, workspaces }
}

/// `state.remote`: the one session's identity, as the state document reports it.
public struct RemoteStateDTO: Decodable, Equatable, Sendable {
    public let sessionID: String?
    public let state: String
    public let mode: String?
    public let backend: String?
    public let revision: Int
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", state, mode, backend, revision }
}

public struct HostStateDTO: Decodable, Equatable, Sendable {
    public struct Host: Decodable, Equatable, Sendable {
        public let name: String?
        public let connected: Bool?
        public let source: String?
    }
    public struct Workspace: Decodable, Equatable, Sendable {
        public let active: Int?
        public let items: [HostBarWorkspaceDTO]?
        public let layoutBinding: WorkspaceLayoutBinding?
        public let layoutBindingFieldPresent: Bool
        enum CodingKeys: String, CodingKey { case active, items, layoutBinding = "layout_binding" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            active = try c.decodeIfPresent(Int.self, forKey: .active)
            items = try c.decodeIfPresent([HostBarWorkspaceDTO].self, forKey: .items)
            layoutBindingFieldPresent = c.contains(.layoutBinding)
            layoutBinding = try? c.decodeIfPresent(WorkspaceLayoutBinding.self, forKey: .layoutBinding)
        }
    }
    public struct Agent: Decodable, Equatable, Sendable {
        public let kind: String?
        public let exists: Bool?
        public let paneAvailable: Bool?
        public let status: CompanionOperationStatus
        /// NOTIFY-2: the status as core wrote it. `status` folds everything it
        /// does not know into `.unknown`, and `waiting_on_approval` /
        /// `waiting_on_user_input` are exactly what the Agent badge and the
        /// app's own alerts need to tell apart.
        public let statusText: String?
        public let paneID: String?
        public let agentID: String?
        public let attachVerified: Bool?
        public let defaultAgent: DefaultAgentCapabilityDTO?
        /// MOTION-1 `state.agent.chat`: the provider's waiting flag, its
        /// pending approvals and `activity` — what the turn is doing now, for
        /// the animated face. Read leniently; a host without it has no face
        /// beyond idle / waiting.
        let chat: AgentActivity?
        /// NOTIFY-1 `state.agent.chat.approval`: the oldest pending approval,
        /// ids only, for an alert's Allow / Deny.
        let approval: AttentionApproval?
        enum CodingKeys: String, CodingKey {
            case kind, exists, paneAvailable = "pane_available", status, paneID = "pane_id"
            case agentID = "agent_id", attachVerified = "attach_verified", defaultAgent = "default_agent"
            case chat
        }
        private struct ChatDTO: Decodable {
            struct Status: Decodable { let waiting: String? }
            struct Activity: Decodable { let phase: String?; let turn_id: String? }
            let status: Status?
            let pending_approvals: Int?
            let activity: Activity?
            let approval: AttentionApproval.Wire?
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            exists = try c.decodeIfPresent(Bool.self, forKey: .exists)
            paneAvailable = try c.decodeIfPresent(Bool.self, forKey: .paneAvailable)
            status = try c.decodeIfPresent(CompanionOperationStatus.self, forKey: .status) ?? .unknown
            statusText = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0 }
            paneID = try c.decodeIfPresent(String.self, forKey: .paneID)
            agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
            attachVerified = try c.decodeIfPresent(Bool.self, forKey: .attachVerified)
            defaultAgent = try c.decodeIfPresent(DefaultAgentCapabilityDTO.self, forKey: .defaultAgent)
            let chatDTO = (try? c.decodeIfPresent(ChatDTO.self, forKey: .chat)) ?? nil
            approval = AttentionApproval(chatDTO?.approval)
            chat = chatDTO.map { dto in
                let phase = dto.activity?.phase ?? "idle"
                let known = ["idle", "thinking", "working", "tool", "done", "error", "stopped", "offline"].contains(phase) // INTEGRATE-2: stopped
                let turn = dto.activity?.turn_id.flatMap { $0.utf8.count <= 128 ? $0 : nil }
                return AgentActivity(phase: known ? phase : "idle", turnID: turn,
                                     waiting: dto.status?.waiting, pendingApprovals: max(0, dto.pending_approvals ?? 0))
            }
        }
    }
    public struct Herdr: Decodable, Equatable, Sendable {
        public let available: Bool?
        public let agentCount: Int?
        /// NOTIFY-2: per watched session, what is blocked right now — the
        /// app's first look, so the next `herdr.layout.changed` is news
        /// against it. Ids and names only; read leniently.
        public let blocked: [String: [HerdrAttentionEvent.Pane]]?
        enum CodingKeys: String, CodingKey { case available, agentCount = "agent_count", blocked }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            available = try c.decodeIfPresent(Bool.self, forKey: .available)
            agentCount = try c.decodeIfPresent(Int.self, forKey: .agentCount)
            struct Row: Decodable { let pane_id: String?; let name: String? }
            let raw = (try? c.decodeIfPresent([String: [Row]].self, forKey: .blocked)) ?? nil
            blocked = raw.map { map in
                Dictionary(uniqueKeysWithValues: map.filter { AppLink.validSession($0.key) }.prefix(64).map { session, rows in
                    (session, rows.prefix(32).compactMap { row in
                        guard let id = row.pane_id, AppLink.validPane(id) else { return nil }
                        let name = row.name.map { String($0.filter { !$0.isNewline }.prefix(32)) }
                        return HerdrAttentionEvent.Pane(paneID: id, name: name?.isEmpty == true ? nil : name)
                    })
                })
            }
        }
    }

    /// ARCH-1 §5 #17 / N-36. The shell's own Do Not Disturb, pushed with every
    /// state change. `nil` is core's own `null`: nobody has read the shell yet.
    /// The client mirrors it and keeps no boolean of its own, because the
    /// desktop's indicator can move it while the iPad is looking at it.
    public struct Notifications: Decodable, Equatable, Sendable {
        public let dnd: Bool?
    }

    public let revision: Int
    public let host: Host?
    public let workspace: Workspace?
    public let agent: Agent?
    public let herdr: Herdr?
    public let toggles: [String: Bool]
    public let eventCursor: Int?
    public let instanceID: String?
    public let catalog: HostCatalogDTO?
    public let bar: HostBarDTO?
    public let remote: RemoteStateDTO?
    public let remoteBar: RemoteBarStateDTO?
    public let wake: HostWakeStateDTO?
    public let focus: HostFocusDTO?
    public let notifications: Notifications?
    /// NOTIFY-1: whether the person is at the computer, and what finished
    /// with nobody looking. Absent from a core before NOTIFY-1.
    let desk: DeskReading?
    let unseen: UnseenReading?
    /// OVERVIEW-1: everything that wants Leo, one list. Absent from a core
    /// before OVERVIEW-1 (then the app builds a smaller one, `fallback`).
    let overview: OverviewReading?

    enum CodingKeys: String, CodingKey {
        case revision, host, workspace, agent, herdr, toggles, catalog, bar, focus, wake, remote
        case notifications, desk, unseen, overview
        case eventCursor = "event_cursor", instanceID = "instance_id", remoteBar = "remote_bar"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        host = try c.decodeIfPresent(Host.self, forKey: .host)
        workspace = try c.decodeIfPresent(Workspace.self, forKey: .workspace)
        agent = try c.decodeIfPresent(Agent.self, forKey: .agent)
        herdr = try c.decodeIfPresent(Herdr.self, forKey: .herdr)
        toggles = try c.decodeIfPresent([String: Bool].self, forKey: .toggles) ?? [:]
        eventCursor = try c.decodeIfPresent(Int.self, forKey: .eventCursor)
        instanceID = try c.decodeIfPresent(String.self, forKey: .instanceID)
        catalog = try c.decodeIfPresent(HostCatalogDTO.self, forKey: .catalog)
        bar = try c.decodeIfPresent(HostBarDTO.self, forKey: .bar)
        remote = try c.decodeIfPresent(RemoteStateDTO.self, forKey: .remote)
        remoteBar = try c.decodeIfPresent(RemoteBarStateDTO.self, forKey: .remoteBar)
        wake = try c.decodeIfPresent(HostWakeStateDTO.self, forKey: .wake)
        focus = try c.decodeIfPresent(HostFocusDTO.self, forKey: .focus)
        notifications = try c.decodeIfPresent(Notifications.self, forKey: .notifications)
        desk = DeskReading((try? c.decodeIfPresent(DeskReading.Wire.self, forKey: .desk)) ?? nil)
        unseen = UnseenReading((try? c.decodeIfPresent(UnseenReading.Wire.self, forKey: .unseen)) ?? nil)
        overview = OverviewReading((try? c.decodeIfPresent(OverviewReading.Wire.self, forKey: .overview)) ?? nil)
    }
}

public struct HostCapabilitiesDTO: Decodable, Equatable, Sendable {
    public let terminal: Bool?
    public let desktop: Bool?
    public let native: [String]
    public let defaultAgent: DefaultAgentCapabilityDTO?
    enum CodingKeys: String, CodingKey { case terminal, desktop, native, defaultAgent = "default_agent" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = try c.decodeIfPresent(Bool.self, forKey: .terminal)
        desktop = try c.decodeIfPresent(Bool.self, forKey: .desktop)
        native = try c.decodeIfPresent([String].self, forKey: .native) ?? []
        defaultAgent = try c.decodeIfPresent(DefaultAgentCapabilityDTO.self, forKey: .defaultAgent)
    }
}

/// Preference and readiness are host observations, never a saved iOS preference.
public struct DefaultAgentCapabilityDTO: Decodable, Equatable, Sendable {
    public let omarchyDefaultAgent: String?
    public let herdrSupportedKinds: [String]?
    public let defaultAgentExists: Bool?
    public let paneID: String?
    public let paneAvailable: Bool?
    public let agentStatus: CompanionOperationStatus?
    public let kindSupported: Bool?
    public let readyToAttach: Bool?
    public let attachVerified: Bool?
    public let configuredKind: String?
    public let actualKind: String?
    public let kindMismatch: Bool?
    public let defaultAgentProbe: String?
    public let herdrAvailable: Bool?
    public let kind: String?
    public let exists: Bool?
    public let status: CompanionOperationStatus?
    enum CodingKeys: String, CodingKey {
        case omarchyDefaultAgent = "omarchy_default_agent", herdrSupportedKinds = "herdr_supported_kinds"
        case defaultAgentExists = "default_agent_exists", paneID = "pane_id", paneAvailable = "pane_available"
        case agentStatus = "agent_status", kindSupported = "kind_supported", readyToAttach = "ready_to_attach"
        case attachVerified = "attach_verified", configuredKind = "configured_kind", actualKind = "actual_kind"
        case kindMismatch = "kind_mismatch", defaultAgentProbe = "default_agent_probe"
        case herdrAvailable = "herdr_available", kind, exists, status
    }
}

/// Only the host-computed route is exposed. Raw action/argv/when/provider source
/// is deliberately absent; the client never evaluates a menu expression.
public struct CatalogRouteDTO: Decodable, Equatable, Sendable {
    public let route: String
    public let supported: Bool
    public let nativeView: String?
    public let entryID: String?
    public let argv: [String]?
    public let ready: Bool?
    /// Why `ready` is false, in the host's own code. MENU-3 reads one of them:
    /// `condition_disabled`, a row the host greys on purpose.
    public let readinessReason: String?
    /// MENU-4 / A-68. The host says this row changes the machine (power,
    /// erasing, updating, security): the panel asks for a second tap before it
    /// sends it. Absent means false.
    public let confirm: Bool?
    enum CodingKeys: String, CodingKey {
        case route, supported, nativeView = "native_view", entryID = "entry_id", argv, ready
        case readinessReason = "readiness_reason", confirm
    }
}

public struct CatalogEntryDTO: Decodable, Equatable, Sendable {
    public let id: String
    public let parentID: String?
    public let label: String?
    /// The row's glyph. Omarchy's menu rows carry a Nerd Font code point here,
    /// or a private-use code point from `omarchy.ttf` when `iconFont` is
    /// `"omarchy"` (`docs/fonts.md`). It is a character, never an SF Symbol.
    public let icon: String?
    public let iconFont: String?
    /// The host's own classification of the row: `menu`, `action`, `link`, or
    /// `app`. `app` is the one that matters to the client, because core's Apps
    /// provider compiles it from a `.desktop` file and its `icon` is then an
    /// **XDG icon name**, not a code point (`omodachi-core/src/omodachi_core/
    /// catalog.py` `_app_kind`). Knowing that from the host is what keeps the
    /// client from guessing at an `apps.` prefix.
    public let kind: String?
    /// ICON-1. The host's own answer to "what kind of thing is `icon`":
    /// `glyph`, `xdg`, `path` or `none` (`omodachi-core/docs/icons.md`). A host
    /// that predates ICON-1 publishes nothing here, and the client classifies
    /// the value itself by the same rule.
    public let iconKind: HostIconKind
    public let descriptor: CatalogRouteDTO?
    public let route: String?
    public let supported: Bool?
    public let available: Bool?
    public let visible: Bool?
    public let order: Int?
    public let checked: Bool?
    public let conditions: CatalogConditionsDTO?
    public let aliases: [String]
    /// MENU-4. Whether the host fills this submenu from a provider (Apps,
    /// fonts). Only the fact is read, from `provider_state`'s presence: Omarchy
    /// keeps such a submenu even while it is empty, and hides any other
    /// submenu none of whose rows is visible (`MenuModel.js` `isVisible`).
    public let providerMenu: Bool
    enum CodingKeys: String, CodingKey {
        case id, parentID = "parent_id", label, icon, iconFont, kind, descriptor, route, supported, available
        case visible, order, conditions, aliases, checkedState = "checked_state", iconKind = "icon_kind"
        case providerState = "provider_state"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        iconFont = try c.decodeIfPresent(String.self, forKey: .iconFont)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        iconKind = (try? c.decodeIfPresent(String.self, forKey: .iconKind))
            .flatMap { $0.flatMap(HostIconKind.init(rawValue:)) }
            ?? HostIconKind.classify(icon, iconFont: iconFont)
        // Core names this object `route`; `descriptor` is the same shape under
        // the older key. Either way it is the host's verdict, not a raw action.
        descriptor = try c.decodeIfPresent(CatalogRouteDTO.self, forKey: .route)
            ?? c.decodeIfPresent(CatalogRouteDTO.self, forKey: .descriptor)
        route = descriptor?.route
        supported = try descriptor?.supported ?? c.decodeIfPresent(Bool.self, forKey: .supported)
        available = try c.decodeIfPresent(Bool.self, forKey: .available)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible)
        order = try c.decodeIfPresent(Int.self, forKey: .order)
        conditions = try c.decodeIfPresent(CatalogConditionsDTO.self, forKey: .conditions)
        checked = try c.decodeIfPresent(Bool.self, forKey: .checkedState)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        providerMenu = c.contains(.providerState)
    }
}

public struct HostCatalogDTO: Decodable, Equatable, Sendable {
    public let revision: String
    public let entries: [CatalogEntryDTO]
    /// HERDR-11: core was told this revision is already here
    /// (`X-Omodachi-Catalog`) and sent no rows; the ones on hand stand.
    public var unchanged: Bool? = nil
}

public struct HerdrAgentDTO: Decodable, Equatable, Sendable {
    public let agentID: String?
    public let kind: String?
    public let status: CompanionOperationStatus?
    public let paneID: String?
    public let paneAvailable: Bool?
    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id", kind, status, paneID = "pane_id", paneAvailable = "pane_available"
    }
}

/// The agent probe's own idea of a session (`/v1/herdr`'s snapshot), which is
/// where an agent lives — not the session list the panel switches between.
/// That one is `HerdrSessionDTO` in `Herdr/HerdrWire.swift`.
public struct HerdrAgentSessionDTO: Decodable, Equatable, Sendable {
    public let name: String
    public let workspaceID: String?
    public let tabID: String?
    public let paneID: String?
    enum CodingKeys: String, CodingKey { case name, workspaceID = "workspace_id", tabID = "tab_id", paneID = "pane_id" }
}

public struct HostHerdrDTO: Decodable, Equatable, Sendable {
    public struct Snapshot: Decodable, Equatable, Sendable {
        public let serverInstalled: Bool?
        public let serverRunning: Bool?
        public let socketAvailable: Bool?
        public let supportedKinds: [String]?
        public let agents: [HerdrAgentDTO]?
        public let paneCount: Int?
        public let sessions: [HerdrAgentSessionDTO]?
        enum CodingKeys: String, CodingKey {
            case serverInstalled = "server_installed", serverRunning = "server_running"
            case socketAvailable = "socket_available", supportedKinds = "supported_kinds"
            case agents, paneCount = "pane_count", sessions
        }
    }
    public let available: Bool?
    public let agentCount: Int?
    public let snapshot: Snapshot?
    enum CodingKeys: String, CodingKey { case available, agentCount = "agent_count", snapshot }

    public var serverRunning: Bool? { snapshot?.serverRunning }
    public var agents: [HerdrAgentDTO] { snapshot?.agents ?? [] }
    public var sessions: [HerdrAgentSessionDTO] { snapshot?.sessions ?? [] }
}

public struct CompanionSnapshot: Equatable, Sendable {
    public let state: HostStateDTO
    public let capabilities: HostCapabilitiesDTO
    public let catalog: HostCatalogDTO
    public let herdr: HostHerdrDTO
}

public struct AgentTaskResponse: Decodable, Equatable, Sendable {
    public let requestID: String?
    public let status: CompanionOperationStatus
    public let agentID: String
    public let paneID: String?
    public var message: String? {
        switch status {
        case .accepted, .working: Strings.agentTaskAccepted
        case .blocked: ReasonText.message("agent_blocked", domain: .agent)
        case .done: Strings.agentTaskDone
        case .unavailable, .rejected: Strings.agentTaskRefused
        default: Strings.agentTaskOutcomeUnknown
        }
    }
    enum CodingKeys: String, CodingKey { case requestID = "request_id", status, agentID = "agent_id", paneID = "pane_id" }
}

public struct CompanionActionResponse: Decodable, Equatable, Sendable {
    public let entryID: String?
    public let code: String?
    /// SHORTCUT-1: what the host saw happen after a binding ran.
    public let observed: ShortcutObservation?
    public let workspaceEffects: WorkspaceLayoutEffects?
    public let requestID: String?
    public let status: CompanionOperationStatus
    public let targetToken: String?
    public let descriptor: CatalogRouteDTO?
    /// PERF-5: the catalog revision the host actually resolved this against.
    /// The client may have sent an older one - the revision is a hint now, not
    /// a gate - and adopts this so its next tap is not behind the same gap.
    public let catalogRevision: String?
    public var message: String? {
        switch status {
        case .accepted, .working: Strings.hostActionAccepted
        case .applied, .done: Strings.hostActionApplied
        case .prepared: Strings.hostActionPrepared
        case .blocked: Strings.hostActionBlocked
        default: Strings.hostActionOutcomeUnknown
        }
    }
    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", status, targetToken = "target_token", descriptor
        case route, entryID = "entry_id", code, observed, workspaceEffects = "workspace_effects"
        case catalogRevision = "catalog_revision"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        status = try c.decodeIfPresent(CompanionOperationStatus.self, forKey: .status) ?? .unknown
        targetToken = try c.decodeIfPresent(String.self, forKey: .targetToken)
        entryID = try c.decodeIfPresent(String.self, forKey: .entryID)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        observed = try c.decodeIfPresent(ShortcutObservation.self, forKey: .observed)
        workspaceEffects = try c.decodeIfPresent(WorkspaceLayoutEffects.self, forKey: .workspaceEffects)
        let resolved = try c.decodeIfPresent(String.self, forKey: .catalogRevision)
        catalogRevision = (resolved?.isEmpty == false && resolved!.utf8.count <= 128) ? resolved : nil
        descriptor = try c.decodeIfPresent(CatalogRouteDTO.self, forKey: .route)
            ?? c.decodeIfPresent(CatalogRouteDTO.self, forKey: .descriptor)
    }
}

/// `panel.summon` under a Remote session: the host end (SPEC-C's menu clone,
/// `SUPER+K`, or one of the two intercepted bar icons) asking the device that
/// owns the stream to present a panel, and saying which one
/// (`omodachi-core/src/omodachi_core/service.py`, `protocol.py` `PANEL_VIEWS`).
/// It is the only event this client acts on rather than treating as "the
/// snapshot is stale".
///
/// ARCH-1 / A-59: there are three views now. `overview` and `keybindings` are
/// the two halves of panel ①; `settings` is panel ⑥, which the Omodachi
/// plugin's own bar icon sends because that is the way to this app's
/// preferences from inside the picture. The toggle — the same view twice means
/// "put it away" — is `Shell/SurfaceRouter`'s, because core's push is
/// stateless and cannot know what is already open.
public struct PanelSummon: Equatable, Sendable {
    public enum View: String, Sendable { case overview, keybindings, settings }
    public let sessionID: String
    public let revision: Int
    public let view: View
}

/// One frame off `GET /v1/events`. The payload is deliberately narrow: pane
/// output, window titles, prompts and logs have no field to arrive in.
public struct SanitizedHostEvent: Equatable, Sendable {
    public let sequence: Int?
    public let eventID: String
    public let type: String
    public let instanceID: String?
    public let snapshot: HostStateDTO?
    public let needsResync: Bool
    public var panelSummon: PanelSummon? = nil
    /// `notification.posted`. The whole row arrives in the payload — the shell
    /// keeps ten of these and evicts the rest, so a client that only learned
    /// "something happened" would have to race the eviction to read it.
    /// NOTIFY-3: `notification.updated` carries the same row (now inactive,
    /// or `withdrawn`).
    public var notification: HostNotification? = nil
    /// `voice.transcript`: the same words the dictation stop response carries,
    /// published so the device that spoke them can still get them when its own
    /// response was lost.
    public var transcript: VoiceTranscriptEvent? = nil
    /// AUTH-1 `auth.approval.requested`. Addressed to this device only, and
    /// carrying the nonce it is being asked to sign. The whole payload arrives
    /// because there is nothing to re-read: the approval lives for its timeout
    /// and then it is gone.
    public var approvalRequest: HostApprovalRequest? = nil
    /// `auth.approval.resolved`: somebody answered, or nobody did. It is what
    /// takes the card away when the host has already moved on.
    public var approvalResolution: HostApprovalResolution? = nil
    /// REMOTE-4 `remote.session.changed`. The session's own client acts on the
    /// reason - `host_reconfigured` means the host rebuilt the output under a
    /// session it still holds - rather than only marking the snapshot stale.
    public var remoteSession: RemoteSessionChange? = nil
    /// NOTIFY-2 `agent.changed`: the status this event set, when it set one.
    /// A patch without a status changed something else.
    public var agentStatus: String? = nil
    /// NOTIFY-2 `herdr.layout.changed`: which session moved and which of its
    /// panes are blocked now — ids and the agent's own name, nothing else.
    public var herdrAttention: HerdrAttentionEvent? = nil
    /// NOTIFY-1 `agent.changed` (the pending approval's ids), `desk.changed`
    /// and `unseen.changed`.
    var notify: NotifyWire? = nil
    /// OVERVIEW-1 `overview.changed`: the whole list.
    var overview: OverviewReading? = nil
}

/// NOTIFY-2. What `herdr.layout.changed` says about a session's panes.
public struct HerdrAttentionEvent: Equatable, Sendable {
    public struct Pane: Equatable, Sendable {
        public let paneID: String
        public let name: String?
    }
    public let session: String
    public let blocked: [Pane]
    /// The session stopped; `blocked` is then empty.
    public var stopped = false
}
