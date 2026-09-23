import Foundation
import OSLog

/// PERF-4. Where the seconds go between a tap and the thing on the host.
///
/// Every line carries a wall-clock `epoch` so a host-side poller and this
/// device can be laid on the same timeline without guessing, and a monotonic
/// `since` in milliseconds from the tap it belongs to, so a timeline can be
/// read without subtracting timestamps by hand.
///
/// This is not a control path. It reads values that already exist; it never
/// changes a request, a snapshot or what the panel draws. It is the same shape
/// `RemoteSessionTrace` and `ShortcutTrace` already use, and it is left in
/// place because a number nobody can reproduce is a number that rots.
enum PanelPerfTrace {
    private static let log = Logger(subsystem: "com.omodachi.ios", category: "perf")

    /// Wall clock, so the host's own log can be lined up against this one.
    private static func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    /// The clock a single interaction is measured against. `mark()` is "now,
    /// in milliseconds since the tap".
    struct Clock: Sendable {
        let started = DispatchTime.now()
        let label: String
        var elapsed: Double {
            Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000
        }
    }

    static func begin(_ label: String, detail: String = "") -> Clock {
        log.notice("perf.begin \(label, privacy: .public) detail=\(detail, privacy: .public) epoch=\(stamp(), privacy: .public)")
        return Clock(label: label)
    }

    /// One step of an interaction: the request went out, the answer came back,
    /// the bar redrew.
    static func mark(_ clock: Clock, _ step: String, detail: String = "") {
        log.notice("perf.mark \(clock.label, privacy: .public) step=\(step, privacy: .public) since=\(String(format: "%.0f", clock.elapsed), privacy: .public)ms detail=\(detail, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// A host round trip that is not part of a named interaction.
    static func round(_ operation: String, milliseconds: Double, outcome: String) {
        log.notice("perf.round op=\(operation, privacy: .public) ms=\(String(format: "%.0f", milliseconds), privacy: .public) outcome=\(outcome, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// Every rebuild of the menu, with how many of its rows would draw
    /// `不可用`. This is the line that makes the flash visible: a rebuild that
    /// turns 0 unavailable rows into all of them is the bug, not the symptom.
    static func menu(total: Int, unavailable: Int, cause: String) {
        log.notice("perf.menu total=\(total) unavailable=\(unavailable) cause=\(cause, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }

    /// Every rebuild of the bar's workspace segment, and where the reading
    /// came from — the host's snapshot, or this device's own optimistic guess.
    static func bar(active: Int, source: String) {
        log.notice("perf.bar active=\(active) source=\(source, privacy: .public) epoch=\(stamp(), privacy: .public)")
    }
}
