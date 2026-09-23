import Foundation

#if canImport(Citadel)
@preconcurrency import Citadel
import Crypto
import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH
#endif

/// The command started inside a newly allocated SSH PTY.
///
/// `.shell` leaves the user's login shell open. The other cases are fixed,
/// application-owned commands; caller supplied task text must never be placed
/// here. Ask-agent text is submitted through the host/core fixed-argv adapter.
public enum SSHLaunch: Sendable, Equatable {
    case shell
    case defaultAgent
    case herdrSession(String?)
    case fixedArgv([String])

    fileprivate var argv: [String]? {
        switch self {
        case .shell: return nil
        case .defaultAgent: return ["herdr", "agent", "attach", "default"]
        case .herdrSession(let name):
            if let name, !name.isEmpty { return ["herdr", "session", "attach", name] }
            return ["herdr"]
        case .fixedArgv(let argv): return argv
        }
    }
}

/// Values needed to create one SSH/PTY session. The private key is looked up
/// from Keychain by `privateKeyAccount`; no password or key is put on a host.
public struct SSHConnectionOptions: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let username: String
    public let privateKeyAccount: String
    public let launch: SSHLaunch
    public let terminal: String
    public let connectTimeoutSeconds: Int

    public init(
        host: String,
        port: Int = 22,
        username: String,
        privateKeyAccount: String,
        launch: SSHLaunch = .shell,
        terminal: String = "xterm-256color",
        connectTimeoutSeconds: Int = 5
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.privateKeyAccount = privateKeyAccount
        self.launch = launch
        self.terminal = terminal
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }
}

public struct SSHHostKeyChallenge: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let algorithm: String
    /// OpenSSH public-key text without a comment.
    public let openSSHPublicKey: String
    /// RFC 4648 SHA-256 fingerprint in the OpenSSH `SHA256:<base64>` form.
    public let fingerprintSHA256: String

    public init(host: String, port: Int, algorithm: String, openSSHPublicKey: String, fingerprintSHA256: String) {
        self.host = host
        self.port = port
        self.algorithm = algorithm
        self.openSSHPublicKey = openSSHPublicKey
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

public enum SSHTransportEvent: Sendable, Equatable {
    case connecting
    case connected
    case disconnected
    case failed(String)
}

public enum SSHTransportError: Error, LocalizedError, Equatable {
    case citadelDependencyUnavailable
    case invalidOptions(String)
    case missingPrivateKey(account: String)
    case unsupportedPrivateKey
    case notConnected
    case alreadyConnected
    case hostKeyRejected
    /// UX-3 §2. The host answered, accepted the username and refused the key.
    /// `swift-nio-ssh` is offered exactly one method here — `publickey` with
    /// this device's ed25519 key — so a refusal has no second method to fall
    /// back to and the client closes the connection itself. On the host that
    /// reads as `Connection closed by authenticating user ... [preauth]`,
    /// which is indistinguishable from a client that hung up for its own
    /// reasons unless this side says which it was.
    case authenticationRejected
    case connectionFailed(String)
    /// UX-2 §1. A sentence this app wrote, about a step this app named. It is
    /// the one connection failure that is safe to show as-is, because none of
    /// it came from the peer.
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .citadelDependencyUnavailable: return Strings.sshTransportUnavailable
        case .invalidOptions(let reason): return reason
        case .missingPrivateKey: return Strings.sshMissingKey
        case .unsupportedPrivateKey: return Strings.sshUnsupportedKey
        case .notConnected: return Strings.sshNotConnected
        case .alreadyConnected: return Strings.sshAlreadyConnected
        case .hostKeyRejected: return Strings.sshHostKeyRejected
        case .authenticationRejected: return Strings.sshKeyRejected
        case .connectionFailed(let reason): return reason
        case .timedOut(let reason): return reason
        }
    }
}

