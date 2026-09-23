import Foundation
import UIKit

/// The media leg of a Remote session. It connects one `connection` document,
/// reports the first frame it actually presented, and stops. Session identity,
/// geometry and the host transaction stay in `RemoteSessionController`.
@MainActor protocol RemoteBackendDriver: AnyObject {
    /// The last presented image, kept across a resize so the old picture stays
    /// on screen until the new backend produces a frame.
    var retainedFrame: UIImage? { get }
    var isIdle: Bool { get }
    /// Decoded pixels and the rectangle they were actually drawn into.
    var onFirstFrame: ((RemotePixels, CGRect) -> Void)? { get set }
    var onStage: ((String) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    /// `profile` is the session's planned output: the host resolved its own
    /// quality preference, its encoder limits and this client's request into
    /// one frame rate and one bitrate, and that plan is what gets streamed.
    func connect(_ connection: RemoteConnectionDTO, profile: RemoteProfileDTO?) async
    func stop() async
    func setInputEnabled(_ enabled: Bool)
    /// A-43. Raise or put away the soft keyboard; answers whether it is up
    /// afterwards. Every backend has one, because the rule is the user's, not
    /// the codec's.
    func toggleKeyboard() -> Bool
    func hideKeyboard()
    /// A-64 / N-37. Which picture gestures the host has a row for right now.
    /// A gesture that is not in this set is not registered and never fires.
    func setRegisteredGestures(_ gestures: Set<RemotePictureGesture>)
    /// One of the picture's own gestures happened. The keyboard tap is not on
    /// this channel — it is local and reports through the keyboard handler.
    var onGesture: ((RemotePictureGesture) -> Void)? { get set }
    /// Operator-only (see `RemoteOperatorSupport.gesture`).
    func replayGestureForOperator(_ gesture: RemotePictureGesture)
}

extension RemoteBackendDriver {
    func replayGestureForOperator(_ gesture: RemotePictureGesture) {}
}

/// Sunshine: the managed fork, launched with this device's existing Moonlight
/// pairing identity. Core has already bound the owned output to the fork's
/// lease, so the client only launches the app named in the connection.
@MainActor final class SunshineBackendDriver: RemoteBackendDriver {
    let client: OMRemoteClient
    private let input: NativeRemoteInputAdapter
    private var generation: UInt64 = 0
    private var reportedGeneration: UInt64?
    var onFirstFrame: ((RemotePixels, CGRect) -> Void)?
    var onStage: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Sunshine pairing is a PIN typed on the host; core bridges approval
    /// through `/v1/media/pairing/*` so the plugin can approve in one step.
    /// The event keeps Moonlight's three answers apart — see
    /// `SunshinePairingEvent`.
    var onPairing: ((SunshinePairingEvent) -> Void)?
    var onGesture: ((RemotePictureGesture) -> Void)?
    /// STREAM-1. One second of the running stream, once a second.
    var onStats: ((RemoteStreamStats) -> Void)?
    private let gestures = RemoteGestureArbiter()

    init(host: String, relativeTouchpad: Bool) {
        client = OMRemoteClient(host: host)
        client.touchpadMode = relativeTouchpad
        client.forcesAbsolutePointer = RemoteOperatorSupport.forcesAbsolutePointer
        input = NativeRemoteInputAdapter(client: client)
        client.inputReceiver = input
        client.eventHandler = { [weak self] json in
            Task { @MainActor [weak self] in self?.receive(json) }
        }
        client.gestureArbiter = gestures
        client.gestureHandler = { [weak self] gesture in
            Task { @MainActor [weak self] in
                guard let self, let value = RemotePictureGesture(rawValue: gesture.rawValue) else { return }
                self.onGesture?(value)
            }
        }
    }

    func setRegisteredGestures(_ value: Set<RemotePictureGesture>) {
        gestures.updateRegistered(gestures: value.map { NSNumber(value: $0.rawValue) })
    }

    var retainedFrame: UIImage? { client.copyDisplayedFrame() }
    var isIdle: Bool { client.idle }

    func inspect() { client.inspectHost() }
    func pair(renewing: Bool = false) { client.pairHostRenewing(renewing) }

