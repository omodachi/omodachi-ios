import XCTest
import Foundation
import CryptoKit
@testable import Omodachi

/// The suite owns Tools/SSHFixture/server.py: setUp starts it, tearDown stops it,
/// so a plain `xcodebuild test` exercises the real Citadel SSH/PTY path. The only
/// skip is a missing python3 that cannot be bootstrapped; it names what went
/// unvalidated. An already-listening fixture (Tools/SSHFixture/run-tests.sh) is
/// reused and never killed.
@MainActor
final class SSHTransportIntegrationTests: XCTestCase {
    private let host = "127.0.0.1"
    private let port = 22222
    private let username = "omodachi-test"
    private let clientSeed = Data(repeating: 0x4F, count: 32)

    override func setUp() async throws {
        try await super.setUp()
        try SSHFixtureProcess.startShared()
    }

    override class func tearDown() {
        SSHFixtureProcess.stopShared()
        super.tearDown()
    }

    func testRealPTYUnicodeResizeAndReconnectUsingSystemKeychain() async throws {
        let material = try makeMaterial()
        defer { material.cleanup() }
        XCTAssertEqual(try material.keys.loadPrivateKey(account: material.id), clientSeed)
        let expectedFingerprint = try material.pins.confirm(host: host, port: port, openSSHPublicKey: publicKey(seed: Data(repeating: 0x48, count: 32)))

        for iteration in 0..<2 {
            let ready = expectation(description: "PTY ready \(iteration)")
            let unicode = expectation(description: "Chinese bytes preserved \(iteration)")
            let resized = expectation(description: "PTY 93x31 \(iteration)")
            let events = EventRecorder()
            let transport = makeTransport(material: material, expectedFingerprint: expectedFingerprint)
            let eventReader = Task { for await event in transport.events { await events.record(event) } }
            let reader = Task {
                var received = Data()
                var didReady = false, didUnicode = false, didResize = false
                do {
                    for try await data in transport.output {
                        received.append(data)
                        // Inspect synthesized fixture text only; transport keeps bytes.
                        if !didReady && received.range(of: Data("OMODACHI_FIXTURE_READY".utf8)) != nil { didReady = true; ready.fulfill() }
                        if !didUnicode && received.range(of: Data("中文输入✓".utf8)) != nil { didUnicode = true; unicode.fulfill() }
                        if !didResize && received.range(of: Data("OMODACHI_SIZE=93x31".utf8)) != nil { didResize = true; resized.fulfill() }
                    }
                } catch { XCTFail("Fixture output failed: \(error)") }
            }
            do {
                try await transport.connect(cols: 80, rows: 24)
                await fulfillment(of: [ready], timeout: 8)
                let bytes = Data("中文输入✓".utf8)
                try await transport.send(Data(bytes.prefix(2)))
                try await transport.send(Data(bytes.dropFirst(2)))
                // Finish byte-preservation validation before the fixture emits
                // its separate resize marker into the same terminal stream.
                await fulfillment(of: [unicode], timeout: 8)
                try await transport.resize(cols: 93, rows: 31)
                await fulfillment(of: [resized], timeout: 8)
                await transport.disconnect()
                await reader.value
                await eventReader.value
                let observed = await events.values
                XCTAssertTrue(observed.contains(.connected))
                XCTAssertTrue(observed.contains(.disconnected))
                XCTAssertFalse(observed.contains(where: { if case .failed = $0 { return true }; return false }))
                do { try await transport.send(Data([0x61])); XCTFail("Closed PTY accepted input") }
                catch { XCTAssertEqual(error as? SSHTransportError, .notConnected) }
                eventReader.cancel()
            } catch {
                await transport.disconnect()
                reader.cancel()
                eventReader.cancel()
                throw error
            }
        }
    }

    func testChangedHostKeyRejectsBeforePTY() async throws {
        let material = try makeMaterial()
        defer { material.cleanup() }
        _ = try material.pins.confirm(host: host, port: port, openSSHPublicKey: publicKey(seed: Data(repeating: 0x49, count: 32)))
        let check = ChallengeRecorder()
        let transport = makeTransport(material: material, challengeRecorder: check)
        do { try await transport.connect(cols: 80, rows: 24); XCTFail("Changed host key accepted") }
        catch { XCTAssertTrue(error is SSHTransportError) }
        await transport.disconnect()
        let challenges = await check.count
        XCTAssertEqual(challenges, 1, "Must reach real SSH server and reject its actual key")
        let actualKey = try publicKey(seed: Data(repeating: 0x48, count: 32))
        guard case .mismatch = try material.pins.verify(host: host, port: port, openSSHPublicKey: actualKey) else {
            return XCTFail("Host-key rejection silently overwrote the pin")
        }
    }

