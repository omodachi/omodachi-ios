import XCTest
@testable import Omodachi

/// PAIR-4. The state a real iPad ended up in after being reinstalled: the
/// Keychain still holds the credential this device was issued, the app
/// container that held the directory record is gone, and the two stores
/// disagree about whether this host is paired.
///
/// Before this spec that disagreement had no exit. The row said one thing, the
/// pairing request was refused by `ensureEmptyCredential` with a sentence that
/// pointed at a Settings page only a *paired* app can open, and "忘记这台主机"
/// lived on that page. These tests are the four ways out.
@MainActor final class OrphanCredentialTests: XCTestCase {

    // MARK: - §4 one derivation

    /// The credential, the pin and the directory record are keyed by one
    /// function. Before PAIR-4 the first two used
    /// `CompanionHostConfiguration`'s normalization and the last two used
    /// `url.absoluteString`, which is a different string for a host typed with
    /// a capital letter or reached with a trailing slash.
    func testOneDerivationKeysTheCredentialThePinAndTheRecord() throws {
        let cases: [(String, String)] = [
            ("https://omarchy:8099", "https://omarchy:8099"),
            ("https://Omarchy:8099", "https://omarchy:8099"),
            ("https://OMARCHY.local:8099", "https://omarchy.local:8099"),
            ("https://omarchy:8099/", "https://omarchy:8099"),
            ("https://192.168.1.10:8099", "https://192.168.1.10:8099"),
            ("https://[fd00::1]:8099", "https://[fd00::1]:8099"),
        ]
        for (input, expected) in cases {
            let url = try XCTUnwrap(URL(string: input))
            XCTAssertEqual(HostAccount.derive(url), expected, "for \(input)")
            // The row and the Keychain must agree, always.
            let candidate = HostCandidate(id: input, name: "omarchy", hostIDSuffix: nil,
                                          address: "omarchy:8099", url: url)
            XCTAssertEqual(candidate.account,
                           try CompanionHostConfiguration(endpoint: url).account, "for \(input)")
        }
        // Something that can never be an account keeps its own string rather
        // than vanishing; nothing is stored under it either way.
        XCTAssertEqual(HostAccount.canonical("http://omarchy:8099"), "http://omarchy:8099")
    }

    /// §4: a record this morning's build wrote is read back and migrated, in
    /// place, so the credential it belongs to can be found again.
    func testARecordFromAnOlderBuildIsMigratedToTheKeychainsKey() throws {
        let name = "omodachi.pair-4.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Exactly the shape the old encoder wrote, un-normalized accounts and
        // all — including two rows that are the same host under two spellings.
        let legacy = """
        [{"account":"https://Omarchy:8099/","hostID":"\(String(repeating: "a", count: 32))",
          "hostName":"omarchy","address":"omarchy:8099"},
         {"account":"https://omarchy:8099","hostID":"\(String(repeating: "a", count: 32))",
          "hostName":"omarchy","address":"192.168.1.10:8099"},
         {"account":"https://studio:8099","hostID":"\(String(repeating: "b", count: 32))",
          "hostName":"studio","address":"10.0.0.23:8099"}]
        """
        defaults.set(Data(legacy.utf8), forKey: PairedHostDirectory.storageKey)

        let directory = PairedHostDirectory(defaults: defaults)
        XCTAssertEqual(directory.records.map(\.account).sorted(),
                       ["https://omarchy:8099", "https://studio:8099"],
                       "one host under two spellings is one record under one key")
        XCTAssertNotNil(directory.record(account: "https://Omarchy:8099/"),
                        "the old spelling still finds its row")
        XCTAssertEqual(directory.record(account: "https://omarchy:8099")?.address, "192.168.1.10:8099",
                       "the later row wins, as `remember` has always made it")
        // The migration is written back, so the next launch does not repeat it
        // and nothing else has to know about the old spelling.
        let reloaded = PairedHostDirectory(defaults: defaults)
        XCTAssertEqual(reloaded.records.map(\.account).sorted(),
                       ["https://omarchy:8099", "https://studio:8099"])
    }

    // MARK: - §1 the row

