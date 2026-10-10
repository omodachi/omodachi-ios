// lint:host-words — agents' questions and the host's session names, standing in for the host's words.
import Foundation

/// OVERVIEW-1, simulator UI runs only (`--ui-testing --overview-fixture`, with
/// `--herdr-agents-fixture`): the demo's list, in the shape core sends
/// (`contracts/fixtures/state-overview1.json`): the Agent waiting on a
/// command, the demo session's three agent panes, and two of Leo's sessions
/// next to it — so the bar count, the session menu, the chips and the list
/// are all drawn from one reading.
enum OverviewFixture {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--overview-fixture")
        #else
        return false
        #endif
    }

    /// The demo has one session; these two are listed beside it.
    static let otherSessions = ["debug", "work"] // non-copy: session names

    static var reading: OverviewReading? {
        guard requested else { return nil }
        let rows: [OverviewRow] = [
            .init(source: .agent, state: .needsYou, ask: .approveCommand, agent: "codex"),
            .init(source: .herdr, state: .needsYou, ask: .pick, question: "Would you like to run the following command?",
                  agent: "codex", session: "omodachi", paneID: "w1:p1", workspaceID: "w1", workspace: "uptime",
                  pane: "uptime"),
            .init(source: .herdr, state: .working, ask: .working, agent: "claude", session: "omodachi",
                  paneID: "w1:p3", workspaceID: "w1", workspace: "uptime", pane: "uptime"),
            .init(source: .herdr, state: .done, ask: .yourMove, question: "要我顺便把 README 里的说明也更新吗？",
                  agent: "codex", session: "omodachi", paneID: "w1:p4", workspaceID: "w1", workspace: "uptime",
                  pane: "uptime"),
            .init(source: .herdr, state: .needsYou, ask: .yesNo, question: "Overwrite the config?", agent: "claude",
                  session: "debug", paneID: "w2:p1", workspaceID: "w2", workspace: "api", pane: "api"),
            .init(source: .herdr, state: .working, ask: .working, agent: "codex", session: "work", paneID: "w1:p2",
                  workspaceID: "w1", workspace: "site", pane: "site"),
        ]
        return OverviewReading(rows: rows, counts: .init(needsYou: 3, working: 2, done: 1),
                               sessions: ["omodachi": .init(needsYou: 1, working: 1, done: 1),
                                          "debug": .init(needsYou: 1), "work": .init(working: 1)])
    }

    /// Leo's two other sessions, running, beside the demo's own in the
    /// session menu (the demo never switches to them).
    static func apply(_ data: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sessions = root["sessions"] as? [String: Any],
              var list = sessions["sessions"] as? [[String: Any]], let first = list.first else { return nil }
        for name in otherSessions {
            var row = first
            row["name"] = name // non-copy: a wire key
            row["owned"] = false // non-copy: a wire key
            list.append(row)
        }
        sessions["sessions"] = list
        root["sessions"] = sessions
        return try? JSONSerialization.data(withJSONObject: root)
    }
}
