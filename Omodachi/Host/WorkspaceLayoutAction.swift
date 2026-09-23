import Foundation

public enum WorkspaceLayout: String, Codable, Sendable { case dwindle, scrolling
    var other: Self { self == .dwindle ? .scrolling : .dwindle }
    var label: String { self == .dwindle ? Strings.workspaceLayoutDwindle : Strings.workspaceLayoutScrolling }
}
/// Stable workspace scope observed in the same state snapshot. Unknown or
/// malformed presence must disable the action, not downgrade to legacy rules.
public struct WorkspaceLayoutBinding: Codable, Equatable, Sendable {
    public let workspaceID: Int
    public let layout: WorkspaceLayout
    public let revision: Int
    public let instanceID: String
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id", layout, revision, instanceID = "instance_id" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try c.decode(Int.self, forKey: .workspaceID)
        layout = try c.decode(WorkspaceLayout.self, forKey: .layout)
        revision = try c.decode(Int.self, forKey: .revision)
        instanceID = try c.decode(String.self, forKey: .instanceID)
        guard (1...10).contains(workspaceID), (1..<9_007_199_254_740_992).contains(revision),
              !instanceID.isEmpty, instanceID.utf8.count <= 128 else { throw WorkspaceLayoutRequestError(code: "invalid_workspace_binding") }
    }
}
public struct WorkspaceLayoutScopeProof: Codable, Equatable, Sendable {
    public let revision: Int
    public let instanceID: String
    enum CodingKeys: String, CodingKey { case revision, instanceID = "instance_id" }
}

public struct WorkspaceLayoutRequest: Encodable, Equatable, Sendable {
    public static let entryID = "trigger.toggle.workspace-layout"
    public let requestID: String
    public let catalogRevision: String
    public let stateRevision: Int
    public let params: Parameters
    public let workspaceBinding: WorkspaceLayoutScopeProof?
    public struct Parameters: Codable, Equatable, Sendable {
        public let workspaceID: Int
        public let fromLayout: WorkspaceLayout
        public let layout: WorkspaceLayout
        enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id", fromLayout = "from_layout", layout }
    }
    enum CodingKeys: String, CodingKey { case requestID = "request_id", catalogRevision = "catalog_revision", stateRevision = "state_revision", params, workspaceBinding = "workspace_binding" }
    init(workspaceID: Int, fromLayout: WorkspaceLayout, target: WorkspaceLayout, stateRevision: Int,
         catalogRevision: String, requestID: String = UUID().uuidString, binding: WorkspaceLayoutBinding? = nil) throws {
        guard (1...10).contains(workspaceID), fromLayout != target, stateRevision >= 0,
              !catalogRevision.isEmpty, catalogRevision.utf8.count <= 256,
              UUID(uuidString: requestID) != nil else { throw WorkspaceLayoutRequestError(code: "invalid_workspace_request") }
        if let binding, binding.workspaceID != workspaceID || binding.layout != fromLayout { throw WorkspaceLayoutRequestError(code: "invalid_workspace_binding") }
        workspaceBinding = binding.map { .init(revision: $0.revision, instanceID: $0.instanceID) }
        self.requestID = requestID; self.catalogRevision = catalogRevision; self.stateRevision = stateRevision
        params = .init(workspaceID: workspaceID, fromLayout: fromLayout, layout: target)
    }
}

