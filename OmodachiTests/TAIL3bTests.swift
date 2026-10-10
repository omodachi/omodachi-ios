import Foundation
import XCTest
@testable import Omodachi

/// TAIL-3b: app links (I1), the Odomo row's address (I2), "Use Tailscale for
/// this computer" (L03), the Tailscale hint, and an already-paired host met
/// again by its Tailscale name.
private final class MemoryKeychain: KeychainRecordStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    func save(_ value: Data, service: String, account: String) throws { lock.withLock { values["\(service)|\(account)"] = value } }
    func insertIfAbsent(_ value: Data, service: String, account: String) throws -> Bool {
        lock.withLock {
            let key = "\(service)|\(account)"
            if values[key] != nil { return false }
            values[key] = value
            return true
        }
    }
    func load(service: String, account: String) throws -> Data? { lock.withLock { values["\(service)|\(account)"] } }
    func remove(service: String, account: String) throws { lock.withLock { _ = values.removeValue(forKey: "\(service)|\(account)") } }
}

private enum Fixture {
    static let hostID = String(repeating: "0", count: 32)
    static let other = String(repeating: "f", count: 32)
    static let fingerprint = String(repeating: "ab", count: 32)
    static let lan = "https://192.168.1.10:8099"
    static let name = "omarchy-fixture.tail0000.ts.net"

    static func record(_ account: String = lan, hostID: String = hostID) -> PairedHostRecord {
        PairedHostRecord(account: account, hostID: hostID, hostName: "omarchy-fixture", address: "192.168.1.10:8099")
    }

    static func pin(hostID: String = hostID) -> HostPin {
        HostPin(hostID: hostID, hostName: "omarchy-fixture", fingerprintSHA256: fingerprint,
                endpoints: [.init(host: "192.168.1.10", port: 8099, kind: .lan),
                            .init(host: name, port: 8099, kind: .tailnet)])
    }
}

/// `GET /v1/state` answers with the status the test sets.
private final class StateStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool {
        ["/v1/state", "/health"].contains { request.url?.path.hasSuffix($0) == true }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let health = request.url?.path.hasSuffix("/health") == true
        let body = health
            ? #"{"service":"omodachid","host_id":"\#(Fixture.hostID)","tls_fingerprint_sha256":"\#(Fixture.fingerprint)"}"#
            : #"{}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: health ? 200 : Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [StateStub.self]
        return URLSession(configuration: options)
    }
}

private struct NoResolver: TailnetNameResolving {
    func reverseName(of address: String) async -> String? { nil }
    func forwardAddresses(of name: String) async -> [String] { [] }
}

@MainActor final class TAIL3bTests: XCTestCase {
    // MARK: - I1 links

    func testBothLinkFormsCarryATargetAndAHostIDAndNothingElse() throws {
        let web = try XCTUnwrap(AppLink.parse(URL(string: "https://omodachi.app/open/remote?host=\(Fixture.hostID)")!))
        XCTAssertEqual(web, AppLink(target: .remote, hostID: Fixture.hostID))
        let scheme = try XCTUnwrap(AppLink.parse(URL(string: "omodachi://open/remote?host=\(Fixture.hostID)&x=1")!))
        XCTAssertEqual(scheme, web)
        XCTAssertEqual(AppLink.parse(URL(string: "omodachi://open/host?host=\(Fixture.hostID)")!)?.target, .host)
        XCTAssertEqual(AppLink.parse(URL(string: "https://www.omodachi.app/open/")!), AppLink(target: .app, hostID: nil))
        XCTAssertEqual(AppLink.parse(URL(string: "omodachi://open/remote?host=192.168.1.10")!)?.hostID, nil,
                       "an address is not a host id, and is never dialled")
        XCTAssertNil(AppLink.parse(URL(string: "https://example.com/open/remote?host=\(Fixture.hostID)")!))
        XCTAssertNil(AppLink.parse(URL(string: "https://omodachi.app/privacy")!))
        XCTAssertNil(AppLink.parse(URL(string: "otherapp://open/remote")!))
    }

