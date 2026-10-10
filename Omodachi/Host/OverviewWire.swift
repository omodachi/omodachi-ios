import Foundation

/// OVERVIEW-1. One list of everything on the computer that wants Leo: the
/// Agent conversation and every Herdr pane with an agent, in every running
/// session — **Needs you**, **Working**, **Done, not seen**.
///
/// core keeps the list (`state.overview`, `overview.changed`): which state each
/// row is in, what it asks in a few words (`ask`), and, where it could be read
/// reliably, the question itself — a blocked pane's dialog off its screen, or
/// the question a finished agent's last reply ends on. Those questions are the
/// agent's own words and are drawn verbatim.
///
/// A core from before OVERVIEW-1 sends none of it. Then `fallback` builds the
/// part an older core does say — blocked panes per session (NOTIFY-2), the
/// Agent's status, what finished unseen (NOTIFY-1) — with no Working rows and
/// no questions: the rows it cannot fill are simply not there.
struct OverviewRow: Equatable, Hashable, Sendable, Identifiable {
    enum Source: String, Sendable { case agent, herdr }
    enum State: String, Sendable, CaseIterable { case needsYou = "needs_you", working, done }
    enum Ask: String, Sendable {
        case approveCommand = "approve_command", approveFiles = "approve_files"
        case approvePermissions = "approve_permissions", approve, answer
        case pick, yesNo = "yes_no", waiting, working
        case yourMove = "your_move", finished, failed
    }

    let id: String
    let source: Source
    let state: State
    let ask: Ask
    /// The agent's own words, at most 120 characters, or nil.
    let question: String?
    /// `codex`, `claude`, … — the marker and the name in the row.
    let agent: String?
    let session: String?
    let paneID: String?
    let workspaceID: String?
    let workspace: String?
    let pane: String?

    struct Wire: Decodable {
        let id: String?, source: String?, state: String?, ask: String?, question: String?
        let agent: String?, session: String?, pane_id: String?, workspace_id: String?
        let workspace: String?, pane: String?
    }

    init?(_ wire: Wire) {
        guard let source = wire.source.flatMap(Source.init(rawValue:)),
              let state = wire.state.flatMap(State.init(rawValue:)) else { return nil }
        self.source = source
        self.state = state
        // An ask this build does not know is said by its state alone.
        ask = wire.ask.flatMap(Ask.init(rawValue:)) ?? Self.plainAsk(state)
        if source == .herdr {
            guard let session = wire.session, AppLink.validSession(session),
                  let pane = wire.pane_id, AppLink.validPane(pane) else { return nil }
            self.session = session
            paneID = pane
            id = "herdr:\(session):\(pane)" // non-copy: an identifier
        } else {
            session = nil
            paneID = nil
            id = "agent" // non-copy: an identifier
        }
        question = Self.line(wire.question, 120)
        agent = Self.line(wire.agent, 32)
        workspaceID = Self.line(wire.workspace_id, 128)
        workspace = Self.line(wire.workspace, 48)
        pane = Self.line(wire.pane, 48)
    }

    init(source: Source, state: State, ask: Ask, question: String? = nil, agent: String? = nil,
         session: String? = nil, paneID: String? = nil, workspaceID: String? = nil,
         workspace: String? = nil, pane: String? = nil) {
        self.source = source
        self.state = state
        self.ask = ask
        self.question = question
        self.agent = agent
        self.session = session
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.workspace = workspace
        self.pane = pane
        id = source == .agent ? "agent" : "herdr:\(session ?? ""):\(paneID ?? "")" // non-copy: an identifier
    }

    static func plainAsk(_ state: State) -> Ask {
        switch state {
        case .needsYou: .waiting
        case .working: .working
        case .done: .finished
        }
    }

