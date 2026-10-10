import Foundation
import Combine
import OSLog
import UIKit
import UserNotifications

/// NOTIFY-2. "Something on the computer is waiting for you", said by the app
/// itself, whichever panel is on screen, and a tap that lands on the place.
///
/// It replaces the panel-scoped `AgentApprovalNotifier`, which spoke only while
/// the Agent panel was up and asked only for quiet (provisional) delivery. This
/// one listens to the host connection's own `/v1/events` stream at the app
/// level — `agent.changed` for an approval or a question, and
/// `herdr.layout.changed` for a Herdr pane whose agent turned `blocked` — and
/// it debounces, coalesces and withdraws by thread the way core's `push.py`
/// does for Odomo.
///
/// There is still no APNs here and none is implied: the stream is the app's
/// own, so it speaks while the app is open, and for the few seconds iOS gives
/// it after it leaves the front (the Shell keeps the stream for those). A
/// locked phone is Odomo's job, and the Notifications panel says so.
///
/// The app tells core what it alerts (`PUT /v1/presence`, `alertKinds`), so
/// Odomo is held back for exactly those kinds while the app is in front.
///
/// NOTIFY-1 adds three things:
///
/// * **Act on the alert.** An approval alert carries the request's id and
///   core's fingerprint of it, and offers Allow / Deny (both ask for Face ID
///   or the passcode first) and Answer…. A decision is sent only if the same
///   request is still pending and still reads the same; otherwise nothing is
///   sent and the alert is replaced by a sentence saying so, which opens the
///   App on the Agent. A question, a Herdr pane, or a host this device holds
///   no pairing for gets Answer… only — never a button that cannot work.
/// * **Quiet at the desk.** While core says the person is using the computer
///   (`state.desk`), alerts are held; when the desk is left or locked, what is
///   still waiting rings and what was answered there is dropped. Herdr waits
///   30 s before it says anything, and several waiting panes are one alert.
///   "Alert me even when I'm at the computer" turns the holding off.
/// * **Done, not yet seen.** `state.unseen`; with "Tell me when an agent
///   finishes" on (off by default), one alert per finished agent.

// MARK: - Where an alert points

struct AttentionTarget: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case agentApproval = "agent_approval"
        case agentNeedsInput = "agent_needs_input"
        case herdrBlocked = "herdr_blocked"
        /// NOTIFY-1: finished, and nobody has looked (opt-in).
        case agentFinished = "agent_done"
        case herdrFinished = "herdr_done"

        var isHerdr: Bool { self == .herdrBlocked || self == .herdrFinished }
    }

    let hostID: String
    let kind: Kind
    var session: String? = nil
    var pane: String? = nil
    /// NOTIFY-1: the approval an Allow / Deny on this alert decides — only on
    /// an approval core says can be decided with a tap.
    var requestID: String? = nil
    var fingerprint: String? = nil

    static let marker = "attention" // non-copy: a userInfo value

    var decidable: Bool { kind == .agentApproval && requestID != nil && fingerprint != nil }

    /// What the notification carries: ids, never text that came from the host.
    var userInfo: [String: String] {
        var value = ["omodachi": Self.marker, "host_id": hostID, "kind": kind.rawValue] // non-copy: wire keys
        if let session { value["session"] = session } // non-copy: wire key
        if let pane { value["pane"] = pane } // non-copy: wire key
        if let requestID, let fingerprint {
            value["request_id"] = requestID // non-copy: wire key
            value["fingerprint"] = fingerprint // non-copy: wire key
        }
        return value
    }

    /// Only a notification of ours, with ids in their own shapes. `simctl push`
    /// and a stale notification from an older build both arrive here too.
    init?(userInfo: [String: String]) {
        guard userInfo["omodachi"] == Self.marker, let host = userInfo["host_id"]?.lowercased(),
              HostPin.validHostID(host), let kind = userInfo["kind"].flatMap(Kind.init(rawValue:)) else { return nil }
        self.hostID = host
        self.kind = kind
        if kind.isHerdr, let session = userInfo["session"], AppLink.validSession(session) {
            self.session = session
            if let pane = userInfo["pane"], AppLink.validPane(pane) { self.pane = pane }
        }
        if kind == .agentApproval, let request = userInfo["request_id"], AttentionApproval.validRequestID(request),
           let fingerprint = userInfo["fingerprint"], AttentionApproval.validFingerprint(fingerprint) {
            self.requestID = request
            self.fingerprint = fingerprint
        }
    }

    init(hostID: String, kind: Kind, session: String? = nil, pane: String? = nil,
         requestID: String? = nil, fingerprint: String? = nil) {
        self.hostID = hostID
        self.kind = kind
        self.session = session
        self.pane = pane
        self.requestID = requestID
        self.fingerprint = fingerprint
    }

    static func strings(_ info: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in info {
            if let key = key as? String, let value = value as? String { out[key] = value }
        }
        return out
    }

    /// The same place, as the link Odomo's "Open in Omodachi" names.
    var link: AppLink {
        AppLink(target: kind.isHerdr ? .herdr : .agent, hostID: hostID, session: session, pane: pane)
    }
}

struct AttentionAlert: Equatable, Sendable {
    /// The request identifier: a newer alert about the same thing replaces it.
    let id: String
    let target: AttentionTarget
    let title: String
    let body: String
    var more = 0
}

enum AttentionAction: Equatable, Sendable {
    case post(AttentionAlert)
    case retract(String)
}

// MARK: - The pure half