    func testUnauthorizedUserRejectedAfterTrustedHostKey() async throws {
        let material = try makeMaterial()
        defer { material.cleanup() }
        _ = try material.pins.confirm(host: host, port: port, openSSHPublicKey: publicKey(seed: Data(repeating: 0x48, count: 32)))
        let check = ChallengeRecorder()
        let transport = makeTransport(material: material, username: "unauthorized-test-user", challengeRecorder: check)
        do { try await transport.connect(cols: 80, rows: 24); XCTFail("Unauthorized username authenticated") }
        catch { XCTAssertTrue(error is SSHTransportError) }
        await transport.disconnect()
        let challenges = await check.count
        XCTAssertEqual(challenges, 1)
    }

    func testDisconnectDuringHostKeyCheckDoesNotResurrectPTY() async throws {
        let material = try makeMaterial()
        defer { material.cleanup() }
        let arrived = expectation(description: "Real host key received")
        let gate = ValidationGate()
        let events = EventRecorder()
        let transport = SSHTransport(
            options: SSHConnectionOptions(host: host, port: port, username: username, privateKeyAccount: material.id, connectTimeoutSeconds: 5),
            privateKeyProvider: { try material.keys.loadPrivateKey(account: material.id) },
            hostKeyValidator: { _ in arrived.fulfill(); await gate.wait() }
        )
        let eventReader = Task { for await event in transport.events { await events.record(event) } }
        let connecting = Task { try await transport.connect(cols: 80, rows: 24) }
        await fulfillment(of: [arrived], timeout: 8)
        await transport.disconnect()
        await gate.release()
        do { try await connecting.value; XCTFail("Cancelled connect resurrected a PTY") }
        catch { XCTAssertTrue(error is CancellationError) }
        let observed = await events.values
        XCTAssertFalse(observed.contains(.connected))
        eventReader.cancel()
    }

