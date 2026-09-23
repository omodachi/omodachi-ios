import Foundation

struct AgentChatSnapshotWire: Decodable {
    let identity: AgentChatIdentity
    let rows: [Row]
    let activeTurn: String?
    let sequence: Int
    /// The host's own request ids, as strings. They are whatever the client
    /// that sent the message chose — core only checks their shape — so a
    /// journal holding one this app did not write must not make the whole
    /// snapshot undecodable.
    let acceptedRequestIDs: [String]?
    let pendingApprovals: [AgentChatApprovalWire]?
    let status: AgentChatStatusWire?
    let usage: AgentChatUsageWire?
    struct Row: Decodable {
        let kind: String
        let id: String
        let turnID: String
        let role: AgentChatRole?
        let text: String?
        let name: String?
        let status: String?
        let detail: String?
        func value() throws -> AgentChatRow {
            if kind == "message", let role { return .message(.init(id: id, turnID: turnID, role: role, text: text ?? "")) }
            if kind == "tool" { return .tool(.init(id: id, turnID: turnID, name: name ?? "Tool", status: AgentChatToolStatus(rawValue: status ?? "") ?? .unknown, detail: detail ?? "")) }
            throw AgentChatFailure.identityChanged
        }
    }
    func value() throws -> AgentChatSnapshot {
        .init(identity: identity, rows: try rows.map { try $0.value() }, activeTurn: activeTurn,
              sequence: sequence, acceptedRequestIDs: acceptedRequestIDs ?? [],
              pendingApprovals: (pendingApprovals ?? []).map { $0.value() },
              status: status?.value() ?? .unknown, usage: usage?.value() ?? .empty)
    }
}
struct AgentChatEventWire: Decodable {
    let identity: AgentChatIdentity
    let sequence: Int
    let event: Event
    struct Event: Decodable {
        let type: String
        let turnID: String?
        let value: AgentChatSnapshotWire.Row?
        let interrupted: Bool?
        let message: String?
        // `agent.approval.*`
        let request_id: String?
        let kind: String?
        let summary: String?
        let details: [String: AgentChatJSON]?
        let decisions: [String]?
        let decision: String?
        let source: String?
        // `agent.status.changed` / `agent.usage.updated`
        let status: AgentChatStatusWire?
        let usage: AgentChatUsageWire?
    }
    func value() throws -> AgentChatEnvelope {
        let result: AgentChatEvent
        switch event.type {
        case "turnStarted": result = .turnStarted(event.turnID ?? "")
        case "message":
            guard let row = event.value, case .message(let message) = try row.value() else { throw AgentChatFailure.identityChanged }
            result = .message(message)
        case "tool":
            guard let row = event.value, case .tool(let tool) = try row.value() else { throw AgentChatFailure.identityChanged }
            result = .tool(tool)
        case "turnFinished": result = .turnFinished(turnID: event.turnID ?? "", interrupted: event.interrupted ?? false)
        case "turnFailed": result = .turnFailed(turnID: event.turnID ?? "", message: Strings.agentTurnFailed)
        case "agent.approval.requested":
            guard let requestID = event.request_id, let kind = event.kind else { throw AgentChatFailure.identityChanged }
            result = .approvalRequested(AgentChatApprovalWire(requestID: requestID, kind: kind, summary: event.summary,
                                                             details: event.details, decisions: event.decisions).value())
        case "agent.approval.resolved":
            guard let requestID = event.request_id else { throw AgentChatFailure.identityChanged }
            result = .approvalResolved(requestID: requestID, decision: event.decision,
                                       source: event.source ?? "elsewhere")
        case "agent.status.changed": result = .statusChanged(event.status?.value() ?? .unknown)
        case "agent.usage.updated": result = .usageUpdated(event.usage?.value() ?? .empty)
        case "connectionLost": result = .connectionLost
        // Receipts with no surface. They are events, so they hold a sequence;
        // dropping them would read as a gap and force a pointless re-snapshot.
        // A type this build does not know is not a broken conversation: it
        // changes nothing here and still advances the sequence, rather than
        // ending the one stream that is supposed to stay open for hours.
        default: result = .ignored(event.type)
        }
        return .init(identity: identity, sequence: sequence, event: result)
    }
}
