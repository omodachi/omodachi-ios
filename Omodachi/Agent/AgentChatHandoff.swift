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
/// AGENT-NEW-1: the New conversation card. `problem` carries the sentence.
enum AgentNewConversationState: Equatable, Sendable {
    case none, confirming, starting, problem(String)
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
            "provider_request_rejected", "structured_agent_kind_unsupported", "agent_state_unknown",
            // ATTACH-1: a chip whose file is no longer on the computer
            "attachment_gone",
            // AGENT-NEW-1
            "agent_turn_active", "agent_approval_pending", "agent_identity_changed", "agent_conversation_changing",
            "new_conversation_confirmation_required", "agent_thread_creation_unconfirmed",
            // NOTIFY-1: a decision (from an alert) that found that request
            // answered already, or reading differently now. Nothing was sent.
            "agent_approval_unknown", "agent_approval_changed",
            // AGENT-PLAN-1
            "agent_mode_unavailable", "invalid_agent_mode", "agent_command_while_working",
            // AGENT-QUEUE-1: handled where they happen, never shown as such
            "agent_queue_unavailable", "agent_queue_item_gone", "agent_history_row_unknown"]
        guard let candidate, known.contains(candidate) else { return "agent_chat_unavailable" }
        return candidate
    }
    var errorDescription: String? { ReasonText.message(code, domain: .agent) }
}
