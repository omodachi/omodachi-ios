import Foundation

/// AGENT-COLLIE-1: a value read leniently - one of a shape this build does not
/// expect decodes as nil instead of failing the document around it.
struct AgentLenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
extension AgentLenient: Sendable where T: Sendable {}

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
    /// AGENT-QUEUE-1, read leniently: an older core says none of these.
    let earlier: AgentLenient<Bool>?
    let queue: AgentLenient<[AgentLenient<AgentQueuedWire>]>?
    let checklist: AgentLenient<AgentChecklistWire>?
    struct Row: Decodable {
        let kind: String
        let id: String
        let turnID: String
        let role: AgentChatRole?
        let text: String?
        let name: String?
        let status: String?
        let detail: String?
        /// ATTACH-1: pictures that rode with a user row (a count).
        let images: Int?
        /// LINKS-1: a tool row's files (`fileChange`, `imageView`).
        let paths: [String]?
        /// AGENT-FIX-2: characters of earlier output core no longer keeps.
        let detail_truncated: Int?
        /// AGENT-PLAN-1: an assistant message that is codex's proposed plan.
        let plan: AgentLenient<Bool>?
        /// AGENT-QUEUE-1: characters of a giant message core did not carry.
        let text_truncated: AgentLenient<Int>?
        /// AGENT-COLLIE-1. Read leniently: a field of a shape this build does
        /// not expect is dropped, never a reason to lose the row or the frame.
        let command: AgentLenient<String>?
        let actions: AgentLenient<[AgentLenient<AgentChatAction>]>?
        let exit_code: AgentLenient<Int>?
        let duration_ms: AgentLenient<Int>?
        let changes: AgentLenient<[AgentLenient<ChangeWire>]>?
        let changes_omitted: AgentLenient<Int>?
        struct ChangeWire: Decodable {
            let path: String
            let kind: AgentChatChange.Kind
            let move_path: String?
            let added: Int
            let removed: Int
            let diff: String
            let diff_omitted: Int?
            var value: AgentChatChange? {
                guard !path.isEmpty, path.utf8.count <= 4096 else { return nil }
                return AgentChatChange(path: path, kind: kind, movePath: move_path.flatMap { $0.isEmpty ? nil : $0 },
                                       added: max(0, added), removed: max(0, removed),
                                       diff: diff.isEmpty ? [] : diff.components(separatedBy: "\n"),
                                       diffOmitted: max(0, diff_omitted ?? 0))
            }
        }
        func value() throws -> AgentChatRow {
            if kind == "message", let role {
                return .message(.init(id: id, turnID: turnID, role: role, text: text ?? "",
                                      images: (images ?? 0) > 0 ? images : nil,
                                      plan: role == .assistant && plan?.value == true ? true : nil,
                                      textTruncated: text_truncated?.value.flatMap { $0 > 0 ? $0 : nil }))
            }
            if kind == "tool" {
                let files = paths?.filter { !$0.isEmpty && $0.utf8.count <= 4096 }.prefix(32)
                let changeRows = (changes?.value ?? []).compactMap { $0.value?.value }.prefix(16)
                let actionRows = (actions?.value ?? []).compactMap(\.value).prefix(4)
                return .tool(.init(id: id, turnID: turnID, name: name ?? "Tool",
                                   status: AgentChatToolStatus(rawValue: status ?? "") ?? .unknown,
                                   detail: detail ?? "", paths: files.map(Array.init).flatMap { $0.isEmpty ? nil : $0 },
                                   detailTruncated: detail_truncated.flatMap { $0 > 0 ? $0 : nil },
                                   command: command?.value.flatMap { $0.isEmpty ? nil : $0 },
                                   actions: actionRows.isEmpty ? nil : Array(actionRows),
                                   exitCode: exit_code?.value, durationMS: duration_ms?.value,
                                   changes: changeRows.isEmpty ? nil : Array(changeRows),
                                   changesOmitted: changes_omitted?.value.flatMap { $0 > 0 ? $0 : nil }))
            }
            throw AgentChatFailure.identityChanged
        }
    }
    func value() throws -> AgentChatSnapshot {
        .init(identity: identity, rows: try rows.map { try $0.value() }, activeTurn: activeTurn,
              sequence: sequence, acceptedRequestIDs: acceptedRequestIDs ?? [],
              pendingApprovals: (pendingApprovals ?? []).map { $0.value() },
              status: status?.value() ?? .unknown, usage: usage?.value() ?? .empty,
              earlier: earlier?.value == true, queue: AgentQueuedWire.list(queue), checklist: checklist?.value?.value)
    }
}
struct AgentChatEventWire: Decodable {
    let identity: AgentChatIdentity
    let sequence: Int
    let event: Event
    /// AGENT-FIX-2: `tool.output`'s value - an increment, not a row.
    struct Output: Decodable {
        let id: String
        let turnID: String
        let delta: String
        let detail_truncated: Int?
    }
    struct Event: Decodable {
        let type: String
        let turnID: String?
        let value: AgentChatSnapshotWire.Row?
        let output: Output?
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
        // AGENT-QUEUE-1: `agent.queue.changed` / `agent.checklist.updated`
        let queue: AgentLenient<[AgentLenient<AgentQueuedWire>]>?
        let checklist: AgentLenient<AgentChecklistWire>?

        private enum CodingKeys: String, CodingKey {
            case type, turnID, value, interrupted, message, request_id, kind, summary, details, decisions,
                 decision, source, status, usage, queue, checklist
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            turnID = try c.decodeIfPresent(String.self, forKey: .turnID)
            // `value` is a row for `message` / `tool` and an increment for
            // `tool.output`; any other type's value is not read at all, so a
            // shape this build does not know never breaks the stream.
            switch type {
            case "message", "tool":
                value = try c.decodeIfPresent(AgentChatSnapshotWire.Row.self, forKey: .value); output = nil
            case "tool.output":
                value = nil; output = try c.decodeIfPresent(Output.self, forKey: .value)
            default:
                value = nil; output = nil
            }
            interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted)
            message = try c.decodeIfPresent(String.self, forKey: .message)
            request_id = try c.decodeIfPresent(String.self, forKey: .request_id)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            details = try c.decodeIfPresent([String: AgentChatJSON].self, forKey: .details)
            decisions = try c.decodeIfPresent([String].self, forKey: .decisions)
            decision = try c.decodeIfPresent(String.self, forKey: .decision)
            source = try c.decodeIfPresent(String.self, forKey: .source)
            status = try c.decodeIfPresent(AgentChatStatusWire.self, forKey: .status)
            usage = try c.decodeIfPresent(AgentChatUsageWire.self, forKey: .usage)
            queue = type == "agent.queue.changed" ? try c.decodeIfPresent(AgentLenient<[AgentLenient<AgentQueuedWire>]>.self,
                                                                          forKey: .queue) : nil
            checklist = type == "agent.checklist.updated" ? try c.decodeIfPresent(AgentLenient<AgentChecklistWire>.self,
                                                                                  forKey: .checklist) : nil
        }
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
        case "tool.output":
            guard let output = event.output else { throw AgentChatFailure.identityChanged }
            result = .toolOutput(id: output.id, turnID: output.turnID, delta: output.delta,
                                 truncated: output.detail_truncated.flatMap { $0 > 0 ? $0 : nil })
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
        case "agent.queue.changed": result = .queueChanged(AgentQueuedWire.list(event.queue))
        case "agent.checklist.updated": result = .checklistUpdated(event.checklist?.value?.value)
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
