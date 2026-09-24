import Foundation

/// `/v1/remote` exactly as `omodachi-core/docs/remote-api.md` declares it.
/// A host has at most one session; everything about it lives in one document
/// with a single monotonic `revision`. There are no lease epochs, geometry
/// epochs or connection generations here, and nothing in this file invents one.

enum RemoteMode: String, Codable, Sendable, CaseIterable {
    case extend, takeover
    var title: String { self == .extend ? Strings.remoteModeExtend : Strings.remoteModeTakeover }
}

enum RemoteBackend: String, Codable, Sendable, CaseIterable {
    case sunshine, vnc
    var title: String { self == .sunshine ? "Sunshine" : "VNC · WSS" } // non-copy: backend names
}

enum RemotePlacement: String, Codable, Sendable, CaseIterable { case right, left, above, below }

struct RemotePixels: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

struct RemotePoints: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
}

struct RemoteRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct RemoteProfileDTO: Codable, Equatable, Sendable {
    let output_id: String
    let output_mode_pixels: RemotePixels
    let output_scale: Double
    let logical_size: RemotePoints
    let stream_pixels: RemotePixels
    let fps: Int
    let bitrate_kbps: Int
    let codec: String
    let dynamic_range: String
}

/// The two shapes `remote-api.md` documents, distinguished by `backend`.
struct RemoteConnectionDTO: Decodable, Equatable, Sendable {
    let backend: RemoteBackend
    let outputID: String
    /// sunshine
    let host: String?
    let httpsPort: Int?
    let appName: String?
    let streamPixels: RemotePixels?
    let fps: Int?
    /// vnc
    let transport: String?
    let path: String?
    let framebufferPixels: RemotePixels?
    /// REMOTE-6. What WayVNC announces in `ServerInit` before it corrects
    /// itself: the compositor's logical size. A host that does not name it is
    /// one that serves a single size, so it falls back to `framebufferPixels`.
    let initialFramebufferPixels: RemotePixels?

    enum CodingKeys: String, CodingKey {
        case backend, host, transport, path, fps
        case outputID = "output_id", httpsPort = "https_port", appName = "app_name"
        case streamPixels = "stream_pixels", framebufferPixels = "framebuffer_pixels"
        case initialFramebufferPixels = "initial_framebuffer_pixels"
    }

    /// Pixels the client will actually decode, whichever backend is in use.
    var decodedPixels: RemotePixels? { streamPixels ?? framebufferPixels }

    var sunshine: Sunshine? {
        guard backend == .sunshine, let host, !host.isEmpty, let httpsPort, (1...65535).contains(httpsPort),
              let appName, !appName.isEmpty, let streamPixels, streamPixels.width > 0, streamPixels.height > 0
        else { return nil }
        return Sunshine(host: host, httpsPort: httpsPort, appName: appName, outputID: outputID,
                        streamPixels: streamPixels, fps: fps ?? 60)
    }
    var vnc: VNC? {
        guard backend == .vnc, transport == "wss", let path,
              path.hasPrefix("/v1/remote/sessions/rs_"), path.hasSuffix("/vnc"), path.count <= 128,
              let framebufferPixels, framebufferPixels.width > 0, framebufferPixels.height > 0
        else { return nil }
        return VNC(path: path, outputID: outputID, framebufferPixels: framebufferPixels,
                   initialFramebufferPixels: initialFramebufferPixels ?? framebufferPixels)
    }

    struct Sunshine: Equatable, Sendable {
        let host: String
        let httpsPort: Int
        let appName: String
        let outputID: String
        let streamPixels: RemotePixels
        let fps: Int
    }
    /// Nothing is exposed on the LAN: WayVNC is reachable only through the
    /// host's own authenticated bridge on the connection this device pinned.
    ///
    /// REMOTE-6: WayVNC shows one client two framebuffer sizes.
    /// `initialFramebufferPixels` is the compositor's logical size, which its
    /// `ServerInit` announces, and `framebufferPixels` is the owned output's
    /// buffer pixels, which it serves from the first `NewFBSize` rect onwards.
    /// The larger is an upper sanity bound on any frame, never an assertion
    /// about a particular one; the authority is always the decoded frame.
    struct VNC: Equatable, Sendable {
        let path: String
        let outputID: String
        let framebufferPixels: RemotePixels
        let initialFramebufferPixels: RemotePixels
    }
}