#if canImport(Citadel)
final class AsyncHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let tag: String
    let callback: @Sendable (SSHHostKeyChallenge) async throws -> Void

    init(host: String, port: Int, tag: String = "",
         callback: @escaping @Sendable (SSHHostKeyChallenge) async throws -> Void) {
        self.host = host
        self.port = port
        self.tag = tag
        self.callback = callback
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let algorithm = parts.first.map(String.init) ?? "unknown"
        let encoded = parts.dropFirst().first.map(String.init) ?? ""
        let rawKey = Data(base64Encoded: encoded) ?? Data()
        let digest = SHA256.hash(data: rawKey)
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let challenge = SSHHostKeyChallenge(
            host: host,
            port: port,
            algorithm: algorithm,
            openSSHPublicKey: openSSH,
            fingerprintSHA256: fingerprint
        )

        // UX-2 §1: the host key is the step that can wait on a person, so it
        // is the step most worth naming. A verdict that never arrives is the
        // attempt's deadline to end, not this promise's.
        SSHConnectionTrace.step(tag, "host-key", detail: challenge.fingerprintSHA256)
        Task {
            do {
                try await callback(challenge)
                SSHConnectionTrace.step(tag, "host-key-accepted", detail: challenge.algorithm)
                validationCompletePromise.succeed(())
            } catch {
                SSHConnectionTrace.failed(tag, step: "host-key", reason: String(describing: error))
                validationCompletePromise.fail(SSHTransportError.hostKeyRejected)
            }
        }
    }
}

private actor TTYBridge {
    private var writer: TTYStdinWriter?
    private var waiters: [CheckedContinuation<TTYStdinWriter, Error>] = []
    private var closed = false

    func setWriter(_ writer: TTYStdinWriter) {
        guard !closed else { return }
        self.writer = writer
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: writer) }
    }

    func getWriter() async throws -> TTYStdinWriter {
        if let writer { return writer }
        guard !closed else { throw SSHTransportError.notConnected }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func clear() { fail(SSHTransportError.notConnected) }

    /// Releases every waiter with the reason the attempt actually ended on.
    func fail(_ error: Error) {
        closed = true
        writer = nil
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: error) }
    }
}
#endif

/// Citadel-backed interactive SSH PTY transport.
///
/// The class deliberately exposes raw `Data` so SwiftTerm can decode UTF-8,
/// ANSI and partial multibyte sequences itself. It does not persist output.
@MainActor
public final class SSHTransport {
    public let options: SSHConnectionOptions
    public let output: AsyncThrowingStream<Data, Error>
    public let events: AsyncStream<SSHTransportEvent>

    private let privateKeyProvider: @Sendable () async throws -> Data?
    private let hostKeyValidator: @Sendable (SSHHostKeyChallenge) async throws -> Void
    private let outputContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let eventContinuation: AsyncStream<SSHTransportEvent>.Continuation
    private var task: Task<Void, Never>?
    private var connected = false
    private var started = false
    private var closed = false

#if canImport(Citadel)
    private let bridge = TTYBridge()
    private var client: SSHClient?
    /// The event loop group this attempt owns. Shutting it down closes the
    /// socket Citadel made on it, which is how a stalled handshake stops being
    /// something `sshd` has to time out at `LoginGraceTime` (UX-2 §1).
    private var group: MultiThreadedEventLoopGroup?
#endif
    /// The step the attempt is on, for the deadline's sentence and the trace.
    private var step = "idle"
    private var timedOutReason: String?
    private var traceTag = ""

    /// Short, unique and greppable: one attempt's lines share it.
    private static func newTag() -> String { String(UUID().uuidString.prefix(8)) }

    public init(
        options: SSHConnectionOptions,
        privateKeyProvider: @escaping @Sendable () async throws -> Data?,
        hostKeyValidator: @escaping @Sendable (SSHHostKeyChallenge) async throws -> Void
    ) {
        self.options = options
        self.privateKeyProvider = privateKeyProvider
        self.hostKeyValidator = hostKeyValidator
        let outputStream = AsyncThrowingStream<Data, Error>.makeStream()
        let eventStream = AsyncStream<SSHTransportEvent>.makeStream()
        self.output = outputStream.stream
        self.outputContinuation = outputStream.continuation
        self.events = eventStream.stream
        self.eventContinuation = eventStream.continuation
    }

    deinit {
        task?.cancel()
        outputContinuation.finish()
        eventContinuation.finish()
    }

