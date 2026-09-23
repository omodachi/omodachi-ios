import Foundation
import OSLog

/// UX-2 §1. The SSH half of what `RemoteSessionTrace` does for a session.
///
/// The real iPad could not open a shell and the host's only evidence was
/// `Timeout before authentication` — the TCP connection was made and then
/// nothing else happened on it for the whole of `LoginGraceTime`. Nothing on
/// the device said which step that was: the key read, the socket, the version
/// exchange, the host key, the user authentication or the PTY. Citadel reports
/// one opaque error for all of them and, on its own ten second login timeout,
/// does not even close the socket.
///
/// So every step of one connection gets a line with the same `session` tag,
/// and the step that has no line after it is the step that hung.
///
/// This is not a control path. It names steps that already happen and never
/// changes a connection, a key or a pin.
enum SSHConnectionTrace {
    private static let log = Logger(subsystem: "com.omodachi.ios", category: "ssh.connect")

    /// UX-3 §2. The same lines, kept in memory so Settings ⑥ can print them
    /// and a person holding the iPad can copy them. `log show` needs a Mac;
    /// the iPad that is failing to connect is the device that has to report.
    static let transcript = DiagnosticsTranscript()

    private static func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    private static func record(_ line: String) {
        transcript.append(DiagnosticsTranscript.stamp() + " " + line)
    }

    /// One attempt, from the first line to the last. `tag` is short and stable
    /// so `log show | grep` gives the whole attempt.
    static func step(_ tag: String, _ step: String, detail: String = "") {
        log.notice("ssh.connect tag=\(tag, privacy: .public) step=\(step, privacy: .public) detail=\(detail, privacy: .public) epoch=\(stamp(), privacy: .public)")
        record("tag=\(tag) step=\(step) detail=\(detail)")
    }

    /// The attempt ended without a shell. An attempt that gave up on its own
    /// deadline says so, because that is the line the host's `Timeout before
    /// authentication` has to be lined up against.
    static func failed(_ tag: String, step: String, reason: String) {
        log.error("ssh.connect tag=\(tag, privacy: .public) step=\(step, privacy: .public) outcome=failed reason=\(reason, privacy: .public) epoch=\(stamp(), privacy: .public)")
        record("tag=\(tag) step=\(step) outcome=failed reason=\(reason)")
    }

    /// A retry that was scheduled, and how long it waited. sshd penalises a
    /// source that exceeds `LoginGraceTime`, so the interval is evidence.
    static func retry(_ tag: String, attempt: Int, delay: Int) {
        log.notice("ssh.connect tag=\(tag, privacy: .public) step=retry attempt=\(attempt) delay_s=\(delay) epoch=\(stamp(), privacy: .public)")
        record("tag=\(tag) step=retry attempt=\(attempt) delay_s=\(delay)")
    }

    /// An attempt that was asked for and **not** started, and why. UX-3 §2:
    /// the ladder cannot be read off a log that only records the attempts that
    /// happened - the evidence that a duplicate dial was refused is the line
    /// saying it was refused.
    static func suppressed(_ tag: String, reason: String) {
        log.notice("ssh.connect tag=\(tag, privacy: .public) step=suppressed reason=\(reason, privacy: .public) epoch=\(stamp(), privacy: .public)")
        record("tag=\(tag) step=suppressed reason=\(reason)")
    }
}
