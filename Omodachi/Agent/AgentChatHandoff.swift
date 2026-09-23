import Foundation

struct AgentChatHandoffPlan: Decodable, Equatable, Sendable {
    let planID: String
    let status: String
    let requiresConfirmation: Bool
    let agentID: String
    let provider: String
    let providerSessionID: String
    let paneID: String
    let impact: String
    let rollback: String
    enum CodingKeys: String, CodingKey {
        case planID = "plan_id", status, requiresConfirmation = "requires_confirmation"
        case agentID = "agent_id", provider, providerSessionID = "provider_session_id", paneID = "pane_id", impact, rollback
    }
}
struct AgentChatHandoffResult: Decodable, Sendable {
    let status: String
    let providerSessionID: String
    let paneID: String
    let sameThread: Bool
    let herdrPaneRegistered: Bool
    enum CodingKeys: String, CodingKey {
        case status, providerSessionID = "provider_session_id", paneID = "pane_id"
        case sameThread = "same_thread", herdrPaneRegistered = "herdr_pane_registered"
    }
}
enum AgentChatHandoffState: Equatable, Sendable {
    case none, required, preparing, prepared(AgentChatHandoffPlan), confirming(AgentChatHandoffPlan)
    case problem(String)
}
/// Shared HTTP client maps machine codes to this typed error. UI never parses
/// localized error text to decide whether it may migrate a running session.
struct AgentChatHostError: LocalizedError, Sendable {
    let code: String
    /// The host's chat codes this client knows how to act on. Anything else is
    /// reported as one unavailable state rather than echoed back to the user.
    static func safeCode(_ candidate: String?) -> String {
        let known: Set<String> = ["existing_thread_handoff_required", "agent_busy", "agent_pane_busy",
            "handoff_rolled_back", "handoff_plan_expired", "handoff_target_changed", "handoff_stop_unconfirmed",
            "handoff_attach_unconfirmed", "handoff_thread_unconfirmed", "agent_owner_start_failed",
            "agent_owner_start_timeout", "agent_owner_socket_unavailable", "thread_creation_unconfirmed",
            "provider_request_rejected", "structured_agent_kind_unsupported", "agent_state_unknown"]
        guard let candidate, known.contains(candidate) else { return "agent_chat_unavailable" }
        return candidate
    }
    var errorDescription: String? { ReasonText.message(code, domain: .agent) }
}