struct RemoteSessionDTO: Decodable, Equatable, Sendable {
    let id: String
    let backend: RemoteBackend
    let mode: RemoteMode
    let state: String
    let revision: Int
    let profile: RemoteProfileDTO?
    let connection: RemoteConnectionDTO?
    let ttlSeconds: Double?
    let placement: RemotePlacement?
    let lockLocalInput: Bool?
    let reason: String?
    /// STREAM-1. Which preset the host planned this session's rates from. A
    /// host from before STREAM-1 does not say.
    let quality: Quality?
    struct Quality: Decodable, Equatable, Sendable {
        let preset: String
        let adaptive: Bool
    }
    enum CodingKeys: String, CodingKey {
        case id, backend, mode, state, revision, profile, connection, placement, reason, quality
        case ttlSeconds = "ttl_seconds", lockLocalInput = "lock_local_input"
    }
    /// `ready` is the only state in which a client may decode and send input.
    var isReady: Bool { state == "ready" }
    var isTerminal: Bool { state == "released" || state == "failed" }
}

/// REMOTE-4. What `remote.session.changed` carries, for the one client that is
/// holding that session. It is not a snapshot and is never treated as one: the
/// session itself is re-read from the host before anything acts on it.
public struct RemoteSessionChange: Equatable, Sendable {
    public let id: String
    public let revision: Int
    public let state: String
    public let reason: String?
    public init(id: String, revision: Int, state: String, reason: String?) {
        self.id = id
        self.revision = revision
        self.state = state
        self.reason = reason
    }
}

struct RemoteCapabilitiesDTO: Decodable, Equatable, Sendable {
    struct Backend: Decodable, Equatable, Sendable {
        let available: Bool
        let reason: String?
        /// A-60's one backend-dependent quick action. Leo's host publishes
        /// `"audio": false` for the VNC leg — RFB over a WebSocket has no audio
        /// channel — and nothing at all for Sunshine, which carries Opus. So
        /// absent means "yes", and only an explicit `false` dims the control.
        let audio: Bool?
    }
    struct EncoderLimits: Decodable, Equatable, Sendable {
        let max_width: Int
        let max_height: Int
        let max_pixels: Int
        let max_fps: Int
        let max_bitrate_kbps: Int
        let codecs: [String]
    }
    let backends: [String: Backend]
    let modes: [String]
    let placement_options: [String]
    let lock_local_input_supported: Bool
    let encoder_limits: EncoderLimits?
    /// SPEC-I: what a session without an explicit `backend` gets. A client with
    /// no opinion shows this rather than inventing a constant of its own, which
    /// is what made core say sunshine while this app said vnc.
    let default_backend: RemoteBackend?
    /// REMOTE-SAFE-1: the host takes `bar_occlusion_points`. Absent on a host
    /// from before it, which is the same as `false`.
    var bar_occlusion: Bool? = nil

    func available(_ backend: RemoteBackend) -> Bool { backends[backend.rawValue]?.available == true }
    /// Whether this backend can carry the host's sound at all.
    func carriesAudio(_ backend: RemoteBackend) -> Bool { backends[backend.rawValue]?.audio != false }
    func reason(_ backend: RemoteBackend) -> String? { backends[backend.rawValue]?.reason }

    /// The backend to use for "自动": the host's answer while it is usable,
    /// then whatever is available, sunshine first.
    var resolvedDefault: RemoteBackend {
        if let value = default_backend, available(value) { return value }
        if available(.sunshine) { return .sunshine }
        if available(.vnc) { return .vnc }
        return default_backend ?? .sunshine
    }
}

/// Study 03 §15's table, implemented as written: every `reason` core can put in
/// `capabilities` or in a create refusal becomes one sentence a person can read
/// and act on, plus the exits that sentence implies.
///
/// `sunshine_assets_missing` is the one special row: it arrives with
/// `available: true`, so it is a notice about quality, not a refusal.
enum RemoteReasonCopy {
    struct Entry: Equatable, Sendable {
        let sentence: String
        /// A notice next to a backend that still works.
        let isAdvisory: Bool
        /// Exits, in the order Study 03 lists them.
        let exits: [Exit]
    }

