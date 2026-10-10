import Foundation

/// TAIL-2 P0-1. Whether the event WebSocket is still a connection.
///
/// Core pings every socket every 20 s and closes one whose pong does not come
/// back (`omodachi-core` `network.py`, aiohttp `heartbeat=20`), so the *host*
/// notices a dead peer. Nothing told this side: `URLSessionWebSocketTask`
/// answers the host's pings by itself and never surfaces them, and a path that
/// died without a FIN leaves `receive()` waiting for ever. This is the
/// client's half: a ping every `pingInterval`, and the socket is declared dead
/// when a pong takes longer than `pongDeadline` or nothing at all — no frame,
/// no pong — arrived for `silence`.
public actor EventLiveness {
    public struct Timing: Sendable, Equatable {
        public var pingInterval: Duration
        public var pongDeadline: Duration
        public var silence: Duration
        public static let standard = Timing(pingInterval: .seconds(15), pongDeadline: .seconds(10),
                                            silence: .seconds(45))
        public init(pingInterval: Duration, pongDeadline: Duration, silence: Duration) {
            self.pingInterval = pingInterval
            self.pongDeadline = pongDeadline
            self.silence = silence
        }
    }

    /// HERDR-11 §3: how often the beat ping proves a socket alive, for the
    /// one connection clock (`ConnectionHealth`): well inside its 4 s amber.
    public static let beat: Duration = .seconds(2)

    private let timing: Timing
    private var lastActivity = ContinuousClock.now
    /// True once `watch` has decided the socket is dead. The reader uses it to
    /// say *why* its `receive()` failed.
    private(set) var declaredDead = false

    public init(timing: Timing = .standard) { self.timing = timing }

    /// A frame or a pong arrived.
    func noteActivity() { lastActivity = .now }

    /// Runs until the socket is judged dead (returns `true`) or the task is
    /// cancelled (returns `false`). `ping` sends one ping and reports whether
    /// its pong arrived within the deadline.
    func watch(ping: @Sendable () async -> Bool) async -> Bool {
        while !Task.isCancelled {
            do { try await Task.sleep(for: timing.pingInterval) } catch { return false }
            let answered = await ping()
            if Task.isCancelled { return false }
            if answered { lastActivity = .now }
            if !answered || ContinuousClock.now - lastActivity > timing.silence {
                declaredDead = true
                return true
            }
        }
        return false
    }

    /// One ping with a deadline. The pong handler of a socket whose path is
    /// gone may never be called, so whichever of the two — pong or deadline —
    /// comes first answers, exactly once, and the other is ignored.
    static func ping(_ task: URLSessionWebSocketTask, deadline: Duration) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { continuation in
            task.sendPing { error in
                if once.claim() { continuation.resume(returning: error == nil) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