    /// One line, control characters and newlines out, cut.
    static func line(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

struct OverviewCounts: Equatable, Sendable {
    var needsYou = 0
    var working = 0
    var done = 0

    var isEmpty: Bool { needsYou == 0 && working == 0 && done == 0 }

    struct Wire: Decodable { let needs_you: Int?; let working: Int?; let done: Int? }
    init(_ wire: Wire?) {
        needsYou = max(0, wire?.needs_you ?? 0)
        working = max(0, wire?.working ?? 0)
        done = max(0, wire?.done ?? 0)
    }
    init(needsYou: Int = 0, working: Int = 0, done: Int = 0) {
        self.needsYou = needsYou
        self.working = working
        self.done = done
    }
}

struct OverviewReading: Equatable, Sendable {
    let rows: [OverviewRow]
    /// Every row's state, the Agent's included, before core cut the list.
    let counts: OverviewCounts
    /// Per running session, its panes only.
    let sessions: [String: OverviewCounts]
    /// Built by this app from an older core's fields (no Working, no asks).
    var fallback = false

    static let empty = OverviewReading(rows: [], counts: .init(), sessions: [:])

    struct Wire: Decodable {
        struct Session: Decodable { let name: String?; let needs_you: Int?; let working: Int?; let done: Int? }
        let rows: [OverviewRow.Wire]?
        let counts: OverviewCounts.Wire?
        let sessions: [Session]?
    }

    init?(_ wire: Wire?) {
        guard let wire, wire.rows != nil else { return nil }
        rows = (wire.rows ?? []).prefix(64).compactMap(OverviewRow.init)
        counts = OverviewCounts(wire.counts)
        var sessions: [String: OverviewCounts] = [:]
        for row in (wire.sessions ?? []).prefix(64) {
            guard let name = row.name, AppLink.validSession(name) else { continue }
            sessions[name] = OverviewCounts(.init(needs_you: row.needs_you, working: row.working, done: row.done))
        }
        self.sessions = sessions
    }

    init(rows: [OverviewRow], counts: OverviewCounts, sessions: [String: OverviewCounts], fallback: Bool = false) {
        self.rows = rows
        self.counts = counts
        self.sessions = sessions
        self.fallback = fallback
    }

    /// The rows of one state, in core's order (position, never status).
    func rows(_ state: OverviewRow.State) -> [OverviewRow] { rows.filter { $0.state == state } }

    /// What waits on Leo in Herdr across every session — the bar's red count.
    var herdrNeedsYou: Int {
        sessions.isEmpty ? rows.filter { $0.source == .herdr && $0.state == .needsYou }.count
            : sessions.values.reduce(0) { $0 + $1.needsYou }
    }

    /// One session's counts, from the per-session list or, in a fallback, its rows.
    func counts(session: String) -> OverviewCounts {
        if let counts = sessions[session] { return counts }
        var counts = OverviewCounts()
        for row in rows where row.session == session {
            switch row.state {
            case .needsYou: counts.needsYou += 1
            case .working: counts.working += 1
            case .done: counts.done += 1
            }
        }
        return counts
    }

    /// The most urgent state of a workspace's panes in one session (its chip's dot).
    func worst(session: String?, workspace: String) -> OverviewRow.State? {
        let states = Set(rows.filter { $0.session == session && $0.workspaceID == workspace }.map(\.state))
        for state in [OverviewRow.State.needsYou, .done, .working] where states.contains(state) { return state }
        return nil
    }

    /// A pane's own row, when it has one.
    func row(session: String?, pane: String) -> OverviewRow? {
        rows.first { $0.session == session && $0.paneID == pane }
    }

    /// From `overview.changed`'s payload, or nil.
    static func parse(payload data: Data) -> OverviewReading? {
        struct Payload: Decodable { let overview: Wire? }
        struct Typed: Decodable { let payload: Payload? }
        struct Framed: Decodable { struct Event: Decodable { let payload: Payload? }; let event: Event? }
        let payload = (try? JSONDecoder().decode(Typed.self, from: data))?.payload
            ?? (try? JSONDecoder().decode(Framed.self, from: data))?.event?.payload
        return OverviewReading(payload?.overview)
    }

    /// A core from before OVERVIEW-1: what it does say, as rows. Blocked panes
    /// per watched session (`state.herdr.blocked`, `herdr.layout.changed`),
    /// the Agent's status, and NOTIFY-1's unseen when that core has it. No
    /// Working rows and no questions — those it never said.
    static func fallback(agentStatus: String?, agentKind: String?, blocked: [String: [HerdrAttentionEvent.Pane]],
                         unseen: UnseenReading?, defaultPane: String?,
                         ownedSession: String = AttentionLedger.ownedSession) -> OverviewReading {
        var rows: [OverviewRow] = []
        switch agentStatus {
        case "waiting_on_approval": // non-copy: a wire value
            rows.append(.init(source: .agent, state: .needsYou, ask: .approve, agent: agentKind))
        case "waiting_on_user_input": // non-copy: a wire value
            rows.append(.init(source: .agent, state: .needsYou, ask: .answer, agent: agentKind))
        default:
            if unseen?.agent == true { rows.append(.init(source: .agent, state: .done, ask: .finished, agent: agentKind)) }
        }
        var sessions: [String: OverviewCounts] = [:]
        var herdr: [OverviewRow] = []
        for (session, panes) in blocked {
            for pane in panes where !(session == ownedSession && pane.paneID == defaultPane) {
                herdr.append(.init(source: .herdr, state: .needsYou, ask: .waiting, agent: pane.name,
                                   session: session, paneID: pane.paneID))
                sessions[session, default: .init()].needsYou += 1
            }
        }
        for pane in unseen?.herdr ?? [] where !herdr.contains(where: { $0.session == pane.session && $0.paneID == pane.paneID }) {
            herdr.append(.init(source: .herdr, state: .done, ask: .finished, agent: pane.name,
                               session: pane.session, paneID: pane.paneID))
            sessions[pane.session, default: .init()].done += 1
        }
        herdr.sort { ($0.session ?? "", $0.paneID ?? "") < ($1.session ?? "", $1.paneID ?? "") }
        rows += herdr
        var counts = OverviewCounts()
        for row in rows {
            switch row.state {
            case .needsYou: counts.needsYou += 1
            case .working: counts.working += 1
            case .done: counts.done += 1
            }
        }
        return OverviewReading(rows: Array(rows.prefix(64)), counts: counts, sessions: sessions, fallback: true)
    }
}