/// Events in, alerts and withdrawals out. No clock of its own and no UIKit, so
/// every rule here is a unit test.
///
/// * The first look at the agent and at each Herdr session is a baseline, not
///   news — a pane that was already blocked when the app connected does not
///   ring. A reconnect to the same computer looks again, and what was waiting
///   before and is not now is withdrawn.
/// * One source (the default agent; a finished pane) speaks at once, then
///   holds whatever it says in the next 30 s and says it once, at the end,
///   with a count (`push.py`'s window).
/// * NOTIFY-1: Herdr says nothing for 30 s, then one alert for every pane
///   waiting on this computer, withdrawn when they are all answered.
/// * NOTIFY-1: while the person is at the computer, posts are held; leaving
///   it says what is still waiting.
/// * When the thing is over and nothing replaces it, the alert is withdrawn.
struct AttentionLedger {
    static let window: TimeInterval = 30
    /// NOTIFY-1: a Herdr pane answered at the computer within this long never
    /// reaches the phone.
    static let herdrDelay: TimeInterval = 30
    static let ownedSession = "omodachi" // non-copy: core's owned session name
    private static let waitingInput: Set<String> = ["waiting_on_user_input", "blocked"]

    struct PaneKey: Hashable, Comparable, Sendable {
        let session: String
        let pane: String
        static func < (a: PaneKey, b: PaneKey) -> Bool { (a.session, a.pane) < (b.session, b.pane) }
    }

    private(set) var hostID: String?
    var hostName = ""
    /// The default agent's own pane: in the owned session its `blocked` is the
    /// agent asking for input, which `agent.changed` already says.
    var defaultPane: String?
    private(set) var agentStatus: String?
    private var agentFresh = true
    private var blocked: [String: Set<String>] = [:]
    private var names: [PaneKey: String] = [:]
    private var freshSessions: Set<String> = []
    private var windows: [String: Window] = [:]

    // NOTIFY-1
    /// The oldest pending approval, as core last said.
    private(set) var approval: AttentionApproval?
    private var alertedRequest: String?
    /// Off when "Alert me even when I'm at the computer" is on.
    var holdAtDesk = true
    /// "Tell me when an agent finishes".
    var finishedAlerts = false
    private(set) var deskPresent = false
    private(set) var held: [String: AttentionAlert] = [:]
    private var herdrAnnounced: Set<PaneKey> = []
    /// Panes that started waiting since the last Herdr alert: where it points.
    private var herdrNews: Set<PaneKey> = []
    private var herdrDue: TimeInterval?
    private var herdrShown = false
    private var unseenPanes: Set<PaneKey>?
    private var unseenAgent: Bool?
    private var unseenFresh = true

    private struct Window {
        var sentAt: TimeInterval?
        var pending: AttentionAlert?
        var count = 0
        var due: TimeInterval?
    }

    /// A new connection. The same computer keeps what it knew, so a reconnect
    /// can withdraw what stopped waiting while the app was away; another one
    /// starts clean.
    mutating func connected(hostID: String, hostName: String) {
        if hostID != self.hostID {
            let (hold, finished) = (holdAtDesk, finishedAlerts)
            self = AttentionLedger()
            self.hostID = hostID
            holdAtDesk = hold
            finishedAlerts = finished
        }
        self.hostName = hostName
        agentFresh = true
        unseenFresh = true
        freshSessions = Set(blocked.keys)
    }

    var nextDue: TimeInterval? { (windows.values.compactMap(\.due) + [herdrDue].compactMap { $0 }).min() }

    // MARK: Agent

    /// `approval` is double-optional: `.none` when the event said nothing
    /// about it, `.some(nil)` when it said nothing is pending.
    mutating func agent(status: String?, approval: AttentionApproval?? = .none, now: TimeInterval) -> [AttentionAction] {
        guard let hostID else { return [] }
        if case let .some(head) = approval { self.approval = head }
        guard let status else { return [] }
        let previous = agentStatus
        agentStatus = status
        if agentFresh {
            agentFresh = false
            if status == "waiting_on_approval" { alertedRequest = self.approval?.requestID } // non-copy: wire value
            // A baseline. Only what stopped waiting while nobody was looking
            // is said: by withdrawing it.
            return gate(isWaiting(previous) && !isWaiting(status) ? retract(Self.agentID(hostID)) : [])
        }
        guard status != previous else {
            // NOTIFY-1: still waiting for an approval, but a different one now:
            // the alert's buttons must decide the one that is pending.
            if status == "waiting_on_approval", let head = self.approval, head.requestID != alertedRequest { // non-copy: wire value
                return gate(admit(approvalAlert(hostID), now: now))
            }
            return []
        }
        var alert: AttentionAlert?
        if status == "waiting_on_approval" { // non-copy: wire value
            alert = approvalAlert(hostID)
        } else if Self.waitingInput.contains(status), !Self.waitingInput.contains(previous ?? "") {
            alert = AttentionAlert(id: Self.agentID(hostID),
                                   target: AttentionTarget(hostID: hostID, kind: .agentNeedsInput),
                                   title: Strings.attentionInputTitle, body: Strings.attentionInputBody(hostName))
        }
        if let alert { return gate(admit(alert, now: now)) }
        return gate(isWaiting(previous) && !isWaiting(status) ? retract(Self.agentID(hostID)) : [])
    }

    private mutating func approvalAlert(_ hostID: String) -> AttentionAlert {
        alertedRequest = approval?.requestID
        let head = approval?.decidable == true ? approval : nil
        return AttentionAlert(id: Self.agentID(hostID),
                              target: AttentionTarget(hostID: hostID, kind: .agentApproval,
                                                      requestID: head?.requestID, fingerprint: head?.fingerprint),
                              title: Strings.attentionApprovalTitle, body: Strings.attentionApprovalBody(hostName))
    }

