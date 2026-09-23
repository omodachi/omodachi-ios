import Foundation
import Combine

/// Push-to-talk into the host's own Voxtype.
///
/// The order is the host's: the uplink has to be live before dictation may
/// start, because pointing Voxtype at a source that is not publishing yet only
/// restarts it into a broken capture (`omodachi-core/docs/voice.md`). So:
/// open the socket, begin the generation, start capturing, and only then ask
/// core to start recording. Stopping is the reverse, and the transcript is
/// whatever the host's own engine returned — this client runs no recognizer.
@MainActor final class VoiceDictationStore: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle
        case checking
        /// The socket and the microphone are coming up.
        case opening
        case recording
        /// Recording stopped; the host is transcribing.
        case transcribing
        /// The host cannot do this, and says why in its own terms.
        case unavailable(String)
        case failed(String)
    }

    /// Why a stop happened, for the frame the host is told about.
    enum EndReason: String, Sendable {
        case userDisabled = "user_disabled"
        case routeChanged = "route_changed"
        case sessionEnd = "session_end"
        case disconnected
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var capabilities: VoiceCapabilities?
    @Published private(set) var level: Double = 0
    /// The last 28 readings, which is exactly what the meter draws.
    @Published private(set) var trace: [Double] = []
    @Published private(set) var transcript: String?
    /// Which surface asked for these words. The Panel stays mounted behind a
    /// work surface, so a transcript published to everyone lands in the Panel's
    /// search field as well as the composer that asked for it. The owner is the
    /// answer to "who held the button".
    private(set) var transcriptOwner: String?
    @Published private(set) var notice: String?

    private let client: () throws -> CompanionHostClient
    private var transport: CompanionMicrophoneTransport?
    private var capture: VoiceCapture?
    /// The host keeps the highest generation it has seen **per device**, for
    /// as long as its daemon runs (`voice_service.py`: `_generations[device]`).
    /// A counter that restarts at 1 with the app is therefore stale for good
    /// after the first recording, so this one is wall-clock milliseconds —
    /// which only moves forward — and is still forced to increase within a
    /// session in case two recordings land in the same millisecond.
    private var generation: UInt64 = 0
    private var target: VoiceTarget = .client
    private var owner: String?
    private var work: Task<Void, Never>?

    init(client: @escaping () throws -> CompanionHostClient) { self.client = client }

    var isRecording: Bool { phase == .recording || phase == .opening }
    var isBusy: Bool {
        switch phase { case .checking, .opening, .recording, .transcribing: true; default: false }
    }
    /// Grey, with a reason, until the host says all four things hold.
    var isAvailable: Bool { capabilities?.ready == true }
    /// The official installer's own command line, when Voxtype is missing.
    var installCommand: [String]? {
        guard capabilities?.voxtype.installed == false else { return nil }
        return capabilities?.voxtype.installCommand ?? ["omarchy-voxtype-install"]
    }

    func refreshCapabilities() async {
        guard !isBusy else { return }
        do {
            let value = try await client().voiceCapabilities()
            capabilities = value
            if let reason = value.blockedReason { phase = .unavailable(reason) }
            else if case .unavailable = phase { phase = .idle }
        } catch {
            capabilities = nil
            phase = .unavailable("voice_unavailable")
        }
    }

    // MARK: - Push to talk

    /// Held down, or tapped once. Both land here; what differs is who calls
    /// `finish()` — the finger, or Voxtype's own silence detection.
    func begin(target: VoiceTarget, owner: String) {
        guard !isBusy else { return }
        self.target = target
        self.owner = owner
        transcript = nil
        transcriptOwner = nil
        notice = nil
        phase = .checking
        work?.cancel()
        work = Task { [weak self] in await self?.open() }
    }

    func finish() {
        guard phase == .recording || phase == .opening else { return }
        work?.cancel()
        work = Task { [weak self] in await self?.close() }
    }

    /// Leaving the surface, or losing the host. No transcript is claimed.
    func cancel(reason: EndReason) {
        work?.cancel()
        work = nil
        let wasRecording = phase == .recording || phase == .opening
        teardown(reason: reason)
        if wasRecording {
            phase = .idle
            // The host is told to stop even when this side gave up, so a
            // recording is never left running on a machine nobody is watching.
            Task { [client, target] in _ = try? await client().stopDictation(target: target) }
        } else if case .failed = phase {} else if case .unavailable = phase {} else {
            phase = .idle
        }
    }

    /// The words, to the surface that asked for them and to no other.
    func take(for owner: String) -> String? {
        guard transcriptOwner == owner, let text = transcript, !text.isEmpty else { return nil }
        transcript = nil
        transcriptOwner = nil
        return text
    }

    /// The `voice.transcript` event. The stop response is the authority for the
    /// device that spoke, so this is only taken when that response was lost —
    /// which is exactly the case it exists for. It is never taken while a
    /// recording is in flight, where it would be words from the turn before.
    func adopt(_ event: VoiceTranscriptEvent?) {
        guard let event, !event.text.isEmpty, transcript == nil else { return }
        guard case .failed = phase else { return }
        transcript = event.text
        transcriptOwner = owner
        notice = Strings.voiceAlreadyTranscribed
        phase = .idle
    }

    // MARK: - Internals

    private func open() async {
        await refreshCapabilities()
        guard let capabilities, capabilities.ready else {
            if case .unavailable = phase {} else { phase = .unavailable(capabilities?.blockedReason ?? "voice_unavailable") }
            return
        }
        guard await VoiceCapture.requestPermission() else {
            phase = .failed("microphone_permission_denied")
            return
        }
        guard !Task.isCancelled else { return }
        phase = .opening

        let wantsLevels = capabilities.levels.available
        let service: CompanionHostClient
        do { service = try client() } catch { phase = .failed("host_unavailable"); return }

        generation = max(UInt64(Date().timeIntervalSince1970 * 1000), generation &+ 1)
        let factory: CompanionMicrophoneTransport.SocketFactory = { [service] in
            URLSessionMicrophoneSocket(task: try await service.makeVoiceUplinkSocket(levels: wantsLevels))
        }
        var meter: (@Sendable (VoiceLevel) -> Void)?
        if wantsLevels {
            meter = { [weak self] row in Task { @MainActor in self?.observe(level: row) } }
        }
        let transport = CompanionMicrophoneTransport(factory: factory, levels: meter,
                                                     generationBase: generation &- 1)
        self.transport = transport

        let began = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OneShot(continuation)
            let accepted: @Sendable (Bool) -> Void = { value in once.resume(value) }
            let acknowledged: @Sendable (Bool, Bool) -> Void = { [weak self] _, channelOpen in
                guard !channelOpen else { return }
                once.resume(false)
                Task { @MainActor in self?.uplinkClosed() }
            }
            transport.beginGeneration(self.generation, sampleRate: 48_000, channels: 1, samplesPerFrame: 960,
                                      completion: accepted, acknowledgement: acknowledged)
        }
        guard began, !Task.isCancelled else {
            teardown(reason: .disconnected)
            if !Task.isCancelled { phase = .failed("audio_input_unavailable") }
            return
        }

        let generation = self.generation
        let capture = VoiceCapture(
            onFrame: { [weak transport] frame, sequence in
                transport?.acceptPCM(frame, generation: generation, sequence: sequence, sampleTime: sequence * 960) ?? false
            },
            onStop: { [weak self] reason in
                Task { @MainActor in self?.captureStopped(reason) }
            })
        self.capture = capture
        if let failure = capture.start() {
            teardown(reason: .disconnected)
            phase = .failed(failure.rawValue)
            return
        }

        do {
            _ = try await service.startDictation(target: target)
        } catch {
            teardown(reason: .disconnected)
            phase = .failed(Self.reason(error))
            return
        }
        guard !Task.isCancelled else { teardown(reason: .sessionEnd); return }
        phase = .recording
    }

    private func close() async {
        phase = .transcribing
        // Recording stops before the host is asked for the words, so nothing
        // said after the finger lifted lands in the transcript.
        capture?.stop(.user)
        capture = nil
        do {
            let result = try await client().stopDictation(target: target)
            teardown(reason: .sessionEnd)
            if let text = result.text, !text.isEmpty {
                transcript = text
                transcriptOwner = owner
                phase = .idle
            } else if result.status == "empty" || result.text?.isEmpty == true {
                notice = Strings.voiceNothingTranscribed
                phase = .idle
            } else if target != .client {
                // `target: host` deliberately carries no text: the words were
                // typed into the focused host window.
                phase = .idle
            } else {
                notice = Strings.voiceNoTranscript
                phase = .idle
            }
        } catch {
            teardown(reason: .disconnected)
            phase = .failed(Self.reason(error))
        }
    }

    private func teardown(reason: EndReason) {
        capture?.stop(.user)
        capture = nil
        transport?.endGeneration(generation)
        transport?.invalidate()
        transport = nil
        level = 0
        trace = []
    }

    private func observe(level row: VoiceLevel) {
        level = row.bar
        trace.append(row.bar)
        if trace.count > 28 { trace.removeFirst(trace.count - 28) }
    }

    private func captureStopped(_ reason: VoiceCapture.Stop) {
        guard isRecording else { return }
        work?.cancel()
        teardown(reason: reason == .routeChanged ? .routeChanged : .disconnected)
        phase = .failed(reason.rawValue)
        // The host must not be left recording from a microphone that went away.
        Task { [client, target] in _ = try? await client().stopDictation(target: target) }
    }

    private func uplinkClosed() {
        guard isRecording else { return }
        captureStopped(.transportClosed)
    }

    private static func reason(_ error: Error) -> String {
        if let host = error as? CompanionHostError, case .unavailable(let code, _) = host, let code { return code }
        if let host = error as? CompanionHostError, case .blocked(let code, _) = host, let code { return code }
        return "voice_unavailable"
    }
}

/// `beginGeneration` reports through two callbacks and either may be first.
/// A continuation may only be resumed once, so the race is settled here rather
/// than by hoping.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        pending?.resume(returning: value)
    }
}

/// The words a host phrase means, in the user's terms. Anything core did not
/// name is reported as one unavailable state rather than echoed as a code.
enum VoiceReason {
    static func message(_ code: String) -> String { ReasonText.message(code, domain: .voice) }
}
