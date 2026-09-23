import XCTest
@testable import Omodachi

/// PAIR-5. AGENT-2 §9.4: two simulators that walked past the host list into a
/// Panel they could not leave, with a red dot and "The host rejected companion
/// authorization" on it, while the host had no pending request because the app
/// never asked for one. The record that let them in was in the app container —
/// `omodachi.pairedHosts.v1` and `omodachi.profile.v1` — and neither a host
/// revoking the device nor `simctl keychain reset` touches those.
///
/// These are the three cases the launch gate has to get right, plus the
/// migration a credential written before PAIR-4 needs before it can be asked
/// about at all.
@MainActor final class RejectedCredentialTests: XCTestCase {

    // MARK: - §2 the credential the host refuses

    func testAHostThatRefusesTheCredentialTakesThePanelAwayAndSaysSoOnce() async throws {
        let fixture = try GateFixture(verdict: .rejected(.unknown))
        fixture.store()
        XCTAssertFalse(fixture.directory.records.isEmpty)

        await fixture.gate.check(directory: fixture.directory, home: fixture.home)

        XCTAssertEqual(GateStub.paths, ["/v1/state"], "one authenticated read, and nothing else")
        XCTAssertEqual(GateStub.authorizations, ["Bearer pair5-token"])
        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.account), "the credential is rubbish")
        XCTAssertNil(fixture.pins.load(account: fixture.account))
        XCTAssertTrue(fixture.directory.records.isEmpty)
        XCTAssertEqual(fixture.home.profile.companionURL, "", "the profile lets the host go too")
        XCTAssertEqual(fixture.gate.discarded.map(\.hostName), ["omarchy"])
        XCTAssertTrue(fixture.gate.discardedCredential)
        XCTAssertTrue(fixture.isBackAtTheHostList,
                      "both halves of the Shell's gate are empty, which is the host list")
    }

    /// The same cleanup, reached from the live connection rather than from the
    /// launch probe. This is the one that removes the resting state: a 401 on a
    /// running app can no longer become a sentence under the menu.
    func testA401OnTheLiveConnectionRunsTheSameCleanup() async throws {
        let fixture = try GateFixture(verdict: .rejected(.revoked))
        fixture.store()

        await fixture.gate.hostRejected(account: "https://OMARCHY-fixture.invalid:8099/",
                                        directory: fixture.directory, home: fixture.home)

        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.account),
                     "the account is canonicalized before anything is deleted")
        XCTAssertTrue(fixture.directory.records.isEmpty)
        XCTAssertTrue(fixture.isBackAtTheHostList)
        // CORE-2: the credential held *now* is asked about once, which is also
        // how the list learns the host's reason.
        XCTAssertEqual(GateStub.paths, ["/v1/state"])
        XCTAssertEqual(fixture.gate.discarded,
                       [HostCredentialGate.StaleCredential(hostName: "omarchy", reason: .revoked)])
    }

    /// CORE-2: a renewal replaced the stored credential while the live
    /// connection still carried the one it traded in. When that one's grace
    /// ends the connection gets a 401 - which is not a refusal of this device.
    func testA401ForATradedInCredentialKeepsTheOneThisDeviceHoldsNow() async throws {
        let fixture = try GateFixture(verdict: .live)
        fixture.store()

        await fixture.gate.hostRejected(account: fixture.account,
                                        directory: fixture.directory, home: fixture.home)

        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), "pair5-token")
        XCTAssertEqual(fixture.directory.records.count, 1)
        XCTAssertFalse(fixture.isBackAtTheHostList)
        XCTAssertTrue(fixture.gate.discarded.isEmpty)
    }

    /// The two errors that mean "this device is not authorized here", and the
    /// one that does not. `.transport` is an offline host, and an offline host
    /// never costs anybody their credential.
    func testOnlyARefusalCountsAsARefusal() {
        XCTAssertTrue(HomeStore.describesACredentialRejection(CompanionHostError.unauthorized))
        XCTAssertTrue(HomeStore.describesACredentialRejection(CompanionHostError.missingCredential))
        XCTAssertTrue(HomeStore.describesACredentialRejection(CompanionHostError.notConnected))
        XCTAssertFalse(HomeStore.describesACredentialRejection(CompanionHostError.transport(message: "x")))
        XCTAssertFalse(HomeStore.describesACredentialRejection(URLError(.timedOut)))
        XCTAssertTrue(HomeStore.describesAnUnreachableHost(CompanionHostError.transport(message: "x")))
        XCTAssertTrue(HomeStore.describesAnUnreachableHost(URLError(.cannotConnectToHost)))
        XCTAssertFalse(HomeStore.describesAnUnreachableHost(CompanionHostError.unauthorized))
        XCTAssertFalse(HomeStore.describesAnUnreachableHost(nil))
    }

    // MARK: - §2 the credential that is gone

    /// `simctl keychain reset`, or a device restored onto a new phone: the
    /// records are still here and the secret is not. Nothing is asked of the
    /// host — there is nothing to ask with — and the app is unpaired again.
    func testACredentialThatIsGoneIsTheSameAsNeverHavingBeenPaired() async throws {
        let fixture = try GateFixture(verdict: .live)
        fixture.store()
        try fixture.credentials.removeToken(account: fixture.account)

        await fixture.gate.check(directory: fixture.directory, home: fixture.home)

        XCTAssertEqual(GateStub.paths, [], "a device with no credential has nothing to ask with")
        XCTAssertTrue(fixture.directory.records.isEmpty)
        XCTAssertNil(fixture.pins.load(account: fixture.account))
        XCTAssertTrue(fixture.isBackAtTheHostList)
        XCTAssertEqual(fixture.gate.discarded.map(\.hostName), ["omarchy"])
    }

    /// PAIR-4 §3.2's rule, kept: a credential with no pin is never put on the
    /// wire, so it is dropped rather than checked.
    func testACredentialWithNoPinIsDroppedRatherThanSentToAnUnpinnedHost() async throws {
        let fixture = try GateFixture(verdict: .live)
        fixture.store()
        try fixture.pins.remove(account: fixture.account)

        await fixture.gate.check(directory: fixture.directory, home: fixture.home)

        XCTAssertEqual(GateStub.authorizations, [], "the token never left the device")
        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.account))
        XCTAssertTrue(fixture.isBackAtTheHostList)
    }

    // MARK: - §2 the host that is not there

    func testAHostThatDoesNotAnswerKeepsEverythingAndOnlyGoesGrey() async throws {
        let fixture = try GateFixture(verdict: .unreachable)
        fixture.store()

        await fixture.gate.check(directory: fixture.directory, home: fixture.home)

        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), "pair5-token",
                       "an unreachable host is not a revocation")
        XCTAssertNotNil(fixture.pins.load(account: fixture.account))
        XCTAssertEqual(fixture.directory.records.count, 1)
        XCTAssertEqual(fixture.home.profile.companionURL, fixture.account)
        XCTAssertTrue(fixture.gate.discarded.isEmpty)
        XCTAssertTrue(fixture.gate.isOffline(fixture.account))
        XCTAssertFalse(fixture.isBackAtTheHostList, "the Panel stays; it just says the host is offline")
    }

    /// The bar's dot, which is the other half of the offline case: grey for a
    /// host that did not answer, red only for one that answered wrongly — and
    /// ① is given no sentence to rest in either way.
    func testTheDotIsGreyForAnOfflineHostAndRedForABrokenOne() throws {
        let home = try GateFixture.store(named: "pair5-bar")
        home.markUnavailable(CompanionHostError.transport(message: "connection lost"))
        XCTAssertEqual(home.connectionState, .offline)
        XCTAssertTrue(home.hostOffline)
        XCTAssertNil(home.notice)

        home.markUnavailable(CompanionHostError.protocolError(message: "nonsense"))
        XCTAssertEqual(home.connectionState, .unavailable)
        XCTAssertFalse(home.hostOffline)
        XCTAssertEqual(home.notice, "nonsense")
    }

    /// PAIR-5 §5, found on the real host: after `simctl keychain reset` the app
    /// is correctly back on the host list, and the tap that should pair is
    /// refused by the computer with `409 pairing_device_exists`, because the
    /// device id is still authorized there. That used to read "电脑上拒绝了这次
    /// 连接 · 按 Reject 的不是你" — nobody pressed anything — and named no way
    /// out. It now names the command that is the way out, with the id.
    func testAHostThatStillHoldsThisDeviceSaysWhichCommandFreesIt() throws {
        let error = PairingError.deviceAlreadyRegistered(deviceID: "ios-c883eadd-42a5-434a-8d02-e0354f01cb32")
        let text = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(text.contains("ios-c883eadd-42a5-434a-8d02-e0354f01cb32"), text)
        XCTAssertEqual(text, Strings.pairErrorDeviceRegistered("ios-c883eadd-42a5-434a-8d02-e0354f01cb32"),
                       "it says where the authorization is removed: \(text)")
        XCTAssertFalse(text.contains("omodachi-host"), "a shell command is not something to put on a phone screen")
        XCTAssertNotEqual(ConnectionFlowModel.describe(error), .rejected,
                          "nobody pressed Reject, so the card must not say somebody did")
        XCTAssertEqual(ConnectionFlowModel.describe(error), .message(text))
    }

    // MARK: - §3 the credential an older build wrote

    /// The spec's migration case, end to end: the credential and the pin are
    /// under the spelling a pre-PAIR-4 build used, the probe is what decides,
    /// and afterwards there is one key.
    func testACredentialUnderAnOlderKeyIsMigratedAndThenProbedSuccessfully() async throws {
        let fixture = try GateFixture(verdict: .live)
        // What a pre-PAIR-4 build left: everything keyed by the string the
        // discovery or the typed address happened to spell, trailing slash,
        // capitals and all. The row it wrote kept that spelling in `address`,
        // which is how this device can still know to look there.
        let legacy = "https://OMARCHY-fixture.invalid:8099/"
        XCTAssertNotEqual(legacy, fixture.account)
        try fixture.credentials.saveToken("pair5-token", account: legacy)
        try fixture.pins.save(fixture.pin, account: legacy)
        fixture.remember(address: "OMARCHY-fixture.invalid:8099")

        await fixture.gate.check(directory: fixture.directory, home: fixture.home)

        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), "pair5-token",
                       "the credential moved to the key `HostAccount.derive` asks for")
        XCTAssertNil(try fixture.credentials.loadToken(account: legacy), "and it moved, rather than being copied")
        XCTAssertNotNil(fixture.pins.load(account: fixture.account))
        XCTAssertNil(fixture.pins.load(account: legacy))
        XCTAssertEqual(GateStub.authorizations, ["Bearer pair5-token"], "the migrated credential is the one probed")
        XCTAssertEqual(fixture.gate.standing[fixture.account], .live)
        XCTAssertEqual(fixture.directory.records.count, 1, "nothing was thrown away")
        XCTAssertFalse(fixture.isBackAtTheHostList)
    }

    /// The keys the migration is allowed to look under: the same machine and
    /// the same port, spelled differently. Never another host, never http.
    func testTheOlderKeysAreOnlyOtherSpellingsOfTheSameOrigin() {
        let keys = LegacyHostAccount.keys(canonical: "https://omarchy:8099",
                                          spellings: ["https://Omarchy:8099/", "OMARCHY:8099", "omarchy",
                                                      "studio", "https://omarchy:9000", "192.168.1.10:8099"])
        XCTAssertEqual(Set(keys), ["https://omarchy:8099/", "https://Omarchy:8099", "https://Omarchy:8099/",
                                   "https://OMARCHY:8099", "https://OMARCHY:8099/"])
        XCTAssertFalse(keys.contains("https://omarchy:8099"), "the canonical key is not its own legacy key")
        XCTAssertFalse(keys.contains { $0.contains("studio") || $0.contains("192.168") },
                       "a credential can never migrate to another machine")
        XCTAssertTrue(LegacyHostAccount.keys(canonical: "not a url", spellings: ["omarchy"]).isEmpty)
    }
}