struct WorkspaceLayoutOffer: Equatable, Identifiable, Sendable {
    let connection: UUID
    let workspaceID: Int
    let from: WorkspaceLayout
    let stateRevision: Int
    let catalogRevision: String
    let binding: WorkspaceLayoutBinding?
    var id: String { "\(connection):\(catalogRevision):\(stateRevision):\(workspaceID):\(from.rawValue)" }
    var label: String { Strings.workspaceLayoutOfferLabel(Format.count(workspaceID), from.label) }
    init?(connection: UUID, workspaceID: Int?, stateRevision: Int, catalogRevision: String?,
          visible: Bool, supported: Bool, ready: Bool, route: String?, checkedStatus: String?,
          checkedReason: String?, checkedValueIsNull: Bool, bindingFieldPresent: Bool = false, binding: WorkspaceLayoutBinding? = nil) {
        guard let workspaceID, (1...10).contains(workspaceID), stateRevision >= 0,
              let catalogRevision, !catalogRevision.isEmpty, catalogRevision.utf8.count <= 256,
              visible, supported, ready, route == "host", checkedStatus == "available", checkedValueIsNull else { return nil }
        let layout: WorkspaceLayout
        switch checkedReason {
        case "workspace_layout_dwindle": layout = .dwindle
        case "workspace_layout_scrolling": layout = .scrolling
        default: return nil
        }
        if bindingFieldPresent {
            guard let binding, binding.workspaceID == workspaceID, binding.layout == layout else { return nil }
        } else if binding != nil { return nil }
        self.binding = binding
        self.connection = connection; self.workspaceID = workspaceID; from = layout
        self.stateRevision = stateRevision; self.catalogRevision = catalogRevision
    }
    func selection() throws -> WorkspaceLayoutSelection {
        .init(connection: connection, request: try .init(workspaceID: workspaceID, fromLayout: from, target: from.other,
            stateRevision: stateRevision, catalogRevision: catalogRevision, binding: binding))
    }
}
struct WorkspaceLayoutSelection: Identifiable, Equatable, Sendable {
    let connection: UUID
    let request: WorkspaceLayoutRequest
    var id: String { request.requestID }
    var title: String { Strings.workspaceLayoutSwap(Format.count(request.params.workspaceID), request.params.fromLayout.label, request.params.layout.label) }
    func canRetrySameRequest(connection: UUID, serverInstanceID: String?) -> Bool {
        guard connection == self.connection, let proof = request.workspaceBinding else { return false }
        return serverInstanceID == proof.instanceID
    }
    func matchesCurrent(_ offer: WorkspaceLayoutOffer?) -> Bool {
        guard let offer, connection == offer.connection, request.params.workspaceID == offer.workspaceID,
              request.params.fromLayout == offer.from, request.catalogRevision == offer.catalogRevision else { return false }
        if let proof = request.workspaceBinding {
            guard let binding = offer.binding else { return false }
            return proof.revision == binding.revision && proof.instanceID == binding.instanceID
        }
        // A newer/unknown binding never downgrades to an old global snapshot.
        return offer.binding == nil && request.stateRevision == offer.stateRevision
    }
}
public struct WorkspaceLayoutEffects: Decodable, Equatable, Sendable {
    public let workspaceID: Int
    public let fromLayout: WorkspaceLayout
    public let layout: WorkspaceLayout
    public let runtimeApplied: Bool
    public let persistentApplied: Bool
    public let readbackConfirmed: Bool
    public let status: String
    public let code: String
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", fromLayout = "from_layout", layout, runtimeApplied = "runtime_applied"
        case persistentApplied = "persistent_applied", readbackConfirmed = "readback_confirmed", status, code
    }
}
public struct WorkspaceLayoutRequestError: Error, Sendable {
    public let code: String
    static let staleCodes: Set<String> = ["stale_workspace_revision", "stale_workspace", "workspace_layout_changed", "stale_catalog_revision", "stale_workspace_binding"]
    static let knownCodes = staleCodes.union(["invalid_workspace_request", "invalid_workspace_binding", "workspace_layout_outcome_unknown", "workspace_layout_unavailable", "workspace_preflight_unavailable", "invalid_route_parameters", "route_unavailable", "permission_denied", "request_id_conflict", "request_conflict"])
    static func safeCode(_ candidate: String?) -> String {
        guard let candidate, candidate.range(of: "^[a-z][a-z0-9_]{0,95}$", options: .regularExpression) != nil,
              knownCodes.contains(candidate) || candidate.hasPrefix("workspace_") || candidate == "invalid_route_parameters" else { return "workspace_layout_outcome_unknown" }
        return candidate
    }
    var message: String {
        if Self.staleCodes.contains(code) { return ReasonText.message("stale_plan", domain: .workspace) }
        if code == "workspace_layout_outcome_unknown" { return ReasonText.message("workspace_layout_outcome_unknown", domain: .workspace) }
        if code == "workspace_preflight_unavailable" { return ReasonText.message("workspace_preflight_unavailable", domain: .workspace) }
        if code == "workspace_layout_persistence_conflict_preserved" { return ReasonText.message("existing_file_conflict", domain: .workspace) }
        return ReasonText.message("workspace_layout_failed", domain: .workspace)
    }
}
enum WorkspaceLayoutResultPolicy {
    static func message(request: WorkspaceLayoutRequest, responseRequestID: String?, entryID: String?, status: String,
                        effects: WorkspaceLayoutEffects?) -> String {
        guard responseRequestID == request.requestID, entryID == WorkspaceLayoutRequest.entryID,
              let effects, effects.workspaceID == request.params.workspaceID,
              effects.fromLayout == request.params.fromLayout, effects.layout == request.params.layout else {
            return ReasonText.message("workspace_layout_outcome_unknown", domain: .workspace)
        }
        if status == "accepted", effects.status == "applied", effects.runtimeApplied, effects.persistentApplied, effects.readbackConfirmed {
            return Strings.workspaceLayoutConfirmed(Format.count(effects.workspaceID), effects.layout.label)
        }
        let runtime = effects.runtimeApplied ? Strings.workspaceRuntimeConfirmed : Strings.workspaceRuntimeUnconfirmed
        let persisted = effects.persistentApplied ? Strings.workspacePersistedConfirmed : Strings.workspacePersistedUnconfirmed
        let readback = effects.readbackConfirmed ? Strings.workspaceReadbackConfirmed : Strings.workspaceReadbackUnconfirmed
        var clauses = [runtime, persisted, readback]
        // The one extra fact a partial result can carry: the layout file was
        // changed elsewhere and the host kept it.
        if WorkspaceLayoutRequestError.safeCode(effects.code) == "workspace_layout_persistence_conflict_preserved" {
            clauses.append(ReasonText.message("existing_file_conflict", domain: .workspace))
        }
        return Strings.workspaceLayoutPartial(Format.count(effects.workspaceID), Format.list(clauses))
    }
}

public struct CatalogCheckedConditionDTO: Decodable, Equatable, Sendable {
    public let status: String?
    public let reason: String?
    public let value: Bool?
    public let valueIsNull: Bool
    enum CodingKeys: String, CodingKey { case status, reason, value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        value = try c.decodeIfPresent(Bool.self, forKey: .value)
        if c.contains(.value) { valueIsNull = try c.decodeNil(forKey: .value) }
        else { valueIsNull = false }
    }
}
public struct CatalogConditionsDTO: Decodable, Equatable, Sendable {
    /// MENU-3: `status` is `available`, `unavailable` or `unknown`. Unknown
    /// means the host ran the row's `when` and got no answer (a timeout, a
    /// shell that did not start): the row is drawn and tappable, and the host
    /// decides what the tap does.
    public let when: CatalogCheckedConditionDTO?
    public let checked: CatalogCheckedConditionDTO?
    /// MENU-3: present only for a row whose source carries a `disabled`
    /// expression. The host already folds a true one into the route's
    /// `ready: false` + `readiness_reason: condition_disabled`.
    public let disabled: CatalogCheckedConditionDTO?
}

