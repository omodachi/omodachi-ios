import Foundation

/// Study 04 A-68 (MENU-4). A row the host marks `confirm` — power and
/// session, erasing, updating, security — is not sent on the first tap. The
/// first tap arms it for two seconds (A-12's toast length) and the row says so;
/// a second tap on the same row inside that window sends it. Anything else —
/// the window running out, a tap on another row — puts the question away.
///
/// A pure decision, so the rule is tested without a view: the store holds the
/// one armed row and the view draws it.
struct ConfirmArm: Equatable, Sendable {
    /// A-12: the same two seconds the 26-high toast stays up.
    static let window: TimeInterval = 2
    let entryID: String
    let until: Date
}

enum ConfirmGate {
    /// What a tap on `entryID` does: whether it is sent now, and which row (if
    /// any) is armed afterwards.
    static func tap(_ entryID: String, confirm: Bool, armed: ConfirmArm?,
                    now: Date = Date()) -> (send: Bool, armed: ConfirmArm?) {
        guard confirm else { return (true, nil) }
        if let armed, armed.entryID == entryID, now < armed.until { return (true, nil) }
        return (false, ConfirmArm(entryID: entryID, until: now.addingTimeInterval(ConfirmArm.window)))
    }
}