    /// UX-2 §1. One attempt, with a deadline this side owns and a socket this
    /// side can close.
    ///
    /// The old body handed the whole thing to `SSHClient.connect(host:port:)`.
    /// That call owns the socket, and Citadel's own login timeout — ten
    /// seconds, hard-coded in `SSHClientSession.addHandlers` — fails the
    /// handshake future **without closing the channel**. A connection that
    /// stalls in the version exchange, the key exchange or user authentication
    /// therefore stayed open on the host until `sshd` killed it at
    /// `LoginGraceTime`, logged `Timeout before authentication`, and put the
    /// device's address in the `srclimit` penalty box — which drops the next
    /// connections outright. That is the failure the real iPad was in, and no
    /// amount of retrying could get out of it because every retry added
    /// another leaked socket. The same hole swallows a backgrounded app: iOS
    /// suspends the process mid-handshake, Citadel's ten second timer never
    /// fires, and the socket is still there when the process resumes.
    ///
    /// So the attempt runs on an event loop group **this object owns**, one
    /// thread, created per attempt. Citadel still makes the socket, but
    /// shutting the group down closes every channel registered on it — which
    /// is how the deadline, cancellation and `disconnect()` all reach a socket
    /// Citadel never handed back. (Handing Citadel a ready-made channel does
    /// not work: `SSHClientSession.addHandlers` uses `syncOperations`, which
    /// must run on the event loop, and `SSHClient.connect(on:)` is `async`, so
    /// it never is.)
    public func connect(cols: Int, rows: Int) async throws {
        // RELEASE-3b: an empty account is what a profile carries when pairing
        // gave no SSH target (`HostProfile.username` defaults to ""), so the
        // sentence says that instead of "the options are invalid".
        guard options.username.isEmpty == false else {
            throw SSHTransportError.invalidOptions(Strings.sshNoPairedTarget)
        }
        guard options.host.isEmpty == false else {
            throw SSHTransportError.invalidOptions(Strings.sshOptionsInvalid)
        }
        guard (1...65_535).contains(options.port), cols > 0, rows > 0 else {
            throw SSHTransportError.invalidOptions(Strings.sshOptionsInvalid)
        }
        guard !started, !closed else { throw SSHTransportError.alreadyConnected }
        started = true
        if let argv = options.launch.argv {
            guard !argv.isEmpty, !argv[0].isEmpty, !argv.contains(where: { $0.contains("\0") }) else {
                throw SSHTransportError.invalidOptions(Strings.sshOptionsInvalid)
            }
        }
        let tag = Self.newTag()
        traceTag = tag
        SSHConnectionTrace.step(tag, "start", detail: "\(options.username)@\(options.host):\(options.port)")
        eventContinuation.yield(.connecting)
#if canImport(Citadel)
        step = "key"
        guard let keyData = try await privateKeyProvider() else {
            SSHConnectionTrace.failed(tag, step: "key", reason: "no key for \(options.privateKeyAccount)")
            throw SSHTransportError.missingPrivateKey(account: options.privateKeyAccount)
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            if keyData.count == 32 {
                privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
            } else {
                privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyData)
            }
        } catch {
            SSHConnectionTrace.failed(tag, step: "key", reason: "unsupported private key")
            throw SSHTransportError.unsupportedPrivateKey
        }
        // UX-3 §2: the *fingerprint*, not the Keychain account. The account is
        // a local name nobody can compare against anything; the fingerprint is
        // the same string `omodachi-host ssh list` prints, so one glance at the
        // trace settles whether the host is holding this device's key at all.
        SSHConnectionTrace.step(tag, "key-ready",
                                detail: CompanionSSHKey.fingerprint(privateKey.publicKey.rawRepresentation))

        let deadline = armDeadline(tag: tag)
        defer { deadline.cancel() }
        do {
            try await dial(privateKey: privateKey, cols: cols, rows: rows, tag: tag)
        } catch {
            let failure = resolveFailure(error, tag: tag)
            await tearDown()
            if case .cancelled = failure { throw CancellationError() }
            if case .transport(let transportError) = failure {
                switch transportError {
                case .connectionFailed(let reason), .timedOut(let reason):
                    eventContinuation.yield(.failed(reason))
                default: break
                }
                throw transportError
            }
            throw error
        }
#else
        eventContinuation.yield(.failed(SSHTransportError.citadelDependencyUnavailable.localizedDescription))
        throw SSHTransportError.citadelDependencyUnavailable
#endif
    }

