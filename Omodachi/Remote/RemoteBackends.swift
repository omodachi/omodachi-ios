import Foundation
import UIKit
import RemoteInputCore

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
    /// REMOTE-INPUT-1. Which road typed text takes on this host, and how text
    /// no key produces reaches it (`nil`: it does not).
    func configureTyping(route: RemoteTypingRoute, deliver: RemoteHostTextSequencer.Deliver?,
                         onUndelivered: ((RemoteHostTextOutcome) -> Void)?)
    /// Operator-only (see `RemoteOperatorSupport.typing`): the text goes in
    /// through the soft keyboard's own `insertText:`.
    func typeTextForOperator(_ text: String)
    /// POLISH-R item 4. The session is over: end whatever the backend left
    /// running on the host. A trace word, or nil when there is nothing of the
    /// kind (VNC's WayVNC is core's own and goes with the session).
    func endHostApp() async -> String?

    // MARK: REMOTE-INPUT-2: the compose bar

    /// The three-finger tap asks the session which keyboard to show.
    func setKeyboardTapHandler(_ handler: (() -> Void)?)
    /// The compose field holds the keyboard; the picture must not take it.
    func setComposeOwnsKeyboard(_ owns: Bool)
    /// A key the compose bar hands straight to the host: down, then up when
    /// the key comes up (a hardware key held repeats on the host).
    func passKey(usage: UInt16, down: Bool)
    /// One press with modifiers held (^C, a host shortcut).
    func passChord(usage: UInt16, modifiers: RemoteModifiers)
}

extension RemoteBackendDriver {
    func setKeyboardTapHandler(_ handler: (() -> Void)?) {}
    func setComposeOwnsKeyboard(_ owns: Bool) {}
    func passKey(usage: UInt16, down: Bool) {}
    func passChord(usage: UInt16, modifiers: RemoteModifiers) {}
    func endHostApp() async -> String? { nil }
    func replayGestureForOperator(_ gesture: RemotePictureGesture) {}
    func configureTyping(route: RemoteTypingRoute, deliver: RemoteHostTextSequencer.Deliver?,
                         onUndelivered: ((RemoteHostTextOutcome) -> Void)?) {}
    func typeTextForOperator(_ text: String) {}
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

    /// TAIL-2 P2-2: the host said this device reaches it through a Tailscale
    /// relay. A stream is then held to `relayedBitrateKbps`.
    var relayedRoad = false
    /// What a DERP relay carried without the picture falling seconds behind:
    /// TAIL-1 §5.4 measured VNC at about 2.8 MiB/s with 1–2 s of lag there.
    static let relayedBitrateKbps = 3_000

    /// TAIL-3b. The name this device reaches the host by — its one road — kept
    /// apart from the address a session's connection document names.
    private(set) var roadHost: String?