    private func isWaiting(_ status: String?) -> Bool {
        status == "waiting_on_approval" || Self.waitingInput.contains(status ?? "") // non-copy: wire value
    }

    // MARK: Herdr

    mutating func herdr(_ event: HerdrAttentionEvent, now: TimeInterval) -> [AttentionAction] {
        guard hostID != nil else { return [] }
        let session = event.session
        for pane in event.blocked { if let name = pane.name { names[PaneKey(session: session, pane: pane.paneID)] = name } }
        let current = Set(event.blocked.map(\.paneID).filter { $0 != defaultPane || session != Self.ownedSession })
        let before = blocked[session]
        if event.stopped {
            blocked[session] = nil
            freshSessions.remove(session)
            return gate(settleHerdr(news: false, now: now))
        }
        blocked[session] = current
        guard let before else { return [] } // the first look at a session is a baseline
        if freshSessions.remove(session) != nil { return gate(settleHerdr(news: false, now: now)) } // withdraw only
        let added = current.subtracting(before)
        herdrNews.formUnion(added.map { PaneKey(session: session, pane: $0) })
        return gate(settleHerdr(news: !added.isEmpty, now: now))
    }

    /// The host's own reading of what is blocked now (`state.herdr.blocked`):
    /// a first look for a session not seen yet, and after a reconnect the way
    /// to withdraw what stopped waiting while the app was away. Never news.
    mutating func seed(_ map: [String: [HerdrAttentionEvent.Pane]]) -> [AttentionAction] {
        guard hostID != nil else { return [] }
        var touched = false
        for (session, rows) in map.sorted(by: { $0.key < $1.key }) {
            for pane in rows { if let name = pane.name { names[PaneKey(session: session, pane: pane.paneID)] = name } }
            let current = Set(rows.map(\.paneID).filter { $0 != defaultPane || session != Self.ownedSession })
            if blocked[session] != nil {
                guard freshSessions.remove(session) != nil else { continue } // events are already in charge
                touched = true
            }
            blocked[session] = current
        }
        return touched ? gate(settleHerdr(news: false, now: 0)) : []
    }

    private var blockedNow: [PaneKey] {
        blocked.flatMap { session, panes in panes.map { PaneKey(session: session, pane: $0) } }.sorted()
    }

    /// A pane started or stopped waiting. News starts the delay; nothing is
    /// said now. When nothing waits any more, the one Herdr alert goes.
    private mutating func settleHerdr(news: Bool, now: TimeInterval) -> [AttentionAction] {
        guard let hostID else { return [] }
        let all = Set(blockedNow)
        herdrAnnounced.formIntersection(all)
        herdrNews.formIntersection(all)
        if all.isEmpty {
            let shown = herdrShown || held[Self.herdrDigestID(hostID)] != nil
            herdrDue = nil
            herdrShown = false
            held[Self.herdrDigestID(hostID)] = nil
            return shown ? [.retract(Self.herdrDigestID(hostID))] : []
        }
        if news, herdrDue == nil { herdrDue = now + Self.herdrDelay }
        return []
    }

    /// The one Herdr alert: every pane waiting now, pointing at the first new one.
    private mutating func herdrDigest(onlyIfNew: Bool) -> AttentionAlert? {
        guard let hostID else { return nil }
        let panes = blockedNow
        let fresh = panes.filter { !herdrAnnounced.contains($0) }
        guard !onlyIfNew || !fresh.isEmpty,
              let first = herdrNews.sorted().first ?? fresh.first ?? panes.first else { return nil }
        herdrAnnounced = Set(panes)
        herdrNews = []
        herdrShown = true
        let name = names[first] ?? Strings.attentionHerdrSomeone
        let title = panes.count == 1 ? Strings.attentionHerdrTitle(name)
            : Strings.attentionHerdrManyTitle(Format.count(panes.count))
        let body = panes.count == 1 ? Strings.attentionHerdrBody(hostName, first.session)
            : Strings.attentionHerdrManyBody(hostName)
        return AttentionAlert(id: Self.herdrDigestID(hostID),
                              target: AttentionTarget(hostID: hostID, kind: .herdrBlocked,
                                                      session: first.session, pane: first.pane),
                              title: title, body: body)
    }

    // MARK: Finished, not yet seen

    /// `state.unseen` / `unseen.changed`. The first reading after a connection
    /// is a baseline; one that is gone is withdrawn; a new one rings only with
    /// "Tell me when an agent finishes" on.
    mutating func unseen(_ reading: UnseenReading, now: TimeInterval) -> [AttentionAction] {
        guard let hostID else { return [] }
        let panes = Set(reading.herdr.map { PaneKey(session: $0.session, pane: $0.paneID) })
        for row in reading.herdr { if let name = row.name { names[PaneKey(session: row.session, pane: row.paneID)] = name } }
        let before = unseenPanes, agentBefore = unseenAgent, fresh = unseenFresh
        unseenPanes = panes
        unseenAgent = reading.agent
        unseenFresh = false
        var out: [AttentionAction] = []
        for key in (before ?? []).subtracting(panes).sorted() { out += retract(Self.finishedID(hostID, key)) }
        if agentBefore == true, !reading.agent { out += retract(Self.agentFinishedID(hostID)) }
        guard let before, let agentBefore, !fresh, finishedAlerts else { return gate(out) }
        for key in panes.subtracting(before).sorted() {
            out += admit(finishedAlert(hostID, key), now: now)
        }
        if reading.agent, !agentBefore {
            out += admit(AttentionAlert(id: Self.agentFinishedID(hostID),
                                        target: AttentionTarget(hostID: hostID, kind: .agentFinished),
                                        title: Strings.attentionAgentFinishedTitle,
                                        body: Strings.attentionAgentFinishedBody(hostName)), now: now)
        }
        return gate(out)
    }