// MARK: - Fixture

@MainActor private struct GateFixture {
    let gate: HostCredentialGate
    let home: HomeStore
    let directory: PairedHostDirectory
    let pins: HostPinStore
    let credentials: CompanionCredentialStore
    let hostKeys: HostKeyStore
    let account = "https://omarchy-fixture.invalid:8099"
    let suiteName: String

    var pin: HostPin {
        HostPin(hostID: GateConstants.hostID, hostName: "omarchy",
                fingerprintSHA256: GateConstants.fingerprint,
                endpoints: [.init(host: "omarchy-fixture.invalid", port: 8099)],
                ssh: .init(user: "alex", host: "omarchy-fixture.invalid", port: 22),
                grants: .init(companion: true, media: true, ssh: true))
    }

    init(verdict: CredentialVerdict) throws {
        GateStub.reset(verdict: verdict)
        let records = GateRecords()
        let service = "com.omodachi.tests.pair5.\(UUID().uuidString)"
        pins = HostPinStore(service: service + ".pin", records: records)
        credentials = CompanionCredentialStore(service: service + ".credential", records: records)
        hostKeys = HostKeyStore(service: service + ".hostkey", records: records)
        suiteName = "omodachi.pair-5.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = account
        defaults.set(try JSONEncoder().encode(profile), forKey: "omodachi.profile.v1")
        directory = PairedHostDirectory(defaults: defaults)
        home = HomeStore(defaults: defaults, clientFactory: { _, _ in GateNoService() }, autoConnect: false)
        gate = HostCredentialGate(pins: pins, credentials: credentials, hostKeys: hostKeys,
                                  forcedVerdict: nil,
                                  makeProbe: { CredentialProbe(endpoint: $0, pinnedFingerprint: $1,
                                                               session: GateStub.session()) })
    }