    init(host: String, relativeTouchpad: Bool, dialHost: String? = nil) {
        client = OMRemoteClient(host: host)
        roadHost = dialHost
        client.dialHost = dialHost
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

    /// The companion connection moved to `host`. Until a session names an
    /// address, Moonlight's pairing and inspection follow it.
    func follow(road host: String?) {
        roadHost = host
        client.dialHost = host
    }

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
        // TAIL-2 P2-2. Dial the address core named for the road this device
        // is on — its LAN address at home, its tailnet address away — and
        // not the bare host name, which only resolves on the home network.
        // REMOTE-FIX-2. One host for the requests and the stream: core's
        // name for the road (TAIL-3b: a Tailscale host is its MagicDNS name).
        let dial = SunshineRoute.dialHost(sessionHost: sunshine.host, road: roadHost)
        client.dialHost = dial
        RemoteSessionTrace.sunshineRoute(output: connection.outputID, core: sunshine.host, dial: dial,
                                         note: SunshineRoute.note(dial: dial))
        generation += 1
        reportedGeneration = nil
        client.setGeometryEpoch(0, generation: generation)
        // The rate is the host's plan for this session. A constant here asked
        // the fork's software encoder for a bitrate the host never planned and
        // silently discarded the host's own quality preference.
        var rate = Self.rate(profile: profile, connection: sunshine)
        if relayedRoad { rate.bitrateKbps = min(rate.bitrateKbps, Self.relayedBitrateKbps) }
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

    /// The fork's desktop app is ended by the one party holding the paired
    /// certificate `/cancel` needs: this client. Bounded (4 s), because a session
    /// that is over must not wait on a host that stopped answering.
    func endHostApp() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let once = HostAppQuitOnce(continuation)
            client.quitDesktop { outcome in MainActor.assumeIsolated { once.finish(outcome) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                MainActor.assumeIsolated { once.finish("skipped:timeout") }
            }
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
    func configureTyping(route: RemoteTypingRoute, deliver: RemoteHostTextSequencer.Deliver?,
                         onUndelivered: ((RemoteHostTextOutcome) -> Void)?) {
        input.typingRoute = route
        input.typing.deliver = route.hostText ? deliver : nil
        input.typing.onUndelivered = onUndelivered
    }
    func typeTextForOperator(_ text: String) { client.typeText(forOperator: text) }
    func setKeyboardTapHandler(_ handler: (() -> Void)?) { client.keyboardTapHandler = handler }
    func setComposeOwnsKeyboard(_ owns: Bool) {
        client.composeOwnsKeyboard = owns
        // Let go: a hardware keyboard goes straight to the host again.
        if !owns { client.reclaimFirstResponder() }
    }
    func passKey(usage: UInt16, down: Bool) { client.sendKey(usage: usage, down: down) }
    /// The latch is RemoteInputCore's one-shot modifier: the next key carries
    /// it and spends it, exactly as the Keybindings list's shortcuts do.
    func passChord(usage: UInt16, modifiers: RemoteModifiers) {
        if !modifiers.isEmpty { client.latchModifierMask(modifiers.rawValue) }
        client.sendShortcutUsage(usage)
    }
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
        case "control":
            let reason = (event["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            RemoteSessionTrace.sunshineRequest(step: event["step"] as? String ?? "?",
                                               host: event["host"] as? String ?? "",
                                               port: (event["port"] as? NSNumber)?.intValue ?? 0,
                                               reason: reason)
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

/// REMOTE-FIX-2. The one host Moonlight dials for a session — its HTTP(S)
/// requests (serverinfo, pairing, applist, launch) and the stream alike.
///
/// TAIL-3b: a Tailscale host is its MagicDNS name. The requests are
/// NSURLSession loads under App Transport Security, which treats a 100.x /
/// fd7a: literal as neither local networking nor the `*.ts.net` exception: it
/// demands system trust for the fork's self-signed certificate and fails every
/// request with -1200 (-9802), however the pinning delegate answers — which
/// is `HostRoad.isDialable` for the companion connection, and what Leo's iPad
/// hit on 2026-10-04 when core named the literal. Core now names the
/// MagicDNS name on a tailnet road; a core from before that still names the
/// literal, and then the road's own name — the name this device already
/// reaches the same computer by — is dialled instead. The stream resolves the
/// name itself (moonlight-common-c tries each address on the RTSP port). Only
/// when there is no name at all does the literal go out, and the diagnostics
/// say why it cannot work.
enum SunshineRoute {
    static func dialHost(sessionHost: String, road: String?) -> String {
        guard HostRoads.isTailnetAddress(sessionHost),
              let road, !road.isEmpty, !isAddressLiteral(road) else { return sessionHost }
        return road
    }

    /// The sentence the diagnostics carry when the dial host is a tailnet
    /// literal; nil otherwise.
    static func note(dial: String) -> String? {
        guard HostRoads.isTailnetAddress(dial) else { return nil }
        return "no MagicDNS name for this computer: iOS refuses the Sunshine certificate on a Tailscale address (TLS -1200), so pair it by its MagicDNS name or turn MagicDNS on" // non-copy: a diagnostics line, never shown as UI text
    }

    static func isAddressLiteral(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.contains(":") { return true }
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
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

    // MARK: REMOTE-INPUT-1

    private let typing = RemoteHostTextSequencer()
    private var typingRoute = RemoteTypingRoute.keysOnly

    func configureTyping(route: RemoteTypingRoute, deliver: RemoteHostTextSequencer.Deliver?,
                         onUndelivered: ((RemoteHostTextOutcome) -> Void)?) {
        typingRoute = route
        typing.reset()
        typing.deliver = route.hostText ? deliver : nil
        typing.onUndelivered = onUndelivered
        adapter.view.textHandler = { [weak self] text in self?.type(text) }
    }
    func typeTextForOperator(_ text: String) { adapter.view.insertText(text) }

    func setKeyboardTapHandler(_ handler: (() -> Void)?) { adapter.view.keyboardTapHandler = handler }
    /// RFB keysyms, behind any text still on its way so the two roads keep
    /// their order. A key without a keysym here is not sent.
    func passKey(usage: UInt16, down: Bool) {
        guard let keysym = VNCTyping.keysym(usage: usage) else { return }
        let view = adapter.view
        typing.perform { [weak view] in view?.sendKeysym(keysym, down: down) }
    }
    func passChord(usage: UInt16, modifiers: RemoteModifiers) {
        guard let keysym = VNCTyping.keysym(usage: usage) else { return }
        let held = VNCTyping.modifierKeysyms(modifiers)
        let view = adapter.view
        typing.perform { [weak view] in
            for modifier in held { view?.sendKeysym(modifier, down: true) }
            view?.tapKeysym(keysym)
            for modifier in held.reversed() { view?.sendKeysym(modifier, down: false) }
        }
    }

    /// RFB keysyms are characters, not positions: WayVNC finds the key for a
    /// keysym in the host's own keymap, so printable ASCII is right on any
    /// layout. Return and Tab are their function keysyms (Tab used to go as
    /// keysym 0x09, which names nothing, and was dropped). What the keymap has
    /// no key for — 中文, emoji, accents on a US keymap — WayVNC drops
    /// silently, so that takes the host-text road like on Sunshine.
    private func type(_ text: String) {
        var pending = ""
        func flush() { if !pending.isEmpty { typing.type(pending); pending = "" } }
        for character in text {
            if let keysym = VNCTyping.keysym(for: character) {
                flush()
                let view = adapter.view
                typing.perform { [weak view] in view?.tapKeysym(keysym) }
            } else if !USKeyboardText.isUntypable(character) {
                pending.append(character)
            }
        }
        flush()
    }
}

/// REMOTE-INPUT-1. Keysyms for the VNC leg.
enum VNCTyping {
    /// REMOTE-INPUT-2. A HID usage the compose bar passes through, as the
    /// keysym WayVNC finds a key for in the host's own keymap.
    static func keysym(usage: UInt16) -> UInt32? {
        switch usage {
        case 0x04...0x1D: return 0x61 + UInt32(usage - 0x04)          // a–z
        case 0x1E...0x26: return 0x31 + UInt32(usage - 0x1E)          // 1–9
        case 0x27: return 0x30
        case 0x28, 0x58: return 0xFF0D                                 // Return
        case 0x29: return 0xFF1B                                       // Escape
        case 0x2A: return 0xFF08                                       // BackSpace
        case 0x2B: return 0xFF09                                       // Tab
        case 0x2C: return 0x20
        case 0x3A...0x45: return 0xFFBE + UInt32(usage - 0x3A)        // F1–F12
        case 0x4A: return 0xFF50; case 0x4B: return 0xFF55             // Home, Prior
        case 0x4C: return 0xFFFF; case 0x4D: return 0xFF57             // Delete, End
        case 0x4E: return 0xFF56                                       // Next
        case 0x4F: return 0xFF53; case 0x50: return 0xFF51             // Right, Left
        case 0x51: return 0xFF54; case 0x52: return 0xFF52             // Down, Up
        default: return nil
        }
    }

    static func modifierKeysyms(_ modifiers: RemoteModifiers) -> [UInt32] {
        var keysyms: [UInt32] = []
        if modifiers.contains(.control) { keysyms.append(0xFFE3) }
        if modifiers.contains(.alt) { keysyms.append(0xFFE9) }
        if modifiers.contains(.shift) { keysyms.append(0xFFE1) }
        if modifiers.contains(.superKey) { keysyms.append(0xFFEB) }
        return keysyms
    }

    static func keysym(for character: Character) -> UInt32? {
        if character == "\r\n" { return 0xFF0D }
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, scalar.isASCII else { return nil }
        switch scalar.value {
        case 0x0A, 0x0D: return 0xFF0D
        case 0x09: return 0xFF09
        case 0x20...0x7E: return scalar.value
        default: return nil
        }
    }
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
        // TAIL-2 P2-2 / TAIL-3b. Until a session's connection document names
        // an address, Moonlight's own pairing and inspection go down the
        // host's one road.
        let road = HostRoads.dialURL(account: profile.companionURL)?.host
        let sunshine = SunshineBackendDriver(host: profile.hostname, relativeTouchpad: relativeTouchpad,
                                             dialHost: road)
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

/// The first of "the fork answered" and "four seconds passed" wins.
@MainActor private final class HostAppQuitOnce {
    private var continuation: CheckedContinuation<String, Never>?
    init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    func finish(_ outcome: String) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
