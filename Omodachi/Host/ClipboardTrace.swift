import Foundation
import OSLog

/// Where a clipboard that did not move stopped, and never what was in it.
///
/// CLIP-1 §2 has four places a push can end without anything visible
/// happening: the switches, iOS refusing the read, nothing new to send, and
/// the host refusing. A feature whose failure mode is silence needs a line per
/// stop, and the lines carry a reason and a length — the same rule the host's
/// own trace follows.
enum ClipboardTrace {
    private static let log = Logger(subsystem: "app.omodachi", category: "clipboard")

    static func pushStopped(_ reason: String) {
        log.notice("clipboard.push stopped reason=\(reason, privacy: .public)")
    }

    static func pushed(bytes: Int) {
        log.notice("clipboard.push sent bytes=\(bytes, privacy: .public)")
    }

    static func received(bytes: Int) {
        log.notice("clipboard.receive applied bytes=\(bytes, privacy: .public)")
    }

    static func failed(_ direction: String, code: String) {
        log.error("clipboard.\(direction, privacy: .public) failed code=\(code, privacy: .public)")
    }
}
