import Combine
import Foundation
import VideoToolbox

/// STREAM-1. What this device asks the host to stream at.
///
/// `host` is the host's own `quality` preference, which is what a device that
/// picks nothing has always had. The three named presets are the *host's*
/// table (`profile_defaults.presets`) chosen by this device instead; `custom`
/// is this device's own numbers inside the range the host publishes; `auto`
/// walks the three named rows by itself from what the connection measures.
enum RemoteStreamPreset: String, CaseIterable, Sendable {
    case host, performance, balanced, quality, custom, auto

    var title: String {
        switch self {
        case .host: Strings.streamPresetHost
        case .performance: Strings.streamPresetPerformance
        case .balanced: Strings.streamPresetBalanced
        case .quality: Strings.streamPresetQuality
        case .custom: Strings.streamPresetCustom
        case .auto: Strings.streamPresetAuto
        }
    }
}

/// The three rows `auto` moves between, slow link first. They are the host's
/// rows by name; the numbers behind them are the host's to publish.
enum RemoteStreamTier: Int, CaseIterable, Comparable, Sendable {
    case performance = 0, balanced, quality

    var wire: String {
        switch self {
        case .performance: "performance"
        case .balanced: "balanced"
        case .quality: "quality"
        }
    }
    var preset: RemoteStreamPreset {
        switch self {
        case .performance: .performance
        case .balanced: .balanced
        case .quality: .quality
        }
    }
    var lower: RemoteStreamTier? { RemoteStreamTier(rawValue: rawValue - 1) }
    var higher: RemoteStreamTier? { RemoteStreamTier(rawValue: rawValue + 1) }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The device's choice, kept apart from `RemotePreferences` so the two panels
/// that write them can never overwrite each other's copy.
struct RemoteStreamChoice: Equatable, Sendable {
    var preset: RemoteStreamPreset = .host
    var customFPS = 60
    var customBitrateKbps = 20_000

    static let storageKey = "omodachi.remoteStream.v1"

    static func load(_ defaults: UserDefaults = AppDefaults.shared) -> RemoteStreamChoice {
        var value = RemoteStreamChoice()
        guard let stored = defaults.dictionary(forKey: storageKey) else { return value }
        if let raw = stored["preset"] as? String, let preset = RemoteStreamPreset(rawValue: raw) { value.preset = preset }
        if let fps = stored["customFPS"] as? Int, [30, 60].contains(fps) { value.customFPS = fps }
        if let rate = stored["customBitrateKbps"] as? Int, (4_000...40_000).contains(rate) { value.customBitrateKbps = rate }
        return value
    }

    func save(_ defaults: UserDefaults = AppDefaults.shared) {
        defaults.set(["preset": preset.rawValue, "customFPS": customFPS, "customBitrateKbps": customBitrateKbps],
                     forKey: Self.storageKey)
    }
}

/// What one create/resize says about rate, resolved from the choice, the tier
/// `auto` is on, and what the host publishes.
struct RemoteRatePlan: Equatable, Sendable {
    /// `nil` = say nothing: the host's preference applies, and a core from
    /// before STREAM-1 (which refuses unknown fields) is not sent one.
    let preset: String?
    let adaptive: Bool?
    let fps: Int
    let bitrateKbps: Int

    /// Numbers for a core that does not publish the presets. It cannot honour
    /// a device's choice above its own preference (it caps the request), so
    /// the most this can do is ask; a host that does publish them is never
    /// second-guessed with these.
    static let olderHostTable: [RemoteStreamTier: (Int, Int)] = [
        .performance: (30, 8_000), .balanced: (60, 12_000), .quality: (60, 20_000),
    ]