#if canImport(Citadel)
    private enum ConnectFailure { case cancelled, transport(SSHTransportError) }

    /// What the attempt should be reported as. A deadline that has already
    /// fired wins over whatever error the interrupted step happened to raise —
    /// "the host did not finish the handshake" is the true sentence, and
    /// `notConnected` from a cleared bridge is not.
    private func resolveFailure(_ error: Error, tag: String) -> ConnectFailure {
        if let reason = timedOutReason {
            return .transport(.timedOut(reason))
        }
        if error is CancellationError { return .cancelled }
        if closed { return .cancelled }
        if let transportError = error as? SSHTransportError { return .transport(transportError) }
        SSHConnectionTrace.failed(tag, step: step, reason: String(describing: error))
        // The handshake's own errors arrive through the PTY task, so they are
        // whatever NIOSSH raised. They are still an SSH connection failure.
        return .transport(.connectionFailed(String(describing: error)))
    }

    /// Citadel offers one method and keeps no spare: when `publickey` is
    /// refused, `nextAuthenticationType` finds its list empty and fails the
    /// promise with `allAuthenticationOptionsFailed`
    /// (`SSHAuthenticationMethod.swift:83-86`). Matching on the description
    /// rather than the case keeps this working if the package renames it, and
    /// this only ever chooses a sentence - it never admits a connection.
    static func describesARefusedKey(_ error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("allAuthenticationOptionsFailed")
            || text.contains("unsupportedPrivateKeyAuthentication")
    }

    /// The attempt's own clock. Nothing here is allowed to outlive it: the
    /// socket is closed and every waiter is released, so the caller gets a
    /// sentence instead of a spinner and `sshd` gets a FIN instead of a
    /// connection to babysit for two minutes.
    /// What the user reads. It names the step, because "SSH connection ended
    /// or was refused" was true of all six of them and useful for none.
    static func timeoutSentence(step: String, seconds: Int) -> String {
        switch step {
        case "tcp": return Strings.sshFailedHandshake("\(seconds)")
        case "host-key": return Strings.sshFailedHostKeyWait
        case "auth": return Strings.sshFailedAuth("\(seconds)")
        case "pty-request", "pty": return Strings.sshFailedShell("\(seconds)")
        default: return Strings.sshFailedHandshake("\(seconds)")
        }
    }

    private func armDeadline(tag: String) -> Task<Void, Never> {
        let budget = max(1, options.connectTimeoutSeconds)
        return Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(budget))
            guard let self, !Task.isCancelled, !self.connected, !self.closed else { return }
            let at = self.step
            self.timedOutReason = Self.timeoutSentence(step: at, seconds: budget)
            SSHConnectionTrace.failed(tag, step: at, reason: "deadline \(budget)s")
            await self.tearDown()
        }
    }

    /// Closes the socket and releases everything waiting on it. Safe to call
    /// more than once and from either the deadline or `disconnect()`.
    private func tearDown() async {
        let loops = group
        group = nil
        let live = client
        client = nil
        await bridge.clear()
        if let live { try? await live.close() }
        if let loops { try? await loops.shutdownGracefully() }
    }

    private func dial(privateKey: Curve25519.Signing.PrivateKey, cols: Int, rows: Int, tag: String) async throws {
        step = "tcp"
        // The TCP half gets its own, shorter bound: a host that is off or
        // behind a dropped route must not spend the whole budget here.
        let tcpSeconds = min(max(1, options.connectTimeoutSeconds), 4)
        let loops = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        group = loops
        let delegate = AsyncHostKeyDelegate(host: options.host, port: options.port, tag: tag,
                                            callback: hostKeyValidator)
        let auth = SSHAuthenticationMethod.ed25519(username: options.username, privateKey: privateKey)
        let connectedClient: SSHClient
        do {
            // UX-3 §2. `SSHClient.connect` resolves only on
            // `UserAuthSuccessEvent` (Citadel `ClientSession.swift:85-88`), so
            // the version exchange, the key exchange, the host key and userauth
            // all happen inside this one call. The label has to say so while it
            // is running, or the deadline reports whichever step was set last —
            // which used to be `auth`, set *after* the PTY request had already
            // started, so a timeout in the PTY phase was labelled `auth` and a
            // timeout during userauth was labelled `pty-request`.
            defer { step = "auth" }
            connectedClient = try await SSHClient.connect(
                host: options.host,
                port: options.port,
                authenticationMethod: auth,
                hostKeyValidator: .custom(delegate),
                reconnect: .never,
                group: loops,
                connectTimeout: .seconds(Int64(tcpSeconds))
            )
        } catch {
            SSHConnectionTrace.failed(tag, step: step, reason: String(describing: error))
            if Self.describesARefusedKey(error) {
                throw SSHTransportError.authenticationRejected
            }
            throw SSHTransportError.connectionFailed(String(describing: error))
        }
        guard !closed, !Task.isCancelled, timedOutReason == nil else {
            try? await connectedClient.close()
            throw CancellationError()
        }
        client = connectedClient
        SSHConnectionTrace.step(tag, "authenticated", detail: "\(options.host):\(options.port)")
        step = "pty-request"

        connectedClient.onDisconnect { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connected else { return }
                self.connected = false
                self.eventContinuation.yield(.disconnected)
            }
        }

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: options.terminal,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let launch = options.launch.argv
        let bridge = self.bridge
        let outputContinuation = self.outputContinuation
        task = Task { [weak self, connectedClient] in
            do {
                try await connectedClient.withPTY(request) { @Sendable [weak self] inbound, writer in
                    guard await self?.canStartPTY == true else { throw CancellationError() }
                    await MainActor.run { self?.step = "pty" }
                    if let launch {
                        let command = "exec " + launch.map(Self.shellEscape).joined(separator: " ") + "\n"
                        try await writer.write(ByteBuffer(string: command))
                    }
                    await MainActor.run {
                        guard let self, !self.closed else { return }
                        self.connected = true
                        self.eventContinuation.yield(.connected)
                    }
                    // Publish the writer only after `connected` is visible, so
                    // connect() cannot return a usable writer while send() still
                    // observes the pre-connect state.
                    await bridge.setWriter(writer)
                    for try await item in inbound {
                        switch item {
                        case .stdout(let buffer), .stderr(let buffer):
                            outputContinuation.yield(Data(buffer.readableBytesView))
                        }
                    }
                }
                outputContinuation.finish()
                try? await connectedClient.close()
                await bridge.clear()
                await MainActor.run { self?.connected = false; _ = self?.eventContinuation.yield(.disconnected) }
            } catch {
                outputContinuation.finish(throwing: error)
                try? await connectedClient.close()
                await bridge.fail(error)
                await MainActor.run {
                    guard let self else { return }
                    self.connected = false
                    // Explicit detach/cancel already published disconnected.
                    // A late channel-close error must not turn it into failure.
                    if !self.closed && self.timedOutReason == nil {
                        self.eventContinuation.yield(.failed(String(describing: error)))
                    }
                }
            }
        }
        // Wait until withPTY installed its writer and emitted connected. NIOSSH
        // holds that channel request until user authentication succeeded, so
        // this is the handshake's finish line.
        _ = try await bridge.getWriter()
        SSHConnectionTrace.step(tag, "connected", detail: "\(cols)x\(rows)")
        step = "connected"
    }
