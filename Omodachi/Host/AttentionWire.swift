import Foundation

/// NOTIFY-1. What the alerts read off the host, besides NOTIFY-2's status and
/// blocked panes: the pending approval an alert may decide (ids only), whether
/// the person is at the computer, and what finished with nobody looking.
/// Everything is read leniently and validated here; a core from before
/// NOTIFY-1 sends none of it and the alerts behave exactly as before.

/// `state.agent.chat.approval`: the oldest pending approval.
struct AttentionApproval: Equatable, Sendable {
    let requestID: String
    let kind: String
    /// 16 hex characters core derives from what the approval shows. A
    /// decision sent from the alert carries it, so core sends nothing if the
    /// request changed since.
    let fingerprint: String
    /// A question needs a typed answer or a choice, so its alert opens the App.
    let decidable: Bool

    static func validRequestID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$"#, options: .regularExpression) != nil
    }
    static func validFingerprint(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil
    }

    struct Wire: Decodable {
        let request_id: String?
        let kind: String?
        let fingerprint: String?
        let decidable: Bool?
    }

    init?(_ wire: Wire?) {
        guard let wire, let id = wire.request_id, Self.validRequestID(id),
              let fingerprint = wire.fingerprint, Self.validFingerprint(fingerprint) else { return nil }
        requestID = id
        kind = String((wire.kind ?? "").prefix(32))
        self.fingerprint = fingerprint
        decidable = wire.decidable == true && kind != "userInput" // non-copy: wire value
    }

    init(requestID: String, kind: String, fingerprint: String, decidable: Bool) {
        self.requestID = requestID
        self.kind = kind
        self.fingerprint = fingerprint
        self.decidable = decidable
    }
}

/// `state.desk`: is the person at the computer right now.
struct DeskReading: Equatable, Sendable {
    /// Only ever true when core could read the compositor's idle timer.
    let present: Bool
    /// `using`, `idle`, `locked`, `remote` or `unknown`.
    let state: String

    struct Wire: Decodable { let present: Bool?; let state: String? }

    init?(_ wire: Wire?) {
        guard let wire, let present = wire.present else { return nil }
        self.present = present
        let state = wire.state ?? "unknown" // non-copy: wire value
        self.state = ["using", "idle", "locked", "remote", "unknown"].contains(state) ? state : "unknown" // non-copy: wire values
    }

    init(present: Bool, state: String) {
        self.present = present
        self.state = state
    }
}

/// `state.unseen`: finished, and nobody has had it open since.
struct UnseenReading: Equatable, Sendable {
    struct Pane: Equatable, Hashable, Sendable {
        let session: String
        let paneID: String
        let name: String?
    }
    let agent: Bool
    let herdr: [Pane]

    var isEmpty: Bool { !agent && herdr.isEmpty }

    struct Wire: Decodable {
        struct Row: Decodable { let session: String?; let pane_id: String?; let name: String? }
        let agent: Bool?
        let herdr: [Row]?
    }

    init?(_ wire: Wire?) {
        guard let wire else { return nil }
        agent = wire.agent == true
        herdr = (wire.herdr ?? []).prefix(64).compactMap { row in
            guard let session = row.session, AppLink.validSession(session),
                  let pane = row.pane_id, AppLink.validPane(pane) else { return nil }
            let name = row.name.map { String($0.filter { !$0.isNewline }.prefix(32)) }
            return Pane(session: session, paneID: pane, name: name?.isEmpty == true ? nil : name)
        }
    }

    init(agent: Bool, herdr: [Pane]) {
        self.agent = agent
        self.herdr = herdr
    }
}

/// What one event says for the alerts. `approval` is double-optional:
/// absent (the event did not touch it) is not the same as `null` (nothing is
/// pending any more).
struct NotifyWire: Equatable, Sendable {
    var approval: AttentionApproval?? = .none
    var desk: DeskReading?
    var unseen: UnseenReading?

    var isEmpty: Bool { approval == nil && desk == nil && unseen == nil }

    /// From an event frame's `payload` (`agent.changed`, `desk.changed`,
    /// `unseen.changed`).
    static func parse(type: String, payload data: Data) -> NotifyWire? {
        struct Chat: Decodable {
            let approval: AttentionApproval.Wire?
            let hasApproval: Bool
            enum CodingKeys: String, CodingKey { case approval }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                hasApproval = c.contains(.approval)
                approval = try? c.decodeIfPresent(AttentionApproval.Wire.self, forKey: .approval)
            }
        }
        struct Agent: Decodable { let chat: Chat? }
        struct Payload: Decodable {
            let agent: Agent?
            let desk: DeskReading.Wire?
            let unseen: UnseenReading.Wire?
        }
        struct Typed: Decodable { let payload: Payload? }
        struct Framed: Decodable { struct Event: Decodable { let payload: Payload? }; let event: Event? }
        guard let payload = (try? JSONDecoder().decode(Typed.self, from: data))?.payload
                ?? (try? JSONDecoder().decode(Framed.self, from: data))?.event?.payload else { return nil }
        var out = NotifyWire()
        switch type {
        case "agent.changed": // non-copy: event type
            if let chat = payload.agent?.chat, chat.hasApproval { out.approval = .some(AttentionApproval(chat.approval)) }
        case "desk.changed": // non-copy: event type
            out.desk = DeskReading(payload.desk)
        case "unseen.changed": // non-copy: event type
            out.unseen = UnseenReading(payload.unseen)
        default:
            return nil
        }
        return out.isEmpty ? nil : out
    }
}
