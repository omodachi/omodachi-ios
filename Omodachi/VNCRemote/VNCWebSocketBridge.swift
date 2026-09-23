import Foundation

/// RFB over the one TLS connection this device already pinned.
///
/// The host bridges WayVNC onto `GET /v1/remote/sessions/{id}/vnc`
/// (`omodachi-core/docs/wayvnc.md`): a WebSocket BINARY message is a run of TCP
/// bytes, with no framing, length prefix or envelope in either direction.
/// LibVNCClient can only dial a TCP port, so this owns a loopback listener that
/// exists for exactly one connection and copies bytes across. There is no SSH
/// here and no second identity: the Remote media path rides the device
/// credential and the pinned certificate, nothing else.
actor VNCWebSocketBridge {
    enum Failure: Error, LocalizedError, Equatable {
        case loopbackUnavailable
        /// The HTTP status the host answered the upgrade with, when there was
        /// one. Everything the bridge can refuse has its own status.
        case handshake(status: Int?)

        var errorDescription: String? {
            switch self {
            case .loopbackUnavailable: Strings.vncLoopbackUnavailable
            case .handshake(let status):
                switch status {
                case 401: Strings.vncUnauthorized
                case 403: ReasonText.message("permission_denied", domain: .remote)
                case 404: ReasonText.message("session_not_found", domain: .remote)
                case 409: ReasonText.message("vnc_bridge_unavailable", domain: .remote)
                case 503: Strings.vncWayvncNotAccepting
                case .some(let value): Strings.vncRefused(Format.count(value))
                case nil: Strings.vncNoChannel
                }
            }
        }
    }

    private var channel: URLSessionWebSocketTask?
    private var listener: Int32 = -1
    private var peer: Int32 = -1
    private var pumps: [Task<Void, Never>] = []
    private var running = false
    private var stage: (@Sendable (String) -> Void)?
    /// Bytes the host sent before the RFB client dialed the loopback listener.
    /// WayVNC greets immediately, so this is normally the version string.
    private var pending: [Data] = []

    func observe(_ callback: @escaping @Sendable (String) -> Void) { stage = callback }

    /// Proves the socket up with the host's own first RFB bytes before handing
    /// out a port, so a refused upgrade is reported as what it was — 401, 403,
    /// 409 — rather than as "the VNC client could not connect".
    ///
    /// The proof is a read, not a ping: `sendPing`'s completion handler is not
    /// delivered on a task nobody is receiving on, and waiting on it hangs the
    /// whole leg while the host's WayVNC drops the unanswered handshake.
    func start(_ task: URLSessionWebSocketTask) async throws -> UInt16 {
        await close()
        task.resume()
        let greeting: Data
        do {
            greeting = try await Self.payload(of: try await task.receive())
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            task.cancel(with: .goingAway, reason: nil)
            throw Failure.handshake(status: status)
        }
        stage?("bridge_host_bytes")
        guard let (descriptor, port) = Self.makeListener() else {
            task.cancel(with: .goingAway, reason: nil)
            throw Failure.loopbackUnavailable
        }
        channel = task
        listener = descriptor
        pending = greeting.isEmpty ? [] : [greeting]
        running = true
        pumps = [Task { await self.acceptThenPump() }]
        return port
    }

    /// Everything shuts down together: closing the descriptors unblocks the
    /// accept/recv threads, and cancelling the task ends the host side.
    func close() async {
        running = false
        let held = pumps
        pumps = []
        channel?.cancel(with: .goingAway, reason: nil)
        channel = nil
        for descriptor in [peer, listener] where descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        peer = -1; listener = -1
        pending = []
        // Never awaited: `finish` calls this from inside one of these pumps,
        // and the descriptors are already shut down, so each loop ends on its
        // next syscall rather than on a join that would deadlock on itself.
        for pump in held { pump.cancel() }
    }

    // MARK: - Pumps

    private func acceptThenPump() async {
        let listening = listener
        guard listening >= 0, let accepted = await Self.accept(listening), running else { return }
        // A half-closed loopback peer must surface as a write error, never as a
        // signal that takes the whole app down.
        var on: Int32 = 1
        setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        peer = accepted
        stage?("rfb_client_attached")
        guard let task = channel else { Darwin.close(accepted); return }
        // Whatever arrived before the client dialed goes out first, in order.
        let held = pending
        pending = []
        for data in held where running {
            guard await Self.send(accepted, data) else { await finish("client_closed"); return }
        }
        pumps += [Task { await self.pumpToHost(accepted, task) },
                  Task { await self.pumpToClient(accepted, task) }]
    }

    /// Client -> host. Blocking reads live on a global queue; only the handoff
    /// crosses back into the actor.
    private func pumpToHost(_ descriptor: Int32, _ task: URLSessionWebSocketTask) async {
        var announced = false
        var reason = "rfb_client_eof"
        while running, !Task.isCancelled {
            let read = await Self.receive(descriptor)
            guard case .bytes(let data) = read else {
                if case .failed(let code) = read { reason = "rfb_client_read_failed_\(code)" }
                break
            }
            if !announced { announced = true; stage?("rfb_client_bytes") }
            do { try await task.send(.data(data)) }
            catch { reason = "bridge_send_failed_\((error as NSError).code)"; break }
        }
        await finish(reason)
    }

    /// Host -> client. A TEXT frame is not a control channel on this path.
    private func pumpToClient(_ descriptor: Int32, _ task: URLSessionWebSocketTask) async {
        var reason = "bridge_closed"
        while running, !Task.isCancelled {
            let data: Data
            do { data = try await Self.payload(of: try await task.receive()) }
            catch { reason = "bridge_receive_failed_\((error as NSError).code)"; break }
            guard !data.isEmpty else { break }
            guard await Self.send(descriptor, data) else { reason = "rfb_client_write_failed"; break }
        }
        await finish(reason)
    }

    /// The bridge is binary in both directions; a TEXT frame is a host bug and
    /// is never interpreted as a control message.
    private static func payload(of message: URLSessionWebSocketTask.Message) throws -> Data {
        guard case .data(let value) = message else { throw Failure.handshake(status: nil) }
        return value
    }

    /// Either end ending ends the other; the adapter sees it as a disconnect.
    private func finish(_ reason: String) async {
        guard running else { return }
        stage?(reason)
        await close()
    }

    // MARK: - The loopback socket

    private static func makeListener() -> (Int32, UInt16)? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else { Darwin.close(descriptor); return nil }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        let port = UInt16(bigEndian: actual.sin_port)
        guard named == 0, port != 0 else { Darwin.close(descriptor); return nil }
        return (descriptor, port)
    }

    private static func blocking<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    private static func accept(_ listener: Int32) async -> Int32? {
        await blocking {
            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let peer = Darwin.accept(listener, &address, &length)
            return peer >= 0 ? peer : nil
        }
    }

    enum Read: Sendable { case bytes(Data), eof, failed(Int32) }

    private static func receive(_ descriptor: Int32) async -> Read {
        await blocking {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count > 0 { return .bytes(Data(buffer[0..<count])) }
            return count == 0 ? .eof : .failed(errno)
        }
    }

    private static func send(_ descriptor: Int32, _ data: Data) async -> Bool {
        await blocking {
            data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var written = 0
                while written < raw.count {
                    let count = Darwin.send(descriptor, base + written, raw.count - written, 0)
                    if count <= 0 { return false }
                    written += count
                }
                return true
            }
        }
    }
}
