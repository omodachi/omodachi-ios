import Foundation
import OSLog

/// What "发送也很慢" actually measures.
///
/// Leo reported the Agent panel as slow to send, and "slow" has at least four
/// different fixes depending on which leg it is: the app not showing the words
/// until the network answered, core doing an `ensure` or a thread lookup per
/// message, the codex app-server round trip, or the model's own first token.
/// These five lines split it, in wall clock, so the answer is measured rather
/// than guessed.
///
/// It is not a control path. Every value here already exists; nothing is
/// delayed, retried or changed because of a line being written.
enum AgentChatTrace {
    private static let log = Logger(subsystem: "app.omodachi", category: "agent.chat")

    private static func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    /// One leg of a send. `request` ties them together; `bytes` is the length
    /// of the message, never the message.
    static func send(_ leg: String, request: String, bytes: Int = -1, detail: String = "") {
        log.notice("agent.send leg=\(leg, privacy: .public) request=\(request, privacy: .public) bytes=\(bytes) detail=\(detail, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// An event coming down the stream, by kind. `turn` lets the first token of
    /// *this* turn be told from a late event of the previous one.
    static func event(_ kind: String, turn: String, sequence: Int, chars: Int = -1) {
        log.notice("agent.event kind=\(kind, privacy: .public) turn=\(turn, privacy: .public) sequence=\(sequence) chars=\(chars) epoch=\(stamp(), privacy: .public)")
    }
}

extension AgentChatTrace {
    /// One line per applied event. The assistant message's *length* is the
    /// thing that says whether tokens are arriving as they are produced or in
    /// one block at the end; its text never appears.
    static func trace(_ event: AgentChatEvent, sequence: Int) {
        switch event {
        case .turnStarted(let id): self.event("turn-started", turn: id, sequence: sequence)
        case .message(let message):
            self.event("message-\(message.role.rawValue)", turn: message.turnID,
                       sequence: sequence, chars: message.text.count)
        case .tool(let tool): self.event("tool-\(tool.status.rawValue)", turn: tool.turnID, sequence: sequence)
        case .turnFinished(let id, _): self.event("turn-finished", turn: id, sequence: sequence)
        case .turnFailed(let id, _): self.event("turn-failed", turn: id, sequence: sequence)
        case .approvalRequested, .approvalResolved, .statusChanged, .usageUpdated,
             .connectionLost, .ignored:
            break
        }
    }
}
