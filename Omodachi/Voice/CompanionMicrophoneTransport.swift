import Foundation

enum MicrophoneSocketMessage: Sendable { case text(String), binary(Data) }
protocol MicrophoneSocketIO: Sendable {
    func resume()
    func send(_ message: MicrophoneSocketMessage) async throws
    func receive() async throws -> MicrophoneSocketMessage
    func close()
}
struct URLSessionMicrophoneSocket: MicrophoneSocketIO {
    let task: URLSessionWebSocketTask
    func resume() { task.resume() }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
    func send(_ message: MicrophoneSocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .binary(let data): try await task.send(.data(data))
        }
    }
    func receive() async throws -> MicrophoneSocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: throw MicrophoneWireProtocol.Failure.invalidAck
        }
    }
}

private final class MicrophoneCallbacks: @unchecked Sendable {
    let begun: (Bool) -> Void
    let acknowledged: (Bool, Bool) -> Void
    init(_ begun: @escaping (Bool) -> Void, _ acknowledged: @escaping (Bool, Bool) -> Void) {
        self.begun = begun; self.acknowledged = acknowledged
    }
}

/// One adapter is scoped to one Companion lease. The wire generation advances
/// on every user enable, independently of the stream's native media generation.
final class CompanionMicrophoneTransport: NSObject, OMMicrophoneTransport, @unchecked Sendable {
    typealias SocketFactory = @Sendable () async throws -> any MicrophoneSocketIO
    private struct Frame { let pcm: Data }
    private struct Channel {
        let id: UUID
        let nativeGeneration: UInt64
        let wireGeneration: UInt64
        let callbacks: MicrophoneCallbacks
        var socket: (any MicrophoneSocketIO)?
        var begun = false
        var window: MicrophoneFrameWindow
        var queued: [Frame] = []
        var sending = false
        var deadline = ProcessInfo.processInfo.systemUptime + 5
    }
    private let lock = NSLock()
    private let factory: SocketFactory
    /// The waveform rows the voice uplink interleaves with its acknowledgements
    /// (`?levels=1`). A Remote-session uplink never asks for them and leaves
    /// this nil, so nothing about that path changes.
    private let levels: (@Sendable (VoiceLevel) -> Void)?
    private var supported = true
    private var wireCounter: UInt64 = 0
    private var channel: Channel?
    /// `generationBase` is where the wire counter starts.
    ///
    /// A Remote lease leaves it at zero, so the first channel of that lease is
    /// generation 1 — which is what the lease's own host-side record expects.
    /// The standalone voice uplink cannot: the host keeps the highest
    /// generation it has seen per *device*, for as long as its daemon runs, so
    /// a counter that restarts with the app is stale for good after the first
    /// recording. That caller passes a base that only ever moves forward.
    init(factory: @escaping SocketFactory, levels: (@Sendable (VoiceLevel) -> Void)? = nil,
         generationBase: UInt64 = 0) {
        self.factory = factory; self.levels = levels
        wireCounter = generationBase
        super.init()
    }