    func connect(_ connection: RemoteConnectionDTO, profile: RemoteProfileDTO?) async {
        guard let sunshine = connection.sunshine else {
            onFailure?(Strings.remoteConnectionIncomplete); return
        }
        guard client.beginLease() else {
            onFailure?(Strings.remotePreviousStreamOpen); return
        }
        client.appTitle = sunshine.appName
        client.httpsPort = Int32(sunshine.httpsPort)
        generation += 1
        reportedGeneration = nil
        client.setGeometryEpoch(0, generation: generation)
        // The rate is the host's plan for this session. A constant here asked
        // the fork's software encoder for a bitrate the host never planned and
        // silently discarded the host's own quality preference.
        let rate = Self.rate(profile: profile, connection: sunshine)
        client.start(width: Int32(sunshine.streamPixels.width), height: Int32(sunshine.streamPixels.height),
                     fps: Int32(rate.fps), bitrate: Int32(rate.bitrateKbps),
                     codec: Self.codec(profile: profile), generation: generation)
    }

    /// The planned rate, with the connection document's `fps` as the only
    /// fallback and the client's own decoder ceiling as the bound. A session
    /// that arrives without a profile is a host contract break, not a licence
    /// to invent a bitrate, so it takes the conservative end of the budget.
    static func rate(profile: RemoteProfileDTO?, connection: RemoteConnectionDTO.Sunshine) -> (fps: Int, bitrateKbps: Int) {
        let limits = RemoteDecoderLimits()
        let fps = min(limits.max_fps, max(1, profile?.fps ?? connection.fps))
        let bitrate = min(limits.max_bitrate_kbps, max(1_000, profile?.bitrate_kbps ?? 8_000))
        return (fps, bitrate)
    }

    /// STREAM-1. The host's negotiated codec, offered alone. The host only
    /// plans HEVC for a client that said it decodes it, so a device without
    /// the decoder is never asked; anything unrecognised is H.264.
    nonisolated static func codec(profile: RemoteProfileDTO?) -> String {
        profile?.codec == "hevc" && RemoteDecoderSupport.hevc ? "hevc" : "h264"
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.stop { _ in continuation.resume() }
        }
    }

    func setInputEnabled(_ enabled: Bool) {
        client.setInputEnabled(enabled, generation: generation)
        if !enabled { client.releaseInputs() }
    }

    func observeCurrentFrame() { client.observeCurrentFrame() }
    func invalidateViewportGeometry() { client.invalidateViewportGeometry() }
    func showKeyboard() { client.showKeyboard() }
    func toggleKeyboard() -> Bool { client.toggleKeyboard() }
    func hideKeyboard() { client.hideKeyboard() }
    func latchModifier(_ mask: UInt8) { client.latchModifierMask(mask) }
    func sendShortcut(_ usage: UInt16) { client.sendShortcutUsage(usage) }

