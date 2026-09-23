import XCTest
@testable import Omodachi

/// CORE-2 §1. A credential lives 30 days; the host renews one in its last week
/// and says why it refuses one. These are the app's half: the reason reaches
/// the list line, a renewal replaces the stored credential without anyone
/// seeing it, and nothing is ever deleted on an answer that is not a refusal.
@MainActor final class CredentialRenewalTests: XCTestCase {

    // MARK: - the reason in a 401

    func testTheReasonIsReadFromTheBodyAndAnOldHostIsUnknown() {
        func body(_ reason: String?) -> Data {
            guard let reason else { return Data(#"{"error":{"code":"permission_denied"}}"#.utf8) }
            return Data(#"{"error":{"code":"permission_denied","reason":"\#(reason)"}}"#.utf8)
        }
        XCTAssertEqual(CredentialRejection.from(body: body("credential_expired")), .expired)
        XCTAssertEqual(CredentialRejection.from(body: body("credential_revoked")), .revoked)
        XCTAssertEqual(CredentialRejection.from(body: body("device_purged")), .purged)
        XCTAssertEqual(CredentialRejection.from(body: body("unknown_credential")), .unknown)
        XCTAssertEqual(CredentialRejection.from(body: body(nil)), .unknown, "a host from before CORE-2")
        XCTAssertEqual(CredentialRejection.from(body: body("invented_later")), .unknown)
        XCTAssertEqual(CredentialRejection.from(body: Data("not json".utf8)), .unknown)
        XCTAssertTrue(CredentialRejection.revoked.tookBack)
        XCTAssertTrue(CredentialRejection.purged.tookBack)
        XCTAssertFalse(CredentialRejection.expired.tookBack)
    }

    func testTheLaunchProbeCarriesTheReasonToTheListLine() async throws {
        let fixture = try RenewalFixture()
        fixture.store()
        RenewalStub.script(["/v1/state": .refuse("credential_expired")])

        await fixture.gate.check(directory: fixture.directory, home: fixture.home)

        XCTAssertEqual(fixture.gate.discarded,
                       [HostCredentialGate.StaleCredential(hostName: "omarchy", reason: .expired)])
        XCTAssertTrue(fixture.isBackAtTheHostList)
        let line = ConnectionScreen.staleMessage(fixture.gate.discarded)
        XCTAssertTrue(line.contains(ReasonText.message("credential_expired", domain: .host)))
        XCTAssertTrue(line.contains(Strings.hostsCredentialExpiredAction), "an expiry is one approval away")
    }

    // MARK: - renewal

    func testACredentialInItsLastWeekIsRenewedSilently() async throws {
        let fixture = try RenewalFixture()
        fixture.store()
        RenewalStub.script(["/v1/pairing/credential": .standing(renewable: true),
                            "/v1/pairing/renew": .renewed("fresh-token")])

        await fixture.gate.renewIfDue(directory: fixture.directory, home: fixture.home, force: true)

        XCTAssertEqual(RenewalStub.paths, ["/v1/pairing/credential", "/v1/pairing/renew"])
        XCTAssertEqual(RenewalStub.methods, ["GET", "POST"])
        XCTAssertEqual(RenewalStub.authorizations, ["Bearer old-token", "Bearer old-token"],
                       "the credential being traded in is what asks for the new one")
        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), "fresh-token")
        XCTAssertNotNil(fixture.pins.load(account: fixture.account), "the pin is untouched")
        XCTAssertEqual(fixture.directory.records.count, 1)
        XCTAssertTrue(fixture.gate.discarded.isEmpty, "nothing is said: renewal is silent")
        guard case .renewed(let token, _)? = fixture.gate.lastRenewal[fixture.account] else {
            return XCTFail("expected a renewal, got \(String(describing: fixture.gate.lastRenewal[fixture.account]))")
        }
        XCTAssertEqual(token, "fresh-token")
    }

    func testACredentialThatIsNotDueIsOnlyLookedAt() async throws {
        let fixture = try RenewalFixture()
        fixture.store()
        RenewalStub.script(["/v1/pairing/credential": .standing(renewable: false)])

        await fixture.gate.renewIfDue(directory: fixture.directory, home: fixture.home, force: true)

        XCTAssertEqual(RenewalStub.paths, ["/v1/pairing/credential"])
        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), "old-token")
        XCTAssertEqual(fixture.gate.lastRenewal[fixture.account], .notDue(expiresAt: 1_792_000_000))
    }

    func testARevokedCredentialIsNeverRenewedAndLandsOnTheList() async throws {
        let fixture = try RenewalFixture()
        fixture.store()
        RenewalStub.script(["/v1/pairing/credential": .refuse("device_purged")])

        await fixture.gate.renewIfDue(directory: fixture.directory, home: fixture.home, force: true)

        XCTAssertEqual(RenewalStub.paths, ["/v1/pairing/credential"], "no renewal is attempted")
        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.account))
        XCTAssertTrue(fixture.isBackAtTheHostList)
        XCTAssertEqual(fixture.gate.discarded,
                       [HostCredentialGate.StaleCredential(hostName: "omarchy", reason: .purged)])
        let line = ConnectionScreen.staleMessage(fixture.gate.discarded)
        XCTAssertTrue(line.contains(ReasonText.message("device_purged", domain: .host)))
        XCTAssertTrue(line.contains(Strings.hostsCredentialRevokedAction), "a revoke says so and does not re-ask")
    }

    func testARefusalOfTheRenewalItselfKeepsTheCredential() async throws {
        let fixture = try RenewalFixture()
        fixture.store()
        RenewalStub.script(["/v1/pairing/credential": .standing(renewable: true),
                            "/v1/pairing/renew": .conflict("credential_renewal_not_due")])

        await fixture.gate.renewIfDue(directory: fixture.directory, home: fixture.home, force: true)

        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), "old-token")
        XCTAssertEqual(fixture.gate.lastRenewal[fixture.account], .refused(code: "credential_renewal_not_due"))
        XCTAssertTrue(fixture.gate.discarded.isEmpty)
    }

    func testAHostFromBeforeCore2AndAnAbsentHostChangeNothing() async throws {
        for (answer, expected) in [(RenewalStub.Answer.notFound, RenewalOutcome.unsupported),
                                   (.unreachable, .unreachable)] {
            let fixture = try RenewalFixture()
            fixture.store()
            RenewalStub.script(["/v1/pairing/credential": answer])

            await fixture.gate.renewIfDue(directory: fixture.directory, home: fixture.home, force: true)

            XCTAssertEqual(fixture.gate.lastRenewal[fixture.account], expected)
            XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), "old-token")
            XCTAssertFalse(fixture.isBackAtTheHostList)
        }
    }

    func testARenewalThatAnswersForAnotherDeviceIsNotStored() async throws {
        let fixture = try RenewalFixture()
        fixture.store()
        RenewalStub.script(["/v1/pairing/credential": .standing(renewable: true),
                            "/v1/pairing/renew": .renewed("fresh-token", device: "someone-else")])

        await fixture.gate.renewIfDue(directory: fixture.directory, home: fixture.home, force: true)

        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), "old-token")
        XCTAssertEqual(fixture.gate.lastRenewal[fixture.account], .refused(code: "invalid_response"))
    }

    func testLaunchAndComingToTheFrontTogetherAreOneCheck() async throws {
        let fixture = try RenewalFixture()
        fixture.store()
        RenewalStub.script(["/v1/pairing/credential": .standing(renewable: false)])

        await fixture.gate.renewIfDue(directory: fixture.directory, home: fixture.home, force: true)
        await fixture.gate.renewIfDue(directory: fixture.directory, home: fixture.home)

        XCTAssertEqual(RenewalStub.paths, ["/v1/pairing/credential"], "the second trigger is inside the debounce")
        XCTAssertEqual(HostCredentialGate.renewalInterval, 12 * 3600)
    }

    // MARK: - the words

    func testEveryCredentialCodeHasASentenceOfItsOwn() {
        for code in ["credential_expired", "credential_revoked", "device_purged", "unknown_credential",
                     "credential_renewal_not_due", "plugin_credential"] {
            XCTAssertEqual(ReasonText.knownCodes[code], .host, code)
            let text = ReasonText.message(code, domain: .host)
            XCTAssertFalse(text.contains(code), "\(code) fell through to the unknown shape: \(text)")
        }
    }

    func testTheListSaysOneSentencePerReason() {
        let lines = ConnectionScreen.staleMessage([
            .init(hostName: "omarchy", reason: .expired),
            .init(hostName: "studio", reason: .revoked),
            .init(hostName: "old", reason: .unknown),
        ]).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.contains(Strings.hostsCredentialStale("old")), "no reason reads exactly as before")
        XCTAssertTrue(lines.contains { $0.hasPrefix("omarchy") && $0.contains(Strings.hostsCredentialExpiredAction) })
        XCTAssertTrue(lines.contains { $0.hasPrefix("studio") && $0.contains(Strings.hostsCredentialRevokedAction) })
    }
}

