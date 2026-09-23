import Foundation

/// One row of the Omarchy shell's own notification record, mirrored by core
/// (`omodachi-core/docs/notifications.md`). The shell is the sole owner of
/// `org.freedesktop.Notifications`; nothing here is a second server, and
/// `execArgv` is deliberately absent from the wire — core reads it to answer
/// "is there an action" and then drops it, so there is no stored command for
/// this client to ask anyone to run.
public struct HostNotification: Identifiable, Equatable, Sendable, Decodable {
    public enum Urgency: String, Sendable, Decodable { case low, normal, critical }

    public let id: String
    public let app: String
    public let summary: String
    public let body: String
    public let glyph: String?
    public let urgency: Urgency
    /// The shell's own millisecond stamp, which is also the sort key and the
    /// first half of the id.
    public let timestamp: Int
    public let hasAction: Bool
    /// `true` while the toast is still on screen on the desktop. A notification
    /// that DND silenced is written straight to history and is never active.
    public var active: Bool

    enum CodingKeys: String, CodingKey {
        case id, app, summary, body, glyph, urgency, timestamp
        case hasAction = "has_action", active
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        glyph = try c.decodeIfPresent(String.self, forKey: .glyph)
        urgency = try c.decodeIfPresent(Urgency.self, forKey: .urgency) ?? .normal
        timestamp = try c.decodeIfPresent(Int.self, forKey: .timestamp) ?? 0
        hasAction = try c.decodeIfPresent(Bool.self, forKey: .hasAction) ?? false
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
    }

    public init(id: String, app: String, summary: String, body: String, glyph: String? = nil,
                urgency: Urgency = .normal, timestamp: Int, hasAction: Bool, active: Bool) {
        self.id = id; self.app = app; self.summary = summary; self.body = body; self.glyph = glyph
        self.urgency = urgency; self.timestamp = timestamp; self.hasAction = hasAction; self.active = active
    }

    public var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }
}

struct HostNotificationPage: Decodable, Sendable {
    let notifications: [HostNotification]
    let cursor: String?
    let historyLimit: Int?
    enum CodingKeys: String, CodingKey { case notifications, cursor, historyLimit = "history_limit" }
}

struct HostNotificationActionResult: Decodable, Sendable {
    let id: String
    let action: String
    /// `ok`, or `none` when the shell had nothing on screen to act on — which
    /// is what a DND-silenced notification looks like.
    let result: String
}

/// The client-side list. Ordering, dedupe and "which one may be invoked" live
/// here rather than in a view, because the last rule is a host rule: the shell
/// only offers "act on the newest popup", so anything else is
/// `notification_not_actionable` and must not be offered as a button.
struct HostNotificationList: Equatable, Sendable {
    /// Newest first, which is the order the Panel reads them in.
    private(set) var rows: [HostNotification] = []
    /// ARCH-1 §5 #17. Do Not Disturb belongs to the host, and the desktop can
    /// change it while this device is looking at it — so this is **not** a
    /// boolean this client owns. It mirrors `state.notifications.dnd`, and
    /// `nil` is that field's own `null`: nobody has read the shell yet, which
    /// is not the same claim as "it is off". The panel draws the switch
    /// disabled until a real reading lands rather than guessing.
    var dnd: Bool?
    var loaded = false

    /// Core keeps 500; there is no reason for a phone to hold more than it can
    /// scroll through in one sitting.
    static let limit = 100

    /// The host's page arrives oldest first with a cursor.
    mutating func replace(with page: [HostNotification]) {
        rows = page.filter { !removed.contains($0.id) }
            .sorted { ($0.timestamp, $0.id) > ($1.timestamp, $1.id) }
        trim()
        loaded = true
    }

    /// A `notification.posted` for an id already held is the same row updated,
    /// not a second copy: the id is the shell's own file name and the dedupe
    /// key.
    mutating func post(_ row: HostNotification) {
        guard !removed.contains(row.id) else { return }
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row }
        else { rows.insert(row, at: 0) }
        rows.sort { ($0.timestamp, $0.id) > ($1.timestamp, $1.id) }
        trim()
    }

    /// A-45. Removing a row from *this device's* list. It is deliberately not
    /// conditional on the host: a row already in history has nothing on the
    /// desktop to dismiss, and a user who swiped it away here has said they do
    /// not want to see it here. The host's own history is untouched and a
    /// reload brings it back — which is the honest behaviour, because this
    /// client is a mirror and does not own the record.
    @discardableResult mutating func remove(id: String) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        removed.insert(id)
        rows.remove(at: index)
        return true
    }

    /// A-45's "清除全部", in the group header.
    mutating func removeAll() {
        removed.formUnion(rows.map(\.id))
        rows.removeAll()
    }

    /// Ids this device has removed, so a reload or a late `notification.posted`
    /// does not put a row the user swiped away back on screen.
    private(set) var removed: Set<String> = []

    mutating func markInactive(id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].active = false
    }

    private mutating func trim() {
        if rows.count > Self.limit { rows.removeLast(rows.count - Self.limit) }
    }

    var newestActive: HostNotification? { rows.first { $0.active } }

    /// A-45. The number the collapsed header shows: what is still on the
    /// desktop's screen. A history row has already been read somewhere.
    var unreadCount: Int { rows.reduce(0) { $0 + ($1.active ? 1 : 0) } }

    /// The shell only exposes "fire the newest popup's default action", and
    /// core refuses anything else rather than running a stored command line.
    /// So the button exists on exactly one row, and only when it has an action.
    func canInvoke(_ row: HostNotification) -> Bool {
        row.hasAction && row.active && newestActive?.id == row.id
    }

    /// Dismissing is offered for anything still on screen. A row already in
    /// history has nothing to take off it.
    func canDismiss(_ row: HostNotification) -> Bool { row.active }

    /// A-45: **every** row can be deleted from this list, history included. The
    /// host `dismiss` is attempted for an active row and its success is not
    /// required — the row leaves this device either way.
    func canDelete(_ row: HostNotification) -> Bool { true }
}