    static func resolve(_ choice: RemoteStreamChoice, tier: RemoteStreamTier,
                        host: RemoteHostPreferences?) -> RemoteRatePlan {
        let published = host?.presets != nil
        func named(_ tier: RemoteStreamTier, adaptive: Bool) -> RemoteRatePlan {
            let rates = host?.presets?[tier.wire].map { ($0.fps, $0.bitrate_kbps) }
                ?? olderHostTable[tier] ?? (60, 12_000)
            return RemoteRatePlan(preset: published ? tier.wire : nil, adaptive: published ? adaptive : nil,
                                  fps: rates.0, bitrateKbps: rates.1)
        }
        switch choice.preset {
        case .host:
            let rates = host?.quality
            return RemoteRatePlan(preset: nil, adaptive: nil,
                                  fps: rates?.fps ?? RemoteQuality().fps,
                                  bitrateKbps: rates?.bitrate_kbps ?? RemoteQuality().bitrate_kbps)
        case .performance: return named(.performance, adaptive: false)
        case .balanced: return named(.balanced, adaptive: false)
        case .quality: return named(.quality, adaptive: false)
        case .auto: return named(tier, adaptive: true)
        case .custom:
            let range = host?.custom
            let fps = (range?.fps ?? [30, 60]).contains(choice.customFPS) ? choice.customFPS : 60
            let low = range?.min_bitrate_kbps ?? 4_000, high = range?.max_bitrate_kbps ?? 40_000
            return RemoteRatePlan(preset: published ? "custom" : nil, adaptive: published ? false : nil,
                                  fps: fps, bitrateKbps: min(high, max(low, choice.customBitrateKbps)))
        }
    }
}

/// One second of the Sunshine connection, as moonlight-common-c counted it.
/// Decode time is deliberately absent: the display layer decodes internally
/// and reports no per-frame timing (Vendor/Moonlight/PATCHES.md, STREAM-1).
struct RemoteStreamStats: Equatable, Sendable {
    var window: Double
    var totalFrames: Int
    var receivedFrames: Int
    var networkDroppedFrames: Int
    var renderedFrames: Int?
    var rttMs: Int?
    var rttVarianceMs: Int?
    var hostLatencyMs: Double
    var codec: String

    var receivedFPS: Double { window > 0 ? Double(receivedFrames) / window : 0 }
    var renderedFPS: Double? { renderedFrames.map { window > 0 ? Double($0) / window : 0 } }
    /// Frames the network lost as a share of the frames the host sent.
    var dropRate: Double { totalFrames > 0 ? Double(networkDroppedFrames) / Double(totalFrames) : 0 }

    init(window: Double, totalFrames: Int, receivedFrames: Int, networkDroppedFrames: Int,
         renderedFrames: Int? = nil, rttMs: Int? = nil, rttVarianceMs: Int? = nil,
         hostLatencyMs: Double = 0, codec: String = "h264") {
        self.window = window
        self.totalFrames = totalFrames
        self.receivedFrames = receivedFrames
        self.networkDroppedFrames = networkDroppedFrames
        self.renderedFrames = renderedFrames
        self.rttMs = rttMs
        self.rttVarianceMs = rttVarianceMs
        self.hostLatencyMs = hostLatencyMs
        self.codec = codec
    }

    /// The `stats` event `OMRemoteClient` emits.
    init?(event: [String: Any]) {
        func int(_ key: String) -> Int? { (event[key] as? NSNumber)?.intValue }
        guard let window = (event["window"] as? NSNumber)?.doubleValue, window > 0,
              let total = int("total_frames"), let received = int("received_frames"),
              let dropped = int("network_dropped_frames") else { return nil }
        self.init(window: window, totalFrames: total, receivedFrames: received, networkDroppedFrames: dropped,
                  renderedFrames: int("rendered_frames"), rttMs: int("rtt_ms"), rttVarianceMs: int("rtt_variance_ms"),
                  hostLatencyMs: (event["host_latency_ms"] as? NSNumber)?.doubleValue ?? 0,
                  codec: event["codec"] as? String ?? "h264")
    }

    /// A measurement, not a sentence: the same line in both languages, and
    /// the same one `RemoteSessionTrace.stats` writes.
    var line: String {
        let codecName = codec == "hevc" ? "HEVC" : "H.264"
        let rtt = rttMs.map { "\($0)±\(rttVarianceMs ?? 0) ms" } ?? "– ms" // non-copy: a measurement
        let rendered = renderedFPS.map { String(format: "%.0f", $0) } ?? "–" // non-copy: a measurement
        return String(format: "%@ · %.0f/%@ fps · RTT %@ · drop %.1f %% · host %.1f ms", // non-copy: a measurement
                      codecName, receivedFPS, rendered, rtt, dropRate * 100, hostLatencyMs)
    }
}

/// STREAM-1 §3. `自动`: start at 画质优先, step down one row after five
/// seconds in a row of a bad link, step up one row after sixty seconds in a
/// row of a clean one. Both directions have hysteresis — a separate, stricter
/// threshold to count as clean than to count as bad, a settling time after
/// every change during which nothing is counted, and a longer wait before
/// climbing back to a row it just fell from — so a link that sits on a
/// threshold cannot make the stream flap. A pure value: the controller feeds
/// it samples and acts on what it answers.
struct RemoteAdaptiveQuality: Equatable, Sendable {
    struct Thresholds: Equatable, Sendable {
        /// Bad: either of these, for `downAfter` seconds in a row.
        var badDropRate = 0.05
        var badRttMs = 80
        var downAfter: Double = 5
        /// Clean: both of these, for `upAfter` seconds in a row.
        var cleanDropRate = 0.01
        var cleanRttMs = 40
        var upAfter: Double = 60
        /// After any change the new stream has to settle (re-dial, IDR, the
        /// first second's counters) before it is judged.
        var settle: Double = 10
        /// Climbing back into a row this controller fell out of waits this
        /// much longer, each time it happens.
        var reentryPenalty: Double = 60
    }

