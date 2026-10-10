import Foundation
import OSLog

/// POLISH-R item 6. What a stall looks like, so the next one is caught.
///
/// Leo's iPad froze for minutes on 2026-10-05 (host time 00:41–00:50, HEVC on
/// the AMD encoder, Sunshine logging nothing wrong) and the only way out was
/// closing the app. Nothing on the device could say afterwards what had
/// happened, for two reasons this file and `OMRemoteClient.publishStats`
/// answer:
///
/// 1. The one-second numbers were replayed. `Connection` closes a stats window
///    only when a frame arrives, so while no frame arrived the diagnostics
///    line kept printing the last healthy second (30 fps, 0 % drop) as if it
///    were now. The window's age is now part of every reading
///    (`RemoteStreamStats.stalledSeconds`).
/// 2. Nothing was kept. The transcript lives in memory and went with the
///    process Leo closed. Stalls are written to `RemoteStallLog`, which
///    survives the app being closed, the moment they begin.
struct RemoteStall: Equatable, Sendable {
    enum Kind: String, Sendable, Comparable {
        /// The app's own once-a-second reading did not run: the main thread
        /// was busy, or the process was suspended.
        case app
        /// Frames arrived and were received but not put on screen.
        case decoder
        /// Too few frames arrived.
        case fewFrames = "few_frames"
        /// Frames arrived but the network lost a large share of them.
        case loss
        /// No frame arrived at all.
        case noFrames = "no_frames"

        private var rank: Int {
            switch self {
            case .app: 0
            case .decoder: 1
            case .fewFrames: 2
            case .loss: 3
            case .noFrames: 4
            }
        }
        static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }
    }

    struct Context: Equatable, Sendable {
        let session: String
        let backend: String
        let codec: String
        let plannedFPS: Int?
        let plannedKbps: Int?
    }

    var start: Date
    var end: Date?
    var kind: Kind
    var codec: String
    var worstRttMs: Int?
    var worstDropRate: Double = 0
    var lowestReceivedFPS: Double
    var lowestRenderedFPS: Double?

    func seconds(at now: Date) -> Double { (end ?? now).timeIntervalSince(start) }

    /// One measurement, the same in both languages. An open stall is
    /// measured up to now.
    var summary: String { summary(at: end ?? Date()) }

    func summary(at now: Date) -> String {
        var parts = [String(format: "%.1f s %@", seconds(at: now), kind.rawValue)] // non-copy: a measurement
        parts.append(String(format: "%.0f fps", lowestReceivedFPS)) // non-copy: a measurement
        if let worstRttMs { parts.append("RTT \(worstRttMs) ms") } // non-copy: a measurement
        if worstDropRate > 0 { parts.append(String(format: "drop %.0f %%", worstDropRate * 100)) } // non-copy: a measurement
        return parts.joined(separator: " ")
    }
}