    enum Exit: String, Equatable, Sendable {
        case useVNC, howToFix, retry, continueAnyway, repairSunshinePairing, takeOver, later, none

        var title: String {
            switch self {
            case .useVNC: Strings.remoteUseVNC
            case .howToFix: Strings.remoteExitHowToFix
            case .retry: Strings.actionRetry
            case .continueAnyway: Strings.remoteExitContinue
            case .repairSunshinePairing: Strings.remotePairAgain
            case .takeOver: Strings.remoteExitTakeOver
            case .later: Strings.remoteExitLater
            case .none: ""
            }
        }
    }

    /// I18N-1 §2: the shape of a refusal lives here — advisory or not, and
    /// which exits it offers. The sentence itself comes from `ReasonText`,
    /// where both languages are filled in.
    struct Shape: Equatable, Sendable {
        let isAdvisory: Bool
        let exits: [Exit]
    }

    static let shapes: [String: Shape] = [
        "sunshine_desktop_unavailable": .init(isAdvisory: false, exits: [.useVNC, .howToFix]),
        "sunshine_control_unavailable": .init(isAdvisory: false, exits: [.retry, .useVNC]),
        "backend_not_installed": .init(isAdvisory: false, exits: [.useVNC]),
        "sunshine_assets_missing": .init(isAdvisory: true, exits: [.continueAnyway, .howToFix]),
        "wayvnc_0_10_1_required": .init(isAdvisory: false, exits: []),
        "remote_runtime_unavailable": .init(isAdvisory: false, exits: [.later]),
        "media_pairing_required": .init(isAdvisory: false, exits: [.repairSunshinePairing]),
        "remote_session_exists": .init(isAdvisory: false, exits: [.takeOver]),
        "host_waking": .init(isAdvisory: true, exits: []),
        "dynamic_resolution_policy_denied": .init(isAdvisory: true, exits: []),
    ]

    /// N-23: an unmapped reason still says something. `ReasonText.unknown`
    /// puts the code in brackets after a sentence rather than on its own, so
    /// nothing is swallowed and nothing is a bare identifier on screen.
    /// `host_waking` is the one row with no sentence: the picture is already
    /// telling that story.
    static func entry(_ reason: String) -> Entry {
        let shape = shapes[reason] ?? Shape(isAdvisory: false, exits: [])
        let sentence = reason == "host_waking" ? "" : ReasonText.message(reason, domain: .remote)
        return Entry(sentence: sentence, isAdvisory: shape.isAdvisory, exits: shape.exits)
    }

    static func sentence(_ reason: String) -> String { entry(reason).sentence }
}

/// What this device can actually decode. VideoToolbox H.264 on every shipping
/// iPhone/iPad tops out at 4096x2304 60fps; the planner checks this separately
/// from the host encoder limits, so it is declared and never inferred.
/// STREAM-1: HEVC is declared where VideoToolbox decodes it in hardware; the
/// host then picks it whenever its encoder serves it too.
struct RemoteDecoderLimits: Encodable, Equatable, Sendable {
    var max_width = 4096
    var max_height = 2304
    var max_pixels = 9_437_184
    var max_fps = 60
    var max_bitrate_kbps = 40_000
    var codecs = RemoteDecoderSupport.codecs
}

struct RemoteQuality: Encodable, Equatable, Sendable {
    var max_pixels = 4_000_000
    var fps = 60
    var bitrate_kbps = 20_000
    /// WayVNC serves the framebuffer itself rather than an encoded stream sized
    /// to a budget, so for VNC the pixel ceiling is the decoder's, not a
    /// quality choice (docs/wayvnc.md).
    static func forBackend(_ backend: RemoteBackend) -> RemoteQuality {
        var value = RemoteQuality()
        if backend == .vnc { value.max_pixels = RemoteDecoderLimits().max_pixels }
        return value
    }
    /// Host quality affects rate only. The pixel budget, viewport, orientation
    /// and decoder constraints stay Remote-owned, exactly as they did when the
    /// lease API carried `profile_defaults` for the same preference.
    func applying(_ defaults: RemoteHostPreferences.Quality?) -> RemoteQuality {
        guard let defaults else { return self }
        var value = self
        value.fps = min(RemoteDecoderLimits().max_fps, max(1, defaults.fps))
        value.bitrate_kbps = min(RemoteDecoderLimits().max_bitrate_kbps, max(1_000, defaults.bitrate_kbps))
        return value
    }
}