#endif

    public func send(_ data: Data) async throws {
#if canImport(Citadel)
        guard connected else { throw SSHTransportError.notConnected }
        let writer = try await bridge.getWriter()
        try await writer.write(ByteBuffer(bytes: data))
#else
        _ = data
        throw SSHTransportError.citadelDependencyUnavailable
#endif
    }

    public func resize(cols: Int, rows: Int) async throws {
        guard cols > 0, rows > 0 else { throw SSHTransportError.invalidOptions(Strings.sshOptionsInvalid) }
#if canImport(Citadel)
        guard connected else { throw SSHTransportError.notConnected }
        let writer = try await bridge.getWriter()
        try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
#else
        throw SSHTransportError.citadelDependencyUnavailable
#endif
    }

    public func disconnect() async {
        guard !closed else { return }
        closed = true
        connected = false
#if canImport(Citadel)
        task?.cancel()
        task = nil
        await bridge.clear()
        if let client {
            try? await client.close()
            self.client = nil
        }
        // The loops go even when there is no client yet: a connect that is
        // still in its handshake is exactly the case that used to leak.
        if let loops = group {
            group = nil
            try? await loops.shutdownGracefully()
        }
        SSHConnectionTrace.step(traceTag, "disconnected", detail: step)
#endif
        connected = false
        outputContinuation.finish()
        eventContinuation.yield(.disconnected)
        eventContinuation.finish()
    }

    private var canStartPTY: Bool { !closed && !Task.isCancelled }

#if canImport(Citadel)
    nonisolated private static func shellEscape(_ value: String) -> String {
        guard value.isEmpty == false else { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
#endif
}
