import Foundation

/// UX-3 §2. One ladder per host, shared by every session that dials it.
///
/// UX-2 built a `4 / 12 / 30` ladder and the real iPad never walked it. Two
/// reasons, and this object answers both:
///
/// 1. **The ladder belonged to the wrong thing.** It was a property of a
///    *reattachable* session — Agent and Herdr — and the SSH panel opens a
///    `shell`, which is not reattachable. So the only path that could have
///    paced the retries was the one path it was never on.
/// 2. **Nothing was counting across sessions.** A runtime guarded its own
///    second dial and nothing guarded the third runtime's first. `sshd`
///    penalises a *source address*, not a session, so the thing that has to be
///    paced is "this device dialling that host", which is what is keyed here.
///
/// The host's own log is the specification: seven connections in two minutes,
/// five of them inside two seconds, and then `srclimit_penalise`. A gate that
/// admits one attempt at a time and then stands back for 4, 12 and 30 seconds
/// cannot produce that shape.
///
/// It is deliberately not a rate limiter in the usual sense: a *successful*
/// dial clears the ladder completely, so a host that works is never slowed
/// down, and the first attempt after a success is always immediate.
@MainActor final class SSHDialGate {
    /// UX-2 §1.4's ladder, kept verbatim. `sshd`'s penalty box is measured in
    /// tens of seconds, so the last rung has to be longer than the penalty it
    /// is trying to outlive rather than shorter than it.
    static let backoff = [4, 12, 30]

    /// Why an attempt was not started, in the words the trace and the panel use.
    enum Verdict: Equatable {
        case admitted
        /// Another dial to this host has not finished yet.
        case busy
        /// The ladder is standing back. `seconds` is what is left of the rung.
        case backingOff(seconds: Int, attempt: Int)
        /// The ladder ran out. Only the person can ask again.
        case exhausted(attempts: Int)
    }

    private struct Entry {
        var inFlight = false
        var failures = 0
        var openAt = Date.distantPast
        /// UX-4 §2. Whether the one automatic key replacement for this host has
        /// already been spent. It belongs here rather than on a runtime for the
        /// same reason the ladder does: a panel that is closed and reopened is
        /// a new runtime, and "retry once" that resets every time the panel is
        /// drawn is not once, it is every time.
        var keyRepairSpent = false
    }

    private var entries: [SSHConnectionIdentity: Entry] = [:]

    /// Ask to dial. An `admitted` answer reserves the slot; the caller **must**
    /// report back with `finished`, or that host is never dialled again.
    func admit(_ key: SSHConnectionIdentity, now: Date = Date()) -> Verdict {
        var entry = entries[key] ?? Entry()
        if entry.inFlight { return .busy }
        if entry.openAt > now {
            if entry.failures >= Self.backoff.count { return .exhausted(attempts: entry.failures) }
            let remaining = max(1, Int(entry.openAt.timeIntervalSince(now).rounded(.up)))
            return .backingOff(seconds: remaining, attempt: entry.failures)
        }
        if entry.failures >= Self.backoff.count { return .exhausted(attempts: entry.failures) }
        entry.inFlight = true
        entries[key] = entry
        return .admitted
    }

    func finished(_ key: SSHConnectionIdentity, success: Bool, now: Date = Date()) {
        var entry = entries[key] ?? Entry()
        entry.inFlight = false
        if success {
            entry.failures = 0
            entry.openAt = .distantPast
            // A connection that worked is the proof the key is right, so the
            // next drift gets its own repair.
            entry.keyRepairSpent = false
        } else {
            entry.failures += 1
            let rung = Self.backoff[min(entry.failures - 1, Self.backoff.count - 1)]
            entry.openAt = now.addingTimeInterval(TimeInterval(rung))
        }
        entries[key] = entry
    }

    /// The person asked. A ladder exists to protect a host from a loop, not to
    /// argue with the owner of the device, so an explicit tap clears it.
    func reset(_ key: SSHConnectionIdentity) {
        var entry = entries[key] ?? Entry()
        entry.failures = 0
        entry.openAt = .distantPast
        entries[key] = entry
    }

    /// UX-4 §2. Take the one automatic key replacement for this host, if it is
    /// still there. `true` exactly once between successes, so a host that
    /// refuses the new key too is asked once and then left alone.
    ///
    /// Only a connection that *worked* refills it — deliberately not `reset`,
    /// which is the person clearing the ladder. The repair's own re-dial goes
    /// through `reset`, so a budget that `reset` refilled would be a loop:
    /// refused, replace, re-dial, refused, replace… And a person tapping
    /// "重连" after a refused replacement would only be offering the same key
    /// the host just turned down.
    func claimKeyRepair(_ key: SSHConnectionIdentity) -> Bool {
        var entry = entries[key] ?? Entry()
        if entry.keyRepairSpent { return false }
        entry.keyRepairSpent = true
        entries[key] = entry
        return true
    }

    /// How long the caller should wait before asking again, or nil when there
    /// is nothing to wait for.
    func waitSeconds(_ key: SSHConnectionIdentity, now: Date = Date()) -> Int? {
        guard let entry = entries[key], entry.openAt > now else { return nil }
        return max(1, Int(entry.openAt.timeIntervalSince(now).rounded(.up)))
    }
}
