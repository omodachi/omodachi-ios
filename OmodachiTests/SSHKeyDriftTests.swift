import XCTest
@testable import Omodachi

/// UX-4. The state Leo's iPad was actually in on 2026-09-22 10:25:
///
/// ```
/// Failed publickey for alex from 192.168.1.24 … ED25519 SHA256:/BMHTpouQsyo…
/// ```
///
/// and `omodachi-host ssh list` holding two keys, neither of them that one.
/// The iPad was offering a third key the host had never seen.
///
/// The mechanism has two halves and they are both in this app. The SSH private
/// key is kept in the Keychain under `ssh-<profile id>`, and the profile lives
/// in `UserDefaults`, which the app container owns. The companion credential
/// and the TLS pin live in the Keychain, which outlives the container. So a
/// reinstall — which is what every one of these rounds hands Leo — produces a
/// device that is still paired, still holding a live credential, and holding a
/// key nobody has ever authorized. PAIR-4's adoption path then settles the
/// credential *without sending a pairing request*, which is correct, and the
/// key goes up with a pairing request, which is the half that is missing.
@MainActor final class SSHKeyDriftTests: XCTestCase {

    // MARK: - §1 the root cause, as an assertion

    /// The whole of it in six lines: the key is keyed by the profile id, the
    /// profile id does not survive a reinstall, and the Keychain does.
    func testAReinstallGivesThisDeviceAKeyTheHostHasNeverSeen() throws {
        let records = KeyRecords()
        let store = SSHKeyStore(service: "com.omodachi.tests.ux4.\(UUID().uuidString)", records: records)

        // First install: one profile, one key, and that is the key that rides
        // up with the pairing request and lands in `authorized_keys`.
        let first = HostProfile()
        let paired = try XCTUnwrap(CompanionSSHKey.publicKeyLine(account: first.keyAccount, store: store))

        // Reinstall. `UserDefaults` is gone, so `HomeStore` makes a new
        // profile with a new id; the Keychain, and everything keyed by the
        // host rather than the profile, is still here.
        let second = HostProfile()
        XCTAssertNotEqual(first.keyAccount, second.keyAccount,
                          "the account is derived from the profile id, which is new")
        let offered = try XCTUnwrap(CompanionSSHKey.publicKeyLine(account: second.keyAccount, store: store))

        XCTAssertNotEqual(paired, offered, "a new account means a newly generated private key")
        XCTAssertNotEqual(SSHKeyOffer.fingerprint(of: paired), SSHKeyOffer.fingerprint(of: offered))
        // And the old key is still sitting in the Keychain, unreachable,
        // because nothing knows the old profile id any more. That is why the
        // host ends up holding keys for a device that cannot use any of them.
        XCTAssertNotNil(try store.loadPrivateKey(account: first.keyAccount))
    }

    /// The fingerprint this app prints is the string `ssh-keygen -lf`,
    /// `sshd`'s journal and `omodachi-host ssh list` all print. It is pinned to
    /// core's own output for a fixed key, because a fingerprint that is only
    /// self-consistent compares equal to nothing on the host.
    func testTheFingerprintIsTheStringTheHostPrints() {
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f omodachi-fixture"
        // Produced by `omodachi_core.ssh_keys.fingerprint` for this exact line.
        XCTAssertEqual(SSHKeyOffer.fingerprint(of: line), "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA")
        // Trailing comment, extra spaces and a missing comment are all one line.
        XCTAssertEqual(SSHKeyOffer.fingerprint(of: String(line.dropLast("omodachi-fixture".count))),
                       "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA")
        XCTAssertNil(SSHKeyOffer.fingerprint(of: "ssh-rsa AAAAB3NzaC1yc2E= alex@mac"))
        XCTAssertNil(SSHKeyOffer.fingerprint(of: "not a key"))
    }

    // MARK: - §2 the wire

