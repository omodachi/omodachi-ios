import Foundation
import XCTest
@testable import Omodachi

/// OVERVIEW-1: one list of what wants Leo, across the Agent and every Herdr
/// pane — the App's half. The wire (state and event), the reading's answers
/// (groups, counts, chips, a pane's row), the words each row says, the store
/// following core's list through its transitions, and an older core's
/// smaller list.
@MainActor final class OVERVIEW1Tests: XCTestCase {
    /// The shape of core's `contracts/fixtures/state-overview1.json`.
    private let overviewJSON = #"""
    {"rows": [
      {"id": "agent", "source": "agent", "state": "needs_you", "ask": "approve_command", "question": null,
       "agent": "codex", "session": null, "pane_id": null, "workspace_id": null, "workspace": null, "pane": null},
      {"id": "herdr:omodachi:w1:p3", "source": "herdr", "state": "done", "ask": "your_move",
       "question": "Should I also archive the old ones?", "agent": "codex", "session": "omodachi", "pane_id": "w1:p3",
       "workspace_id": "w1", "workspace": "~", "pane": "notes"},
      {"id": "herdr:work:w1:p1", "source": "herdr", "state": "needs_you", "ask": "pick",
       "question": "Would you like to run the following command?", "agent": "codex", "session": "work",
       "pane_id": "w1:p1", "workspace_id": "w1", "workspace": "api", "pane": "api"},
      {"id": "herdr:work:w1:p2", "source": "herdr", "state": "working", "ask": "working", "question": null,
       "agent": "claude", "session": "work", "pane_id": "w1:p2", "workspace_id": "w1", "workspace": "api", "pane": "claude"},
      {"id": "herdr:work:w2:p1", "source": "herdr", "state": "needs_you", "ask": "waiting", "question": null,
       "agent": "codex", "session": "work", "pane_id": "w2:p1", "workspace_id": "w2", "workspace": "2", "pane": "site"}],
     "counts": {"needs_you": 3, "working": 1, "done": 1},
     "sessions": [{"name": "omodachi", "needs_you": 0, "working": 0, "done": 1},
                  {"name": "work", "needs_you": 2, "working": 1, "done": 0}]}
    """#

    private func state(_ revision: Int, _ body: String) throws -> HostStateDTO {
        try JSONDecoder().decode(HostStateDTO.self, from: Data(#"{"revision": \#(revision), \#(body)}"#.utf8))
    }

    private func event(_ type: String, _ payload: String, seq: Int = 3) throws -> SanitizedHostEvent {
        try CompanionHostClient.decodeEvent(Data(#"{"event":{"seq":\#(seq),"event_id":"e\#(seq)","type":"\#(type)","device_id":null,"payload":\#(payload),"ts":1},"instance_id":"o1","after_cursor":2}"#.utf8))
    }

    private func home() -> HomeStore {
        let suite = "overview1-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let home = HomeStore(defaults: defaults, credentials: FixtureCredential(), autoConnect: false)
        home.profile.mock = false
        home.profile.companionURL = "https://omarchy.example:8099"
        return home
    }

    // MARK: - The wire

    func testTheStateCarriesTheListAndAnOlderCoreDoesNot() throws {
        let reading = try XCTUnwrap(try state(4, #""overview": \#(overviewJSON)"#).overview)
        XCTAssertEqual(reading.rows.map(\.id), ["agent", "herdr:omodachi:w1:p3", "herdr:work:w1:p1",
                                                 "herdr:work:w1:p2", "herdr:work:w2:p1"])
        XCTAssertEqual(reading.rows.map(\.ask), [.approveCommand, .yourMove, .pick, .working, .waiting])
        XCTAssertEqual(reading.counts, OverviewCounts(needsYou: 3, working: 1, done: 1))
        XCTAssertEqual(reading.sessions["work"], OverviewCounts(needsYou: 2, working: 1))
        XCTAssertFalse(reading.fallback)
        let agent = reading.rows[0]
        XCTAssertEqual(agent.source, .agent)
        XCTAssertNil(agent.session)
        XCTAssertEqual(agent.agent, "codex")
        XCTAssertNil(try state(5, #""agent": {"status": "working"}"#).overview, "a core from before OVERVIEW-1")
    }

    func testRowsAreReadLenientlyAndOnlyWhatIsValidIsKept() throws {
        let json = #"""
        "overview": {"rows": [
          {"source": "herdr", "state": "needs_you", "ask": "something_new", "session": "work", "pane_id": "w1:p1"},
          {"source": "herdr", "state": "working", "ask": "working", "session": "--bad", "pane_id": "w1:p1"},
          {"source": "herdr", "state": "sleeping", "ask": "working", "session": "work", "pane_id": "w1:p2"},
          {"source": "herdr", "state": "done", "ask": "finished", "session": "work", "pane_id": "w1:p3",
           "question": "line one\nline two \#(String(repeating: "x", count: 200))", "agent": "co\u0007dex"}],
         "counts": {"needs_you": -2}, "sessions": [{"name": "../x", "needs_you": 1}, {"name": "work", "done": 1}]}
        """#
        let reading = try XCTUnwrap(try state(1, json).overview)
        XCTAssertEqual(reading.rows.count, 2, "a bad session and an unknown state are left out")
        XCTAssertEqual(reading.rows[0].ask, .waiting, "an ask this build does not know is said by its state")
        let done = reading.rows[1]
        XCTAssertLessThanOrEqual(done.question?.count ?? 0, 120)
        XCTAssertFalse(done.question?.contains("\n") ?? true)
        XCTAssertEqual(done.agent, "co dex")
        XCTAssertEqual(reading.counts.needsYou, 0)
        XCTAssertEqual(Array(reading.sessions.keys), ["work"])
    }

    func testTheEventCarriesTheWholeList() throws {
        let changed = try event("overview.changed", #"{"overview": \#(overviewJSON), "revision": 9}"#)
        XCTAssertEqual(changed.overview?.rows.count, 5)
        XCTAssertNil(try event("agent.changed", #"{"agent": {"status": "working"}, "revision": 10}"#).overview)
    }

    // MARK: - What the reading answers

    func testGroupsKeepCoresOrderAndTheCountsAnswerTheBarTheMenuAndTheChips() throws {
        let reading = try XCTUnwrap(try state(4, #""overview": \#(overviewJSON)"#).overview)
        XCTAssertEqual(reading.rows(.needsYou).map(\.id), ["agent", "herdr:work:w1:p1", "herdr:work:w2:p1"],
                       "position order, never re-sorted")
        XCTAssertEqual(reading.rows(.working).map(\.id), ["herdr:work:w1:p2"])
        XCTAssertEqual(reading.rows(.done).map(\.id), ["herdr:omodachi:w1:p3"])
        XCTAssertEqual(reading.herdrNeedsYou, 2, "the bar's Herdr count: panes, never the Agent")
        XCTAssertEqual(reading.counts(session: "work"), OverviewCounts(needsYou: 2, working: 1))
        XCTAssertEqual(reading.counts(session: "gone"), OverviewCounts())
        XCTAssertEqual(reading.worst(session: "work", workspace: "w1"), .needsYou)
        XCTAssertEqual(reading.worst(session: "work", workspace: "w2"), .needsYou)
        XCTAssertEqual(reading.worst(session: "omodachi", workspace: "w1"), .done, "done outranks working")
        XCTAssertNil(reading.worst(session: "omodachi", workspace: "w9"))
        XCTAssertEqual(reading.row(session: "omodachi", pane: "w1:p3")?.state, .done)
        XCTAssertNil(reading.row(session: "work", pane: "w1:p3"), "a pane id repeats across sessions")
        XCTAssertEqual(OverviewReading.empty.herdrNeedsYou, 0)
    }

    func testEachRowSaysItsAskInAFewWordsAndWhereItIs() throws {
        let reading = try XCTUnwrap(try state(4, #""overview": \#(overviewJSON)"#).overview)
        XCTAssertEqual(OverviewWords.ask(reading.rows[0]), Strings.overviewAskApproveCommand)
        XCTAssertEqual(OverviewWords.place(reading.rows[0]), "codex · " + Strings.panelAgent)
        XCTAssertEqual(OverviewWords.ask(reading.rows[1]), Strings.overviewAskYourMove("Should I also archive the old ones?"))
        XCTAssertEqual(OverviewWords.ask(reading.rows[2]),
                       Strings.overviewAskPickQuestion("Would you like to run the following command?"))
        XCTAssertEqual(OverviewWords.place(reading.rows[2]), "codex · work · api", "a pane named like its workspace once")
        XCTAssertEqual(OverviewWords.place(reading.rows[3]), "claude · work · api", "nor like its agent")
        XCTAssertEqual(OverviewWords.ask(reading.rows[4]), Strings.herdrWaiting)
        func ask(_ ask: OverviewRow.Ask, _ question: String? = nil) -> String {
            OverviewWords.ask(.init(source: .herdr, state: .needsYou, ask: ask, question: question,
                                    session: "s", paneID: "w1:p1"))
        }
        XCTAssertEqual(ask(.pick), Strings.overviewAskPick, "no question read: no words invented")
        XCTAssertEqual(ask(.yesNo, "Overwrite?"), Strings.overviewAskYesNoQuestion("Overwrite?"))
        XCTAssertEqual(ask(.yesNo), Strings.overviewAskYesNo)
        XCTAssertEqual(ask(.yourMove), Strings.overviewAskFinished)
        XCTAssertEqual(ask(.approveFiles), Strings.overviewAskApproveFiles)
        XCTAssertEqual(ask(.approvePermissions), Strings.overviewAskApprovePermissions)
        XCTAssertEqual(ask(.approve), Strings.overviewAskApprove)
        XCTAssertEqual(ask(.answer), Strings.overviewAskAnswer)
        XCTAssertEqual(ask(.failed), Strings.overviewAskFailed)
        XCTAssertEqual(OverviewWords.counts(OverviewCounts(needsYou: 2, working: 3, done: 1)),
                       [Strings.overviewCountNeedsYou("2"), Strings.overviewCountDone("1"),
                        Strings.overviewCountWorking("3")].joined(separator: " · "))
        XCTAssertEqual(OverviewWords.counts(OverviewCounts(working: 1)), Strings.overviewCountWorking("1"))
        XCTAssertNil(OverviewWords.counts(OverviewCounts()), "nothing to say: no summary at all")
    }

    // MARK: - The store follows core

    func testTheStoreFollowsTheListThroughWorkingWaitingFinishedAndSeen() throws {
        let home = home()
        func row(_ state: String, _ ask: String) -> String {
            #"{"rows": [{"source": "herdr", "state": "\#(state)", "ask": "\#(ask)", "session": "work", "pane_id": "w1:p1", "workspace_id": "w1", "agent": "codex"}], "counts": {"needs_you": \#(state == "needs_you" ? 1 : 0), "working": \#(state == "working" ? 1 : 0), "done": \#(state == "done" ? 1 : 0)}, "sessions": [{"name": "work", "needs_you": \#(state == "needs_you" ? 1 : 0), "working": 0, "done": 0}]}"#
        }
        home.apply(try state(1, #""overview": \#(row("working", "working"))"#))
        XCTAssertEqual(home.overviewShown.rows.map(\.state), [.working])
        XCTAssertTrue(home.overviewEvent(try event("overview.changed", #"{"overview": \#(row("needs_you", "pick")), "revision": 2}"#)))
        XCTAssertEqual(home.overviewShown.rows.map(\.state), [.needsYou])
        XCTAssertEqual(home.overviewShown.herdrNeedsYou, 1)
        _ = home.overviewEvent(try event("overview.changed", #"{"overview": \#(row("done", "finished")), "revision": 3}"#))
        XCTAssertEqual(home.overviewShown.rows.map(\.state), [.done])
        XCTAssertEqual(home.overviewShown.row(session: "work", pane: "w1:p1")?.state, .done, "the pane's square")
        // The pane was opened on a phone: core takes it off the list.
        _ = home.overviewEvent(try event("overview.changed", #"{"overview": {"rows": [], "counts": {}, "sessions": []}, "revision": 4}"#))
        XCTAssertTrue(home.overviewShown.rows.isEmpty)
        XCTAssertNil(home.overviewShown.row(session: "work", pane: "w1:p1"), "the square goes with it")
        XCTAssertFalse(home.overviewEvent(try event("agent.changed", #"{"agent": {"status": "waiting_on_approval"}, "revision": 5}"#)),
                       "with core's list, other events never build one")
        XCTAssertTrue(home.overviewShown.rows.isEmpty)
    }

    func testAnOlderCoreGetsTheListItCanSayAndNothingInvented() throws {
        let home = home()
        let old = #"""
        "agent": {"status": "waiting_on_user_input", "kind": "codex"},
        "herdr": {"blocked": {"work": [{"pane_id": "w1:p1", "name": "claude"}]}},
        "unseen": {"agent": false, "herdr": [{"session": "debug", "pane_id": "w2:p1", "name": "codex"}]}
        """#
        home.apply(try state(1, old))
        var shown = home.overviewShown
        XCTAssertTrue(shown.fallback)
        XCTAssertEqual(shown.rows.map(\.id), ["agent", "herdr:debug:w2:p1", "herdr:work:w1:p1"])
        XCTAssertEqual(shown.rows.map(\.ask), [.answer, .finished, .waiting], "no questions, no Working")
        XCTAssertEqual(shown.herdrNeedsYou, 1)
        // `herdr.layout.changed` says what is blocked in that session now.
        _ = home.overviewEvent(try event("herdr.layout.changed",
                                         #"{"revision": 3, "session": "work", "blocked": [{"pane_id": "w1:p1", "name": "claude"}, {"pane_id": "w1:p2", "name": "codex"}]}"#))
        XCTAssertEqual(home.overviewShown.herdrNeedsYou, 2)
        _ = home.overviewEvent(try event("herdr.layout.changed", #"{"revision": 4, "session": "work", "blocked": [], "stopped": true}"#))
        XCTAssertEqual(home.overviewShown.herdrNeedsYou, 0)
        _ = home.overviewEvent(try event("agent.changed", #"{"agent": {"status": "working"}, "revision": 5}"#))
        _ = home.overviewEvent(try event("unseen.changed", #"{"unseen": {"agent": false, "herdr": []}, "revision": 6}"#))
        shown = home.overviewShown
        XCTAssertTrue(shown.rows.isEmpty)
        // The host is updated: from now on the list is core's.
        home.apply(try state(7, #""overview": \#(overviewJSON)"#))
        XCTAssertFalse(home.overviewShown.fallback)
        XCTAssertEqual(home.overviewShown.rows.count, 5)
    }

    func testTheDefaultAgentsOwnPaneIsTheAgentRowNotASecondOne() {
        let reading = OverviewReading.fallback(agentStatus: "waiting_on_approval", agentKind: "codex",
                                               blocked: ["omodachi": [.init(paneID: "w1:p9", name: "codex")],
                                                         "work": [.init(paneID: "w1:p9", name: "codex")]],
                                               unseen: nil, defaultPane: "w1:p9")
        XCTAssertEqual(reading.rows.map(\.id), ["agent", "herdr:work:w1:p9"])
        XCTAssertEqual(reading.rows[0].ask, .approve, "an older core never says which kind")
        XCTAssertEqual(reading.counts, OverviewCounts(needsYou: 2))
    }

    func testTheDemoShowsItsFixtureOrNothing() {
        let home = home()
        home.overview = OverviewReading(rows: [.init(source: .agent, state: .needsYou, ask: .approve)],
                                        counts: .init(needsYou: 1), sessions: [:])
        home.profile.mock = true
        XCTAssertEqual(home.overviewShown, OverviewFixture.reading ?? .empty, "a demo never shows a host's list")
    }

    // MARK: - The Herdr panel

    func testTheListAndTheNewCardsTakeTurnsUnderTheSwitcher() {
        let home = home()
        let store = HerdrStore(home: home)
        store.overviewOpen = true
        store.openNewSession()
        XCTAssertFalse(store.overviewOpen)
        XCTAssertTrue(store.newSessionOpen)
        store.overviewOpen = true
        store.openNewWorkspace()
        XCTAssertFalse(store.overviewOpen)
    }
}
