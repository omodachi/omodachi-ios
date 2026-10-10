import XCTest
@testable import Omodachi

/// REMOTE-PAIR-1. Leo's iPhone paired a second time under a new id, and Remote
/// then refused the phone's own certificate. These pin the app's half of the
/// fix: the id lives beside the credential and follows it, a credential is only
/// thrown away on a refusal that is really one, and Remote renews by itself and
/// says what to do when it cannot.

// MARK: - The id and the credential stay one identity

@MainActor final class CompanionDeviceIdentityTests: XCTestCase {
    private func suite() throws -> UserDefaults {
        let name = "omodachi.remote-pair-1.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testTheIdOutlivesTheAppContainerLikeTheCredentialDoes() throws {
        let keychain = PairMemoryKeychain()
        let first = try suite()
        let minted = CompanionDeviceIdentity.current(defaults: first, keychain: keychain)
        XCTAssertTrue(minted.hasPrefix("ios-"))
        XCTAssertEqual(CompanionDeviceIdentity.current(defaults: first, keychain: keychain), minted)
        // A reinstall: the defaults are new, the Keychain is not.
        let reinstalled = try suite()
        XCTAssertEqual(CompanionDeviceIdentity.current(defaults: reinstalled, keychain: keychain), minted,
                       "a reinstalled app pairs under the id its credential was issued to")
        XCTAssertEqual(reinstalled.string(forKey: CompanionDeviceIdentity.defaultsKey), minted,
                       "and the readers that only look at the defaults see the same id")
    }

    func testAnIdFromBeforeThisBuildMovesIntoTheKeychain() throws {
        let keychain = PairMemoryKeychain()
        let defaults = try suite()
        defaults.set("ios-older-build", forKey: CompanionDeviceIdentity.defaultsKey)
        XCTAssertEqual(CompanionDeviceIdentity.current(defaults: defaults, keychain: keychain), "ios-older-build")
        XCTAssertEqual(CompanionDeviceIdentity.stored(defaults: try suite(), keychain: keychain), "ios-older-build")
    }

    func testTheCredentialNamesTheIdTheHostKnowsThisDeviceBy() throws {
        XCTAssertEqual(CompanionDeviceIdentity.deviceID(inCredential: Self.token(for: "ios-4c37679b")), "ios-4c37679b")
        XCTAssertNil(CompanionDeviceIdentity.deviceID(inCredential: "not-a-token"))
        XCTAssertNil(CompanionDeviceIdentity.deviceID(inCredential: "e30.c2ln"), "a payload without an id")
        XCTAssertNil(CompanionDeviceIdentity.deviceID(inCredential: Self.token(for: "bad id with spaces")))
    }

    /// Leo's phone, 2026-09-24: the reinstall adopted the live credential of
    /// `ios-4c37679b` but minted `ios-47b40305` for itself, and the next
    /// pairing went up as a stranger. Proving the credential live now settles
    /// the id on the credential's.
    func testALiveCredentialSettlesTheIdOnTheOneItWasIssuedTo() throws {
        let keychain = PairMemoryKeychain()
        let defaults = try suite()
        XCTAssertEqual(CompanionDeviceIdentity.current(defaults: defaults, keychain: keychain).prefix(4), "ios-")
        XCTAssertEqual(CompanionDeviceIdentity.adopt(credential: Self.token(for: "ios-4c37679b"),
                                                     defaults: defaults, keychain: keychain), "ios-4c37679b")
        XCTAssertEqual(CompanionDeviceIdentity.current(defaults: defaults, keychain: keychain), "ios-4c37679b")
        XCTAssertNil(CompanionDeviceIdentity.adopt(credential: Self.token(for: "ios-4c37679b"),
                                                   defaults: defaults, keychain: keychain), "nothing to change")
    }

    /// The shape core mints (`auth.py` `_mint`): base64url JSON, a dot, a signature.
    static func token(for device: String) -> String {
        let payload = #"{"v":1,"device_id":"\#(device)","iat":1790000000,"nonce":"abc"}"#
        func url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return url(Data(payload.utf8)) + "." + url(Data(repeating: 7, count: 32))
    }
}

// MARK: - A credential goes only on a refusal that is really one

