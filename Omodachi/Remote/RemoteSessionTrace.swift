import CoreGraphics
import Foundation
import OSLog

/// REMOTE-2 item 1. The host releases a session whose client stops beating
/// within its TTL, and MERGE-1 §8 found sessions dying exactly one TTL after a
/// beat that never came again — with nothing on either side saying who stopped
/// beating or why. Three lines answer that: every beat, every release with the
/// reason it was asked for, and every heartbeat failure with the host's own
/// word for it.
///
/// This is not a control path. It reads values that already exist and never
/// changes a request, a session or a phase.
enum RemoteSessionTrace {
    private static let log = Logger(subsystem: "com.omodachi.ios", category: "remote.session")

    private static func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    /// Every beat that went out, with the host's answer. `epoch` is wall clock
    /// so a host-side poller can be lined up against it without guessing.
    static func heartbeat(session: String, outcome: String, beat: Int) {
        log.notice("remote.heartbeat session=\(session, privacy: .public) beat=\(beat) outcome=\(outcome, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// The beat loop started or ended. An ended loop with a live session is the
    /// bug itself, so it is logged at error level and names its reason.
    static func heartbeatLoop(_ event: String, session: String, reason: String = "") {
        let line = "remote.heartbeat_loop \(event) session=\(session) reason=\(reason) epoch=\(stamp())"
        if event == "stopped-with-session" { log.error("\(line, privacy: .public)") }
        else { log.notice("\(line, privacy: .public)") }
    }

    /// Who asked for the session to go away. "user", "background", "failure:…",
    /// "foreground-policy" — never an anonymous release.
    static func release(session: String, cause: String, message: String) {
        log.notice("remote.release session=\(session, privacy: .public) cause=\(cause, privacy: .public) message=\(message, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// The app left the foreground, and what that did to the session.
    static func foreground(_ active: Bool, decision: String) {
        log.notice("remote.foreground active=\(active) decision=\(decision, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// MENU-2. Our mark on the picture was tapped. The mark is a view above
    /// the stream, so the tap never reached the picture at all —
    /// this line is the client half of the evidence that the host's fork
    /// received nothing; the host half is its own input counters.
    static func barMark(_ target: String, rect: CGRect? = nil) {
        let where_ = rect.map { String(format: "%.4f,%.4f,%.4f,%.4f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none"
        log.notice("remote.bar_mark target=\(target, privacy: .public) rect=\(where_, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// MENU-2. What the App is covering right now, published when it changes:
    /// the logo's rectangle as a fraction of the host's own output, or its
    /// absence. A session whose bar is hidden logs `targets=0`, which is what
    /// the corner handle (A-67) exists for.
    static func barGeometry(output: String, logo: CGRect?) {
        func describe(_ rect: CGRect?) -> String {
            guard let rect else { return "none" }
            return String(format: "%.4f,%.4f,%.4f,%.4f", rect.minX, rect.minY, rect.width, rect.height)
        }
        log.notice("remote.bar_geometry output=\(output, privacy: .public) targets=\(logo == nil ? 0 : 1) logo=\(describe(logo), privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// GEST-1. What the picture made of a touch cycle, and what it resolved to.
    /// A gesture that resolved to nothing logs `row=none`, which is N-37 seen
    /// from the outside: the host has no such row, so there is no such gesture.
    static func gesture(_ value: String, row: String, outcome: String) {
        log.notice("remote.gesture gesture=\(value, privacy: .public) row=\(row, privacy: .public) outcome=\(outcome, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// GEST-1 §4. Which of the four gestures are registered right now.
    static func gestureBindings(_ value: String) {
        log.notice("remote.gesture_bindings \(value, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// REMOTE-4. Every attempt at dialling a session the host still holds
    /// after its backend went away, and how that attempt ended. Leo's
    /// 2026-09-22 report was "Remote disconnected and I was back on panel ①"
    /// with nothing on either side saying whether the session had died or only
    /// its stream; this line is the difference.
    static func reconnect(session: String, attempt: Int, outcome: String) {
        log.notice("remote.reconnect session=\(session, privacy: .public) attempt=\(attempt) outcome=\(outcome, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// REMOTE-4. What the host said about the session this device is holding.
    static func hostChange(session: String, revision: Int, state: String, reason: String) {
        log.notice("remote.host_change session=\(session, privacy: .public) revision=\(revision) state=\(state, privacy: .public) reason=\(reason, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// REMOTE-6. WayVNC 0.10.1 serves two framebuffer sizes in one session: the
    /// compositor's logical size until its first `NewFBSize` rect, the owned
    /// output's buffer pixels after it. Both are recorded, because "the picture
    /// is soft" and "the picture flipped size" look identical from the outside
    /// and only this line tells them apart.
    static func framebuffer(session: String, event: String, pixels: String) {
        log.notice("remote.framebuffer session=\(session, privacy: .public) event=\(event, privacy: .public) pixels=\(pixels, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// STREAM-1. One second of the running Sunshine stream: codec, received /
    /// rendered fps, RTT, network drop share, the host's own encode time.
    static func stats(session: String, line: String) {
        log.notice("remote.stats session=\(session, privacy: .public) \(line, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// STREAM-1. The device's preset changed, or `自动` moved a row, and what
    /// was done about it (`user`, `redial:…`, `auto:<why>`).
    static func quality(session: String, preset: String, tier: String, cause: String) {
        log.notice("remote.quality session=\(session, privacy: .public) preset=\(preset, privacy: .public) tier=\(tier, privacy: .public) cause=\(cause, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    static func phase(_ value: String, streaming: Bool, panelVisible: Bool) {
        log.notice("remote.phase value=\(value, privacy: .public) streaming=\(streaming) panel_visible=\(panelVisible) epoch=\(stamp(), privacy: .public)")
    }
}