    func testACredentialWithNoDirectoryRecordReadsAsUnconfirmedNotUnpaired() throws {
        let fixture = try OrphanFixture(verdict: .live)
        fixture.storeCredentialAndPin()
        XCTAssertEqual(fixture.flow.decorate(fixture.candidate).pairing, .unconfirmed)
        XCTAssertEqual(fixture.flow.decorate(fixture.candidate).statusLabel, Strings.hostPairingUnconfirmed)

        // With the record back, it is an ordinary paired row again.
        fixture.directory.remember(.init(account: fixture.candidate.account, hostID: OrphanFixture.hostID,
                                         hostName: "omarchy", address: "omarchy:8099"))
        XCTAssertEqual(fixture.flow.decorate(fixture.candidate).pairing, .paired)
    }

    func testAHostThisDeviceHasNothingForIsStillJustUnpaired() throws {
        let fixture = try OrphanFixture(verdict: .live)
        XCTAssertEqual(fixture.flow.decorate(fixture.candidate).pairing, .new)
        XCTAssertFalse(fixture.flow.hasStoredIdentity(fixture.candidate))
    }

    /// A pin with no credential is not a green chip — there is nothing to
    /// connect with — but it is still something this device is holding, so the
    /// row still offers the way to drop it.
    func testAPinWithNoCredentialIsNotPairedButCanStillBeForgotten() throws {
        let fixture = try OrphanFixture(verdict: .live)
        try fixture.pins.save(fixture.pin, account: fixture.candidate.account)
        XCTAssertEqual(fixture.flow.decorate(fixture.candidate).pairing, .new)
        XCTAssertTrue(fixture.flow.hasStoredIdentity(fixture.candidate))
    }

    // MARK: - §1 adoption

    /// The whole point: an adopted host reaches the Panel without a pairing
    /// request, so the computer never shows a second approval for a device it
    /// already approved.
    func testAdoptingALiveCredentialSendsNoPairingRequest() async throws {
        let fixture = try OrphanFixture(verdict: .live)
        fixture.storeCredentialAndPin()
        await fixture.select()

        XCTAssertNil(fixture.flow.failure)
        let claimed = try XCTUnwrap(fixture.flow.claimed)
        XCTAssertEqual(claimed.account, fixture.candidate.account)
        XCTAssertEqual(claimed.hostID, OrphanFixture.hostID)
        XCTAssertEqual(fixture.flow.grants, fixture.pin.grants)
        XCTAssertEqual(OrphanStub.paths.filter { $0.contains("pairing") }, [],
                       "adoption must never create a pending request on the host")
        XCTAssertTrue(OrphanStub.paths.contains { $0.hasSuffix("/v1/state") })
        XCTAssertEqual(OrphanStub.authorizations, ["Bearer orphan-token"],
                       "the stored credential is what proves this, and it goes nowhere else")
        // Nothing was deleted: this device still holds what it held.
        XCTAssertNotNil(try fixture.credentials.loadToken(account: fixture.candidate.account))
        XCTAssertNotNil(fixture.pins.load(account: fixture.candidate.account))
    }