    private func finishedAlert(_ hostID: String, _ key: PaneKey) -> AttentionAlert {
        AttentionAlert(id: Self.finishedID(hostID, key),
                       target: AttentionTarget(hostID: hostID, kind: .herdrFinished, session: key.session, pane: key.pane),
                       title: Strings.attentionFinishedTitle(names[key] ?? Strings.attentionHerdrSomeone),
                       body: Strings.attentionFinishedBody(hostName, key.session))
    }

    // MARK: The desk

    /// `state.desk` / `desk.changed`. Leaving the desk (idle, locked, driven
    /// from the phone) says what is still waiting, once.
    mutating func desk(present: Bool, now: TimeInterval) -> [AttentionAction] {
        deskPresent = present
        return present ? [] : release()
    }

    /// "Alert me even when I'm at the computer" switched on: nothing is held
    /// any more, and what was held goes now.
    mutating func setHoldAtDesk(_ hold: Bool) -> [AttentionAction] {
        holdAtDesk = hold
        return hold ? [] : release()
    }

    private mutating func release() -> [AttentionAction] {
        var out: [AttentionAction] = []
        let waiting = held
        held = [:]
        for (_, alert) in waiting.sorted(by: { $0.key < $1.key }) {
            if let fresh = stillWaiting(alert) { out.append(.post(fresh)) }
        }
        return out
    }

    /// What a held alert says now, or nil when it was answered meanwhile.
    private mutating func stillWaiting(_ alert: AttentionAlert) -> AttentionAlert? {
        guard let hostID, alert.target.hostID == hostID else { return nil }
        switch alert.target.kind {
        case .agentApproval:
            return agentStatus == "waiting_on_approval" ? approvalAlert(hostID) : nil // non-copy: wire value
        case .agentNeedsInput:
            return Self.waitingInput.contains(agentStatus ?? "") ? alert : nil
        case .herdrBlocked:
            return herdrDigest(onlyIfNew: false)
        case .herdrFinished:
            guard let session = alert.target.session, let pane = alert.target.pane else { return nil }
            return unseenPanes?.contains(PaneKey(session: session, pane: pane)) == true ? alert : nil
        case .agentFinished:
            return unseenAgent == true ? alert : nil
        }
    }

    /// Every post passes here: at the desk it is held instead (newest per
    /// id); a withdrawal also drops what was held for it.
    private mutating func gate(_ actions: [AttentionAction]) -> [AttentionAction] {
        actions.compactMap { action in
            switch action {
            case .post(let alert) where deskPresent && holdAtDesk:
                held[alert.id] = alert
                return nil
            case .retract(let id):
                held[id] = nil
                return action
            default:
                return action
            }
        }
    }

    // MARK: Windows

    private mutating func admit(_ alert: AttentionAlert, now: TimeInterval) -> [AttentionAction] {
        var window = windows[alert.id] ?? Window()
        if window.due == nil, window.sentAt.map({ now - $0 >= Self.window }) ?? true {
            window.sentAt = now
            windows[alert.id] = window
            return [.post(alert)]
        }
        window.pending = alert
        window.count += 1
        if window.due == nil { window.due = (window.sentAt ?? now) + Self.window }
        windows[alert.id] = window
        return []
    }

    private mutating func retract(_ id: String) -> [AttentionAction] {
        if var window = windows[id] {
            window.pending = nil
            window.count = 0
            windows[id] = window
        }
        return [.retract(id)]
    }

    /// The windows whose 30 s are up, said once each, and the Herdr alert
    /// once its delay is up.
    mutating func due(now: TimeInterval) -> [AttentionAction] {
        var out: [AttentionAction] = []
        for (id, window) in windows.sorted(by: { $0.key < $1.key }) {
            guard let due = window.due, due <= now else { continue }
            var next = window
            next.due = nil
            if var pending = window.pending {
                pending.more = window.count - 1
                next.sentAt = now
                out.append(.post(pending))
            }
            next.pending = nil
            next.count = 0
            windows[id] = next
        }
        if let due = herdrDue, due <= now {
            herdrDue = nil
            if let digest = herdrDigest(onlyIfNew: true) { out.append(.post(digest)) }
        }
        return gate(out)
    }

    static func agentID(_ host: String) -> String { "omodachi.\(host).agent" } // non-copy: an identifier
    static func herdrID(_ host: String, _ session: String, _ pane: String) -> String {
        "omodachi.\(host).herdr.\(session).\(pane)" // non-copy: an identifier
    }
    /// NOTIFY-1: the one Herdr alert of a computer.
    static func herdrDigestID(_ host: String) -> String { "omodachi.\(host).herdr" } // non-copy: an identifier
    static func finishedID(_ host: String, _ key: PaneKey) -> String {
        "omodachi.\(host).done.\(key.session).\(key.pane)" // non-copy: an identifier
    }
    static func agentFinishedID(_ host: String) -> String { "omodachi.\(host).agent.done" } // non-copy: an identifier
    /// NOTIFY-1: what a decision taken on alert `id` came to.
    static func outcomeID(_ id: String) -> String { id + ".outcome" } // non-copy: an identifier
}

// MARK: - Permission

enum AlertPermission: Equatable, Sendable {
    /// Not read yet.
    case unknown
    case notDetermined
    /// Quiet delivery: Notification Centre only, no banner, no sound.
    case provisional
    case authorized
    case denied

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .ephemeral: self = .authorized
        case .provisional: self = .provisional
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        @unknown default: self = .unknown
        }
    }

    /// Whether anything posted reaches Notification Centre at all.
    var delivers: Bool { self == .authorized || self == .provisional }
}

