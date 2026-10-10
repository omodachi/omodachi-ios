import Foundation

/// AGENT-QUEUE-1: one message waiting in codex's own queue for the running
/// turn to end (codex 0.160 `thread/queue/*`, kept on the host). `clipped`:
/// core carries the first 16000 characters only, so it cannot be edited here.
struct AgentQueuedMessage: Identifiable, Equatable, Sendable {
    let id: String
    var requestID: String
    var text: String
    var images = 0
    var clipped = false
}

/// What a waiting message's buttons ask of the host.
enum AgentQueueAction: String, Sendable { case send, edit, delete }

/// AGENT-QUEUE-1: codex's plan checklist (`turn/plan/updated`, the model's
/// `update_plan` tool - off unless codex's config turns it on).
struct AgentChecklist: Equatable, Sendable {
    enum Status: String, Sendable { case pending, inProgress, completed }
    struct Step: Equatable, Sendable {
        let step: String
        let status: Status
    }
    var turnID: String?
    var explanation: String?
    var steps: [Step]

    /// "2 of 3" and the step being done (else the next to do, else the last).
    var line: (done: Int, total: Int, current: String) {
        let done = steps.filter { $0.status == .completed }.count
        let current = steps.first { $0.status == .inProgress } ?? steps.first { $0.status == .pending } ?? steps.last
        return (done, steps.count, current?.step ?? "")
    }
}

/// AGENT-QUEUE-1: earlier rows (`GET …/chat/history`) and whether there are more.
struct AgentHistoryPage: Sendable {
    var rows: [AgentChatRow]
    var earlier: Bool
}

// MARK: - Wire

struct AgentQueuedWire: Decodable, Sendable {
    let id: String
    let request_id: String?
    let text: String
    let images: Int?
    let text_clipped: Bool?
    var value: AgentQueuedMessage? {
        guard !id.isEmpty, id.utf8.count <= 128 else { return nil }
        return AgentQueuedMessage(id: id, requestID: request_id ?? "", text: text,
                                  images: max(0, images ?? 0), clipped: text_clipped == true)
    }
    /// A list as core sends it: nil when this codex has no queue, and a
    /// shape this build does not read is no list either.
    static func list(_ wire: AgentLenient<[AgentLenient<AgentQueuedWire>]>?) -> [AgentQueuedMessage]? {
        guard let items = wire?.value else { return nil }
        return Array(items.compactMap { $0.value?.value }.prefix(20))
    }
}

struct AgentChecklistWire: Decodable, Sendable {
    struct Step: Decodable, Sendable {
        let step: String
        let status: String?
    }
    let turnID: String?
    let explanation: String?
    let steps: [AgentLenient<Step>]
    var value: AgentChecklist? {
        let read = steps.compactMap(\.value).filter { !$0.step.isEmpty }.prefix(32).map {
            AgentChecklist.Step(step: $0.step, status: AgentChecklist.Status(rawValue: $0.status ?? "") ?? .pending)
        }
        guard !read.isEmpty else { return nil }
        return AgentChecklist(turnID: turnID, explanation: explanation.flatMap { $0.isEmpty ? nil : $0 }, steps: Array(read))
    }
}

// MARK: - The model

extension AgentChatModel {
    /// While a turn runs, Send puts the words in codex's queue - when this
    /// codex has one. Otherwise the composer steers, as before.
    var queues: Bool { queue != nil && (phase == .running || phase == .cancelling) && turnID != nil }
    var canQueue: Bool {
        queues && identity != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The pinned checklist shows while the plan is active: its turn still
    /// running, or a step still open and no later turn since. A plan the model
    /// left behind (a later turn, or one it never finished) is history, and goes.
    var checklistShown: AgentChecklist? {
        guard let checklist, let turn = checklist.turnID else { return nil }
        if turn == turnID { return checklist }
        let open = checklist.steps.contains { $0.status != .completed }
        let latest: String? = switch rows.last {
        case .message(let message)?: message.turnID
        case .tool(let tool)?: tool.turnID
        case nil: nil
        }
        return open && turnID == nil && latest == turn ? checklist : nil
    }

}

/// AGENT-QUEUE-1 (Leo: "askuserquestion 的卡片 会循环"): where a question card
/// is - the choices, the words, the page - kept beside the conversation rather
/// than in the card's own view state. A card drawn again (codex re-sending the
/// same request after core re-attached, the panel re-presented, the list
/// re-laid out) carries on from here; before, it started again at question 1,
/// answers gone. `fingerprint` is the questions themselves: a new request that
/// happens to reuse an id starts clean.
struct AgentQuestionDraft: Equatable, Sendable {
    var fingerprint: String
    var chosen: [String: String] = [:]
    var others: Set<String> = []
    var typed: [String: String] = [:]
    var page = 0
}

extension AgentChatApproval {
    /// The questions as asked, for `AgentQuestionDraft.fingerprint`.
    var questionsFingerprint: String {
        questions.map { question in
            ([question.id, question.header ?? "", question.question] + question.choices.map(\.label)).joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
    }
}