    func testReadingAndOfferingCarryTheCredentialOverThePinnedCertificate() async throws {
        let fixture = try KeyFixture()
        fixture.store()
        KeyStub.reset(held: ["SHA256:somethingElseEntirely" + String(repeating: "x", count: 22)])

        let read = try await fixture.offer.read(account: fixture.account, keyAccount: fixture.keyAccount)
        XCTAssertEqual(read.deviceID, "ios-host-says")
        XCTAssertFalse(read.matches, "the host is holding a key this device does not have")
        XCTAssertEqual(KeyStub.methods, ["GET"], "a read never writes")
        XCTAssertEqual(KeyStub.authorizations, ["Bearer ux4-token"])

        let offered = try await fixture.offer.offer(account: fixture.account, keyAccount: fixture.keyAccount)
        XCTAssertEqual(KeyStub.methods, ["GET", "PUT"])
        XCTAssertTrue(offered.matches, "after the offer, the host holds this device's key")
        XCTAssertEqual(offered.hostFingerprints, [read.localFingerprint])
        // The body is one OpenSSH line and nothing else — no device id, no
        // private half, no key this device is not actually holding.
        let body = try XCTUnwrap(KeyStub.bodies.last)
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(Array(sent.keys), ["public_key"])
        XCTAssertEqual(SSHKeyOffer.fingerprint(of: try XCTUnwrap(sent["public_key"])), read.localFingerprint)
    }

    /// The credential is this device's secret. A host this device has no pin
    /// for is a host it will not put that secret on, so the repair refuses
    /// before anything leaves the device.
    func testAHostWithNoPinIsNeverSentTheCredential() async throws {
        let fixture = try KeyFixture()
        try fixture.credentials.saveToken("ux4-token", account: fixture.account)
        KeyStub.reset(held: [])
        do {
            _ = try await fixture.offer.offer(account: fixture.account, keyAccount: fixture.keyAccount)
            XCTFail("expected notPaired")
        } catch { XCTAssertEqual(error as? SSHKeyOfferError, .notPaired) }
        XCTAssertEqual(KeyStub.methods, [], "nothing at all went on the wire")
    }

    func testAHostThatRefusesTheKeySaysWhichCodeItRefusedWith() async throws {
        let fixture = try KeyFixture()
        fixture.store()
        KeyStub.reset(held: [], refusal: (409, "public_key_not_owned"))
        do {
            _ = try await fixture.offer.offer(account: fixture.account, keyAccount: fixture.keyAccount)
            XCTFail("expected refused")
        } catch {
            XCTAssertEqual(error as? SSHKeyOfferError, .refused(code: "public_key_not_owned"))
        }
        // A revoked credential is not a refusal to fix; it is a device that has
        // to pair again, and it says so under its own name.
        KeyStub.reset(held: [], refusal: (401, "permission_denied"))
        do {
            _ = try await fixture.offer.read(account: fixture.account, keyAccount: fixture.keyAccount)
            XCTFail("expected notPaired")
        } catch { XCTAssertEqual(error as? SSHKeyOfferError, .notPaired) }
    }

    // MARK: - §2 adoption

    /// The bug, end to end: adopting a live credential used to leave the key
    /// behind because the key rides on a pairing request and adoption sends
    /// none. Now the adoption asks what the host holds and offers the key.
    func testAdoptingACredentialOffersTheKeyTheHostDoesNotHold() async throws {
        let fixture = try AdoptionFixture(hostHolds: ["SHA256:aKeyFromBeforeTheReinstallxxxxxxxxxxxxxxxxxx"])
        await fixture.select()
        XCTAssertNotNil(fixture.flow.claimed, "the credential is still adopted")
        XCTAssertEqual(fixture.keys.reads, 1)
        XCTAssertEqual(fixture.keys.offers, 1, "the host was holding somebody else's key")
    }

    /// And the ordinary case costs one read and changes nothing: the key went
    /// up with the pairing request, so the host already holds it.
    func testAKeyTheHostAlreadyHoldsIsNotRewritten() async throws {
        let fixture = try AdoptionFixture(hostHolds: [FakeKeyOffer.localFingerprint])
        await fixture.select()
        XCTAssertNotNil(fixture.flow.claimed)
        XCTAssertEqual(fixture.keys.reads, 1)
        XCTAssertEqual(fixture.keys.offers, 0)
    }

    /// A host that will not answer this question does not stop a pairing. The
    /// SSH panel's own repair is the second chance, and it is one tap away.
    func testAHostThatCannotAnswerStillLeavesTheDevicePaired() async throws {
        let fixture = try AdoptionFixture(hostHolds: [], unreachable: true)
        await fixture.select()
        XCTAssertNotNil(fixture.flow.claimed)
        XCTAssertNil(fixture.flow.failure)
        XCTAssertEqual(fixture.keys.offers, 0)
    }

    // MARK: - §2 the one repair, on the gate

