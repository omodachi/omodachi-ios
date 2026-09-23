import Foundation

/// Confirmed B contract: GET /v1/shortcuts. No host script/dispatcher text is
/// decoded as executable content; action_ref is the real catalog entry identity.
struct ShortcutListDTO: Decodable {
    struct Item: Decodable {
        let id: String
        let label: String
        let shortcutDisplay: String
        let order: Int
        let enabled: Bool
        let disabledReason: String?
        /// SHORTCUT-1. Core's own sentence about *this* row, e.g.
        /// `host record carries no executable binding: dispatcher="" arg=""`.
        /// It is the host's words and is shown as written.
        let disabledReasonDetail: String?
        let actionRef: String?
        let requiresTarget: Bool
        /// CLIP-1. The host says this row can never run from here, so leave it
        /// out. Optional because a host from before CLIP-1 does not send it,
        /// and a missing field is not a hidden row.
        let hidden: Bool?
        enum CodingKeys: String, CodingKey {
            case id, label, order, enabled, hidden
            case shortcutDisplay = "shortcut_display", disabledReason = "disabled_reason"
            case disabledReasonDetail = "disabled_reason_detail"
            case actionRef = "action_ref", requiresTarget = "requires_target"
        }
    }
    let revision: String
    let source: String
    let items: [Item]
    let available: Bool?
    let reason: String?

    func snapshot() throws -> ShortcutSnapshot {
        guard source == "hyprland", !revision.isEmpty,
              Set(items.map(\.id)).count == items.count else { throw ShortcutWireError.invalidSnapshot }
        return ShortcutSnapshot(revision: revision, source: source,
            entries: items.map { .init(id: $0.id, label: $0.label, keys: $0.shortcutDisplay,
                order: $0.order, actionRef: $0.actionRef, enabled: $0.enabled,
                disabledReason: $0.disabledReason,
                disabledReasonDetail: $0.disabledReasonDetail,
                requiresTarget: $0.requiresTarget, hidden: $0.hidden ?? false) },
            available: available ?? true, unavailableReason: reason)
    }
}

enum ShortcutWireError: Error { case invalidSnapshot, unavailableContext }

/// SHORTCUT-1's receipt: what the compositor looked like before and after the
/// binding ran, and whether anything moved.
///
/// It is the answer to the question a client cannot answer for itself — "did
/// pressing that do something" — and it is the row's transient state (ARCH-1
/// §7). Before it, the best the row could say was that a request had been sent.
public struct ShortcutObservation: Decodable, Equatable, Sendable {
    public struct Snapshot: Decodable, Equatable, Sendable {
        public struct Workspace: Decodable, Equatable, Sendable {
            public let id: Int
            public let name: String?
        }
        public struct Window: Decodable, Equatable, Sendable {
            public let appID: String?
            enum CodingKeys: String, CodingKey { case appID = "app_id" }
        }
        public let workspace: Workspace?
        public let window: Window?
    }
    public let kind: String?
    public let before: Snapshot?
    public let after: Snapshot?
    public let changed: Bool?

    /// One short line, in the host's own nouns. `nil` when there is nothing to
    /// say that the row does not already show.
    public var summary: String? {
        guard changed == true else { return nil }
        if let workspace = after?.workspace, workspace.id != before?.workspace?.id {
            return Strings.keybindingsNowOnWorkspace(workspace.name ?? String(workspace.id))
        }
        if let app = after?.window?.appID, app != before?.window?.appID {
            return Strings.keybindingsNowFocused(app)
        }
        return Strings.keybindingsChanged
    }
}

/// Encode body for existing POST /v1/actions/{action_ref}:invoke. The authenticated
/// shared client owns URL construction, connection and parsing its result envelope.
struct ShortcutInvokeBody: Encodable {
    /// Core accepts exactly `{surface}` for the Omarchy surface and exactly
    /// `{surface, session_id, revision}` for a Remote one, and answers
    /// `invalid_request` for any other key set (`shortcut_provider.py:98-112`).
    ///
    /// UX-1 item B: this used to send `connection_generation` and
    /// `geometry_epoch` for the Remote surface — a shape core has never
    /// accepted. Nothing hit it because the client never sets the Remote
    /// surface: under Remote the Keybindings list executes through the same
    /// Omarchy path the Panel does, which is what B asked for. It is corrected
    /// here so that staying on one path is a choice rather than the only shape
    /// that happens to work.
    struct Context: Encodable {
        let surface: String
        let sessionID: String?
        let revision: Int?
        enum CodingKeys: String, CodingKey {
            case surface, sessionID = "session_id", revision
        }
    }
    let requestID: String
    let catalogRevision: String
    let params: [String: String] = [:]
    let executionContext: Context
    let stateRevision: Int?
    let targetToken: String?
    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", catalogRevision = "catalog_revision", params
        case executionContext = "execution_context", stateRevision = "state_revision", targetToken = "target_token"
    }

    init(_ request: ShortcutExecutionRequest) throws {
        let context = request.context
        guard context.canExecute else { throw ShortcutWireError.unavailableContext }
        requestID = request.requestID.uuidString
        catalogRevision = request.revision
        executionContext = .init(surface: context.surface == .remote ? "remote" : "omarchy",
            sessionID: context.surface == .remote ? context.remoteSessionID : nil,
            revision: context.surface == .remote ? context.sessionRevision : nil)
        stateRevision = context.stateRevision
        targetToken = context.targetToken
    }
}