    /// Leo's real state after the host revoked the device: 401, so the orphan
    /// goes and the same tap becomes an ordinary pairing.
    func testARevokedCredentialIsDiscardedAndTheSameTapPairsNormally() async throws {
        let fixture = try OrphanFixture(verdict: .rejected(.revoked))
        fixture.storeCredentialAndPin()
        _ = try fixture.hostKeys.confirm(host: "192.168.1.10", port: 22,
                                     openSSHPublicKey: OrphanFixture.sshKeyLine)
        await fixture.select()

        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.candidate.account),
                     "a credential the host does not know is rubbish, not a lock")
        XCTAssertNil(fixture.pins.load(account: fixture.candidate.account))
        XCTAssertNil(try fixture.hostKeys.pinnedFingerprint(host: "192.168.1.10:22"))
        XCTAssertTrue(OrphanStub.paths.contains { $0.hasSuffix("/v1/pairing/requests") },
                      "the tap becomes the ordinary request it would have been")
        // And not the sentence that used to be the end of the road.
        if case let .message(text)? = fixture.flow.failure {
            XCTAssertFalse(text.contains("请先在连接设置中明确删除"))
        }
    }

    /// An unreachable host is not a revocation. Nothing is deleted on a
    /// timeout, because a credential thrown away here cannot be recovered.
    func testAHostThatDoesNotAnswerNeverDeletesTheCredential() async throws {
        let fixture = try OrphanFixture(verdict: .unreachable)
        fixture.storeCredentialAndPin()
        await fixture.select()

        XCTAssertNotNil(try fixture.credentials.loadToken(account: fixture.candidate.account))
        XCTAssertNotNil(fixture.pins.load(account: fixture.candidate.account))
        XCTAssertNil(fixture.flow.claimed)
        guard case .message = fixture.flow.failure else {
            return XCTFail("an unanswered probe has to say so, got \(String(describing: fixture.flow.failure))")
        }
        XCTAssertFalse(OrphanStub.paths.contains { $0.hasSuffix("/v1/pairing/requests") },
                       "nothing is sent while the credential's fate is unknown")
    }

    /// The credential is this device's secret. With no pin there is no
    /// certificate to put it behind, so it is never offered to whoever answers
    /// that address — it is dropped and the host is paired with from scratch.
    func testACredentialWithNoPinIsDroppedRatherThanSentToAnUnpinnedHost() async throws {
        let fixture = try OrphanFixture(verdict: .live)
        try fixture.credentials.saveToken("orphan-token", account: fixture.candidate.account)
        await fixture.select()

        XCTAssertEqual(OrphanStub.authorizations, [], "an unpinned host is never shown the token")
        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.candidate.account))
        XCTAssertTrue(OrphanStub.paths.contains { $0.hasSuffix("/v1/pairing/requests") })
    }

    // MARK: - §2 the row can always forget

    func testForgettingARowDropsAllFourRecordsWithoutAskingTheHost() throws {
        let fixture = try OrphanFixture(verdict: .unreachable)
        fixture.storeCredentialAndPin()
        fixture.directory.remember(.init(account: fixture.candidate.account, hostID: OrphanFixture.hostID,
                                         hostName: "omarchy", address: "omarchy:8099"))
        _ = try fixture.hostKeys.confirm(host: "192.168.1.10", port: 22,
                                     openSSHPublicKey: OrphanFixture.sshKeyLine)

        XCTAssertTrue(fixture.flow.forget(account: fixture.candidate.account))

        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.candidate.account))
        XCTAssertNil(fixture.pins.load(account: fixture.candidate.account))
        XCTAssertNil(try fixture.hostKeys.pinnedFingerprint(host: "192.168.1.10:22"),
                     "the SSH target the pin named goes with it")
        XCTAssertNil(fixture.directory.record(account: fixture.candidate.account))
        XCTAssertEqual(fixture.flow.decorate(fixture.candidate).pairing, .new)
        XCTAssertFalse(fixture.flow.hasStoredIdentity(fixture.candidate))
        XCTAssertEqual(OrphanStub.paths, [], "forgetting never touches the network")
    }

    /// The old spelling of an account still forgets the row it wrote.
    func testForgettingAcceptsAnAccountWrittenByAnOlderBuild() throws {
        let fixture = try OrphanFixture(verdict: .unreachable)
        fixture.storeCredentialAndPin()
        XCTAssertTrue(fixture.flow.forget(account: "https://Orphan-Host.invalid:8099/"))
        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.candidate.account))
    }
}

// MARK: - Fixture

/// One host that answers `/health`, one authenticated `/v1/state` whose status
/// the test chooses, and one pairing request — over in-memory Keychain stores
/// so nothing here touches the device's own records.
@MainActor private struct OrphanFixture {
    static let hostID = String(repeating: "c", count: 32)
    static let fingerprint = String(repeating: "d", count: 64)
    static let sshKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"

    let flow: ConnectionFlowModel
    let pins: HostPinStore
    let credentials: CompanionCredentialStore
    let hostKeys: HostKeyStore
    let directory: PairedHostDirectory
    let candidate: HostCandidate
    let suiteName: String

    var pin: HostPin {
        HostPin(hostID: Self.hostID, hostName: "omarchy", fingerprintSHA256: Self.fingerprint,
                endpoints: [.init(host: "192.168.1.10", port: 8099)],
                ssh: .init(user: "alex", host: "192.168.1.10", port: 22),
                grants: .init(companion: true, media: true, ssh: true))
    }