// MARK: - fixture

@MainActor private struct RenewalFixture {
    let gate: HostCredentialGate
    let home: HomeStore
    let directory: PairedHostDirectory
    let pins: HostPinStore
    let credentials: CompanionCredentialStore
    let account = "https://renewal-fixture.invalid:8099"

    init() throws {
        RenewalStub.script([:])
        let records = RenewalRecords()
        let service = "com.omodachi.tests.core2.\(UUID().uuidString)"
        pins = HostPinStore(service: service + ".pin", records: records)
        credentials = CompanionCredentialStore(service: service + ".credential", records: records)
        let hostKeys = HostKeyStore(service: service + ".hostkey", records: records)
        let suite = "omodachi.core-2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = account
        defaults.set(try JSONEncoder().encode(profile), forKey: "omodachi.profile.v1")
        directory = PairedHostDirectory(defaults: defaults)
        home = HomeStore(defaults: defaults, clientFactory: { _, _ in RenewalNoService() }, autoConnect: false)
        gate = HostCredentialGate(pins: pins, credentials: credentials, hostKeys: hostKeys, forcedVerdict: nil,
                                  makeProbe: { CredentialProbe(endpoint: $0, pinnedFingerprint: $1,
                                                               session: RenewalStub.session()) },
                                  makeRenewer: { CredentialRenewer(endpoint: $0, pinnedFingerprint: $1,
                                                                   session: RenewalStub.session()) })
    }