@MainActor final class DefinitiveRefusalTests: XCTestCase {
    func testA403IsNotAVerdictOnTheCredential() async throws {
        let fixture = try RefusalFixture(answers: [.status(403, #"{"error":{"code":"host_not_allowed"}}"#)])
        await fixture.gate.check(directory: fixture.directory, home: fixture.home)
        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), fixture.token)
        XCTAssertEqual(fixture.directory.records.count, 1)
        XCTAssertTrue(fixture.gate.discarded.isEmpty)
        XCTAssertTrue(fixture.gate.isOffline(fixture.account))
    }

    /// A host half-way through a restart, or one whose registry could not be
    /// read just then, answering a 401 that names no reason - and then the
    /// ordinary 200. Nothing is thrown away.
    func testARefusalWithNoReasonThatDoesNotRepeatCostsNothing() async throws {
        let fixture = try RefusalFixture(answers: [.status(401, #"{"error":{"code":"permission_denied"}}"#), .status(200, "{}")])
        await fixture.gate.check(directory: fixture.directory, home: fixture.home)
        XCTAssertEqual(RefusalStub.count, 2, "asked twice before deciding")
        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), fixture.token)
        XCTAssertEqual(fixture.gate.standing[fixture.account], .live)
        XCTAssertTrue(fixture.gate.discarded.isEmpty)
    }

    func testARefusalWithNoReasonThatRepeatsIsOne() async throws {
        let fixture = try RefusalFixture(answers: [.status(401, #"{"error":{"code":"permission_denied"}}"#),
                                                  .status(401, #"{"error":{"code":"permission_denied"}}"#)])
        await fixture.gate.check(directory: fixture.directory, home: fixture.home)
        XCTAssertEqual(RefusalStub.count, 2)
        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.account))
        XCTAssertEqual(fixture.gate.discarded.map(\.reason), [.unknown])
    }

    func testARefusalThatSaysWhyIsFinalAtOnce() async throws {
        let fixture = try RefusalFixture(answers: [.status(401, #"{"error":{"code":"permission_denied","reason":"credential_revoked"}}"#)])
        await fixture.gate.check(directory: fixture.directory, home: fixture.home)
        XCTAssertEqual(RefusalStub.count, 1)
        XCTAssertNil(try fixture.credentials.loadToken(account: fixture.account))
        XCTAssertEqual(fixture.gate.discarded.map(\.reason), [.revoked])
    }

    func testAHostThatAnswers503IsOfflineNotARevocation() async throws {
        let fixture = try RefusalFixture(answers: [.status(503, #"{"error":{"code":"auth_unavailable"}}"#)])
        await fixture.gate.check(directory: fixture.directory, home: fixture.home)
        XCTAssertEqual(try fixture.credentials.loadToken(account: fixture.account), fixture.token)
        XCTAssertTrue(fixture.gate.isOffline(fixture.account))
    }

    func testTheLaunchCheckSettlesTheIdOnTheLiveCredential() async throws {
        let fixture = try RefusalFixture(answers: [.status(200, "{}")], device: "ios-4c37679b")
        fixture.home.defaults.set("ios-47b40305", forKey: CompanionDeviceIdentity.defaultsKey)
        await fixture.gate.check(directory: fixture.directory, home: fixture.home)
        XCTAssertEqual(CompanionDeviceIdentity.stored(defaults: fixture.home.defaults, keychain: fixture.identity),
                       "ios-4c37679b")
    }
}

@MainActor private struct RefusalFixture {
    let gate: HostCredentialGate
    let home: HomeStore
    let directory: PairedHostDirectory
    let pins: HostPinStore
    let credentials: CompanionCredentialStore
    let identity = PairMemoryKeychain()
    let account = "https://pair1-fixture.invalid:8099"
    let token: String

    init(answers: [RefusalStub.Answer], device: String = "ios-fixture") throws {
        RefusalStub.reset(answers)
        let records = PairMemoryKeychain()
        let service = "com.omodachi.tests.remote-pair-1.\(UUID().uuidString)"
        pins = HostPinStore(service: service + ".pin", records: records)
        credentials = CompanionCredentialStore(service: service + ".credential", records: records)
        let hostKeys = HostKeyStore(service: service + ".hostkey", records: records)
        let name = "omodachi.remote-pair-1.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = account
        defaults.set(try JSONEncoder().encode(profile), forKey: "omodachi.profile.v1")
        directory = PairedHostDirectory(defaults: defaults)
        home = HomeStore(defaults: defaults, clientFactory: { _, _ in PairNoService() }, autoConnect: false)
        token = CompanionDeviceIdentityTests.token(for: device)
        try credentials.saveToken(token, account: account)
        try pins.save(HostPin(hostID: String(repeating: "e", count: 32), hostName: "omarchy",
                              fingerprintSHA256: String(repeating: "f", count: 64),
                              endpoints: [.init(host: "pair1-fixture.invalid", port: 8099)],
                              ssh: nil, grants: .init(companion: true, media: true, ssh: true)),
                      account: account)
        directory.remember(.init(account: account, hostID: String(repeating: "e", count: 32),
                                 hostName: "omarchy", address: "pair1-fixture.invalid:8099"))
        gate = HostCredentialGate(pins: pins, credentials: credentials, hostKeys: hostKeys, forcedVerdict: nil,
                                  makeProbe: { CredentialProbe(endpoint: $0, pinnedFingerprint: $1,
                                                               session: RefusalStub.session()) },
                                  confirmationDelay: .zero, identityKeychain: identity)
    }
}

/// `GET /v1/state` answered from a script, one answer per request.
private final class RefusalStub: URLProtocol, @unchecked Sendable {
    enum Answer { case status(Int, String) }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: [Answer] = []
    nonisolated(unsafe) private static var seen = 0

    static func reset(_ answers: [Answer]) { lock.withLock { script = answers; seen = 0 } }
    static var count: Int { lock.withLock { seen } }
    static func session() -> URLSession {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [RefusalStub.self]
        return URLSession(configuration: options)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pair1-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let answer = Self.lock.withLock { () -> Answer in
            Self.seen += 1
            return Self.script.isEmpty ? .status(200, "{}") : Self.script.removeFirst()
        }
        guard case let .status(code, body) = answer else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class PairMemoryKeychain: KeychainRecordStore, @unchecked Sendable {
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
    func load(service: String, account: String) throws -> Data? { lock.withLock { values["\(service)|\(account)"] } }
    func remove(service: String, account: String) throws {
        lock.withLock { _ = values.removeValue(forKey: "\(service)|\(account)") }
    }
}

private struct PairNoService: CompanionServing {
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

// MARK: - Remote renews by itself, and says what to do when it cannot

@MainActor final class RemoteRenewalTests: XCTestCase {
    private func make() -> (RemoteSessionController, FakeRemoteHost) {
        let host = FakeRemoteHost()
        let controller = RemoteSessionController(service: host, driver: FakeBackend(),
                                                 heartbeatInterval: .milliseconds(10),
                                                 backgroundGrace: .seconds(60))
        controller.backendChoice = .sunshine
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        return (controller, host)
    }

    private func refused(_ controller: RemoteSessionController, _ host: FakeRemoteHost) async {
        await host.setFailNextCreate(RemoteRequestError(code: "media_pairing_required", status: 409))
        controller.start()
        for _ in 0..<400 where controller.pairingStatus.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.pairingStatus, Strings.remotePairingRenewing, "the renewal starts by itself")
    }

    /// The first stumble of a renewal the app started is not shown to anyone:
    /// no failure, no repair card, no button - it simply goes again.
    func testARenewalThatStumblesOnceTriesAgainByItself() async throws {
        let (controller, host) = make()
        await refused(controller, host)
        controller.pairingFinished(paired: false, retriable: true)
        XCTAssertEqual(controller.automaticRenewalRetries, 1)
        XCTAssertFalse(controller.phase.isFailed, "\(controller.phase)")
        XCTAssertFalse(controller.showsSunshineRepair, "no manual button while it is still trying")
        // The second stumble is a real failure, with the button.
        controller.pairingFinished(paired: false, retriable: true)
        XCTAssertTrue(controller.phase.isFailed)
        XCTAssertTrue(controller.showsSunshineRepair)
    }

    /// Something only the person at the computer can change is said at once.
    func testARenewalTheHostRefusesForGoodShowsTheButtonAndTheWayOut() async throws {
        let (controller, host) = make()
        await refused(controller, host)
        controller.pairingFinished(paired: false, retriable: false)
        XCTAssertEqual(controller.automaticRenewalRetries, 0)
        XCTAssertTrue(controller.phase.isFailed)
        XCTAssertTrue(controller.showsSunshineRepair)
        // What the card then says for the refusal this spec is about.
        XCTAssertEqual(MediaPairingError(code: "media_pairing_binding_mismatch", status: 403).userMessage,
                       Strings.reasonMediaBindingMismatch)
    }

    /// A pairing that lands after one retry resumes the session it was for.
    func testARetriedRenewalThatLandsResumesTheSession() async throws {
        let (controller, host) = make()
        await refused(controller, host)
        controller.pairingFinished(paired: false, retriable: true)
        controller.pairingFinished(paired: true, retriable: false)
        for _ in 0..<400 { if await host.created.count == 1 { break }; try? await Task.sleep(for: .milliseconds(5)) }
        let created = await host.created.count
        XCTAssertEqual(created, 1, "the session the refusal interrupted is asked for again")
        XCTAssertEqual(controller.automaticRenewalRetries, 0)
        XCTAssertTrue(controller.sunshinePaired)
    }

    /// The old sentence was "bound to another device, start again" - and
    /// starting again failed the same way, for ever. The new one names the
    /// place on the computer that ends it.
    func testTheMismatchSentenceSaysWhatToDo() {
        let text = ReasonText.message("media_pairing_binding_mismatch", domain: .media)
        XCTAssertEqual(text, Strings.reasonMediaBindingMismatch)
        XCTAssertFalse(text.contains("请重新发起") || text.contains("Start again"), text)
        XCTAssertTrue(text.contains("Omodachi"), text)
    }
}

// MARK: - Which pairing failures a second try can get past

@MainActor final class PairingRetriabilityTests: XCTestCase {
    func testOnlyWhatASecondTryCanFixIsRetried() {
        XCTAssertTrue(SunshinePairingFlow.retriable(MediaPairingError(code: "media_pairing_request_not_unique", status: 409)))
        XCTAssertTrue(SunshinePairingFlow.retriable(MediaPairingError(code: "media_pairing_ipc_unavailable", status: 503)))
        XCTAssertTrue(SunshinePairingFlow.retriable(MediaPairingError(code: "media_pairing_timeout", status: 504)))
        XCTAssertFalse(SunshinePairingFlow.retriable(MediaPairingError(code: "media_pairing_binding_mismatch", status: 403)))
        XCTAssertFalse(SunshinePairingFlow.retriable(MediaPairingError(code: "media_permission_required", status: 403)))
        XCTAssertFalse(SunshinePairingFlow.retriable(MediaPairingError(code: "media_certificate_already_associated", status: 409)))
    }
}