    func testTheGateHandsOutOneKeyRepairUntilAConnectionSucceeds() {
        let gate = SSHDialGate()
        let host = SSHConnectionIdentity(profileID: UUID(), hostname: "omarchy", port: 22,
                                         username: "alex", mock: false, keyAccount: "ssh-1")
        let other = SSHConnectionIdentity(profileID: UUID(), hostname: "studio", port: 22,
                                          username: "alex", mock: false, keyAccount: "ssh-1")
        XCTAssertTrue(gate.claimKeyRepair(host))
        XCTAssertFalse(gate.claimKeyRepair(host), "a panel reopened is not another repair")
        XCTAssertTrue(gate.claimKeyRepair(other), "the budget is per host, like the ladder")
        // A dial that worked is the proof the key is right, so the next drift
        // gets its own repair.
        gate.finished(host, success: true)
        XCTAssertTrue(gate.claimKeyRepair(host))
        gate.finished(host, success: false)
        XCTAssertFalse(gate.claimKeyRepair(host), "a failure does not refill it")
        // And neither does clearing the ladder. The repair re-dials through
        // `reset`, so a budget `reset` refilled would be an endless loop —
        // which is exactly what the first draft of this did, 9061 times.
        gate.reset(host)
        XCTAssertFalse(gate.claimKeyRepair(host))
        gate.finished(host, success: true)
        XCTAssertTrue(gate.claimKeyRepair(host))
    }

    // MARK: - §2 the SSH panel repairs itself

    /// The acceptance shape, without a host: the dial is refused at
    /// `publickey`, the device offers its key once, and dials again.
    func testARefusedKeyIsReplacedOnceAndThenDialledAgain() async throws {
        let keys = FakeKeyOffer(hostHolds: [])
        let transport = RefusingTransport()
        let store = SessionStore(defaults: try scratchDefaults(), keyOffer: keys,
                                 factory: { _ in transport })
        var profile = HostProfile()
        profile.mock = false
        profile.companionURL = "https://omarchy:8099"
        let runtime = store.create(SessionDescriptor(title: "SSH", kind: .shell, host: profile, argv: []))
        runtime.appeared()

        try await settle { transport.attempts == 2 }
        XCTAssertEqual(keys.offers, 1, "one refusal, one replacement")
        XCTAssertEqual(transport.attempts, 2, "and one more dial with the key the host now holds")

        // The host refuses that one too. There is no second replacement: the
        // sentence a person can act on is what is left.
        try await settle { runtime.errorMessage == Strings.sshKeyRejected }
        XCTAssertEqual(keys.offers, 1)
        XCTAssertEqual(runtime.errorMessage, Strings.sshKeyRejected)
        await runtime.disconnect()
    }

    /// A mock host has no key and no companion, so it never reaches any of
    /// this — the demo fixture must not try to talk to a computer.
    func testAMockHostNeverOffersAnything() async throws {
        let keys = FakeKeyOffer(hostHolds: [])
        let transport = RefusingTransport()
        let store = SessionStore(defaults: try scratchDefaults(), keyOffer: keys,
                                 factory: { _ in transport })
        var profile = HostProfile()
        profile.mock = true
        let runtime = store.create(SessionDescriptor(title: "SSH", kind: .shell, host: profile, argv: []))
        runtime.appeared()
        try await settle { runtime.state == .failed }
        XCTAssertEqual(keys.offers, 0)
        XCTAssertEqual(keys.reads, 0)
        await runtime.disconnect()
    }

    // MARK: - helpers

    private func scratchDefaults() throws -> UserDefaults {
        let name = "omodachi.ux-4.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// Waits for a condition rather than for a duration: a fixed sleep either
    /// makes the suite slow or makes it flaky, and usually both.
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "condition never became true")
    }
}

// MARK: - fakes

/// Counts what the two calls were asked, and answers what the test says the
/// host is holding.
private final class FakeKeyOffer: SSHKeyOffering, @unchecked Sendable {
    static let localFingerprint = "SHA256:thisDevicesOwnKeyxxxxxxxxxxxxxxxxxxxxxxxxxx"
    private let lock = NSLock()
    private var held: [String]
    private let unreachable: Bool
    private(set) var reads = 0
    private(set) var offers = 0

    init(hostHolds: [String], unreachable: Bool = false) {
        held = hostHolds
        self.unreachable = unreachable
    }

