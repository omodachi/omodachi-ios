import Combine

/// The authenticated bridge, injected so the adapter never owns the host
/// client, the credential or the pinned certificate. It takes the `path` from
/// the connection document and answers with a loopback port on this device.
struct VNCBridgeOperations: Sendable {
    let open: @Sendable (String) async throws -> UInt16
    let close: @Sendable () async -> Void
}

enum VNCBackendPhase: Equatable { case idle, bridging, connecting, ready, stopping, failed(String) }

/// Connects one VNC connection document, reports the first complete framebuffer
/// it actually presented, and awaits stop. The session transaction stays in
/// `RemoteSessionController`.
@MainActor final class VNCBackendAdapter: ObservableObject {
    let view = OMVNCRemoteView(frame: .zero)
    @Published private(set) var phase: VNCBackendPhase = .idle {
        didSet { guard oldValue != phase else { return }; applyInput() }
    }
    /// INPUT-2: the same rule as the Sunshine leg. `enableInput` is a standing
    /// want, not a moment: a Panel that closes while the RFB client is still
    /// connecting used to lose its answer for the rest of the session.
    private var inputDesired = false
    private let bridge: VNCBridgeOperations
    private var operation: UInt = 0
    private var connectTask: Task<Void, Never>?
    /// The geometry last handed upward. REMOTE-6: WayVNC changes the size it
    /// serves one update into a scale-2 session, so "the first frame" is not
    /// the only frame whose size the session needs to know about.
    private var reported: RemotePixels?
    var onFrameReady: ((RemotePixels, CGRect) -> Void)?
    /// REMOTE-6. The server framebuffer changed size mid-stream.
    var onFramebufferResize: ((RemotePixels, RemotePixels) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStage: ((String) -> Void)?

    init(bridge: VNCBridgeOperations) { self.bridge = bridge }

    func connect(_ connection: RemoteConnectionDTO.VNC) async {
        await stop()
        operation &+= 1
        let current = operation
        reported = nil
        inputDesired = false
        phase = .bridging
        onStage?("bridging")
        let bridge = bridge
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let localPort = try await bridge.open(connection.path)
                guard !Task.isCancelled, self.operation == current else { await bridge.close(); return }
                guard localPort != 0 else { throw VNCBackendError.invalidBridge }
                self.onStage?("bridge_ready")
                self.phase = .connecting
                self.view.onStage = { [weak self] stage in
                    guard let self, self.operation == current else { return }
                    self.onStage?(stage)
                }
                self.view.onDisconnected = { [weak self] reason in
                    guard let self, self.operation == current else { return }
                    self.fail(reason)
                    Task { guard self.operation == current else { return }; await self.stop(preserveFailure: true) }
                }
                self.view.onFramebufferResized = { [weak self] from, to in
                    guard let self, self.operation == current else { return }
                    self.onFramebufferResize?(
                        RemotePixels(width: Int(from.width), height: Int(from.height)),
                        RemotePixels(width: Int(to.width), height: Int(to.height)))
                }
                self.view.onFramePresented = { [weak self] pixels, rect in
                    // The decoded frame is the only authority on its own size:
                    // WayVNC serves the compositor's logical size first and the
                    // output's buffer pixels afterwards, so a session is told
                    // the geometry again whenever it actually changes.
                    guard let self, self.operation == current,
                          pixels.width > 0, pixels.height > 0 else { return }
                    let value = RemotePixels(width: Int(pixels.width), height: Int(pixels.height))
                    let first = self.reported == nil
                    guard first || self.reported != value else { return }
                    self.reported = value
                    self.phase = .ready
                    self.onStage?(first ? "native_frame" : "native_frame_resized")
                    self.onFrameReady?(value, rect)
                }
                // The ceiling is the larger of the two sizes the host named:
                // anything above the owned output's own pixels is a protocol
                // error whichever of them WayVNC happens to be serving.
                let ceiling = connection.framebufferPixels.width * connection.framebufferPixels.height
                    >= connection.initialFramebufferPixels.width * connection.initialFramebufferPixels.height
                    ? connection.framebufferPixels : connection.initialFramebufferPixels
                self.view.connectLoopbackPort(localPort, expectedPixels: CGSize(
                    width: ceiling.width, height: ceiling.height))
            } catch {
                guard self.operation == current, !Task.isCancelled else { return }
                // Report the first failure before waiting on transport cleanup.
                self.onStage?("bridge_failed")
                self.fail(Self.describe(error))
                await bridge.close()
            }
        }
        connectTask = task
        await task.value
        if operation == current { connectTask = nil }
    }

    /// Await this before claiming the old media stopped or changing backend.
    /// The native client releases input and closes its socket BEFORE the
    /// bridge does, so the host sees an ordinary RFB disconnect.
    func stop(preserveFailure: Bool = false) async {
        operation &+= 1
        let previous = phase
        if !preserveFailure { phase = .stopping }
        let task = connectTask
        connectTask = nil
        task?.cancel()
        await task?.value
        view.onStage = nil; view.onFramePresented = nil; view.onDisconnected = nil
        view.onFramebufferResized = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.disconnect { continuation.resume() }
        }
        await bridge.close()
        reported = nil
        inputDesired = false
        phase = preserveFailure ? previous : .idle
        // The last UIImage is intentionally retained for the parent's transition.
    }

    func enableInput(_ enabled: Bool) { inputDesired = enabled; applyInput() }
    private func applyInput() { view.setInputEnabled(inputDesired && phase == .ready) }
    var snapshotImage: UIImage? { view.snapshotImage }

    private func fail(_ reason: String) { phase = .failed(reason); onFailure?(reason) }

    /// The transport leg is where this backend historically died, so its
    /// failure is named rather than collapsed into one message.
    private static func describe(_ error: Error) -> String {
        if let failure = error as? VNCWebSocketBridge.Failure { return failure.errorDescription ?? Strings.vncNoChannel }
        if let failure = error as? RemoteRequestError { return failure.userMessage }
        if let failure = error as? CompanionHostError { return failure.errorDescription ?? Strings.vncNoChannel }
        if error is VNCBackendError { return Strings.vncNoLocalPort }
        return Strings.vncNoChannel
    }
}

enum VNCBackendError: Error { case invalidBridge }