    func testALinkIsAnsweredOnlyByThisDevicesOwnPairedList() {
        let paired = Fixture.record()
        let second = Fixture.record("https://\(Fixture.name):8099", hostID: String(repeating: "1", count: 32))
        let link = AppLink(target: .remote, hostID: Fixture.hostID)
        XCTAssertEqual(link.resolve(records: [second, paired], current: second.account), .open(paired, .remote))
        XCTAssertEqual(AppLink(target: .remote, hostID: Fixture.other).resolve(records: [paired], current: paired.account),
                       .unknownHost, "an unknown host is a sentence, never a pairing")
        XCTAssertEqual(AppLink(target: .host, hostID: nil).resolve(records: [second, paired], current: paired.account),
                       .open(paired, .host))
        XCTAssertEqual(AppLink(target: .host, hostID: nil).resolve(records: [second, paired], current: nil), .unknownHost)
        XCTAssertEqual(AppLink(target: .host, hostID: nil).resolve(records: [paired], current: nil), .open(paired, .host))
        XCTAssertEqual(link.resolve(records: [], current: nil), .unknownHost)
    }

    // MARK: - LITE-1c: links that just open the app

    func testGetTheAppAndOpenTheAppOpenTheAppWithNoSentence() throws {
        let paired = Fixture.record()
        let second = Fixture.record("https://\(Fixture.name):8099", hostID: String(repeating: "1", count: 32))
        for value in ["https://omodachi.app/open/", "https://omodachi.app/open", "https://www.omodachi.app/open/app",
                      "https://omodachi.app/open/app?host=\(Fixture.hostID)", "omodachi://open/", "omodachi://open",
                      "omodachi://open/app", "OMODACHI://OPEN/APP"] {
            let link = try XCTUnwrap(AppLink.parse(URL(string: value)!), value)
            XCTAssertEqual(link.target, .app, value)
            // Not paired, paired with one, paired with two and none on screen:
            // never "This link is for a computer not paired here".
            XCTAssertEqual(link.resolve(records: [], current: nil), .home, value)
            XCTAssertEqual(link.resolve(records: [paired], current: nil), .home, value)
            XCTAssertEqual(link.resolve(records: [second, paired], current: nil), .home, value)
        }
        // The two that name a host keep working as before.
        let remote = try XCTUnwrap(AppLink.parse(URL(string: "https://omodachi.app/open/remote?host=\(Fixture.hostID)")!))
        XCTAssertEqual(remote.resolve(records: [second, paired], current: nil), .open(paired, .remote))
        let host = try XCTUnwrap(AppLink.parse(URL(string: "omodachi://open/host?host=\(Fixture.hostID)")!))
        XCTAssertEqual(host.resolve(records: [second, paired], current: nil), .open(paired, .host))
        XCTAssertNil(AppLink.parse(URL(string: "https://omodachi.app/")!), "only /open/* is ours")
    }

    // MARK: - I2 Odomo's address

