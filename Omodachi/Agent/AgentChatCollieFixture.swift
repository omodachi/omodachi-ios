// lint:host-words — an agent's words, commands and files, standing in for the host's.
import Foundation

/// AGENT-COLLIE-1, simulator UI runs only (`--ui-testing --agent-collie-fixture`):
/// a conversation shaped like the real codex 0.160 capture
/// (`omodachi-core/tests/fixtures/codex-0160-agent-collie1.json`). An edit that
/// already ran, six commands in a row (one fails), a second edit waiting for
/// approval with its change, and a question with descriptions, Other and a
/// secret answer. Sending a message adds a reply, so a test can see output
/// arrive while it reads further up.
actor AgentChatCollieFixtureTransport: AgentChatTransport {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--agent-collie-fixture")
        #else
        return false
        #endif
    }

    static let identity = AgentChatIdentity(hostID: "fixture", agentID: "default", // non-copy: ids
                                            provider: "codex", providerSessionID: "fixture-collie")
    private var sequence = 0
    private var rows: [AgentChatRow] = AgentChatCollieFixtureTransport.history
    /// No turn is running: the prompts wait on their own, and Send works.
    private var activeTurn: String?
    private var pending: [AgentChatApproval] = AgentChatCollieFixtureTransport.prompts
    private var continuation: AsyncThrowingStream<AgentChatEnvelope, Error>.Continuation?
    private var replies = 0

    private static func command(_ id: String, _ words: String, _ actions: [AgentChatAction], exit: Int = 0,
                                output: String) -> AgentChatRow {
        .tool(.init(id: id, turnID: "t2", name: "/bin/zsh -lc '\(words)'", status: exit == 0 ? .succeeded : .failed,
                    detail: output, command: words, actions: actions, exitCode: exit, durationMS: 12))
    }

    private static let filler: [AgentChatRow] = (1...6).flatMap { index -> [AgentChatRow] in
        [.message(.init(id: "f-ask-\(index)", turnID: "t0-\(index)", role: .user, text: "Note \(index): keep the logs short.")),
         .message(.init(id: "f-reply-\(index)", turnID: "t0-\(index)", role: .assistant,
                        text: "Understood. I will keep log lines under eighty characters in step \(index).\n\nNothing else changes."))]
    }

    static let history: [AgentChatRow] = filler + [
        .message(.init(id: "u1", turnID: "t1", role: .user, text: "Change the port and write a plan.")),
        .message(.init(id: "m1", turnID: "t1", role: .assistant, text: "Changing the port and writing a plan.")),
        .tool(.init(id: "p1", turnID: "t1", name: "File changes", status: .succeeded, detail: "[]",
                    paths: ["/home/user/ac1test/app.py", "/home/user/ac1test/notes/plan.md"],
                    changes: [
                        AgentChatChange(path: "/home/user/ac1test/app.py", kind: .update, added: 3, removed: 2,
                                        diff: ["@@ -4,4 +4,5 @@", " def main():", "-    port = 8080", "-    print(\"hello\")",
                                               "+    port = int(os.environ.get(\"PORT\", \"9090\"))",
                                               "+    print(\"hello on\", port)", "+    serve(port)", " "]),
                        AgentChatChange(path: "/home/user/ac1test/notes/plan.md", kind: .add, added: 5, removed: 0,
                                        diff: ["+# Plan", "+", "+1. Read the config.", "+2. Change the port.", "+3. Run the tests."]),
                    ])),
        .message(.init(id: "u2", turnID: "t2", role: .user, text: "Look around the project.")),
        command("s0", "git status", [.init(type: .unknown)], output: "On branch main\nnothing to commit\n"),
        command("s1", "cat app.py", [.init(type: .read, name: "app.py")], output: "import os\n"),
        command("s2", "ls -la", [.init(type: .listFiles)], output: "app.py\nnotes\n"),
        command("s3", "grep -rn TODO .", [.init(type: .search, path: ".", query: "TODO")],
                output: "./app.py:9:# TODO: read the port from the environment\n"),
        command("s4", "sed -n 1,3p app.py", [.init(type: .read, name: "app.py")], output: "import os\n"),
        command("s5", "false", [.init(type: .unknown)], exit: 1, output: ""),
        .message(.init(id: "m2", turnID: "t2", role: .assistant, text: "Looked around; one step failed.")),
        .message(.init(id: "u3", turnID: "t3", role: .user, text: "Raise the retries outside the project too.")),
        .tool(.init(id: "p2", turnID: "t3", name: "File changes", status: .running, detail: "[]",
                    paths: ["/home/user/ac1-outside/settings.txt"],
                    changes: [AgentChatChange(path: "/home/user/ac1-outside/settings.txt", kind: .update, added: 2, removed: 1,
                                              diff: ["@@ -1,2 +1,3 @@", "-mode = slow", "+mode = fast", "+retries = 3", " name = demo"])])),
    ]

    static let prompts: [AgentChatApproval] = [
        AgentChatApprovalWire(requestID: "0", kind: "fileChange", summary: "Apply file changes",
                              details: ["item_id": .string("p2"), "turn_id": .string("t3"),
                                        "files": .array([.string("/home/user/ac1-outside/settings.txt")]),
                                        "added": .number(2), "removed": .number(1)],
                              decisions: ["accept", "acceptForSession", "decline", "cancel"]).value(),
        AgentChatApprovalWire(requestID: "1", kind: "userInput", summary: "Branch",
                              details: ["item_id": .string("q1"), "questions": .array([
                                .object(["id": .string("branch"), "header": .string("Branch"),
                                         "question": .string("Which branch should I push to?"), "secret": .bool(false),
                                         "options": .array([.string("main (Recommended)"), .string("release")]),
                                         "choices": .array([
                                            .object(["label": .string("main (Recommended)"),
                                                     "description": .string("The default branch everyone pulls from.")]),
                                            .object(["label": .string("release"), "description": .string("Only for tagged builds.")])]),
                                         "other": .bool(true)]),
                                .object(["id": .string("token"), "header": .string("Token"),
                                         "question": .string("Paste the deploy token."), "secret": .bool(true),
                                         "options": .array([.string("Use the saved one")]),
                                         "choices": .array([.object(["label": .string("Use the saved one"),
                                                                     "description": .string("The token already in the keychain.")])]),
                                         "other": .bool(true)])])],
                              decisions: []).value(),
    ]

    private var snapshot: AgentChatSnapshot {
        AgentChatSnapshot(identity: Self.identity, rows: rows, activeTurn: activeTurn, sequence: sequence,
                          pendingApprovals: pending)
    }

    func ensureDefault() async throws -> AgentChatSnapshot { snapshot }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        guard identity == Self.identity else { throw AgentChatFailure.identityChanged }
        return snapshot
    }

    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        guard identity == Self.identity else { throw AgentChatFailure.identityChanged }
        continuation?.finish()
        let (stream, continuation) = AsyncThrowingStream<AgentChatEnvelope, Error>.makeStream()
        self.continuation = continuation
        continuation.yield(AgentChatEnvelope(identity: Self.identity, sequence: self.sequence, snapshot: snapshot))
        return stream
    }

    private func emit(_ event: AgentChatEvent) {
        sequence += 1
        switch event {
        case .message(let message): put(.message(message))
        case .tool(let tool): put(.tool(tool))
        case .turnStarted(let id): activeTurn = id
        case .turnFinished: activeTurn = nil
        case .approvalResolved(let id, _, _): pending.removeAll { $0.requestID == id }
        default: break
        }
        continuation?.yield(AgentChatEnvelope(identity: Self.identity, sequence: sequence, event: event))
    }

    private func put(_ row: AgentChatRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row } else { rows.append(row) }
    }

    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws {
        guard identity == Self.identity else { throw AgentChatHostError(code: "agent_busy") }
        replies += 1
        let turn = "t-reply-\(replies)"
        if let activeTurn { emit(.turnFinished(turnID: activeTurn, interrupted: false)) }
        emit(.turnStarted(turn))
        emit(.message(.init(id: "you-\(replies)", turnID: turn, role: .user, text: text)))
        emit(.message(.init(id: "reply-\(replies)", turnID: turn, role: .assistant, text: "Noted: \(text)")))
        emit(.turnFinished(turnID: turn, interrupted: false))
    }

    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        guard let approval = pending.first(where: { $0.requestID == requestID }) else {
            throw AgentChatHostError(code: "agent_approval_unknown")
        }
        let applied = approval.kind == "userInput" ? "input" : (decision ?? "accept")
        emit(.approvalResolved(requestID: requestID, decision: applied, source: "client"))
        return AgentChatApprovalResolution(requestID: requestID, kind: approval.kind, decision: applied, resolved: true)
    }

    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws {}
}
