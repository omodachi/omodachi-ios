import Foundation

/// One pane, one WebSocket. `observe` is read-only and unlimited; `control` is
/// read-write and one at a time, refused with **HTTP 409 before the upgrade**
/// when another end holds it (`docs/herdr.md`).
///
/// This type owns exactly the socket: it does not decide what a frame means,
/// it does not draw, and it does not retry. Retrying is the store's, because
/// only the store knows whether the surface is still on screen.
@MainActor final class HerdrPaneStream {
    enum Event: Sendable {
        case opened(HerdrStreamMode)
        /// The bridge refused `control` because someone else holds the pane.
        /// The caller stays on `observe`; it never escalates on its own.
        case controlInUse
        case message(HerdrStreamMessage)
        /// The socket ended. `reason` is the bridge's own close code when it
        /// sent one, never peer terminal output.
        case ended(reason: String?)
    }

    let mode: HerdrStreamMode
    private let client: CompanionHostClient
    private let pane: String
    private var task: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var pending: [HerdrControlCommand] = []
    private(set) var isOpen = false

    init(client: CompanionHostClient, pane: String, mode: HerdrStreamMode) {
        self.client = client
        self.pane = pane
        self.mode = mode
    }

    func start(cols: Int, rows: Int, handler: @escaping @MainActor (Event) -> Void) {
        stop()
        let client = self.client, pane = self.pane, mode = self.mode
        let geometry = HerdrGeometry.clamp(cols: cols, rows: rows)
        reader = Task { [weak self] in
            let socket: URLSessionWebSocketTask
            do {
                socket = try await client.makeHerdrSocket(pane: pane, mode: mode,
                                                          cols: geometry.cols, rows: geometry.rows)
            } catch {
                guard !Task.isCancelled else { return }
                handler(.ended(reason: nil))
                return
            }
            guard let self, !Task.isCancelled else {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
            self.task = socket
            socket.resume()
            var announced = false
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    if !announced {
                        announced = true
                        self.isOpen = true
                        self.flushPending()
                        handler(.opened(mode))
                    }
                    let data: Data = switch message {
                    case .string(let text): Data(text.utf8)
                    case .data(let value): value
                    @unknown default: Data()
                    }
                    // A line this client cannot parse is dropped, not fatal:
                    // the bridge is a pipe and a later Herdr may add fields.
                    if let decoded = try? HerdrStreamDecoder.decode(data) { handler(.message(decoded)) }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.isOpen = false
                    // The 409 is an HTTP status on the upgrade, so it lands on
                    // the task's response rather than inside the error.
                    if !announced, (socket.response as? HTTPURLResponse)?.statusCode == 409 {
                        handler(.controlInUse)
                    } else {
                        handler(.ended(reason: Self.closeReason(socket)))
                    }
                    return
                }
            }
        }
    }

    /// `control` takes Herdr's four commands. On `observe` the one accepted
    /// message is a resize, which the bridge answers by restarting the stream.
    func send(_ command: HerdrControlCommand) {
        guard let task, isOpen else { pending.append(command); return }
        task.send(.string(command.json)) { _ in }
    }

    private func flushPending() {
        let queued = pending
        pending = []
        for command in queued { send(command) }
    }

    /// `terminal.release` first, then the socket. Leaving a pane must not look
    /// to Herdr like a client that vanished mid-session.
    func release() {
        if mode == .control, isOpen { send(.release) }
        stop()
    }

    func stop() {
        reader?.cancel()
        reader = nil
        isOpen = false
        pending = []
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private static func closeReason(_ task: URLSessionWebSocketTask) -> String? {
        guard let data = task.closeReason, let text = String(data: data, encoding: .utf8),
              !text.isEmpty, text.utf8.count <= 120,
              text.allSatisfy({ $0.isLetter || $0 == "_" || $0.isNumber }) else { return nil }
        return text
    }
}

/// §1.1: "WS 掉后指数退避重连". The delays are this client's, the cap keeps a
/// host that is down from being hammered, and nothing is ever re-run on the
/// host — a reconnect asks for a repaint, not for the command again.
enum HerdrReconnectPolicy {
    static let maximumDelay: TimeInterval = 8

    static func delay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(maximumDelay, pow(2, Double(min(attempt, 8) - 1)) * 0.5)
    }
}

/// Keyboard and paste bytes on their way to `terminal.input`, which takes
/// `text` — so a multi-byte character split across two `send` callbacks must
/// not become two replacement characters.
struct HerdrInputEncoder {
    private var tail: [UInt8] = []

    /// Returns the text to send, holding back an incomplete trailing UTF-8
    /// sequence until its remaining bytes arrive.
    mutating func encode(_ bytes: [UInt8]) -> String? {
        var buffer = tail + bytes
        tail = []
        var split = buffer.count
        // Walk back over at most three continuation bytes to find a lead byte
        // whose sequence has not arrived in full yet.
        var index = buffer.count - 1
        var continuations = 0
        while index >= 0, continuations < 3, buffer[index] & 0b1100_0000 == 0b1000_0000 {
            index -= 1; continuations += 1
        }
        if index >= 0, buffer[index] & 0b1000_0000 != 0 {
            let lead = buffer[index]
            let expected = lead >= 0b1111_0000 ? 4 : lead >= 0b1110_0000 ? 3 : lead >= 0b1100_0000 ? 2 : 1
            if expected > 1, buffer.count - index < expected { split = index }
        }
        if split < buffer.count {
            tail = Array(buffer[split...])
            buffer = Array(buffer[..<split])
        }
        guard !buffer.isEmpty else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}