// MARK: - Deciding from the alert (NOTIFY-1)

enum AttentionDecisionOutcome: Equatable, Sendable {
    /// Core sent it to the agent.
    case sent
    /// Nothing pending under that id: answered at the computer, or elsewhere.
    case gone
    /// The request reads differently from what the alert was about.
    case changed
    /// The computer could not be asked (offline, no pairing, any error).
    case unreachable
}

protocol ApprovalDeciding: Sendable {
    /// Whether this device holds a pairing for that computer at all, so an
    /// alert is never given a button that cannot work.
    @MainActor func canDecide(hostID: String) -> Bool
    func decide(hostID: String, requestID: String, fingerprint: String, decision: String) async -> AttentionDecisionOutcome
}

/// The real one: a one-shot, pinned, credentialed request to that computer,
/// independent of the app's own connection, so it works from a notification
/// action with the app in the background (or launched for it).
struct HostApprovalDecider: ApprovalDeciding {
    @MainActor func canDecide(hostID: String) -> Bool {
        PairedHostDirectory().records.contains { $0.hostID == hostID }
    }

    func decide(hostID: String, requestID: String, fingerprint: String, decision: String) async -> AttentionDecisionOutcome {
        let records = await MainActor.run { PairedHostDirectory().records }
        let pins = HostPinStore()
        guard let record = records.first(where: { $0.hostID == hostID }),
              let pin = pins.load(account: record.account), pin.hostID == hostID else { return .unreachable }
        let endpoint = HostRoads.dialURL(road: pin.road(account: record.account), roads: pin.roads, attempt: 0)
            ?? URL(string: record.account)
        guard let endpoint, let configuration = try? CompanionHostConfiguration(endpoint: endpoint, account: record.account)
        else { return .unreachable }
        let client = CompanionHostClient(configuration: configuration, credentials: CompanionCredentialStore(),
                                         pinnedFingerprint: pin.fingerprintSHA256)
        let outcome: AttentionDecisionOutcome
        do {
            try await client.connect()
            let result = try await client.chatResolveApproval(requestID: requestID, decision: decision, input: nil,
                                                              fingerprint: fingerprint)
            outcome = result.resolved ? .sent : .unreachable
        } catch let error as AgentChatHostError {
            switch error.code {
            case "agent_approval_unknown": outcome = .gone // non-copy: wire value
            case "agent_approval_changed": outcome = .changed // non-copy: wire value
            default: outcome = .unreachable
            }
        } catch {
            outcome = .unreachable
        }
        await client.disconnect()
        return outcome
    }
}

// MARK: - The app-level half

@MainActor final class AttentionNotifier: ObservableObject {
    static let shared = AttentionNotifier()

    /// NOTIFY-1: the notification actions and the categories that carry them.
    enum ActionID {
        static let allow = "omodachi.allow" // non-copy: an identifier
        static let deny = "omodachi.deny" // non-copy: an identifier
        static let answer = "omodachi.answer" // non-copy: an identifier
    }
    enum CategoryID {
        /// Allow / Deny / Answer…: an approval this device can decide.
        static let decide = "omodachi.decide" // non-copy: an identifier
        /// Answer… only: a question, a Herdr pane, or no way to decide here.
        static let answer = "omodachi.answer" // non-copy: an identifier
    }

    @Published private(set) var permission: AlertPermission = .unknown
    /// The default agent's status as this app last read it — what the Agent
    /// entry's badge reads when the Agent panel is not on screen.
    @Published private(set) var agentStatus: String?
    /// NOTIFY-1: what finished with nobody looking (the bar's quiet dot).
    @Published private(set) var unseen: UnseenReading?
    /// NOTIFY-1: whether core says the person is at the computer.
    @Published private(set) var desk: DeskReading?
    /// NOTIFY-1: a sentence for the Shell to show once, after a decision from
    /// an alert could not be sent.
    @Published var notice: String?
    /// NOTIFY-1: "Alert me even when I'm at the computer". Off by default:
    /// quiet while you are there.
    @Published var alertAtDesk: Bool {
        didSet {
            guard alertAtDesk != oldValue else { return }
            defaults?.set(alertAtDesk, forKey: Self.atDeskKey)
            perform(ledger.setHoldAtDesk(!alertAtDesk))
        }
    }
    /// NOTIFY-1: "Tell me when an agent finishes". Off by default.
    @Published var finishedAlerts: Bool {
        didSet {
            guard finishedAlerts != oldValue else { return }
            defaults?.set(finishedAlerts, forKey: Self.finishedKey)
            ledger.finishedAlerts = finishedAlerts
            onPermissionChanged?()
        }
    }

    /// Asked by the delegate before a banner: is the person already looking at
    /// exactly this place? Set by the Shell.
    var isShowing: ((AttentionTarget) -> Bool)?
    /// A tap. Set by the Shell; a tap that arrives before it (a cold launch
    /// from the notification) waits for it.
    var onOpen: ((AttentionTarget) -> Void)? {
        didSet {
            if let onOpen, let pendingOpen { self.pendingOpen = nil; onOpen(pendingOpen) }
        }
    }
    /// The permission changed: core has to be told what the app alerts now.
    var onPermissionChanged: (() -> Void)?

    private let center: UNUserNotificationCenter?
    private let delegate = AttentionCenterDelegate()
    private var ledger = AttentionLedger()
    private var flush: Task<Void, Never>?
    private var pendingOpen: AttentionTarget?
    private let clock: () -> TimeInterval
    private let defaults: UserDefaults?
    let decider: any ApprovalDeciding
    private static let log = Logger(subsystem: "app.omodachi", category: "attention")
    static let atDeskKey = "omodachi.attention.alertAtDesk.v1" // non-copy: a defaults key
    static let finishedKey = "omodachi.attention.finished.v1" // non-copy: a defaults key