    /// What a completed pairing leaves behind: a credential, a pin and a row.
    func store() {
        try? credentials.saveToken("pair5-token", account: account)
        try? pins.save(pin, account: account)
        remember()
    }

    func remember(address: String = "omarchy-fixture.invalid:8099") {
        directory.remember(.init(account: account, hostID: GateConstants.hostID,
                                 hostName: "omarchy", address: address))
    }

    /// The Shell's gate, in the two records it actually reads
    /// (`Omodachi/Shell/OmodachiApp.swift` `needsPairing`).
    var isBackAtTheHostList: Bool {
        directory.records.isEmpty && home.profile.companionURL.isEmpty
    }

    static func store(named name: String) throws -> HomeStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "omodachi.\(name).\(UUID().uuidString)"))
        return HomeStore(defaults: defaults, clientFactory: { _, _ in GateNoService() }, autoConnect: false)
    }
}

private enum GateConstants {
    static let hostID = String(repeating: "e", count: 32)
    static let fingerprint = String(repeating: "f", count: 64)
}

/// `GET /v1/state` for one invalid host, answering the way core's boundary
/// answers: 200, or 401 `permission_denied`, or nobody home.
private final class GateStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var verdict: CredentialVerdict = .live
    nonisolated(unsafe) private static var seenPaths: [String] = []
    nonisolated(unsafe) private static var seenAuthorizations: [String] = []

    static func reset(verdict value: CredentialVerdict) {
        lock.withLock { verdict = value; seenPaths = []; seenAuthorizations = [] }
    }
    static var paths: [String] { lock.withLock { seenPaths } }
    static var authorizations: [String] { lock.withLock { seenAuthorizations } }

    static func session() -> URLSession {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [GateStub.self]
        return URLSession(configuration: options)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "omarchy-fixture.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let verdict = Self.lock.withLock { () -> CredentialVerdict in
            Self.seenPaths.append(request.url?.path ?? "")
            if let value = request.value(forHTTPHeaderField: "Authorization") {
                Self.seenAuthorizations.append(value)
            }
            return Self.verdict
        }
        var status = 200
        var body = Data("{}".utf8)
        switch verdict {
        case .live: status = 200
        case let .rejected(reason):
            status = 401
            // A host from before CORE-2 names no reason; `.unknown` is that host.
            body = reason == .unknown
                ? Data(#"{"error":{"code":"permission_denied"}}"#.utf8)
                : Data(#"{"error":{"code":"permission_denied","reason":"\#(reason.rawValue)"}}"#.utf8)
        case .unreachable:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class GateRecords: KeychainRecordStore, @unchecked Sendable {
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

/// The Shell's store needs a client factory; PAIR-5's cases never connect.
private struct GateNoService: CompanionServing {
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
