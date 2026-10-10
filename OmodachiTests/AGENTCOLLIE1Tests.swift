import XCTest
@testable import Omodachi

/// AGENT-COLLIE-1 on what core makes of real codex 0.160 frames
/// (`CoreFixtures/agent-chat-snapshot-changes.json`, `-steps.json`,
/// `agent-chat-event-question.json`, from core's replay of a private
/// app-server capture): change cards, steps and runs, question cards, find.
@MainActor final class AGENTCOLLIE1Tests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }
    private func snapshot(_ name: String) throws -> AgentChatSnapshot {
        try JSONDecoder().decode(AgentChatSnapshotWire.self, from: fixture(name)).value()
    }
    private func tools(_ snapshot: AgentChatSnapshot) -> [AgentChatTool] {
        snapshot.rows.compactMap { if case .tool(let tool) = $0 { tool } else { nil } }
    }
    private func model(_ snapshot: AgentChatSnapshot) -> AgentChatModel {
        var model = AgentChatModel()
        XCTAssertTrue(model.restore(snapshot))
        return model
    }

    // MARK: Idea 1

    func testRealFileChangesDecodeIntoChangeCards() throws {
        let snapshot = try snapshot("agent-chat-snapshot-changes")
        let rows = tools(snapshot)
        XCTAssertEqual(rows.count, 2)
        let inside = try XCTUnwrap(rows[0].changes)
        XCTAssertEqual(inside.map(\.name).sorted(), ["app.py", "notes.txt", "old.txt", "plan.md"])
        let update = try XCTUnwrap(inside.first { $0.name == "app.py" })
        XCTAssertEqual(update.kind, .update)
        XCTAssertEqual(update.verb, Strings.agentStepEdited)
        XCTAssertEqual([update.added, update.removed], [3, 2])
        XCTAssertEqual(update.lines.first, .hunk)
        XCTAssertEqual(update.lines.filter { if case .added = $0 { true } else { false } }.count, 3)
        let added = try XCTUnwrap(inside.first { $0.name == "plan.md" })
        XCTAssertEqual(added.verb, Strings.agentStepCreated)
        XCTAssertEqual(added.lines.first, .added("# Plan"))
        let deleted = try XCTUnwrap(inside.first { $0.name == "old.txt" })
        XCTAssertEqual(deleted.verb, Strings.agentStepDeleted)
        XCTAssertEqual(deleted.lines, [.removed("remove me"), .removed("second line")])
        let moved = try XCTUnwrap(inside.first { $0.name == "notes.txt" })
        XCTAssertEqual(moved.verb, Strings.agentStepMoved)
        // Same name, other folder: the folder says where it went.
        XCTAssertEqual(moved.subject, "notes.txt → docs/notes.txt")
        XCTAssertEqual(rows[0].stepKind, .edit)
        XCTAssertEqual(rows[0].editCount, 4)
    }

    func testAWaitingFileChangeNamesTheRowItAllows() throws {
        let snapshot = try snapshot("agent-chat-snapshot-changes")
        let model = model(snapshot)
        let waiting = try XCTUnwrap(model.waitingApprovals.first)
        XCTAssertEqual(waiting.kind, "fileChange")
        XCTAssertEqual(waiting.itemID, "call-p2-2")
        XCTAssertEqual(waiting.changeFiles.map(AgentChatChange.name), ["settings.txt"])
        XCTAssertEqual([waiting.changeAdded, waiting.changeRemoved], [2, 1])
        // files / added / removed are the change summary, not detail lines.
        XCTAssertFalse(waiting.details.contains { ["files", "added", "removed"].contains($0.key) })
        let row = try XCTUnwrap(tools(snapshot).first { $0.id == waiting.itemID })
        XCTAssertEqual(row.status, .running)
        XCTAssertEqual(row.changes?.first?.lines, [.hunk, .removed("mode = slow"), .added("mode = fast"),
                                                    .added("retries = 3"), .context("name = demo")])
    }

    func testANewFieldOfAnUnexpectedShapeNeverLosesTheRow() throws {
        let json = """
        {"identity":{"hostID":"h","agentID":"default","provider":"codex","providerSessionID":"s"},
         "rows":[{"kind":"tool","id":"x","turnID":"t","name":"File changes","status":"succeeded","detail":"",
                  "changes":"not a list","actions":[{"type":"teleport"},{"type":"read","name":"a.py"}],
                  "exit_code":"zero","command":7},
                 {"kind":"tool","id":"y","turnID":"t","name":"File changes","status":"succeeded","detail":"",
                  "changes":[{"path":"/w/a","kind":"update","added":1,"removed":0,"diff":"+a"},{"path":"/w/b","kind":"rename"}]}],
         "activeTurn":null,"sequence":3,"acceptedRequestIDs":[],"pendingApprovals":[],
         "status":{"type":"idle","activeFlags":[],"waiting":null},
         "usage":{"tokens":null,"rate_limits":null,"model":null,"effort":null}}
        """
        let snapshot = try JSONDecoder().decode(AgentChatSnapshotWire.self, from: Data(json.utf8)).value()
        let rows = tools(snapshot)
        XCTAssertEqual(rows.map(\.id), ["x", "y"])
        XCTAssertNil(rows[0].changes)
        XCTAssertNil(rows[0].exitCode)
        XCTAssertNil(rows[0].command)
        XCTAssertEqual(rows[0].actions, [AgentChatAction(type: .read, name: "a.py")])
        XCTAssertEqual(rows[1].changes?.map(\.name), ["a"])
    }

    // MARK: Idea 2

    func testRealCommandsReadAsSteps() throws {
        let rows = tools(try snapshot("agent-chat-snapshot-steps"))
        XCTAssertEqual(rows.map(\.stepLine.text), [
            "$ git status", "\(Strings.agentStepRead) app.py", "$ ls -la",
            "\(Strings.agentStepSearched) TODO", "\(Strings.agentStepRead) app.py", "$ false"])
        XCTAssertEqual(rows.map(\.stepKind), [.command, .read, .search, .search, .read, .command])
        XCTAssertEqual(rows.last?.exitCode, 1)
        XCTAssertEqual(rows.last?.status, .failed)
    }

    func testRunsFoldThreeOrMoreStepsAndCountThem() throws {
        let model = model(try snapshot("agent-chat-snapshot-steps"))
        let items = AgentRun.group(model.timeline)
        let runs = items.compactMap { if case .run(let run) = $0 { run } else { nil } }
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(run.tools.count, 6)
        XCTAssertEqual(run.failed, 1)
        XCTAssertEqual(run.counts, AgentRunCounts(commands: 2, reads: 2, searches: 2, edits: 0, others: 0))
        XCTAssertEqual(run.counts.summary, Strings.pair(Strings.pair(Strings.agentRunCommands("2"), Strings.agentRunReads("2")),
                                                        Strings.agentRunSearches("2")))
        // The user's words and the reply stay outside the run.
        XCTAssertEqual(items.count, 3)
        // A finished run tails from its newest six steps.
        XCTAssertEqual(run.tailStart(waiting: []), 0)
    }

    func testTwoStepsStayRowsAndAnswersRideInsideTheirRun() {
        func tool(_ id: String, _ status: AgentChatToolStatus = .succeeded) -> AgentTimelineEntry {
            .row(.tool(.init(id: id, turnID: "t", name: id, status: status, detail: "")))
        }
        let message = AgentTimelineEntry.row(.message(.init(id: "m", turnID: "t", role: .assistant, text: "ok")))
        var answered = AgentChatApprovalWire(requestID: "9", kind: "commandExecution", summary: "b", details: nil,
                                             decisions: ["accept"]).value()
        answered.state = .resolved(decision: "accept", source: "client")
        let two = AgentRun.group([tool("a"), tool("b"), message])
        XCTAssertEqual(two.map(\.id), ["tool:a", "tool:b", "message:m"])
        let three = AgentRun.group([tool("a"), tool("b"), .answered(answered), tool("c", .running), message])
        guard case .run(let run) = three.first else { return XCTFail("no run") }
        XCTAssertEqual(run.entries.count, 4)
        XCTAssertTrue(run.running)
        XCTAssertEqual(three.last?.id, "message:m")
        // A live run shows its newest six steps, or from a step that waits.
        let many = (0..<10).map { tool("s\($0)") }
        guard case .run(let long) = AgentRun.group(many).first else { return XCTFail("no run") }
        XCTAssertEqual(long.tailStart(waiting: []), 4)
        XCTAssertEqual(long.steps(before: 4), 4)
        XCTAssertEqual(long.tailStart(waiting: ["s1"]), 1)
    }

    // MARK: Idea 3

    func testRealQuestionCarriesChoicesOtherAndSecret() throws {
        let envelope = try JSONDecoder().decode(AgentChatEventWire.self, from: fixture("agent-chat-event-question")).value()
        guard case .approvalRequested(let approval) = envelope.event else { return XCTFail("not a question") }
        XCTAssertEqual(approval.questions.map(\.id), ["branch", "token"])
        let branch = approval.questions[0], token = approval.questions[1]
        XCTAssertEqual(branch.choices, [AgentChatChoice(label: "main (Recommended)", description: "The default branch everyone pulls from."),
                                        AgentChatChoice(label: "release", description: "Only for tagged builds.")])
        XCTAssertTrue(branch.other)
        XCTAssertFalse(branch.secret)
        XCTAssertTrue(token.secret)
        XCTAssertTrue(token.other)
    }

    func testTheAnsweredLineSaysWhatWasChosenButNeverASecret() throws {
        let envelope = try JSONDecoder().decode(AgentChatEventWire.self, from: fixture("agent-chat-event-question")).value()
        guard case .approvalRequested(let approval) = envelope.event else { return XCTFail("not a question") }
        var model = model(try snapshot("agent-chat-snapshot-steps"))
        model.receive(approval)
        XCTAssertTrue(model.beginAnswer(requestID: approval.requestID, input: ["branch": ["release"], "token": ["s3cret"]]))
        XCTAssertEqual(model.approvals.last?.answered, ["release"])
        XCTAssertFalse(model.beginAnswer(requestID: approval.requestID, input: ["branch": ["main"]]), "already in flight")
        model.settleDecision(requestID: approval.requestID, decision: "input", source: "client")
        XCTAssertEqual(model.approvals.last?.answered, ["release"])
        XCTAssertFalse((model.approvals.last?.answered ?? []).contains("s3cret"))
        // Only secret answers: nothing is kept.
        var other = AgentChatModel()
        XCTAssertTrue(other.restore(try snapshot("agent-chat-snapshot-steps")))
        other.receive(approval)
        XCTAssertTrue(other.beginAnswer(requestID: approval.requestID, input: ["token": ["s3cret"]]))
        XCTAssertNil(other.approvals.last?.answered)
        // A failed answer forgets what it said; answered on the host says nothing.
        var failed = AgentChatModel()
        XCTAssertTrue(failed.restore(try snapshot("agent-chat-snapshot-steps")))
        failed.receive(approval)
        XCTAssertTrue(failed.beginAnswer(requestID: approval.requestID, input: ["branch": ["main"]]))
        failed.failDecision(requestID: approval.requestID)
        XCTAssertNil(failed.approvals.last?.answered)
        XCTAssertTrue(failed.beginAnswer(requestID: approval.requestID, input: ["branch": ["main"]]))
        failed.settleDecision(requestID: approval.requestID, decision: nil, source: "elsewhere")
        XCTAssertNil(failed.approvals.last?.answered)
        XCTAssertEqual(AgentChatApproval.label(decision: "input"), Strings.approvalAnswered)
    }

    // MARK: Idea 4

    func testFindSearchesWhatIsOnScreenAndWraps() throws {
        let model = model(try snapshot("agent-chat-snapshot-steps"))
        let timeline = model.timeline
        let order = timeline.map(\.id)
        let todo = AgentFind.matches(timeline, query: "todo")
        XCTAssertEqual(todo, ["tool:call-s3-7"], "the step line, not the output")
        let app = AgentFind.matches(timeline, query: "APP.PY")
        XCTAssertEqual(app, ["tool:call-s1-5", "tool:call-s4-8"])
        XCTAssertEqual(AgentFind.step(app, in: order, from: nil, forward: true), "tool:call-s1-5")
        XCTAssertEqual(AgentFind.step(app, in: order, from: "tool:call-s1-5", forward: true), "tool:call-s4-8")
        XCTAssertEqual(AgentFind.step(app, in: order, from: "tool:call-s4-8", forward: true), "tool:call-s1-5", "wraps")
        XCTAssertEqual(AgentFind.step(app, in: order, from: "tool:call-s1-5", forward: false), "tool:call-s4-8", "wraps back")
        XCTAssertEqual(AgentFind.matches(timeline, query: "  "), [])
        XCTAssertEqual(AgentFind.matches(timeline, query: "("), [], "a stray bracket is text, not a pattern")
        XCTAssertNil(AgentFind.step([], in: order, from: nil, forward: true))
        // Change cards are found by their files.
        let changes = self.model(try snapshot("agent-chat-snapshot-changes"))
        XCTAssertEqual(AgentFind.matches(changes.timeline, query: "plan.md"), ["tool:call-p1-1"])
    }
}