    /// `UNUserNotificationCenter.current()` traps in a process with no bundle
    /// proxy, which is what a unit-test host looks like.
    /// `system: false` is a notifier that posts nothing anywhere (unit tests).
    init(center: UNUserNotificationCenter? = nil, system: Bool = true,
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         defaults: UserDefaults? = nil, decider: (any ApprovalDeciding)? = nil) {
        self.center = center ?? (!system || Bundle.main.bundleIdentifier == nil ? nil : .current())
        self.clock = clock
        let store = defaults ?? (system ? AppDefaults.shared : nil)
        self.defaults = store
        self.decider = decider ?? HostApprovalDecider()
        let atDesk = store?.bool(forKey: Self.atDeskKey) ?? false
        let finished = store?.bool(forKey: Self.finishedKey) ?? false
        _alertAtDesk = Published(initialValue: atDesk)
        _finishedAlerts = Published(initialValue: finished)
        ledger.holdAtDesk = !atDesk
        ledger.finishedAlerts = finished
    }

    /// At launch, before any notification can be tapped.
    func install() {
        center?.delegate = delegate
        center?.setNotificationCategories(Self.categories())
        Task { await refreshPermission() }
    }

    /// NOTIFY-1. Allow and Deny run without opening the app, but only after
    /// Face ID or the passcode (`.authenticationRequired`): on a locked phone
    /// that is the unlock, and the credential they need is only readable then.
    /// Answer… opens the app on the card. There is no "don't ask again".
    nonisolated static func categories() -> Set<UNNotificationCategory> {
        let allow = UNNotificationAction(identifier: ActionID.allow, title: Strings.attentionActionAllow,
                                         options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: ActionID.deny, title: Strings.attentionActionDeny,
                                        options: [.authenticationRequired, .destructive])
        let answer = UNNotificationAction(identifier: ActionID.answer, title: Strings.attentionActionAnswer,
                                          options: [.foreground])
        return [UNNotificationCategory(identifier: CategoryID.decide, actions: [allow, deny, answer], intentIdentifiers: []),
                UNNotificationCategory(identifier: CategoryID.answer, actions: [answer], intentIdentifiers: [])]
    }

    func refreshPermission() async {
        guard let center else { return }
        let value = AlertPermission(await center.notificationSettings().authorizationStatus)
        guard value != permission else { return }
        permission = value
        onPermissionChanged?()
    }

    /// "Turn on alerts": the real question, with banners and sound. After a
    /// refusal iOS will not ask again, so the button opens Settings instead.
    func turnOn(openURL: (URL) -> Void) async {
        guard let center else { return }
        if permission == .denied {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            return
        }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshPermission()
    }

