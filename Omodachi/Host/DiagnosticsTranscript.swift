import Foundation

/// UX-3 §2. The lines a trace already writes, kept where a person can reach them.
///
/// `SSHConnectionTrace` has written a precise record of every connection
/// attempt since UX-2 — and on Leo's iPad that record was unreachable. Reading
/// it needs a Mac, a cable and `log show`, which is the one thing a person
/// holding the iPad that is failing does not have. So the same lines also land
/// here, in a small ring in memory, and Settings ⑥ prints the ring with a
/// button that copies it.
///
/// It is a transcript, not a log: bounded, in memory only, never written to
/// disk and gone when the app is. Nothing reads it back to make a decision.
///
/// What may go in it is fixed by the same rule the OSLog lines follow: steps,
/// outcomes, addresses, fingerprints, timings and the host's own error text.
/// Never a token, never a private key, never a password — there is no field
/// for one, and the approval transcript carries only values the host already
/// knows or could compute.
final class DiagnosticsTranscript: @unchecked Sendable {
    /// Enough to hold several whole attempts plus the ladder between them, and
    /// small enough that the oldest line is never interesting.
    static let capacity = 120

    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
    }

    /// One block of text, oldest first. Empty when nothing has happened yet,
    /// which is a true answer and not a placeholder.
    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll()
    }

    /// `2026-09-22T09:13:11.482Z`, so a line can be lined up against a host
    /// journal without anybody having to convert an epoch in their head. The
    /// epoch is on the line too, because that is what the OSLog copy carries.
    static func stamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
