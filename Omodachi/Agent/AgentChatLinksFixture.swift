// lint:host-words — an agent's reply, standing in for the host's words.
import Foundation

/// LINKS-1, simulator UI runs only (`--ui-testing --links-fixture`): one
/// answer with every kind of link an agent writes, so a test can tap each one
/// in the real panel. Its words are the agent's, not the app's.
enum AgentChatLinksFixture {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--links-fixture")
        #else
        return false
        #endif
    }

    static let rows: [AgentChatRow] = [
        .message(.init(id: "links-ask", turnID: "links-turn", role: .user, text: "Show me the report.")),
        .tool(.init(id: "links-change", turnID: "links-turn", name: "File changes", status: .succeeded,
                    detail: "", paths: ["/home/user/l1test/report.md"])),
        .message(.init(id: "links-reply", turnID: "links-turn", role: .assistant, text: """
            ## Done

            Open [report.md](/home/user/l1test/report.md) or line `/home/user/l1test/report.md:12`.

            Docs: https://example.com/docs
            """)),
        // The reply LINKS-1 was tested with on the host, list and all.
        .message(.init(id: "links-list", turnID: "links-turn", role: .assistant, text: """
            ## Links

            - [notes.md](/home/user/l1test/notes.md)
            - the totals at `/home/user/l1test/report.md:12`
            - the chart ![Bar chart](/home/user/l1test/chart.png)
            - the preview http://localhost:8765/
            - the script ~/l1test/run.sh
            - the config ~/.ssh/config
            """)),
    ]
}