    func isAvailable(forGeneration generation: UInt64) -> Bool {
        lock.withLock { supported && generation > 0 }
    }
    func beginGeneration(_ generation: UInt64, sampleRate rate: UInt, channels: UInt, samplesPerFrame samples: UInt,
                         completion: @escaping (Bool) -> Void, acknowledgement: @escaping (Bool, Bool) -> Void) {
        let callbacks = MicrophoneCallbacks(completion, acknowledgement)
        let id: UUID? = lock.withLock {
            guard supported, generation > 0, channel == nil, rate == 48_000, channels == 1, samples == 960,
                  wireCounter < UInt64.max else { return nil }
            wireCounter += 1
            let id = UUID()
            channel = Channel(id: id, nativeGeneration: generation, wireGeneration: wireCounter,
                              callbacks: callbacks, window: MicrophoneFrameWindow(generation: wireCounter))
            return id
        }
        guard let id else { completion(false); return }
        Task { [weak self] in await self?.open(id: id) }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                let status = self.lock.withLock { () -> (Bool, Bool) in
                    guard let channel = self.channel, channel.id == id else { return (false, false) }
                    let timedOut = (!channel.begun || channel.window.reserved > 0) && ProcessInfo.processInfo.systemUptime > channel.deadline
                    return (true, timedOut)
                }
                guard status.0 else { return }
                if status.1 { self.fail(id: id); return }
            }
        }
    }
    private func open(id: UUID) async {
        do {
            let socket = try await factory()
            let generation: UInt64? = lock.withLock {
                guard channel?.id == id else { return nil }
                channel?.socket = socket
                return channel?.wireGeneration
            }
            guard let generation else { socket.close(); return }
            socket.resume()
            try await socket.send(.text(MicrophoneWireProtocol.begin(generation: generation)))
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard case .text(let text) = message else { throw MicrophoneWireProtocol.Failure.invalidAck }
                if let level = MicrophoneWireProtocol.level(text) { levels?(level); continue }
                let ack = try MicrophoneWireProtocol.ack(text)
                let delivery: (MicrophoneCallbacks, Bool, Bool)? = try lock.withLock {
                    guard var current = channel, current.id == id else { return nil }
                    guard ack.generation == current.wireGeneration else { throw MicrophoneWireProtocol.Failure.invalidAck }
                    if !current.begun {
                        guard ack.validBegin else { throw MicrophoneWireProtocol.Failure.invalidAck }
                        current.begun = true; channel = current
                        return (current.callbacks, true, true)
                    }
                    let acceptance = current.window.acknowledge(ack)
                    guard acceptance != .invalid else { throw MicrophoneWireProtocol.Failure.invalidAck }
                    current.deadline = ProcessInfo.processInfo.systemUptime + 1
                    channel = current
                    return (current.callbacks, false, acceptance == .accepted)
                }
                guard let delivery else { socket.close(); return }
                if delivery.1 { delivery.0.begun(true) }
                else { delivery.0.acknowledged(delivery.2, true) }
            }
        } catch { fail(id: id) }
    }
    /// Returns channel viability, including intentional bounded local drops.
    /// Only an authenticated peer ACK invokes acknowledged(true, true).
    func acceptPCM(_ pcm: Data, generation: UInt64, sequence: UInt64, sampleTime: UInt64) -> Bool {
        let result: (Bool, UUID?) = lock.withLock {
            guard var current = channel, current.nativeGeneration == generation, current.begun else { return (false, nil) }
            let reservation = current.window.reserve(bytes: pcm.count, sequence: sequence, sampleTime: sampleTime)
            if reservation == .invalid { return (false, nil) }
            if reservation == .dropped { channel = current; return (true, nil) }
            if current.window.reserved == 1 { current.deadline = ProcessInfo.processInfo.systemUptime + 1 }
            current.queued.append(Frame(pcm: pcm))
            let start = !current.sending
            current.sending = true; channel = current
            return (true, start ? current.id : nil)
        }
        if let id = result.1 { Task { [weak self] in await self?.sendQueued(id: id) } }
        return result.0
    }
    private func sendQueued(id: UUID) async {
        do {
            while true {
                let next: ((any MicrophoneSocketIO), Frame)? = try lock.withLock {
                    guard var current = channel, current.id == id, let socket = current.socket, current.begun else { return nil }
                    if current.queued.isEmpty { current.sending = false; channel = current; return nil }
                    let frame = current.queued.removeFirst()
                    guard current.window.sending() != nil else { throw MicrophoneWireProtocol.Failure.invalidFrame }
                    channel = current; return (socket, frame)
                }
                guard let next else { return }
                try await next.0.send(.binary(next.1.pcm))
            }
        } catch { fail(id: id) }
    }
    func endGeneration(_ generation: UInt64) {
        let ended: Channel? = lock.withLock {
            guard let current = channel, current.nativeGeneration == generation else { return nil }
            channel = nil; return current
        }
        guard let ended else { return }
        // Stop local acceptance synchronously. Send a bounded graceful end, then
        // close even if the peer does not reply; close also triggers host flush.
        if let socket = ended.socket {
            Task {
                if let text = try? MicrophoneWireProtocol.end(generation: ended.wireGeneration) { try? await socket.send(.text(text)) }
                socket.close()
            }
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                socket.close()
            }
        }
    }
    private func fail(id: UUID) {
        let failed: Channel? = lock.withLock {
            guard channel?.id == id else { return nil }
            let current = channel; channel = nil
            // Failed route/backend/handshake is unavailable until next lease's
            // capability query; never repeatedly open from the capture callback.
            supported = false
            return current
        }
        guard let failed else { return }
        failed.socket?.close()
        if failed.begun { failed.callbacks.acknowledged(false, false) }
        else { failed.callbacks.begun(false) }
    }
    func invalidate() {
        let generation = lock.withLock { supported = false; return channel?.nativeGeneration }
        if let generation { endGeneration(generation) }
    }
    deinit { channel?.socket?.close() }
}