    init(verdict: CredentialVerdict) throws {
        OrphanStub.reset(verdict: verdict)
        let records = OrphanRecords()
        let service = "com.omodachi.tests.pair4.\(UUID().uuidString)"
        pins = HostPinStore(service: service + ".pin", records: records)
        credentials = CompanionCredentialStore(service: service + ".credential", records: records)
        hostKeys = HostKeyStore(service: service + ".hostkey", records: records)
        suiteName = "omodachi.pair-4.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        directory = PairedHostDirectory(defaults: defaults)
        let url = try XCTUnwrap(URL(string: "https://orphan-host.invalid:8099"))
        candidate = HostCandidate(id: url.absoluteString, name: "omarchy", hostIDSuffix: nil,
                                  address: "192.168.1.10:8099", url: url)
        let session = OrphanStub.session()
        flow = ConnectionFlowModel(
            deviceID: "ios-fixture", deviceName: "Fixture",
            pins: pins, credentials: credentials, hostKeys: hostKeys, directory: directory,
            probe: HostHealthProbe(session: session),
            makeClient: { try PairingClient(endpoint: $0, records: records,
                                            service: service + ".credential",
                                            pins: HostPinStore(service: service + ".pin", records: records),
                                            session: session) },
            makeProbe: { CredentialProbe(endpoint: $0, pinnedFingerprint: $1, session: session) })
    }

    func storeCredentialAndPin() {
        try? credentials.saveToken("orphan-token", account: candidate.account)
        try? pins.save(pin, account: candidate.account)
    }

    /// Runs the tap and waits for the model to come to rest.
    func select() async {
        flow.select(candidate, sshPublicKey: nil)
        for _ in 0..<400 where flow.claimed == nil && flow.failure == nil && !OrphanStub.sawPairingRequest {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // The pairing poll never resolves here; stop it before asserting.
        flow.cancel()
    }
}

private final class OrphanRecords: KeychainRecordStore, @unchecked Sendable {
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

/// `/health`, `/v1/state` and `/v1/pairing/requests` for one invalid host.
private final class OrphanStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var verdict: CredentialVerdict = .live
    nonisolated(unsafe) private static var seenPaths: [String] = []
    nonisolated(unsafe) private static var seenAuthorizations: [String] = []

    static func reset(verdict value: CredentialVerdict) {
        lock.withLock { verdict = value; seenPaths = []; seenAuthorizations = [] }
    }
    static var paths: [String] { lock.withLock { seenPaths } }
    static var authorizations: [String] { lock.withLock { seenAuthorizations } }
    static var sawPairingRequest: Bool { paths.contains { $0.hasSuffix("/v1/pairing/requests") } }

    static func session() -> URLSession {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [OrphanStub.self]
        return URLSession(configuration: options)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "orphan-host.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let verdict = Self.lock.withLock { () -> CredentialVerdict in
            Self.seenPaths.append(path)
            if let value = request.value(forHTTPHeaderField: "Authorization") {
                Self.seenAuthorizations.append(value)
            }
            return Self.verdict
        }
        var status = 200
        var body = Data("{}".utf8)
        switch path {
        case "/health":
            body = Data(#"{"service":"omodachid","host_id":"\#(OrphanFixtureConstants.hostID)","tls_fingerprint_sha256":"\#(OrphanFixtureConstants.fingerprint)","pairing":{"mode":"open"}}"#.utf8)
        case "/v1/state":
            switch verdict {
            case .live: status = 200
            case let .rejected(reason):
                status = 401
                body = Data(#"{"error":{"code":"permission_denied","reason":"\#(reason.rawValue)"}}"#.utf8)
            case .unreachable:
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
        case "/v1/pairing/requests":
            let expiry = Int(Date().timeIntervalSince1970) + 300
            body = Data(#"{"request_id":"pair_\#(String(repeating: "0", count: 32))","device_id":"ios-fixture","device_name":"Fixture","status":"pending","expires_at":\#(expiry),"request_secret":"\#(String(repeating: "B", count: 43))"}"#.utf8)
        default:
            body = Data(#"{"request_id":"pair_\#(String(repeating: "0", count: 32))","device_id":"ios-fixture","device_name":"Fixture","status":"pending","expires_at":\#(Int(Date().timeIntervalSince1970) + 300)}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The stub runs off the main actor, so it cannot read `OrphanFixture`.
private enum OrphanFixtureConstants {
    static let hostID = String(repeating: "c", count: 32)
    static let fingerprint = String(repeating: "d", count: 64)
}