    /// UX-2 §1. The failure the real iPad was in: the host accepts the socket
    /// and then nothing happens on it. Citadel's own login timeout is ten
    /// seconds, hard-coded, and it fails the handshake **without closing the
    /// channel** — so `sshd` held the connection for the whole of
    /// `LoginGraceTime`, logged `Timeout before authentication`, and put the
    /// address in its `srclimit` penalty box.
    ///
    /// Two things are asserted, and the second is the one that matters to the
    /// host: the attempt gives up inside its own budget with a sentence that
    /// names a step, and the socket is gone when it does.
    func testASilentServerFailsInsideTheBudgetAndClosesTheSocket() async throws {
        let silent = try SilentTCPServer()
        defer { silent.stop() }
        let material = try makeMaterial()
        defer { material.cleanup() }
        let transport = SSHTransport(
            options: SSHConnectionOptions(host: "127.0.0.1", port: silent.port, username: username,
                                          privateKeyAccount: material.id, connectTimeoutSeconds: 3),
            privateKeyProvider: { try material.keys.loadPrivateKey(account: material.id) },
            hostKeyValidator: { _ in })
        let started = Date()
        do {
            try await transport.connect(cols: 80, rows: 24)
            XCTFail("A server that never speaks SSH produced a shell")
        } catch {
            guard let failure = error as? SSHTransportError, case .timedOut(let reason) = failure else {
                return XCTFail("Expected a named timeout, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 6, "The attempt outlived its own deadline")
        // The host's half: the connection it accepted is closed, and it did not
        // have to wait out LoginGraceTime to find that out.
        let closed = await silent.waitForClose(seconds: 5)
        XCTAssertTrue(closed, "The stalled handshake left its socket open")
        await transport.disconnect()
    }

    /// The ladder that used to be 1, 2, 4 — three more connections inside
    /// seven, which is what earned the penalty in the first place.
    func testTheReattachLadderLeavesTheHostTimeToForget() {
        XCTAssertEqual(TerminalRuntime.reattachDelays, [4, 12, 30])
    }

    /// A deadline says which step it gave up on, because the one line that
    /// covered all of them told the user nothing.
    func testTheTimeoutSentenceNamesTheStep() {
        XCTAssertEqual(SSHTransport.timeoutSentence(step: "host-key", seconds: 5), Strings.sshFailedHostKeyWait)
        XCTAssertEqual(SSHTransport.timeoutSentence(step: "pty", seconds: 5), Strings.sshFailedShell("5"))
        XCTAssertNotEqual(SSHTransport.timeoutSentence(step: "tcp", seconds: 5),
                          SSHTransport.timeoutSentence(step: "host-key", seconds: 5))
    }

    private struct TestMaterial: Sendable {
        let id: String
        let keys: SSHKeyStore
        let pins: HostKeyStore
        func cleanup() {
            do {
                try keys.removePrivateKey(account: id)
                try pins.reset(host: "127.0.0.1", port: 22222)
                XCTAssertNil(try keys.loadPrivateKey(account: id))
                XCTAssertNil(try pins.pinnedFingerprint(host: "127.0.0.1:22222"))
            } catch { XCTFail("Temporary system Keychain cleanup failed: \(error)") }
        }
    }

    private func makeMaterial() throws -> TestMaterial {
        let id = UUID().uuidString
        // Default backing store is SystemKeychainRecordStore, never MemoryKeychain.
        let material = TestMaterial(id: id,
            keys: SSHKeyStore(service: "com.omodachi.tests.ssh.keys.\(id)"),
            pins: HostKeyStore(service: "com.omodachi.tests.ssh.hostkeys.\(id)"))
        try material.keys.savePrivateKey(clientSeed, account: id)
        return material
    }

    private func makeTransport(material: TestMaterial, username: String? = nil, expectedFingerprint: String? = nil, challengeRecorder: ChallengeRecorder? = nil) -> SSHTransport {
        SSHTransport(options: SSHConnectionOptions(host: host, port: port, username: username ?? self.username, privateKeyAccount: material.id, connectTimeoutSeconds: 5),
            privateKeyProvider: { try material.keys.loadPrivateKey(account: material.id) },
            hostKeyValidator: { challenge in
                await challengeRecorder?.record()
                if let expectedFingerprint { XCTAssertEqual(challenge.fingerprintSHA256, expectedFingerprint) }
                switch try material.pins.verify(host: challenge.host, port: challenge.port, openSSHPublicKey: challenge.openSSHPublicKey) {
                case .accepted: return
                case .firstSeen, .mismatch: throw SSHTransportError.hostKeyRejected
                }
            })
    }

    private func publicKey(seed: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        var blob = Data()
        for part in [Data("ssh-ed25519".utf8), key.publicKey.rawRepresentation] {
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
            blob.append(part)
        }
        return "ssh-ed25519 " + blob.base64EncodedString()
    }
}

private actor EventRecorder {
    private(set) var values: [SSHTransportEvent] = []
    func record(_ event: SSHTransportEvent) { values.append(event) }
}
private actor ChallengeRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}
private actor ValidationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}


/// Accepts one TCP connection and says nothing at all — a host whose `sshd`
/// took the socket and never got to the version exchange.
private final class SilentTCPServer: @unchecked Sendable {
    private let listener: Int32
    let port: Int
    private var accepted: Int32 = -1
    private let lock = NSLock()
    private var closedAt: Date?

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SilentServerError.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw SilentServerError.bind }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0 else { close(fd); throw SilentServerError.bind }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        start(fd: fd)
    }

    private func start(fd: Int32) {
        Thread.detachNewThread { [weak self] in
            let child = accept(fd, nil, nil)
            guard child >= 0, let self else { return }
            self.lock.lock(); self.accepted = child; self.lock.unlock()
            // Read until EOF. The client closing is the only thing that ends it.
            var byte: UInt8 = 0
            while recv(child, &byte, 1, 0) > 0 {}
            self.lock.lock(); self.closedAt = Date(); self.lock.unlock()
            close(child)
        }
    }

    var didClose: Bool {
        lock.lock(); defer { lock.unlock() }
        return closedAt != nil
    }

    func waitForClose(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if didClose { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func stop() {
        lock.lock(); let child = accepted; lock.unlock()
        if child >= 0 { close(child) }
        close(listener)
    }

    enum SilentServerError: Error { case socket, bind }
}