    /// Entering the Agent panel used to ask for quiet delivery; it still does,
    /// so a person who never pressed "Turn on alerts" keeps what they had.
    func prepareQuietly() {
        guard let center, permission == .notDetermined || permission == .unknown else { return }
        Task {
            if AlertPermission(await center.notificationSettings().authorizationStatus) == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
            }
            await refreshPermission()
        }
    }

    /// What `PUT /v1/presence` says this app alerts while it is in front. With
    /// banners on: all three of its own kinds, and the host's notifications,
    /// which the Shell always toasts — plus, with "Tell me when an agent
    /// finishes" on, the two finished kinds. Quiet or refused: only the
    /// toasts, so Odomo is never muted for something this app would not say.
    var alertKinds: [String] { Self.alertKinds(for: permission, finished: finishedAlerts) }

    nonisolated static func alertKinds(for permission: AlertPermission, finished: Bool = false) -> [String] {
        guard permission == .authorized else { return ["host_notification"] } // non-copy: wire value
        let base = ["agent_approval", "agent_needs_input", "herdr_blocked", "host_notification"] // non-copy: wire values
        return finished ? base + ["agent_done", "herdr_done"] : base // non-copy: wire values
    }

    // MARK: Events

    func connected(hostID: String, hostName: String) {
        ledger.connected(hostID: hostID, hostName: hostName)
        agentStatus = ledger.agentStatus
    }

    func stateApplied(agentStatus status: String?, defaultPane: String?, hostName: String,
                      herdrBlocked: [String: [HerdrAttentionEvent.Pane]]? = nil,
                      approval: AttentionApproval? = nil, desk reading: DeskReading? = nil,
                      unseen seenReading: UnseenReading? = nil) {
        if !hostName.isEmpty { ledger.hostName = hostName }
        if let defaultPane { ledger.defaultPane = defaultPane }
        var actions: [AttentionAction] = []
        if let reading {
            desk = reading
            actions += ledger.desk(present: reading.present, now: clock())
        }
        actions += ledger.agent(status: status, approval: .some(approval), now: clock())
        if let herdrBlocked { actions += ledger.seed(herdrBlocked) }
        if let seenReading {
            unseen = seenReading
            actions += ledger.unseen(seenReading, now: clock())
        }
        perform(actions)
    }

    func handle(_ event: SanitizedHostEvent) {
        if event.type == "agent.changed" { // non-copy: event type
            let approval = event.notify?.approval ?? .none
            if event.agentStatus != nil || approval != nil {
                perform(ledger.agent(status: event.agentStatus ?? ledger.agentStatus, approval: approval, now: clock()))
            }
        } else if let change = event.herdrAttention {
            perform(ledger.herdr(change, now: clock()))
        } else if let reading = event.notify?.desk {
            desk = reading
            Self.note("desk \(reading.state)") // non-copy: a log line
            perform(ledger.desk(present: reading.present, now: clock()))
        } else if let reading = event.notify?.unseen {
            unseen = reading
            perform(ledger.unseen(reading, now: clock()))
        }
    }

    private func perform(_ actions: [AttentionAction]) {
        if agentStatus != ledger.agentStatus { agentStatus = ledger.agentStatus }
        for action in actions {
            switch action {
            case .post(let alert): post(alert)
            case .retract(let id):
                Self.note("attention retract \(Self.short(id))") // non-copy: a log line
                // NOTIFY-1: and the line a decision from that alert left.
                center?.removeDeliveredNotifications(withIdentifiers: [id, AttentionLedger.outcomeID(id)])
                center?.removePendingNotificationRequests(withIdentifiers: [id])
            }
        }
        scheduleFlush()
    }

    /// Allow / Deny only when every piece is there: an approval core says can
    /// be decided with a tap, its id and fingerprint, and a pairing with that
    /// computer on this device. Anything else gets Answer…, which always works.
    func category(for target: AttentionTarget) -> String? {
        switch target.kind {
        case .agentApproval:
            return target.decidable && decider.canDecide(hostID: target.hostID) ? CategoryID.decide : CategoryID.answer
        case .agentNeedsInput, .herdrBlocked:
            return CategoryID.answer
        case .agentFinished, .herdrFinished:
            return nil
        }
    }

    private func post(_ alert: AttentionAlert) {
        Self.note("attention post \(alert.target.kind.rawValue) \(Self.short(alert.id)) more=\(alert.more)") // non-copy: a log line
        guard let center, permission.delivers || permission == .unknown else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.more > 0 ? alert.body + Strings.attentionMore(Format.count(alert.more)) : alert.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "omodachi.\(alert.target.hostID)" // non-copy: an identifier
        content.userInfo = alert.target.userInfo
        if let category = category(for: alert.target) { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }

    private func scheduleFlush() {
        flush?.cancel()
        guard let due = ledger.nextDue else { flush = nil; return }
        let wait = max(0, due - clock())
        flush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.flush = nil
            self.perform(self.ledger.due(now: self.clock()))
        }
    }

    // MARK: Deciding from the alert

    /// Allow or Deny on an approval alert. Core is asked to decide exactly the
    /// request the alert named, and only if it still reads the same. Whatever
    /// happens, the alert gives way to one line saying what happened — and
    /// when nothing was sent, that line opens the app on the Agent and says
    /// why there.
    func decide(_ info: [String: String], allow: Bool, appActive: Bool = false) async {
        guard let target = AttentionTarget(userInfo: info) else { return }
        guard target.decidable, let request = target.requestID, let fingerprint = target.fingerprint else {
            opened(info)
            return
        }
        let hostName = ledger.hostID == target.hostID ? ledger.hostName : ""
        let outcome = await decider.decide(hostID: target.hostID, requestID: request, fingerprint: fingerprint,
                                           decision: allow ? "accept" : "decline") // non-copy: wire values
        Self.note("attention decide \(allow ? "allow" : "deny") \(outcome)") // non-copy: a log line
        let id = AttentionLedger.agentID(target.hostID)
        let plain = AttentionTarget(hostID: target.hostID, kind: .agentApproval)
        let sentence = Self.sentence(for: outcome, hostName: hostName)
        if outcome == .sent {
            replace(id: id, title: allow ? Strings.attentionAllowedTitle : Strings.attentionDeniedTitle,
                    body: allow ? Strings.attentionAllowedBody(hostName.isEmpty ? Strings.attentionTheComputer : hostName)
                        : Strings.attentionDeniedBody(hostName.isEmpty ? Strings.attentionTheComputer : hostName),
                    target: plain, notice: nil, passive: true)
            return
        }
        replace(id: id, title: Strings.attentionNotSentTitle, body: sentence ?? "", target: plain,
                notice: outcome, passive: false)
        if appActive {
            notice = Self.sentence(for: outcome, hostName: hostName, inApp: true)
            opened(plain.userInfo)
        }
    }

    /// The line on the alert (`inApp: false`, which says to tap) or the one
    /// the app shows where the tap landed.
    nonisolated static func sentence(for outcome: AttentionDecisionOutcome, hostName: String,
                                     inApp: Bool = false) -> String? {
        let host = hostName.isEmpty ? Strings.attentionTheComputer : hostName
        switch outcome {
        case .sent: return nil
        case .gone: return inApp ? Strings.attentionNoticeGone : Strings.attentionNotSentGone
        case .changed: return inApp ? Strings.attentionNoticeChanged : Strings.attentionNotSentChanged
        case .unreachable: return inApp ? Strings.attentionNoticeUnreachable(host) : Strings.attentionNotSentUnreachable(host)
        }
    }

    private func replace(id: String, title: String, body: String, target: AttentionTarget,
                         notice: AttentionDecisionOutcome?, passive: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "omodachi.\(target.hostID)" // non-copy: an identifier
        var info = target.userInfo
        if let notice { info["notice"] = "\(notice)" } // non-copy: a userInfo key
        content.userInfo = info
        if passive {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
            content.categoryIdentifier = CategoryID.answer
        }
        // Its own identifier: a request re-added under the alert's own id is
        // an update iOS shows without a banner (measured on the simulator),
        // and this line has to be seen.
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.add(UNNotificationRequest(identifier: AttentionLedger.outcomeID(id), content: content, trigger: nil)) { error in
            if let error { Self.note("attention replace failed \((error as NSError).code)") } // non-copy: a log line
        }
    }

    // MARK: The delegate's two questions

    func presentation(for info: [String: String]) -> UNNotificationPresentationOptions {
        // AUTH-1's own notification has the toast on screen already; it was
        // never shown in front and still is not.
        guard let target = AttentionTarget(userInfo: info) else { return [] }
        if UIApplication.shared.applicationState == .active, isShowing?(target) == true { return [] }
        return [.banner, .list, .sound]
    }

    func opened(_ info: [String: String]) {
        guard let target = AttentionTarget(userInfo: info) else { return }
        Self.note("attention tap \(target.kind.rawValue) host=\(target.hostID.suffix(6))") // non-copy: a log line
        // NOTIFY-1: the line that replaced an alert whose decision was not
        // sent is said again where it lands.
        if let raw = info["notice"], let outcome = [AttentionDecisionOutcome.gone, .changed, .unreachable] // non-copy: a userInfo key
            .first(where: { "\($0)" == raw }) {
            notice = Self.sentence(for: outcome, hostName: ledger.hostID == target.hostID ? ledger.hostName : "", inApp: true)
        }
        if let onOpen { onOpen(target) } else { pendingOpen = target }
    }

    private static func short(_ id: String) -> String {
        id.split(separator: ".").dropFirst(2).joined(separator: ".")
    }

    static func note(_ line: String) {
        log.notice("\(line, privacy: .public)")
        SSHConnectionTrace.transcript.append(DiagnosticsTranscript.stamp() + " " + line)
    }
}