    func store() {
        try? credentials.saveToken("old-token", account: account)
        try? pins.save(HostPin(hostID: String(repeating: "e", count: 32), hostName: "omarchy",
                               fingerprintSHA256: String(repeating: "f", count: 64),
                               endpoints: [.init(host: "renewal-fixture.invalid", port: 8099)],
                               ssh: nil, grants: .init(companion: true, media: true, ssh: true)),
                       account: account)
        directory.remember(.init(account: account, hostID: String(repeating: "e", count: 32),
                                 hostName: "omarchy", address: "renewal-fixture.invalid:8099"))
    }

    var isBackAtTheHostList: Bool { directory.records.isEmpty && home.profile.companionURL.isEmpty }
}

/// The two credential routes and `GET /v1/state`, answering the way core does.
private final class RenewalStub: URLProtocol, @unchecked Sendable {
    enum Answer {
        case standing(renewable: Bool)
        case renewed(String, device: String = "ios-fixture")
        case refuse(String)
        case conflict(String)
        case notFound
        case unreachable
        case ok
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var seen: [(path: String, method: String, authorization: String)] = []

    static func script(_ value: [String: Answer]) { lock.withLock { answers = value; seen = [] } }
    static var paths: [String] { lock.withLock { seen.map(\.path) } }
    static var methods: [String] { lock.withLock { seen.map(\.method) } }
    static var authorizations: [String] { lock.withLock { seen.map(\.authorization) } }

    static func session() -> URLSession {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [RenewalStub.self]
        return URLSession(configuration: options)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "renewal-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let answer = Self.lock.withLock { () -> Answer in
            Self.seen.append((path, request.httpMethod ?? "GET", request.value(forHTTPHeaderField: "Authorization") ?? ""))
            return Self.answers[path] ?? .ok
        }
        var status = 200
        var body = "{}"
        switch answer {
        case let .standing(renewable):
            body = #"{"contract_revision":"omodachi.v1","device_id":"ios-fixture","issued_at":1789400000,"# +
                #""expires_at":1792000000,"renewable_at":1791395200,"renewable":\#(renewable),"superseded":false}"#
        case let .renewed(token, device):
            body = #"{"contract_revision":"omodachi.v1","device_id":"\#(device)","credential":"\#(token)","# +
                #""issued_at":1791500000,"credential_expires_at":4102444800,"renewable_at":4101840000,"# +
                #""previous_credential_expires_at":1791586400}"#
        case let .refuse(reason):
            status = 401
            body = #"{"contract_revision":"omodachi.v1","error":{"code":"permission_denied","message":"x","reason":"\#(reason)"}}"#
        case let .conflict(code):
            status = 409
            body = #"{"contract_revision":"omodachi.v1","error":{"code":"\#(code)","message":"\#(code)"}}"#
        case .notFound:
            status = 404
            body = #"{"contract_revision":"omodachi.v1","error":{"code":"request_rejected","message":"Not Found"}}"#
        case .unreachable:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        case .ok: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class RenewalRecords: KeychainRecordStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    func save(_ value: Data, service: String, account: String) throws {
        lock.withLock { values["\(service)|\(account)"] = value }
    }
    func insertIfAbsent(_ value: Data, service: String, account: String) throws -> Bool {
        lock.withLock {
            let key = "\(service)|\(account)"
            guard values[key] == nil else { return false }
            values[key] = value
            return true
        }
    }
    func load(service: String, account: String) throws -> Data? {
        lock.withLock { values["\(service)|\(account)"] }
    }
    func remove(service: String, account: String) throws {
        lock.withLock { values["\(service)|\(account)"] = nil }
    }
}
/// The Shell's store needs a client factory; CORE-2 cases never connect.
private struct RenewalNoService: CompanionServing {
    func connect() async throws { throw CompanionHostError.notConnected }
    func disconnect() async {}
    func fetchState() async throws -> HostStateDTO { throw CompanionHostError.notConnected }
    func fetchSnapshot() async throws -> CompanionSnapshot { throw CompanionHostError.notConnected }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter],
                targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse {
        throw CompanionHostError.notConnected
    }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse {
        throw CompanionHostError.notConnected
    }
    func invokeWorkspaceLayout(_ request: WorkspaceLayoutRequest) async throws -> CompanionActionResponse {
        throw CompanionHostError.notConnected
    }
    func selectWorkspace(_ id: Int) async throws { throw CompanionHostError.notConnected }
    func wakeDesktop() async throws -> HostWakeResponseDTO { throw CompanionHostError.notConnected }
    func fetchShortcuts() async throws -> ShortcutSnapshot { throw CompanionHostError.notConnected }
    func executeShortcut(_ request: ShortcutExecutionRequest) async throws -> ShortcutExecutionResult {
        throw CompanionHostError.notConnected
    }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
