import Foundation

/// `GET /v1/voice/capabilities` — one document covering the uplink, Voxtype and
/// the level fan-out (`omodachi-core/docs/voice.md`). Nothing here is inferred:
/// if the host says dictation is unavailable it says why, and if Voxtype is
/// missing it hands over the official installer's own command line.
struct VoiceCapabilities: Decodable, Equatable, Sendable {
    struct Uplink: Decodable, Equatable, Sendable {
        let supported: Bool
        let available: Bool
        let active: Bool
        let transport: String
        let endpoint: String
        let sourceName: String?
        let format: String
        let rate: Int
        let channels: Int
        let frameSamples: Int
        let frameBytes: Int
        let maxQueuedFrames: Int
        let reason: String?
        enum CodingKeys: String, CodingKey {
            case supported, available, active, transport, endpoint, format, rate, channels, reason
            case sourceName = "source_name", frameSamples = "frame_samples"
            case frameBytes = "frame_bytes", maxQueuedFrames = "max_queued_frames"
        }
        /// The PCM contract this client can actually produce. A host that wants
        /// a different rate gets no audio rather than a resampled lie.
        var usable: Bool {
            supported && available && transport == "websocket" && endpoint == "/v1/voice/uplink"
                && format == "s16le" && rate == 48_000 && channels == 1
                && frameSamples == 960 && frameBytes == 1920 && maxQueuedFrames == 3
        }
    }
    struct Dictation: Decodable, Equatable, Sendable {
        let available: Bool
        let active: Bool
        let targets: [String]
        /// `config` or `default_source` — which route core takes to point
        /// Voxtype at our virtual microphone. It is reported, not chosen here.
        let route: String?
        let reason: String?
    }
    struct Levels: Decodable, Equatable, Sendable {
        let available: Bool
        let hz: Int?
    }
    struct Voxtype: Decodable, Equatable, Sendable {
        let installed: Bool
        let supported: Bool
        let waitSupported: Bool
        let serviceActive: Bool
        let state: String?
        let device: String?
        let installCommand: [String]?
        let reason: String?
        enum CodingKeys: String, CodingKey {
            case installed, supported, state, device, reason
            case waitSupported = "wait_supported", serviceActive = "service_active"
            case installCommand = "install_command"
        }
    }
    let voiceUplinkEnabled: Bool
    let uplink: Uplink
    let dictation: Dictation
    let levels: Levels
    let voxtype: Voxtype
    enum CodingKeys: String, CodingKey {
        case voiceUplinkEnabled = "voice_uplink_enabled", uplink, dictation, levels, voxtype
    }

    /// Everything that has to hold before a microphone button does anything.
    var ready: Bool { voiceUplinkEnabled && uplink.usable && dictation.available && voxtype.installed }

    /// Why the button is grey, in the host's own terms. The order matters: a
    /// missing Voxtype is the answer with an installer behind it, and the
    /// preference is the answer the user can act on themselves.
    var blockedReason: String? {
        if !voxtype.installed { return "voxtype_not_installed" }
        if !voiceUplinkEnabled { return "voice_uplink_disabled" }
        if let reason = dictation.reason, !dictation.available { return reason }
        if let reason = uplink.reason, !uplink.usable { return reason }
        if !uplink.usable { return "audio_input_unsupported" }
        if !dictation.available { return "dictation_unavailable" }
        return nil
    }
}

/// `POST /v1/voice/dictation:stop`. `text` is absent for `target: host`,
/// where the words were typed into the focused host window instead.
struct VoiceDictationResult: Decodable, Equatable, Sendable {
    let target: String?
    let route: String?
    let text: String?
    let chars: Int?
    let status: String?
    let sourceName: String?
    let state: String?
    let deliveredToHost: Bool?
    let configChanged: Bool?
    enum CodingKeys: String, CodingKey {
        case target, route, text, chars, status, state
        case sourceName = "source_name", deliveredToHost = "delivered_to_host", configChanged = "config_changed"
    }
}

/// Where the transcribed words go. The Agent composer and the Panel search
/// field take them here; under Remote they are typed into the host's own
/// focused window, because that is where the user is looking.
enum VoiceTarget: String, Sendable, Equatable {
    case client, host, both
}

/// One row off the level fan-out, throttled by core to 20 Hz.
struct VoiceLevel: Decodable, Equatable, Sendable {
    let seq: Int?
    let peak: Double?
    let rms: Double?
    let vad: Bool?

    /// dBFS peak mapped onto the 28-high meter. -60 dB is the floor; below it
    /// the line is flat rather than noise amplified into a picture.
    var bar: Double {
        guard let peak, peak.isFinite else { return 0 }
        return min(1, max(0, (peak + 60) / 60))
    }
}

/// `voice.transcript`, the device event core publishes alongside the stop
/// response, so a second device watching the stream sees the same words.
public struct VoiceTranscriptEvent: Decodable, Equatable, Sendable {
    public let text: String
    public let chars: Int?
    public let status: String?
}