    func read(account: String, keyAccount: String) async throws -> SSHKeyReport {
        try lock.withLock {
            reads += 1
            if unreachable { throw SSHKeyOfferError.unreachable }
            return SSHKeyReport(deviceID: "ios-fixture", localFingerprint: Self.localFingerprint,
                                hostFingerprints: held)
        }
    }

    func offer(account: String, keyAccount: String) async throws -> SSHKeyReport {
        try lock.withLock {
            offers += 1
            if unreachable { throw SSHKeyOfferError.unreachable }
            held = [Self.localFingerprint]
            return SSHKeyReport(deviceID: "ios-fixture", localFingerprint: Self.localFingerprint,
                                hostFingerprints: held)
        }
    }
}

/// A transport that gets as far as `publickey` and is refused, which is the
/// one failure UX-4 repairs. It counts dials so a test can tell a retry from a
/// loop.
@MainActor private final class RefusingTransport: PTYTransport {
    private(set) var attempts = 0
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    lazy var output: AsyncThrowingStream<Data, Error> = AsyncThrowingStream { self.continuation = $0 }

    func connect(cols: Int, rows: Int) async throws {
        attempts += 1
        throw SSHTransportError.authenticationRejected
    }
    func send(_ bytes: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func disconnect() async {}
}

/// The Keychain, in memory.
private final class KeyRecords: KeychainRecordStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    func save(_ value: Data, service: String, account: String) throws {
        lock.withLock { values["\(service)|\(account)"] = value }
    }
    func insertIfAbsent(_ value: Data, service: String, account: String) throws -> Bool {
        lock.withLock {
            let key = "\(service)|\(account)"
            if values[key] != nil { return false }
            values[key] = value
            return true
        }
    }
    func load(service: String, account: String) throws -> Data? {
        lock.withLock { values["\(service)|\(account)"] }
    }
    func remove(service: String, account: String) throws {
        lock.withLock { _ = values.removeValue(forKey: "\(service)|\(account)") }
    }
}

/// One `SSHKeyOffer` wired to in-memory stores and a stub host.
@MainActor private struct KeyFixture {
    let offer: SSHKeyOffer
    let pins: HostPinStore
    let credentials: CompanionCredentialStore
    let account = "https://ux4-host.invalid:8099"
    let keyAccount = "ssh-\(UUID().uuidString)"

    init() throws {
        let records = KeyRecords()
        let service = "com.omodachi.tests.ux4.\(UUID().uuidString)"
        pins = HostPinStore(service: service + ".pin", records: records)
        credentials = CompanionCredentialStore(service: service + ".credential", records: records)
        offer = SSHKeyOffer(pins: pins, credentials: credentials,
                            keys: SSHKeyStore(service: service + ".ssh", records: records),
                            makeSession: { _ in KeyStub.session() })
    }

    func store() {
        try? credentials.saveToken("ux4-token", account: account)
        try? pins.save(HostPin(hostID: String(repeating: "c", count: 32), hostName: "omarchy",
                               fingerprintSHA256: String(repeating: "d", count: 64),
                               endpoints: [.init(host: "192.168.1.10", port: 8099)],
                               ssh: .init(user: "alex", host: "192.168.1.10", port: 22),
                               grants: .init(companion: true, media: true, ssh: true)),
                       account: account)
    }
}