/// The app-level `UNUserNotificationCenterDelegate`, installed at launch. It
/// reads the ids off the notification and asks the notifier on the main actor.
final class AttentionCenterDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = AttentionTarget.strings(notification.request.content.userInfo)
        return await MainActor.run { AttentionNotifier.shared.presentation(for: info) }
    }

    /// NOTIFY-1: the completion-handler form, finished on the main thread.
    /// The `async` form hands iOS its completion on a background thread, and
    /// for an action that leaves the app in the background UIKit then
    /// updates the app's snapshot from there and throws (seen on the
    /// simulator with Allow).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let info = AttentionTarget.strings(response.notification.request.content.userInfo)
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case UNNotificationDefaultActionIdentifier, AttentionNotifier.ActionID.answer:
                AttentionNotifier.shared.opened(info)
            case AttentionNotifier.ActionID.allow, AttentionNotifier.ActionID.deny:
                // iOS keeps the app running (launching it in the background
                // if it has to) until the completion is called.
                await AttentionNotifier.shared.decide(info, allow: action == AttentionNotifier.ActionID.allow,
                                                      appActive: UIApplication.shared.applicationState == .active)
            default:
                break
            }
            completionHandler()
        }
    }
}

// MARK: - Leaving the front

/// NOTIFY-2. Going to the background used to close the event stream at once
/// (TAIL-3b I3 — that was how core knew the app had left). Presence says that
/// now, so the stream is kept for the seconds iOS allows, and an alert can
/// still ring in them; then it is closed as before.
@MainActor final class BackgroundGrace {
    static let cap: TimeInterval = 25
    private var task: Task<Void, Never>?
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var close: (@MainActor () async -> Void)?

    var running: Bool { task != nil }

    func begin(announce: @escaping @MainActor () async -> Void, close: @escaping @MainActor () async -> Void) {
        _ = cancel()
        self.close = close
        identifier = UIApplication.shared.beginBackgroundTask(withName: "omodachi.attention") { [weak self] in // non-copy: a task name
            MainActor.assumeIsolated { self?.expire() }
        }
        let budget = min(Self.cap, max(0, UIApplication.shared.backgroundTimeRemaining - 8))
        task = Task { [weak self] in
            await announce()
            try? await Task.sleep(for: .seconds(budget))
            guard !Task.isCancelled, let self else { return }
            await self.finish()
        }
    }

    /// Back in front before the grace ran out: the stream is still there.
    /// `true` when it was.
    @discardableResult func cancel() -> Bool {
        let was = task != nil
        task?.cancel()
        task = nil
        close = nil
        end()
        return was
    }

    private func finish() async {
        let action = close
        task = nil
        close = nil
        await action?()
        end()
    }

    /// iOS is out of patience: close now, and give the time back at once.
    private func expire() {
        task?.cancel()
        task = nil
        if let action = close { close = nil; Task { await action() } }
        end()
    }

    private func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

// MARK: - Landing on a pane

/// NOTIFY-2. A tap (or `/open/herdr?session=&pane=`) is "Herdr, that session,
/// that pane". The Herdr surface reads its sessions and its layout as it
/// appears, so this waits for each fact before it acts on it, with the
/// store's own `selectSession` and `select(pane)`, and gives up after a
/// deadline with a sentence rather than a guess.
@MainActor enum HerdrLanding {
    static func land(store: HerdrStore, home: HomeStore, session: String, pane: String?,
                     deadline: TimeInterval = 15) async {
        let end = Date().addingTimeInterval(deadline)
        func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
            while !condition() {
                guard Date() < end, !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return true
        }
        guard await waitUntil({ home.companionConnected && store.selectedSession != nil && !store.switchingSession })
        else { return }
        if store.selectedSession != session {
            AttentionNotifier.note("landing session") // non-copy: a log line
            store.selectSession(session)
            guard await waitUntil({ !store.switchingSession }) else { return }
        }
        guard store.selectedSession == session else { return } // the store said why
        guard let pane else { return }
        guard await waitUntil({ store.layout?.session == session && store.layout?.pane(pane) != nil }) else {
            if store.selectedSession == session, store.layout != nil { store.notice = Strings.attentionPaneGone }
            return
        }
        if store.selected != pane { store.select(pane) }
        AttentionNotifier.note("landing pane") // non-copy: a log line
    }
}