/// Feeds on the once-a-second readings and says when a stall begins and ends.
/// A pure value, so its thresholds are testable without a stream.
struct RemoteStallDetector: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case began(RemoteStall)
        case ended(RemoteStall)
    }

    /// Readings come once a second; one that comes this late means the app's
    /// own reading did not run in between.
    var gapSeconds: Double = 3
    /// Below this share of the planned rate a second counts as stalled. The
    /// fork keeps at least half the planned rate flowing on a still desktop
    /// ("Minimum FPS target"), so a fifth is well clear of an idle screen.
    var floorShare: Double = 0.2
    var lossShare: Double = 0.2

    private(set) var open: RemoteStall?
    private var lastSample: Date?

    mutating func observe(_ sample: RemoteStreamStats, plannedFPS: Int?, at now: Date) -> [Event] {
        var events: [Event] = []
        defer { lastSample = now }
        // A reading that itself says "no frame for N s" is that stall, not
        // the app's: the timer may well have been late *because* of it.
        if open == nil, sample.stalledSeconds == nil, let lastSample,
           now.timeIntervalSince(lastSample) > gapSeconds {
            // Nothing measured in between, so all that is known is the gap.
            var stall = RemoteStall(start: lastSample, end: now, kind: .app, codec: sample.codec,
                                    worstRttMs: sample.rttMs, lowestReceivedFPS: sample.receivedFPS,
                                    lowestRenderedFPS: sample.renderedFPS)
            stall.end = now
            events.append(.began(stall))
            events.append(.ended(stall))
        }
        guard let kind = kind(of: sample, plannedFPS: plannedFPS) else {
            if var stall = open {
                stall.end = now
                open = nil
                events.append(.ended(stall))
            }
            return events
        }
        if var stall = open {
            stall.kind = max(stall.kind, kind)
            stall.worstRttMs = [stall.worstRttMs, sample.rttMs].compactMap { $0 }.max()
            stall.worstDropRate = max(stall.worstDropRate, sample.dropRate)
            stall.lowestReceivedFPS = min(stall.lowestReceivedFPS, sample.receivedFPS)
            if let rendered = sample.renderedFPS {
                stall.lowestRenderedFPS = min(stall.lowestRenderedFPS ?? rendered, rendered)
            }
            open = stall
        } else {
            // A reading that says "no frame for 4 s" began 4 s ago.
            let start = now.addingTimeInterval(-(sample.stalledSeconds ?? 0))
            let stall = RemoteStall(start: start, end: nil, kind: kind, codec: sample.codec,
                                    worstRttMs: sample.rttMs, worstDropRate: sample.dropRate,
                                    lowestReceivedFPS: sample.receivedFPS, lowestRenderedFPS: sample.renderedFPS)
            open = stall
            events.append(.began(stall))
        }
        return events
    }

    /// The session ended; a stall still open ends with it.
    mutating func close(at now: Date) -> RemoteStall? {
        guard var stall = open else { return nil }
        stall.end = now
        open = nil
        return stall
    }

    func kind(of sample: RemoteStreamStats, plannedFPS: Int?) -> RemoteStall.Kind? {
        if sample.stalledSeconds != nil { return .noFrames }
        let floor = max(2, Double(plannedFPS ?? 30) * floorShare)
        if sample.receivedFPS < floor {
            return sample.dropRate >= lossShare ? .loss : .fewFrames
        }
        if sample.dropRate >= lossShare { return .loss }
        if let rendered = sample.renderedFPS, rendered < floor { return .decoder }
        return nil
    }
}

/// Stalls, kept where a closed app does not lose them: the last few lines in
/// the app's defaults. A stall is written when it *begins*, so one the user
/// ended by closing the app is still there next time, as a "began" line with
/// no "ended" after it. Measurements only — no host name, no address.
final class RemoteStallLog: @unchecked Sendable {
    static let shared = RemoteStallLog()
    static let key = "omodachi.remoteStalls.v1"
    static let capacity = 40

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let osLog = Logger(subsystem: "app.omodachi", category: "remote.stall")

    init(defaults: UserDefaults = AppDefaults.shared) { self.defaults = defaults }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return defaults.stringArray(forKey: Self.key) ?? []
    }

    var transcript: String { lines.joined(separator: "\n") }

    func began(_ stall: RemoteStall, context: RemoteStall.Context) {
        let planned = context.plannedFPS.map { "\($0)fps/\(context.plannedKbps ?? 0)kbps" } ?? "-"
        append("\(DiagnosticsTranscript.stamp(stall.start)) stall.began session=\(context.session) backend=\(context.backend) codec=\(stall.codec) planned=\(planned) kind=\(stall.kind.rawValue)") // non-copy: a trace
    }

    func ended(_ stall: RemoteStall, context: RemoteStall.Context, how: String) {
        let end = stall.end ?? Date()
        append("\(DiagnosticsTranscript.stamp(end)) stall.ended session=\(context.session) \(stall.summary) how=\(how)") // non-copy: a trace
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.key)
    }

    private func append(_ line: String) {
        Self.osLog.notice("\(line, privacy: .public)")
        RemoteSessionTrace.transcript.append(line)
        lock.lock(); defer { lock.unlock() }
        var value = defaults.stringArray(forKey: Self.key) ?? []
        value.append(line)
        if value.count > Self.capacity { value.removeFirst(value.count - Self.capacity) }
        defaults.set(value, forKey: Self.key)
    }
}
