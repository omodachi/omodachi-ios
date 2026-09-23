import Foundation
import OSLog

/// One line, on the failure path only. UX-1 item B asked that "lit" and
/// "works" mean the same thing; when they still do not, this is where the
/// host's own reason is readable without a debugger — the same shape
/// `RemoteGeometryTrace` and `RemotePairingTrace` already use.
enum ShortcutTrace {
    private static let log = Logger(subsystem: "com.omodachi.ios", category: "shortcut")

    static func executionRetried(entry: String, reason: String) {
        log.notice("shortcut.execute retrying entry=\(entry, privacy: .public) after=\(reason, privacy: .public)")
    }

    /// REMOTE-2 item 5: a covered row ran the app's own control instead of
    /// going to the host, and that is a thing that happened, not silence.
    static func executedLocally(entry: String, capability: String) {
        log.notice("shortcut.execute local entry=\(entry, privacy: .public) capability=\(capability, privacy: .public)")
    }

    static func executionFailed(entry: String, reason: String) {
        log.error("shortcut.execute failed entry=\(entry, privacy: .public) reason=\(reason, privacy: .public)")
    }
}