/// `GET /v1/preferences`. The host's own quality preference
/// (`performance | balanced | quality`) reaches the client already resolved to
/// a frame rate and a bitrate in `profile_defaults`; nothing here re-derives
/// that mapping, and nothing else in the document is a Remote input.
struct RemoteHostPreferences: Decodable, Equatable, Sendable {
    struct Quality: Decodable, Equatable, Sendable {
        let fps: Int
        let bitrate_kbps: Int
    }
    /// STREAM-1: what a device may choose instead of the host's default. A
    /// host from before STREAM-1 publishes only `quality`.
    struct Custom: Decodable, Equatable, Sendable {
        let fps: [Int]
        let min_bitrate_kbps: Int
        let max_bitrate_kbps: Int
    }
    struct ProfileDefaults: Decodable, Equatable, Sendable {
        let quality: Quality
        var preset: String? = nil
        var presets: [String: Quality]? = nil
        var custom: Custom? = nil
    }
    let profile_defaults: ProfileDefaults?
    /// Absent, malformed or out-of-range defaults leave the request untouched
    /// rather than substituting an invented rate.
    var quality: Quality? {
        guard let value = profile_defaults?.quality,
              (1...240).contains(value.fps), (64...250_000).contains(value.bitrate_kbps) else { return nil }
        return value
    }
    /// The three rows, only when the host publishes all three sanely.
    var presets: [String: Quality]? {
        guard let rows = profile_defaults?.presets,
              ["performance", "balanced", "quality"].allSatisfy({ name in
                  rows[name].map { (1...240).contains($0.fps) && (64...250_000).contains($0.bitrate_kbps) } ?? false
              }) else { return nil }
        return rows
    }
    /// The host's own row name, e.g. `performance`.
    var preset: String? { profile_defaults?.preset }
    var custom: Custom? {
        guard let value = profile_defaults?.custom, !value.fps.isEmpty,
              value.min_bitrate_kbps <= value.max_bitrate_kbps else { return nil }
        return value
    }
}

struct RemoteGeometryRequest: Encodable, Equatable, Sendable {
    let viewport_points: RemotePoints
    let orientation: String
    var logical_long_edge: Int
    var quality: RemoteQuality
    var decoder = RemoteDecoderLimits()
    /// STREAM-1. Absent unless this device chose something other than the
    /// host's default, so a host from before STREAM-1 is never sent a field it
    /// would refuse.
    var quality_preset: String? = nil
    var adaptive: Bool? = nil
    /// REMOTE-SAFE-1. How much of each end of the host's bar this display's
    /// corners hide, in points. Sent only to a host whose capabilities say
    /// `bar_occlusion`; absent, a host from before it is never refused.
    var bar_occlusion_points: RemoteBarOcclusion? = nil
}

struct RemoteCreateRequest: Encodable, Sendable {
    let backend: RemoteBackend
    let mode: RemoteMode
    let viewport_points: RemotePoints
    let orientation: String
    let logical_long_edge: Int
    let quality: RemoteQuality
    let decoder: RemoteDecoderLimits
    let placement: RemotePlacement
    let lock_local_input: Bool
    let ttl_seconds: Double
    let quality_preset: String?
    let adaptive: Bool?
    let bar_occlusion_points: RemoteBarOcclusion?
    init(backend: RemoteBackend, mode: RemoteMode, geometry: RemoteGeometryRequest,
         placement: RemotePlacement = .right, lockLocalInput: Bool = false, ttlSeconds: Double) {
        self.backend = backend
        self.mode = mode
        viewport_points = geometry.viewport_points
        orientation = geometry.orientation
        logical_long_edge = geometry.logical_long_edge
        quality = geometry.quality
        decoder = geometry.decoder
        self.placement = placement
        // N-25: v1 does lock, but only when the takeover card's switch was
        // turned on next to the sentence that says what it costs.
        lock_local_input = mode == .takeover && lockLocalInput
        ttl_seconds = ttlSeconds
        quality_preset = geometry.quality_preset
        adaptive = geometry.adaptive
        bar_occlusion_points = geometry.bar_occlusion_points
    }
}