    private func receive(_ json: String) {
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "pin": onPairing?(.pin(event["pin"] as? String ?? ""))
        case "paired": onPairing?(.paired)
        case "already_paired": onPairing?(.alreadyPaired(renewing: (event["renewing"] as? NSNumber)?.boolValue ?? false))
        case "unpaired": onPairing?(.unpaired)
        case "stats":
            // A measurement of the running generation only; never a stage.
            guard (event["generation"] as? NSNumber)?.uint64Value == generation,
                  let stats = RemoteStreamStats(event: event) else { return }
            onStats?(stats)
        case "error", "stop_failed":
            onFailure?(event["message"] as? String ?? Strings.remoteStreamFailed)
        case "first_frame", "frame_observation":
            guard let generation = (event["generation"] as? NSNumber)?.uint64Value,
                  generation == self.generation, reportedGeneration != generation else { return }
            func number(_ key: String) -> CGFloat { (event[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? .nan }
            let width = Int(number("width")), height = Int(number("height"))
            let rect = CGRect(x: number("x"), y: number("y"), width: number("video_width"), height: number("video_height"))
            guard width > 0, height > 0, rect.width.isFinite, rect.height.isFinite, rect.width > 0 else {
                // The client already counts this frame as reported, so its own
                // deadline will not fire again. Dropping it silently leaves the
                // session waiting forever with nothing on screen to say why.
                if type == "first_frame" {
                    onStage?(Strings.remoteFirstFrameRejected)
                }
                return
            }
            reportedGeneration = generation
            onFirstFrame?(RemotePixels(width: width, height: height), rect)
        default: onStage?(type)
        }
    }
}

/// VNC: WayVNC 0.10.1 reached through the host's own authenticated WSS bridge,
/// on the connection this device pinned. Nothing is exposed on the LAN.
@MainActor final class VNCBackendDriver: RemoteBackendDriver {
    let adapter: VNCBackendAdapter
    var onFirstFrame: ((RemotePixels, CGRect) -> Void)?
    /// REMOTE-6. Only this leg can change framebuffer size without the session
    /// asking: WayVNC opens at the compositor's logical size and corrects
    /// itself to the output's buffer pixels one update in. Sunshine renegotiates
    /// geometry through a session resize instead, so it has nothing to report.
    var onFramebufferResize: ((RemotePixels, RemotePixels) -> Void)? {
        didSet { adapter.onFramebufferResize = onFramebufferResize }
    }
    var onGesture: ((RemotePictureGesture) -> Void)?
    private let gestures = RemoteGestureArbiter()
    var onStage: ((String) -> Void)? {
        didSet { adapter.onStage = onStage }
    }
    var onFailure: ((String) -> Void)? {
        didSet { adapter.onFailure = onFailure }
    }

    init(adapter: VNCBackendAdapter) {
        self.adapter = adapter
        adapter.onFrameReady = { [weak self] pixels, rect in self?.onFirstFrame?(pixels, rect) }
        adapter.view.gestureArbiter = gestures
        adapter.view.onGesture = { [weak self] gesture in
            guard let self, let value = RemotePictureGesture(rawValue: gesture.rawValue) else { return }
            self.onGesture?(value)
        }
    }

    func setRegisteredGestures(_ value: Set<RemotePictureGesture>) {
        gestures.updateRegistered(gestures: value.map { NSNumber(value: $0.rawValue) })
    }

    var retainedFrame: UIImage? { adapter.snapshotImage }
    var isIdle: Bool { adapter.phase == .idle }

    /// WayVNC serves the framebuffer itself, so the planned encoder rate is not
    /// an input on this leg; the profile is accepted and ignored.
    func connect(_ connection: RemoteConnectionDTO, profile: RemoteProfileDTO?) async {
        guard let vnc = connection.vnc else {
            onFailure?(Strings.remoteConnectionIncomplete); return
        }
        await adapter.connect(vnc)
    }
    func stop() async { await adapter.stop() }
    func setInputEnabled(_ enabled: Bool) { adapter.enableInput(enabled) }
    func toggleKeyboard() -> Bool { adapter.view.toggleKeyboard() }
    func hideKeyboard() { adapter.view.hideKeyboard() }
}


/// Builds the two drivers for one host profile. The transport is wired in here
/// so the session controller never touches a socket: `socket` is the caller's
/// authenticated, certificate-pinned WebSocket factory for the bridge path the
/// host named in its connection document.
@MainActor enum RemoteBackendFactory {
    static func make(profile: HostProfile, relativeTouchpad: Bool,
                     socket: @escaping @Sendable (String) async throws -> URLSessionWebSocketTask)
    -> (SunshineBackendDriver?, VNCBackendDriver?) {
        guard !profile.mock, !profile.companionURL.isEmpty else { return (nil, nil) }
        let sunshine = SunshineBackendDriver(host: profile.hostname, relativeTouchpad: relativeTouchpad)
        let bridge = VNCWebSocketBridge()
        let adapter = VNCBackendAdapter(bridge: .init(
            open: { path in try await bridge.start(try await socket(path)) },
            close: { await bridge.close() }))
        let vnc = VNCBackendDriver(adapter: adapter)
        // The bridge reports its own stages; without this a failed upgrade is
        // invisible behind whatever the RFB client says next.
        let sink = vnc
        Task {
            await bridge.observe { stage in
                Task { @MainActor [weak sink] in sink?.onStage?(stage) }
            }
        }
        return (sunshine, vnc)
    }
}