/// `GET`/`PUT /v1/ssh/key` for one invalid host, in core's own wire shape.
private final class KeyStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [String] = []
    nonisolated(unsafe) private static var refusal: (Int, String)?
    nonisolated(unsafe) private static var seenMethods: [String] = []
    nonisolated(unsafe) private static var seenAuthorizations: [String] = []
    nonisolated(unsafe) private static var seenBodies: [Data] = []

    static func reset(held values: [String], refusal code: (Int, String)? = nil) {
        lock.withLock {
            held = values; refusal = code
            seenMethods = []; seenAuthorizations = []; seenBodies = []
        }
    }
    static var methods: [String] { lock.withLock { seenMethods } }
    static var authorizations: [String] { lock.withLock { seenAuthorizations } }
    static var bodies: [Data] { lock.withLock { seenBodies } }

    static func session() -> URLSession {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [KeyStub.self]
        return URLSession(configuration: options)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ux4-host.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        // `URLProtocol` hands a streamed body over `httpBodyStream`, so a PUT
        // built with `httpBody` still has to be read through it.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 8192)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            stream.close()
            body = collected
        }
        let answer: (Int, Data) = Self.lock.withLock {
            Self.seenMethods.append(method)
            if let value = request.value(forHTTPHeaderField: "Authorization") {
                Self.seenAuthorizations.append(value)
            }
            if let body { Self.seenBodies.append(body) }
            if let refusal = Self.refusal {
                return (refusal.0, Data(#"{"error":{"code":"\#(refusal.1)","message":"no"}}"#.utf8))
            }
            if method == "PUT",
               let sent = try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String],
               let line = sent["public_key"], let print = SSHKeyOffer.fingerprint(of: line) {
                Self.held = [print]
                return (200, Data(#"{"contract_revision":"omodachi.v1","device_id":"ios-host-says","authorized":true,"changed":true,"reason":"replaced","fingerprint":"\#(print)","removed":1,"replaced":[]}"#.utf8))
            }
            let list = Self.held.map { "\"\($0)\"" }.joined(separator: ",")
            let newest = Self.held.last.map { "\"\($0)\"" } ?? "null"
            return (200, Data(#"{"contract_revision":"omodachi.v1","device_id":"ios-host-says","authorized":\#(!Self.held.isEmpty),"fingerprint":\#(newest),"fingerprints":[\#(list)]}"#.utf8))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.0,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A `ConnectionFlowModel` adopting a live credential, with the key calls
/// counted. The transport half is `AdoptionStub`; the key half is fake, so the
/// only thing under test is whether the adoption asks at all.
@MainActor private struct AdoptionFixture {
    let flow: ConnectionFlowModel
    let keys: FakeKeyOffer
    let candidate: HostCandidate

    init(hostHolds: [String], unreachable: Bool = false) throws {
        AdoptionStub.reset()
        let records = KeyRecords()
        let service = "com.omodachi.tests.ux4-adopt.\(UUID().uuidString)"
        let pins = HostPinStore(service: service + ".pin", records: records)
        let credentials = CompanionCredentialStore(service: service + ".credential", records: records)
        let suite = "omodachi.ux-4-adopt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let url = try XCTUnwrap(URL(string: "https://adopt-host.invalid:8099"))
        candidate = HostCandidate(id: url.absoluteString, name: "omarchy", hostIDSuffix: nil,
                                  address: "192.168.1.10:8099", url: url)
        try credentials.saveToken("adopt-token", account: candidate.account)
        try pins.save(HostPin(hostID: String(repeating: "c", count: 32), hostName: "omarchy",
                              fingerprintSHA256: String(repeating: "d", count: 64),
                              endpoints: [.init(host: "192.168.1.10", port: 8099)],
                              ssh: .init(user: "alex", host: "192.168.1.10", port: 22),
                              grants: .init(companion: true, media: true, ssh: true)),
                      account: candidate.account)
        keys = FakeKeyOffer(hostHolds: hostHolds, unreachable: unreachable)
        let session = AdoptionStub.session()
        flow = ConnectionFlowModel(
            deviceID: "ios-fixture", deviceName: "Fixture",
            pins: pins, credentials: credentials, hostKeys: HostKeyStore(service: service + ".hostkey", records: records),
            directory: PairedHostDirectory(defaults: defaults),
            probe: HostHealthProbe(session: session), keyOffer: keys,
            makeClient: { try PairingClient(endpoint: $0, records: records,
                                            service: service + ".credential",
                                            pins: pins, session: session) },
            makeProbe: { CredentialProbe(endpoint: $0, pinnedFingerprint: $1, session: session) })
    }

    func select() async {
        flow.select(candidate, sshPublicKey: "ssh-ed25519 AAAA", sshKeyAccount: "ssh-fixture")
        for _ in 0..<400 where flow.claimed == nil && flow.failure == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        flow.cancel()
    }
}

/// `/health` and an authenticated `/v1/state` that answers 200, which is what
/// makes the credential `live` and takes the adoption branch.
private final class AdoptionStub: URLProtocol, @unchecked Sendable {
    static func reset() {}
    static func session() -> URLSession {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [AdoptionStub.self]
        return URLSession(configuration: options)
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "adopt-host.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = path == "/health"
            ? Data(#"{"contract_revision":"omodachi.v1","status":"ok","host_id":"\#(String(repeating: "c", count: 32))","tls_fingerprint_sha256":"\#(String(repeating: "d", count: 64))","pairing":{"mode":"open"}}"#.utf8)
            : Data(#"{"contract_revision":"omodachi.v1"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