    func testOnlyAnOdomoAddressOfTheShapeCorePublishesIsOpened() throws {
        func odomo(_ value: String?) throws -> URL? {
            var json = #"{"host_id":"\#(Fixture.hostID)","endpoints":[]"#
            if let value { json += #","odomo_url":"\#(value)""# }
            return try JSONDecoder().decode(HostRoadsDTO.self, from: Data((json + "}").utf8)).odomoURL
        }
        XCTAssertEqual(try odomo("https://omarchy-fixture.tail0000.ts.net/odomo/")?.host, Fixture.name)
        XCTAssertNotNil(try odomo("https://omarchy-fixture.tail0000.ts.net:8443/odomo/"))
        XCTAssertNil(try odomo(nil))
        XCTAssertNil(try odomo("http://omarchy-fixture.tail0000.ts.net/odomo/"))
        XCTAssertNil(try odomo("https://evil.example/odomo/"))
        XCTAssertNil(try odomo("https://omarchy-fixture.tail0000.ts.net/other/"))
        XCTAssertNil(try odomo("https://omarchy-fixture.tail0000.ts.net/lite/"), "the old path is not Odomo's")
        XCTAssertNil(try odomo("https://user@omarchy-fixture.tail0000.ts.net/odomo/"))
        let fixture = try Data(contentsOf: XCTUnwrap(Bundle(for: TAIL3bTests.self)
            .url(forResource: "host-roads", withExtension: "json", subdirectory: "CoreFixtures")))
        XCTAssertNil(try JSONDecoder().decode(HostRoadsDTO.self, from: fixture).odomoURL)
        // Core's own fixture (contracts/fixtures/host-roads-odomo.json).
        let withOdomo = try Data(contentsOf: XCTUnwrap(Bundle(for: TAIL3bTests.self)
            .url(forResource: "host-roads-odomo", withExtension: "json", subdirectory: "CoreFixtures")))
        XCTAssertEqual(try JSONDecoder().decode(HostRoadsDTO.self, from: withOdomo).odomoURL?.absoluteString,
                       "https://omarchy-fixture.tail0000.ts.net/odomo/")
    }

    func testTheWebAppIsNamedInOnePlace() {
        XCTAssertEqual(Strings.odomoName, "Odomo")
        XCTAssertTrue(Strings.odomoRow(DeviceWord.current, Strings.odomoName).contains(Strings.odomoName))
        XCTAssertTrue(Strings.odomoRowDetail(Strings.odomoName).contains(Strings.odomoName))
        XCTAssertFalse(Strings.odomoRowDetail(Strings.odomoName).contains("Safari"), "it opens in the app now")
        XCTAssertTrue(Strings.odomoNone(Strings.odomoName, Strings.odomoName).contains(Strings.odomoName))
        XCTAssertFalse(Strings.pairingCertificateChangedDetail.contains("omodachi-host"), "no command on a phone screen")
        XCTAssertFalse(Strings.settingsRevokeOnHost.contains("omodachi-host"), "no command on a phone screen")
    }

    // MARK: - L03 Use Tailscale for this computer

    private func move(status: Int, health: HostHealth?, input: String = Fixture.name) throws
        -> (TailscaleMoveModel, HostPinStore) {
        let pins = HostPinStore(service: "tail3b.move", records: MemoryKeychain())
        try pins.save(Fixture.pin(), account: Fixture.lan)
        let credentials = CompanionCredentialStore(service: "tail3b.move", records: MemoryKeychain())
        try credentials.saveToken("fixture-token", account: Fixture.lan)
        StateStub.status = status
        let model = TailscaleMoveModel(account: Fixture.lan, hostName: "omarchy-fixture", pins: pins,
                                       credentials: credentials, resolver: NoResolver(),
                                       readHealth: { _ in
                                           guard let health else { throw HostHealthError.unreachable }
                                           return health
                                       },
                                       makeProbe: { CredentialProbe(endpoint: $0, pinnedFingerprint: $1, session: StateStub.session()) })
        model.input = input
        return (model, pins)
    }

    func testTheMoveIsPrefilledAndHappensOnlyWhenTheNameIsThisHost() async throws {
        let (model, pins) = try move(status: 200, health: HostHealth(hostID: Fixture.hostID, hostName: nil,
                                                                     fingerprint: Fixture.fingerprint))
        XCTAssertEqual(model.knownName, Fixture.name, "L03: learnt from GET /v1/host/roads")
        let moved = await model.run()
        XCTAssertTrue(moved)
        XCTAssertEqual(model.state, .done)
        let pin = try XCTUnwrap(pins.load(account: Fixture.lan))
        XCTAssertEqual(pin.road, HostRoad(host: Fixture.name, port: 8099, kind: .tailnet))
        XCTAssertEqual(pin.hostID, Fixture.hostID, "no new pairing: same pin, same account")
    }

    func testAnotherMachineOnThatNameChangesNothing() async throws {
        let (model, pins) = try move(status: 200, health: HostHealth(hostID: Fixture.other, hostName: nil,
                                                                     fingerprint: Fixture.fingerprint))
        let moved = await model.run()
        XCTAssertFalse(moved)
        XCTAssertEqual(model.state, .notSame(Fixture.name))
        XCTAssertNil(pins.load(account: Fixture.lan)?.road)
    }

    func testANameThatDoesNotAnswerChangesNothing() async throws {
        let (model, pins) = try move(status: 200, health: nil)
        let moved = await model.run()
        XCTAssertFalse(moved)
        XCTAssertEqual(model.state, .noAnswer(Fixture.name))
        XCTAssertNil(pins.load(account: Fixture.lan)?.road)
    }

    func testAMoveToSomethingThatIsNotATailscaleNameIsRefused() async throws {
        let (model, _) = try move(status: 200, health: nil, input: "192.168.1.10")
        let moved = await model.run()
        XCTAssertFalse(moved)
        XCTAssertEqual(model.state, .problem(.notTailscale("192.168.1.10")))
    }

    func testACredentialTheNameDoesNotTakeIsNotThisHost() async throws {
        let (model, pins) = try move(status: 401, health: HostHealth(hostID: Fixture.hostID, hostName: nil,
                                                                     fingerprint: Fixture.fingerprint))
        let moved = await model.run()
        XCTAssertFalse(moved)
        XCTAssertEqual(model.state, .notSame(Fixture.name))
        XCTAssertNil(pins.load(account: Fixture.lan)?.road)
    }

    // MARK: - An already-paired host met again on the Tailscale page

    private func flow(paired account: String, road: HostRoad? = nil, defaults: UserDefaults)
        throws -> (ConnectionFlowModel, HostPinStore) {
        let directory = PairedHostDirectory(defaults: defaults)
        directory.remember(Fixture.record(account))
        let pins = HostPinStore(service: "tail3b.flow", records: MemoryKeychain())
        var pin = Fixture.pin()
        pin.road = road
        try pins.save(pin, account: account)
        let credentials = CompanionCredentialStore(service: "tail3b.flow", records: MemoryKeychain())
        try credentials.saveToken("fixture-token", account: account)
        StateStub.status = 200
        let flow = ConnectionFlowModel(deviceID: "ios-fixture", deviceName: "Fixture iPad", pins: pins,
                                       credentials: credentials, directory: directory,
                                       probe: HostHealthProbe(session: StateStub.session()), keyOffer: nil,
                                       nameResolver: NoResolver(),
                                       makeClient: { _ in throw PairingError.unreachable },
                                       makeProbe: { CredentialProbe(endpoint: $0, pinnedFingerprint: $1, session: StateStub.session()) })
        return (flow, pins)
    }

    private func settle(_ flow: ConnectionFlowModel) async {
        let deadline = Date().addingTimeInterval(5)
        while flow.claimed == nil, flow.failure == nil, flow.tailscaleProblem == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAWiFiHostReachedByItsTailscaleNameMovesToTailscaleWithoutPairing() async throws {
        let name = "tail3b-adopt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let (flow, pins) = try flow(paired: Fixture.lan, defaults: defaults)
        flow.tailscaleInput = Fixture.name
        flow.connectTailscale(sshPublicKey: nil)
        await settle(flow)
        XCTAssertEqual(flow.claimed?.account, HostAccount.canonical(Fixture.lan), "the same row, no second host")
        XCTAssertEqual(pins.load(account: Fixture.lan)?.road?.host, Fixture.name)
        XCTAssertEqual(pins.load(account: Fixture.lan)?.road?.kind, .tailnet)
    }

    func testATailscaleHostFoundOnTheWiFiStaysOnTailscale() async throws {
        let name = "tail3b-stay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let account = "https://\(Fixture.name):8099"
        let (flow, pins) = try flow(paired: account, defaults: defaults)
        flow.stage = .wifi
        flow.select(try XCTUnwrap(HostCandidate.manual("192.168.1.10")), sshPublicKey: nil, from: .wifi)
        await settle(flow)
        XCTAssertEqual(flow.claimed?.account, account)
        XCTAssertEqual(pins.load(account: account)?.road(account: account).kind, .tailnet,
                       "there is no \"back to Wi-Fi only\": forget the computer and pair again")
    }

    // MARK: - The Tailscale hint

    func testTailscaleIsUpOnlyWithATailnetAddressOnATunnel() {
        XCTAssertTrue(TailscaleAddress.isUp([("en0", "192.168.1.27"), ("utun4", "100.101.102.103")]))
        XCTAssertTrue(TailscaleAddress.isUp([("utun2", "fd7a:115c:a1e0::1")]))
        XCTAssertFalse(TailscaleAddress.isUp([("en0", "100.101.102.103")]), "not on a tunnel")
        XCTAssertFalse(TailscaleAddress.isUp([("utun3", "10.8.0.2")]), "another VPN")
        XCTAssertFalse(TailscaleAddress.isUp([]))
        XCTAssertEqual(TailscaleAddress.appStoreURL.absoluteString, "https://apps.apple.com/app/id1470499037")
    }

    // MARK: - The words

    func testTheProblemWordsNameTheRightThing() {
        let off = TailscaleConnectView.words(.noName("omarchy"), tailscaleUp: false)
        XCTAssertEqual(off.title, Strings.errTsOffTitle(DeviceWord.current), "no Tailscale here is about this device")
        XCTAssertEqual(TailscaleConnectView.words(.noName("omarchy"), tailscaleUp: true).title, Strings.errNoNameTitle("omarchy"))
        XCTAssertEqual(TailscaleConnectView.words(.notTailscale("omarchy"), tailscaleUp: false).title,
                       Strings.errNotTailscaleTitle("omarchy"))
        XCTAssertEqual(TailscaleConnectView.words(.noHost("omarchy"), tailscaleUp: true).detail, Strings.errNoHostBody)
        XCTAssertFalse(Strings.sshTailscaleSSH.contains("同一网络"), "E07: there is no second road to suggest")
        XCTAssertNotEqual(Strings.roadTailscale, Strings.roadLAN)
    }
}