    enum Decision: Equatable, Sendable {
        case hold
        case step(to: RemoteStreamTier, why: String)
    }

    let thresholds: Thresholds
    private(set) var tier: RemoteStreamTier
    private var badFor: Double = 0
    private var cleanFor: Double = 0
    private var settling: Double
    /// How many times each row has been fallen out of this session.
    private var fallen: [RemoteStreamTier: Int] = [:]

    init(start: RemoteStreamTier = .quality, thresholds: Thresholds = .init()) {
        self.tier = start
        self.thresholds = thresholds
        self.settling = thresholds.settle
    }

    /// One window of the connection. Answers what to do *now*; the controller
    /// applies it (a re-dial) and the next samples are judged at the new row.
    mutating func observe(_ sample: RemoteStreamStats) -> Decision {
        let seconds = max(0.1, min(5, sample.window))
        if settling > 0 {
            settling -= seconds
            return .hold
        }
        let rttBad = sample.rttMs.map { $0 > thresholds.badRttMs } ?? false
        let bad = sample.dropRate > thresholds.badDropRate || rttBad
        let clean = sample.dropRate <= thresholds.cleanDropRate
            && (sample.rttMs.map { $0 <= thresholds.cleanRttMs } ?? true)
        if bad { badFor += seconds; cleanFor = 0 }
        else if clean { cleanFor += seconds; badFor = 0 }
        else { badFor = 0; cleanFor = 0 } // the gap between the two thresholds counts for neither
        if badFor >= thresholds.downAfter, let next = tier.lower {
            fallen[tier, default: 0] += 1
            let why = String(format: "drop=%.1f%% rtt=%@ for %.0fs", sample.dropRate * 100, // non-copy: a trace
                             sample.rttMs.map(String.init) ?? "-", badFor)
            return change(to: next, why: why)
        }
        if let next = tier.higher {
            let wait = thresholds.upAfter + thresholds.reentryPenalty * Double(fallen[next, default: 0])
            if cleanFor >= wait {
                return change(to: next, why: String(format: "clean for %.0fs", cleanFor)) // non-copy: a trace
            }
        }
        return .hold
    }

    private mutating func change(to next: RemoteStreamTier, why: String) -> Decision {
        tier = next
        badFor = 0
        cleanFor = 0
        settling = thresholds.settle
        return .step(to: next, why: why)
    }
}

/// What this device can decode. HEVC is declared only where VideoToolbox says
/// it is decoded in hardware; the simulator's answer is its host Mac's.
enum RemoteDecoderSupport {
    static let hevc: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    static var codecs: [String] { hevc ? ["h264", "hevc"] : ["h264"] }
}

/// STREAM-1. The last second of the running stream, for ⑥'s diagnostics line.
/// Its own object so that only the view showing it redraws once a second —
/// PERF-1 measured what a per-frame `@Published` on the controller costs.
@MainActor final class RemoteStreamMonitor: ObservableObject {
    struct Reading: Equatable, Sendable {
        let stats: RemoteStreamStats
        let preset: RemoteStreamPreset
        let tier: RemoteStreamTier
        let fps: Int?
        let bitrateKbps: Int?
    }
    @Published private(set) var reading: Reading?

    func publish(_ stats: RemoteStreamStats, preset: RemoteStreamPreset, tier: RemoteStreamTier,
                 session: RemoteSessionDTO) {
        reading = Reading(stats: stats, preset: preset, tier: tier,
                          fps: session.profile?.fps, bitrateKbps: session.profile?.bitrate_kbps)
    }

    func clear() { reading = nil }

    /// Planned rate and the measured second, as one measurement line.
    var line: String? {
        guard let reading else { return nil }
        let planned = reading.fps.map { fps in
            "\(fps) fps · \(String(format: "%.1f", Double(reading.bitrateKbps ?? 0) / 1000)) Mbps · " // non-copy: a measurement
        } ?? ""
        return planned + reading.stats.line
    }
}