struct RemoteResizeRequest: Encodable, Sendable {
    let expected_revision: Int
    let viewport_points: RemotePoints
    let orientation: String
    let logical_long_edge: Int
    let quality: RemoteQuality
    let decoder: RemoteDecoderLimits
    let quality_preset: String?
    let adaptive: Bool?
    let bar_occlusion_points: RemoteBarOcclusion?
    init(expectedRevision: Int, geometry: RemoteGeometryRequest) {
        expected_revision = expectedRevision
        viewport_points = geometry.viewport_points
        orientation = geometry.orientation
        logical_long_edge = geometry.logical_long_edge
        quality = geometry.quality
        decoder = geometry.decoder
        quality_preset = geometry.quality_preset
        adaptive = geometry.adaptive
        bar_occlusion_points = geometry.bar_occlusion_points
    }
}

struct RemoteBackendRequest: Encodable, Sendable {
    let expected_revision: Int
    let backend: RemoteBackend
}

/// Telemetry. `validate_presented_geometry` records whether the rectangle was a
/// correct aspect fit; the result blocks nothing on either side.
struct RemotePresentedRequest: Encodable, Sendable {
    let revision: Int
    let video_rect_points: RemoteRect
    let decoded_pixels: RemotePixels
}

struct RemoteHeartbeatDTO: Decodable, Sendable {
    let revision: Int
    let state: String
}

struct RemotePresentedDTO: Decodable, Sendable {
    let accepted: Bool
    let reason: String?
    let revision: Int
}

struct RemoteReleaseDTO: Decodable, Sendable {
    let released: Bool
    let errors: [String]
}

/// The bounded code set from `remote-api.md`'s error table, plus the daemon
/// codes the boundary can raise ahead of the Remote manager.
struct RemoteRequestError: Error, Equatable, Sendable {
    let code: String
    let status: Int
    /// `409 remote_session_exists` names who holds the host (SPEC-I §1.2), so
    /// "end it on your other device" can say which device.
    var owner: Owner?

    struct Owner: Equatable, Sendable {
        let sessionID: String
        let deviceID: String
        let deviceName: String
        let mode: RemoteMode?
        let backend: RemoteBackend?
        let startedAt: Date?
    }

    init(code: String, status: Int, owner: Owner? = nil) {
        self.code = code
        self.status = status
        self.owner = owner
    }

    var isStaleRevision: Bool { code == "stale_revision" }
    var isSessionExists: Bool { code == "remote_session_exists" }
    var isDynamicResolutionDenied: Bool { code == "dynamic_resolution_policy_denied" }

    var userMessage: String {
        if code == "remote_session_exists", let owner {
            return Strings.remoteSessionOwnedBy(owner.deviceName, owner.mode?.title ?? Strings.panelRemote)
        }
        return ReasonText.message(code, domain: .remote, status: status)
    }
}

/// The Remote half of the host client, as a seam. The controller's state
/// machine can then be exercised against a fake without a socket.
protocol RemoteSessionServing: Sendable {
    func remoteCapabilities() async throws -> RemoteCapabilitiesDTO
    func remoteHostPreferences() async throws -> RemoteHostPreferences
    func createRemoteSession(_ body: RemoteCreateRequest) async throws -> RemoteSessionDTO
    func remoteSession(id: String) async throws -> RemoteSessionDTO
    func resizeRemoteSession(id: String, body: RemoteResizeRequest) async throws -> RemoteSessionDTO
    func switchRemoteBackend(id: String, body: RemoteBackendRequest) async throws -> RemoteSessionDTO
    func heartbeatRemoteSession(id: String) async throws -> RemoteHeartbeatDTO
    func reportRemotePresented(id: String, body: RemotePresentedRequest) async throws -> RemotePresentedDTO
    func releaseRemoteSession(id: String) async throws -> RemoteReleaseDTO
}

/// A seam that only the real client has to answer. A test double exercising the
/// session state machine keeps the host's own defaults out of the picture.
extension RemoteSessionServing {
    func remoteHostPreferences() async throws -> RemoteHostPreferences {
        RemoteHostPreferences(profile_defaults: nil)
    }
}
