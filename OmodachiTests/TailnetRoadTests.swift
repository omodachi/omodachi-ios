import Foundation
import XCTest
@testable import Omodachi

/// TAIL-2: one host, several roads — the tailnet among them.
private final class RoadMemoryKeychain: KeychainRecordStore, @unchecked Sendable {
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
    func remove(service: String, account: String) throws { lock.withLock { _ = values.removeValue(forKey: "\(service)|\(account)") } }
}

private enum RoadFixture {
    static let hostID = String(repeating: "0", count: 32)
    static let fingerprint = String(repeating: "ab", count: 32)
    static let lan = "https://192.168.1.10:8099"
    static let name = "omarchy-fixture.tail0000.ts.net"

    static func coreFixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: TailnetRoadTests.self)
            .url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures")))
    }

    static func pin(roads: [HostRoad], ssh: HostPin.SSHEndpoint? = nil) -> HostPin {
        HostPin(hostID: hostID, hostName: "omarchy-fixture", fingerprintSHA256: fingerprint,
                endpoints: roads.map { .init(host: $0.host, port: $0.port, kind: $0.kind) }, ssh: ssh, grants: nil)
    }

    static func health(hostID: String = RoadFixture.hostID) -> HostHealth {
        HostHealth(hostID: hostID, hostName: "omarchy-fixture", fingerprint: fingerprint)
    }
}

/// A host that hands out one snapshot and one event stream per connection,
/// and lets the test end the stream the way a dead socket ends it.
private actor RoadFixtureService: CompanionServing, HostRoadsReading {
    private(set) var snapshots = 0
    /// `GET /v1/host/roads`; nil is a core without the route.
    private var roadsDocument: HostRoadsDTO?
    func setRoads(_ value: HostRoadsDTO?) { roadsDocument = value }
    func fetchHostRoads() async -> HostRoadsDTO? { roadsDocument }
    private var continuation: AsyncThrowingStream<SanitizedHostEvent, Error>.Continuation?
    func connect() async throws {}
    func disconnect() async { continuation?.finish(); continuation = nil }
    func fetchState() async throws -> HostStateDTO { try Self.state() }
    static func state() throws -> HostStateDTO {
        try JSONDecoder().decode(HostStateDTO.self, from: Data(#"{"revision":1,"event_cursor":1,"instance_id":"road","host":{"name":"omarchy-fixture","connected":true}}"#.utf8))
    }
    func fetchSnapshot() async throws -> CompanionSnapshot {
        snapshots += 1
        let decoder = JSONDecoder()
        return try CompanionSnapshot(state: Self.state(),
            capabilities: decoder.decode(HostCapabilitiesDTO.self, from: Data(#"{"terminal":true,"desktop":false}"#.utf8)),
            catalog: decoder.decode(HostCatalogDTO.self, from: Data(#"{"revision":"road","entries":[]}"#.utf8)),
            herdr: decoder.decode(HostHerdrDTO.self, from: Data(#"{"available":false}"#.utf8)))
    }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter], targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse { throw CompanionHostError.notConnected }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse { throw CompanionHostError.notConnected }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        AsyncThrowingStream { continuation = $0 }
    }
    var isListening: Bool { continuation != nil }
    /// What `CompanionHostClient` throws when the liveness check cancels a
    /// socket nobody answers on.
    func dieSilently() {
        continuation?.finish(throwing: CompanionHostError.transport(message: Strings.hostErrorEventStreamSilent))
        continuation = nil
    }
}

private final class DialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CompanionHostConfiguration] = []
    func add(_ value: CompanionHostConfiguration) { lock.withLock { values.append(value) } }
    var all: [CompanionHostConfiguration] { lock.withLock { values } }
}

@MainActor final class TailnetRoadTests: XCTestCase {
    // MARK: - Kinds and the dial order

    func testKindsAreReadOffAnAddressThatCameWithoutOne() {
        XCTAssertEqual(HostRoads.kind(of: "192.168.1.10"), .lan)
        XCTAssertEqual(HostRoads.kind(of: "omarchy.local"), .mdns)
        XCTAssertEqual(HostRoads.kind(of: "omarchy.tail0000.ts.net"), .tailnet)
        XCTAssertEqual(HostRoads.kind(of: "100.64.12.11"), .tailnet)
        XCTAssertEqual(HostRoads.kind(of: "100.128.0.1"), .lan, "outside 100.64/10")
        XCTAssertEqual(HostRoads.kind(of: "fd7a:115c:a1e0::35"), .tailnet)
        XCTAssertTrue(HostRoads.isTailnetAddress("100.64.0.1"))
        XCTAssertFalse(HostRoads.isTailnetAddress("100.63.255.255"))
        XCTAssertFalse(HostRoads.isMagicDNSName("ts.net"))
        XCTAssertFalse(HostRoad(host: "100.64.12.11", port: 8099).isDialable, "ATS refuses an address literal")
        XCTAssertTrue(HostRoad(host: RoadFixture.name, port: 8099).isDialable)
    }

    // MARK: - TAIL-3b one road per host

    func testATailscaleHostIsDialledByItsNameAndNothingElse() {
        let roads = [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan),
                     HostRoad(host: "omarchy-fixture.local", port: 8099, kind: .mdns),
                     HostRoad(host: RoadFixture.name, port: 8099, kind: .tailnet)]
        let road = HostRoad(host: RoadFixture.name, port: 8099)
        for attempt in 0..<6 {
            XCTAssertEqual(HostRoads.dialURL(road: road, roads: roads, attempt: attempt)?.host, RoadFixture.name,
                           "attempt \(attempt): a Tailscale host never dials a LAN address (no Local Network prompt)")
        }
    }

    func testAWiFiHostIsDialledAtItsAddressAndItsLocalNameOnly() {
        let roads = [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan),
                     HostRoad(host: "omarchy-fixture.local", port: 8099, kind: .mdns),
                     HostRoad(host: RoadFixture.name, port: 8099, kind: .tailnet)]
        let road = HostRoad(host: "192.168.1.10", port: 8099)
        let hosts = (0..<4).compactMap { HostRoads.dialURL(road: road, roads: roads, attempt: $0)?.host }
        XCTAssertEqual(hosts, ["192.168.1.10", "omarchy-fixture.local", "192.168.1.10", "omarchy-fixture.local"])
        XCTAssertFalse(hosts.contains(RoadFixture.name), "the app never moves a Wi-Fi host to Tailscale by itself")
        XCTAssertEqual(HostRoads.dialURL(road: road, roads: [road], attempt: 1)?.host, "192.168.1.10")
    }

    func testAPinFromBeforeTheOneRoadModelIsOnTheRoadItsAccountNames() throws {
        let old = RoadFixture.pin(roads: [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan),
                                          HostRoad(host: RoadFixture.name, port: 8099, kind: .tailnet)])
        XCTAssertNil(old.road)
        XCTAssertEqual(old.road(account: RoadFixture.lan), HostRoad(host: "192.168.1.10", port: 8099, kind: .lan))
        XCTAssertEqual(old.road(account: "https://\(RoadFixture.name):8099").kind, .tailnet)
        // Decoding a TAIL-2 pin (no `road` key) still works, and keeps no road.
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"road\""))
        XCTAssertEqual(try JSONDecoder().decode(HostPin.self, from: data), old)
        XCTAssertEqual(HostRoadWords.word(HostRoad(host: RoadFixture.name, port: 8099)), Strings.roadTailscale)
        XCTAssertEqual(HostRoadWords.word(HostRoad(host: "omarchy.local", port: 8099)), Strings.roadLAN)
    }

    func testTheHostRoadsRouteCarriesEveryRoadAndTheTailnetName() throws {
        let roads = try JSONDecoder().decode(HostRoadsDTO.self, from: RoadFixture.coreFixture("host-roads"))
        XCTAssertEqual(roads.host_id, RoadFixture.hostID)
        XCTAssertEqual(roads.tailnetName, RoadFixture.name)
        XCTAssertEqual(roads.roads.map(\.kind), [.lan, .mdns, .tailnet, .tailnet, .tailnet])
        XCTAssertEqual(roads.roads.filter { $0.host == RoadFixture.name }.count, 1, "the name is not added twice")
    }

    func testHealthIsAnAnchorOnly() async throws {
        let json = String(decoding: try RoadFixture.coreFixture("health"), as: UTF8.self)
        let health = try await HealthFixture.read(json)
        XCTAssertEqual(health.hostID, RoadFixture.hostID)
        XCTAssertEqual(health.fingerprint, RoadFixture.fingerprint)
    }

    private func home(roads: [HostRoad], road: HostRoad? = nil,
                      service: RoadFixtureService, log: DialLog, defaults: UserDefaults) throws -> (HomeStore, HostPinStore) {
        var profile = HostProfile(); profile.mock = false; profile.companionURL = RoadFixture.lan
        defaults.set(try JSONEncoder().encode(profile), forKey: "omodachi.profile.v1")
        let pins = HostPinStore(service: "tail2.pins", records: RoadMemoryKeychain())
        var pin = RoadFixture.pin(roads: roads)
        pin.road = road
        try pins.save(pin, account: RoadFixture.lan)
        let home = HomeStore(defaults: defaults, pinStore: pins,
                             clientFactory: { configuration, _ in log.add(configuration); return service },
                             autoConnect: false)
        return (home, pins)
    }

    func testAWiFiHostAwayFromHomeIsNeverDialledOverTailscale() async throws {
        let name = "tail3b-away-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = RoadFixtureService(), log = DialLog()
        let roads = [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan),
                     HostRoad(host: RoadFixture.name, port: 8099, kind: .tailnet)]
        let (home, _) = try home(roads: roads, service: service, log: log, defaults: defaults)
        await home.connectCompanion()
        XCTAssertEqual(log.all.map(\.endpoint.host), ["192.168.1.10"])
        XCTAssertEqual(home.hostRoad?.kind, .lan)
        XCTAssertEqual(home.roadWord, Strings.roadLAN)
        XCTAssertNil(defaults.object(forKey: "omodachi.lastGoodRoad.v1"), "TAIL-2's road memory is gone")
        await home.disconnectCompanion()
    }

    func testAHostMovedToTailscaleIsDialledByItsNameWithTheSameAccount() async throws {
        let name = "tail3b-moved-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = RoadFixtureService(), log = DialLog()
        let roads = [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan),
                     HostRoad(host: RoadFixture.name, port: 8099, kind: .tailnet)]
        let (home, _) = try home(roads: roads, road: HostRoad(host: RoadFixture.name, port: 8099),
                                 service: service, log: log, defaults: defaults)
        await home.connectCompanion()
        XCTAssertEqual(home.connectionState, .connected)
        let dialled = try XCTUnwrap(log.all.last)
        XCTAssertEqual(dialled.endpoint.host, RoadFixture.name)
        XCTAssertEqual(dialled.account, RoadFixture.lan, "the credential and the pin never move")
        XCTAssertEqual(log.all.count, 1, "one road, one dial: nothing else is probed")
        XCTAssertEqual(home.roadWord, Strings.roadTailscale)
        XCTAssertEqual(home.roadValue, Strings.roadA11yTailscale(RoadFixture.name))
        await home.disconnectCompanion()
        XCTAssertEqual(home.roadWord, Strings.roadTailscale, "the road is what the host is set to, connected or not")
    }

    /// I3: the event stream — core's "the App is in front" — closes when the
    /// App leaves the front, and opens again when it comes back.
    func testTheEventStreamClosesWhenTheAppLeavesTheFront() async throws {
        let name = "tail3b-front-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = RoadFixtureService(), log = DialLog()
        let (home, _) = try home(roads: [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan)],
                                 service: service, log: log, defaults: defaults)
        await home.connectCompanion()
        for _ in 0..<200 where !(await service.isListening) { await Task.yield() }
        let listeningInFront = await service.isListening
        XCTAssertTrue(listeningInFront)
        await home.setForeground(false)
        let listeningBehind = await service.isListening
        XCTAssertFalse(listeningBehind, "closed before setForeground returns, not left to time out")
        XCTAssertEqual(home.connectionState, .suspended)
        await home.setForeground(true)
        for _ in 0..<200 where !(await service.isListening) { await Task.yield() }
        let listeningAgain = await service.isListening
        XCTAssertTrue(listeningAgain)
        await home.disconnectCompanion()
    }

    func testAConnectionLearnsTheTailnetNameFromTheAuthenticatedRoadsAtHome() async throws {
        let name = "tail2-learn-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = RoadFixtureService(), log = DialLog()
        await service.setRoads(try JSONDecoder().decode(HostRoadsDTO.self, from: RoadFixture.coreFixture("host-roads")))
        let (home, pins) = try home(roads: [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan)],
                                    service: service, log: log, defaults: defaults)
        await home.connectCompanion()
        XCTAssertEqual(home.road?.kind, .lan)
        XCTAssertEqual(home.roadWord, Strings.roadLAN)
        for _ in 0..<200 where pins.load(account: RoadFixture.lan)?.tailnetName == nil { await Task.yield() }
        XCTAssertEqual(pins.load(account: RoadFixture.lan)?.tailnetName, RoadFixture.name,
                       "learnt for \"Use Tailscale for this computer\"")
        XCTAssertEqual(pins.load(account: RoadFixture.lan)?.road(account: RoadFixture.lan).kind, .lan,
                       "learning the name never moves the road")
        await home.disconnectCompanion()
    }

    func testAnOldCoreWithoutTheRoadsRouteChangesNothing() async throws {
        let name = "tail2-oldcore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = RoadFixtureService(), log = DialLog()
        let (home, pins) = try home(roads: [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan)],
                                    service: service, log: log, defaults: defaults)
        await home.connectCompanion()
        XCTAssertEqual(home.connectionState, .connected)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(pins.load(account: RoadFixture.lan)?.roads, [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan)])
        await home.disconnectCompanion()
    }

    func testRoadsFromAnotherInstallationAreIgnored() async throws {
        let name = "tail2-other-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = RoadFixtureService(), log = DialLog()
        let json = String(decoding: try RoadFixture.coreFixture("host-roads"), as: UTF8.self)
            .replacingOccurrences(of: RoadFixture.hostID, with: String(repeating: "f", count: 32))
        await service.setRoads(try JSONDecoder().decode(HostRoadsDTO.self, from: Data(json.utf8)))
        let (home, pins) = try home(roads: [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan)],
                                    service: service, log: log, defaults: defaults)
        await home.connectCompanion()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(pins.load(account: RoadFixture.lan)?.tailnetName)
        await home.disconnectCompanion()
    }

    /// LITE-1d: the connection reads what core says about Odomo; reading the
    /// roads again after the Safari view closes is what takes the card away
    /// once a phone gets Odomo's pushes; "Not now" is for this computer only.
    func testOdomoStateFollowsTheRoadsAndNotNowIsPerComputer() async throws {
        let name = "lite1d-odomo-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = RoadFixtureService(), log = DialLog()
        await service.setRoads(try JSONDecoder().decode(HostRoadsDTO.self, from: RoadFixture.coreFixture("host-roads-odomo-none")))
        let (home, _) = try home(roads: [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan)],
                                 service: service, log: log, defaults: defaults)
        XCTAssertEqual(home.odomoState, .unknown, "nothing is said before the roads are read")
        await home.connectCompanion()
        for _ in 0..<200 where home.odomo == nil { await Task.yield() }
        XCTAssertEqual(home.odomoState, .noAddress, "no Tailscale on the computer: explained, not hidden")
        await service.setRoads(try JSONDecoder().decode(HostRoadsDTO.self, from: RoadFixture.coreFixture("host-roads-odomo")))
        await home.refreshOdomo()
        let url = try XCTUnwrap(URL(string: "https://omarchy-fixture.tail0000.ts.net/odomo/"))
        XCTAssertEqual(home.odomoState, .on(devices: 1, url: url))
        XCTAssertFalse(OdomoOffer.showsCard(home.odomoState, dismissed: false), "a phone has it: the card goes")

        let memory = OdomoOfferMemory(defaults: defaults)
        XCTAssertEqual(home.odomoHostKey, RoadFixture.hostID, "remembered under the computer, not its address")
        XCTAssertFalse(home.odomoOfferDismissed(memory: memory))
        home.dismissOdomoOffer(memory: memory)
        XCTAssertTrue(home.odomoOfferDismissed(memory: memory))
        XCTAssertFalse(memory.isDismissed("another-computer"))

        // Another computer's Odomo is not this one's.
        var profile = home.profile
        profile.companionURL = "https://192.168.1.26:8099"
        home.profile = profile
        XCTAssertNil(home.odomo)
        XCTAssertEqual(home.odomoState, .unknown)
        await home.disconnectCompanion()
    }

    // MARK: - P0-1 events liveness

    func testADeadEventSocketLeavesConnectedAndReconnects() async throws {
        let name = "tail2-liveness-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = RoadFixtureService(), log = DialLog()
        let (home, _) = try home(roads: [], service: service, log: log, defaults: defaults)
        await home.connectCompanion()
        for _ in 0..<200 where !(await service.isListening) { await Task.yield() }
        XCTAssertEqual(home.connectionState, .connected)
        await service.dieSilently()
        for _ in 0..<200 where home.connectionState == .connected { await Task.yield() }
        XCTAssertNotEqual(home.connectionState, .connected, "the bar must stop saying Connected")
        XCTAssertFalse(home.companionConnected)
        // The existing backoff (1 s for the first retry) brings it back, and
        // the reconnect reads a fresh snapshot (and the notification history).
        let deadline = Date().addingTimeInterval(5)
        while await service.snapshots < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let snapshots = await service.snapshots
        XCTAssertEqual(snapshots, 2)
        for _ in 0..<200 where home.connectionState != .connected { await Task.yield() }
        XCTAssertEqual(home.connectionState, .connected)
        await home.disconnectCompanion()
    }

    func testAMissingPongDeclaresTheSocketDead() async {
        let liveness = EventLiveness(timing: .init(pingInterval: .milliseconds(20), pongDeadline: .milliseconds(20),
                                                   silence: .seconds(5)))
        let dead = await liveness.watch(ping: { false })
        XCTAssertTrue(dead)
        let declared = await liveness.declaredDead
        XCTAssertTrue(declared)
    }

    func testAnsweredPingsKeepTheSocketAliveUntilCancelled() async throws {
        let liveness = EventLiveness(timing: .init(pingInterval: .milliseconds(10), pongDeadline: .milliseconds(20),
                                                   silence: .seconds(5)))
        let counter = PingCounter()
        let watch = Task { await liveness.watch(ping: { counter.tick(); return true }) }
        try await Task.sleep(for: .milliseconds(150))
        watch.cancel()
        let dead = await watch.value
        XCTAssertFalse(dead)
        XCTAssertGreaterThan(counter.count, 3)
    }

    func testSilenceAloneDeclaresTheSocketDead() async {
        // Pongs that come back but nothing else for longer than `silence` is
        // impossible by construction (a pong is activity), so silence here is
        // a ping that never even returned before the window closed.
        let liveness = EventLiveness(timing: .init(pingInterval: .milliseconds(10), pongDeadline: .milliseconds(10),
                                                   silence: .milliseconds(1)))
        let dead = await liveness.watch(ping: { try? await Task.sleep(for: .milliseconds(30)); return false })
        XCTAssertTrue(dead)
    }

    // MARK: - P0-0 a typed 100.x

    private func settle(_ flow: ConnectionFlowModel) async {
        let deadline = Date().addingTimeInterval(5)
        while flow.failure == nil, flow.candidate?.url.host.map(HostRoads.isMagicDNSName) != true
                || flow.probing, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func manualFlow(resolver: any TailnetNameResolving, pins: HostPinStore = HostPinStore(service: "tail2.manual", records: RoadMemoryKeychain()),
                            directory: PairedHostDirectory? = nil, defaults: UserDefaults? = nil) -> ConnectionFlowModel {
        ConnectionFlowModel(deviceID: "ios-fixture", deviceName: "Fixture iPad", pins: pins,
                            credentials: CompanionCredentialStore(service: "tail2.manual.\(UUID().uuidString)"),
                            directory: directory, probe: ManualHealth.probe(), keyOffer: nil,
                            nameResolver: resolver,
                            makeClient: { _ in throw PairingError.unreachable })
    }

    func testATypedTailnetAddressWithNoNameSaysToUseTheMagicDNSName() async throws {
        let flow = manualFlow(resolver: FixedResolver(answer: nil))
        flow.select(try XCTUnwrap(HostCandidate.manual("100.64.12.11")), sshPublicKey: nil)
        await settle(flow)
        XCTAssertEqual(flow.failure, .message(Strings.errNoPtrBody))
        XCTAssertEqual(flow.stage, .pairing)
        XCTAssertEqual(flow.candidate?.url.host, "100.64.12.11")
        flow.cancel()
    }

    func testATypedTailnetAddressWhoseReverseNameIsNotTailscaleSaysTheSame() async throws {
        let flow = manualFlow(resolver: FixedResolver(answer: "printer.example.com."))
        flow.select(try XCTUnwrap(HostCandidate.manual("100.64.12.11")), sshPublicKey: nil)
        await settle(flow)
        XCTAssertEqual(flow.failure, .message(Strings.errNoPtrBody))
        flow.cancel()
    }

    func testATypedTailnetAddressIsDialledByItsReverseMagicDNSName() async throws {
        let flow = manualFlow(resolver: FixedResolver(answer: "Omodachi-Lab.tail0000.ts.net."))
        flow.select(try XCTUnwrap(HostCandidate.manual("100.65.151.60")), sshPublicKey: nil)
        await settle(flow)
        XCTAssertEqual(flow.candidate?.url.host, ManualHealth.full)
        XCTAssertEqual(flow.candidate?.account, "https://\(ManualHealth.full):8099")
        XCTAssertNotEqual(flow.failure, .message(Strings.errNoPtrBody))
        flow.cancel()
    }

    func testATypedTailnetAddressOfAKnownHostUsesItsName() async throws {
        let name = "tail2-known-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = PairedHostDirectory(defaults: defaults)
        directory.remember(PairedHostRecord(account: RoadFixture.lan, hostID: RoadFixture.hostID,
                                            hostName: "omarchy-fixture", address: "192.168.1.10:8099"))
        let pins = HostPinStore(service: "tail2.known", records: RoadMemoryKeychain())
        try pins.save(RoadFixture.pin(roads: [HostRoad(host: "192.168.1.10", port: 8099, kind: .lan),
                                              HostRoad(host: RoadFixture.name, port: 8099, kind: .tailnet),
                                              HostRoad(host: "100.64.0.35", port: 8099, kind: .tailnet)]),
                      account: RoadFixture.lan)
        let resolver = FixedResolver(answer: nil)
        let flow = manualFlow(resolver: resolver, pins: pins, directory: directory, defaults: defaults)
        flow.select(try XCTUnwrap(HostCandidate.manual("100.64.0.35")), sshPublicKey: nil)
        await settle(flow)
        XCTAssertEqual(flow.candidate?.url.host, RoadFixture.name)
        XCTAssertFalse(resolver.asked, "a paired host's own name needs no lookup")
        flow.cancel()
    }

    func testABareNameOnTheWiFiRoadStaysALanName() async throws {
        let resolver = FixedResolver(answer: "omodachi-lab.tail0000.ts.net.", forward: ["100.65.151.60"])
        let flow = manualFlow(resolver: resolver)
        flow.stage = .manual
        flow.select(try XCTUnwrap(HostCandidate.manual("omarchy")), sshPublicKey: nil, from: .manual)
        let deadline = Date().addingTimeInterval(5)
        while flow.failure == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(flow.candidate?.url.host, "omarchy")
        XCTAssertFalse(resolver.asked, "the Wi-Fi road never turns a name into a Tailscale one")
        flow.cancel()
    }

    // MARK: - TAIL-3b the Tailscale page

    private func resolve(_ typed: String, _ resolver: FixedResolver) async -> TailscaleResolution {
        await TailscaleName.resolve(typed, resolver: resolver)
    }

    func testEverythingThePageAcceptsBecomesAMagicDNSName() async {
        let full = URL(string: "https://\(ManualHealth.full):8099")!
        let none = FixedResolver(answer: nil)
        let alias = FixedResolver(answer: "Omodachi-Lab.tail0000.ts.net.", forward: ["192.168.1.27", "100.65.151.60"])
        let ptr = FixedResolver(answer: "omodachi-lab.tail0000.ts.net.")
        let result1 = await resolve("Omodachi-Lab.tail0000.ts.net", none)
        XCTAssertEqual(result1, .resolved(full))
        XCTAssertFalse(none.asked, "a full name needs no lookup")
        let result2 = await resolve("omodachi-lab", alias)
        XCTAssertEqual(result2, .resolved(full))
        let result3 = await resolve(" 100.65.151.60 ", ptr)
        XCTAssertEqual(result3, .resolved(full))
        let result4 = await resolve("https://omodachi-lab.tail0000.ts.net:9443/", none)
        XCTAssertEqual(result4, .resolved(URL(string: "https://omodachi-lab.tail0000.ts.net:9443")!))
        let known = await TailscaleName.resolve("100.64.0.35", resolver: none, known: ["100.64.0.35": RoadFixture.name])
        XCTAssertEqual(known, .resolved(URL(string: "https://\(RoadFixture.name):8099")!))
    }

    func testWhatIsNotATailscaleNameIsRefusedOnThePage() async {
        let lan = FixedResolver(answer: nil, forward: ["192.168.1.10"])
        let result1 = await resolve("omarchy", lan)
        XCTAssertEqual(result1, .notTailscale("omarchy"), "E04b: TAIL-2 kept this as a LAN name")
        XCTAssertFalse(lan.asked)
        let result2 = await resolve("192.168.1.10", lan)
        XCTAssertEqual(result2, .notTailscale("192.168.1.10"))
        let result3 = await resolve("omarchy.local", lan)
        XCTAssertEqual(result3, .notTailscale("omarchy.local"))
        let result4 = await resolve("omarchy", FixedResolver(answer: nil, forward: []))
        XCTAssertEqual(result4, .noName("omarchy"), "E04: nothing answers to it")
        let result5 = await resolve("omarchy", FixedResolver(answer: "omodachi-lab.tail0000.ts.net.", forward: ["100.65.151.60"]))
        XCTAssertEqual(result5, .noName("omarchy"), "its tailnet address is another machine")
        let result6 = await resolve("100.64.12.11", FixedResolver(answer: "printer.example.com."))
        XCTAssertEqual(result6, .noPtr("100.64.12.11"), "E05")
        let result7 = await resolve("   ", lan)
        XCTAssertEqual(result7, .empty)
    }

    func testAPageNameThatDoesNotAnswerIsSaidOnThePage() {
        XCTAssertEqual(HostHealthError.reach(URLError(.cannotFindHost)), .noSuchName)
        XCTAssertEqual(HostHealthError.reach(URLError(.dnsLookupFailed)), .noSuchName)
        XCTAssertEqual(HostHealthError.reach(URLError(.cannotConnectToHost)), .refused)
        XCTAssertEqual(HostHealthError.reach(URLError(.timedOut)), .unreachable)
        XCTAssertEqual(ConnectionFlowModel.problem(HostHealthError.noSuchName, name: "omarchy"), .noName("omarchy"))
        XCTAssertEqual(ConnectionFlowModel.problem(HostHealthError.refused, name: "omarchy"), .noHost("omarchy"))
        XCTAssertEqual(ConnectionFlowModel.problem(HostHealthError.notAnOmodachiHost, name: "omarchy"), .noHost("omarchy"))
        XCTAssertEqual(ConnectionFlowModel.problem(HostHealthError.unreachable, name: "omarchy"), .asleep("omarchy"))
    }

    func testConnectOnThePageWithALanAddressNeverDialsIt() async throws {
        let flow = manualFlow(resolver: FixedResolver(answer: nil, forward: []))
        XCTAssertEqual(flow.stage, .tailscale, "the first screen is the Tailscale page")
        flow.tailscaleInput = "192.168.1.10"
        flow.connectTailscale(sshPublicKey: nil)
        let deadline = Date().addingTimeInterval(5)
        while flow.tailscaleProblem == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(flow.tailscaleProblem, .notTailscale("192.168.1.10"))
        XCTAssertEqual(flow.stage, .tailscale)
        XCTAssertNil(flow.candidate, "nothing was selected, so nothing was dialled")
    }

    func testConnectOnThePageWithANameGoesToTheCardOverThatName() async throws {
        let flow = manualFlow(resolver: FixedResolver(answer: nil))
        flow.tailscaleInput = ManualHealth.full
        flow.connectTailscale(sshPublicKey: nil)
        let deadline = Date().addingTimeInterval(5)
        while flow.stage != .pairing || flow.probing, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(flow.stage, .pairing)
        XCTAssertEqual(flow.candidate?.url.host, ManualHealth.full)
        XCTAssertEqual(flow.candidate?.name, "omodachi-lab")
        XCTAssertEqual(flow.fingerprint, RoadFixture.fingerprint)
        flow.cancel()
    }

    func testOnlyANameWithNoDotThatIsNotAnAddressIsShort() {
        XCTAssertTrue(ConnectionFlowModel.isShortName("omodachi-lab"))
        XCTAssertFalse(ConnectionFlowModel.isShortName("omodachi-lab.local"))
        XCTAssertFalse(ConnectionFlowModel.isShortName("100.64.0.1"))
        XCTAssertFalse(ConnectionFlowModel.isShortName("fd7a:115c:a1e0::1"))
        XCTAssertEqual(ConnectionFlowModel.firstLabel("Omodachi-Lab.tail0000.ts.net"), "omodachi-lab")
    }

    // MARK: - P0-2 refusals and the claim

    func testARefusalThatNeverReachedTheHostIsNotASecurityFailure() {
        XCTAssertEqual(PairingClient.classify(URLError(.timedOut)), .unreachable)
        XCTAssertEqual(PairingClient.classify(URLError(.cannotFindHost)), .unreachable)
        XCTAssertEqual(PairingClient.classify(URLError(.serverCertificateUntrusted)), .transport)
        XCTAssertEqual(PairingClient.classify(URLError(.secureConnectionFailed)), .transport)
        XCTAssertNotEqual(PairingError.unreachable.localizedDescription, PairingError.transport.localizedDescription)
        XCTAssertNotEqual(PairingError.busy.localizedDescription, PairingError.unavailable.localizedDescription)
    }

    func testTheSSHTargetFromTheHostCarriesTypedHostsAndTheTailscaleFlag() throws {
        struct Envelope: Decodable { let target: SSHTargetDTO? }
        let target = try XCTUnwrap(JSONDecoder().decode(Envelope.self, from: RoadFixture.coreFixture("ssh-key-state")).target)
        let endpoint = try XCTUnwrap(target.endpoint(keeping: nil))
        XCTAssertEqual(endpoint.host, "192.168.1.10")
        XCTAssertEqual(endpoint.tailscaleSSH, false)
        XCTAssertEqual(endpoint.hosts?.map(\.host), ["192.168.1.10", "omarchy-fixture.local", RoadFixture.name, "100.64.0.35"],
                       "an IPv6 literal cannot be an SSH host here and is dropped")
        // A host from before TAIL-2 publishes no target at all.
        let old = try JSONDecoder().decode(Envelope.self, from: Data(#"{"device_id":"x","authorized":true,"fingerprint":null,"fingerprints":[]}"#.utf8))
        XCTAssertNil(old.target)
    }

    // MARK: - P0-4 the terminal follows the road

    func testTheTerminalTakesTheSameRoadAsTheCompanion() {
        var profile = HostProfile(); profile.mock = false; profile.companionURL = RoadFixture.lan
        let ssh = HostPin.SSHEndpoint(user: "fixture-user", host: "192.168.1.10", port: 22,
                                      hosts: [HostRoad(host: "192.168.1.10", port: 22, kind: .lan),
                                              HostRoad(host: RoadFixture.name, port: 22, kind: .tailnet)])
        let pin = RoadFixture.pin(roads: [], ssh: ssh)
        let home = SSHTargetResolver.resolve(profile: profile, pin: pin, road: HostRoad(host: "192.168.1.10", port: 8099))
        XCTAssertEqual(home?.host, "192.168.1.10")
        let away = SSHTargetResolver.resolve(profile: profile, pin: pin, road: HostRoad(host: RoadFixture.name, port: 8099))
        XCTAssertEqual(away?.host, RoadFixture.name)
        XCTAssertEqual(away?.username, "fixture-user")
        // A pin from a core before TAIL-2: no typed hosts, so the companion's
        // own tailnet address is the terminal's too (the TAIL-1 prototype).
        let old = RoadFixture.pin(roads: [], ssh: .init(user: "fixture-user", host: "192.168.1.10", port: 22))
        XCTAssertEqual(SSHTargetResolver.resolve(profile: profile, pin: old,
                                                 road: HostRoad(host: RoadFixture.name, port: 8099))?.host, RoadFixture.name)
        XCTAssertEqual(SSHTargetResolver.resolve(profile: profile, pin: old, road: nil)?.host, "192.168.1.10")
        // TAIL-3b: a Wi-Fi host's terminal is the claim's address, whichever
        // spelling of the Wi-Fi road the companion is on; a tailnet address
        // literal is never the terminal.
        XCTAssertEqual(SSHTargetResolver.resolve(profile: profile, pin: pin,
                                                 road: HostRoad(host: "omarchy-fixture.local", port: 8099))?.host, "192.168.1.10")
        XCTAssertEqual(SSHTargetResolver.resolve(profile: profile, pin: old,
                                                 road: HostRoad(host: "100.64.0.35", port: 8099))?.host, "192.168.1.10")
    }

    func testARestoredSessionDialsWhereTheHostIsNow() async {
        var stale = HostProfile(); stale.mock = false; stale.hostname = "192.168.1.10"; stale.username = "u"
        let descriptor = SessionDescriptor(title: "Shell", kind: .shell, host: stale, argv: [])
        let dialled = DialledHosts()
        let runtime = TerminalRuntime(descriptor: descriptor, restored: true, factory: { dial in
            dialled.add(dial.host.hostname)
            return MockPTYTransport(kind: dial.kind)
        }, resolver: { host in var value = host; value.hostname = RoadFixture.name; return value })
        runtime.connect(explicit: true, asked: true)
        XCTAssertEqual(dialled.all, [RoadFixture.name])
        XCTAssertEqual(runtime.descriptor.host.hostname, "192.168.1.10", "the stored descriptor is not rewritten")
        await runtime.disconnect()
        var moved = descriptor; moved.id = UUID(); moved.host.hostname = RoadFixture.name
        XCTAssertTrue(descriptor.sameSessionOnAnotherRoad(moved))
    }

    func testAPairedHostKeyIsOnePinWhicheverRoadReachedIt() async throws {
        let keys = HostKeyStore(service: "tail2.hostkeys", records: RoadMemoryKeychain())
        let trust = HostTrustCoordinator(pins: keys, paired: { [] }, pairedHost: { host, _ in
            ["192.168.1.10", RoadFixture.name].contains(host) ? RoadFixture.hostID : nil
        })
        func challenge(_ host: String, key: String = "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f") -> SSHHostKeyChallenge {
            SSHHostKeyChallenge(host: host, port: 22, algorithm: "ssh-ed25519",
                                openSSHPublicKey: "ssh-ed25519 \(key)", fingerprintSHA256: "SHA256:fixture")
        }
        try await trust.validate(challenge("192.168.1.10"))
        XCTAssertNil(trust.request)
        try await trust.validate(challenge(RoadFixture.name))
        XCTAssertNil(trust.request, "a road change is not a new trust-on-first-use")
        XCTAssertNotNil(try keys.pinnedFingerprint(host: "host-\(RoadFixture.hostID):22"))
        do {
            try await trust.validate(challenge(RoadFixture.name, key: "AAAAC3NzaC1lZDI1NTE5AAAAIB8eHRwbGhkYFxYVFBMSERAPDg0MCwoJCAcGBQQDAgEA"))
            XCTFail("a changed key must still fail")
        } catch { XCTAssertEqual(error as? TerminalFailure, .hostKeyChanged) }
    }

    // MARK: - P2-2 Remote over the tailnet

    func testTheRemoteEntryReReadsTheRoadEachTimeAndNeverUnderASession() async throws {
        let host = FakeRemoteHost()
        let controller = RemoteSessionController(service: host, driver: FakeBackend())
        await controller.refreshEntryCapabilities()
        XCTAssertEqual(controller.capabilities?.relayedTailnet, false)
        // The path dropped to DERP under the same connection.
        await host.setRelayed(true)
        await controller.refreshEntryCapabilities()
        XCTAssertEqual(controller.capabilities?.relayedTailnet, true)
        XCTAssertEqual(controller.capabilities?.resolvedDefault, .vnc)
    }

    func testARelayedTailnetPathDefaultsToVNC() throws {
        let capabilities = try JSONDecoder().decode(RemoteCapabilitiesDTO.self,
                                                    from: RoadFixture.coreFixture("remote-capabilities-relayed"))
        XCTAssertTrue(capabilities.relayedTailnet)
        XCTAssertEqual(RemoteBackendChoice.auto.resolve(capabilities), capabilities.available(.vnc) ? .vnc : capabilities.resolvedDefault)
        XCTAssertEqual(ReasonText.message("tailnet_relayed", domain: .remote), Strings.remoteTailnetRelayed)
        let plain = try JSONDecoder().decode(RemoteCapabilitiesDTO.self, from: RoadFixture.coreFixture("remote-capabilities"))
        XCTAssertFalse(plain.relayedTailnet)
    }
}

private final class PingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func tick() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class DialledHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private final class FixedResolver: TailnetNameResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: String?
    private let forward: [String]
    private var wasAsked = false
    init(answer: String?, forward: [String] = []) { self.answer = answer; self.forward = forward }
    func forwardAddresses(of name: String) async -> [String] { forward }
    func reverseName(of address: String) async -> String? {
        lock.withLock { wasAsked = true }
        return answer
    }
    var asked: Bool { lock.withLock { wasAsked } }
}

/// `/health` for the names these tests type, served locally: an anchor only,
/// host_id and fingerprint.
private enum ManualHealth {
    static let full = "omodachi-lab.tail0000.ts.net"
    final class Stub: URLProtocol, @unchecked Sendable {
        static let hosts: Set<String> = ["omodachi-lab", "omarchy", "omodachi-lab.tail0000.ts.net", RoadFixture.name]
        override class func canInit(with request: URLRequest) -> Bool { hosts.contains(request.url?.host?.lowercased() ?? "") }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let body = #"{"service":"omodachid","host_id":"\#(RoadFixture.hostID)","tls_fingerprint_sha256":"\#(RoadFixture.fingerprint)"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    static func probe() -> HostHealthProbe {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [Stub.self]
        return HostHealthProbe(session: URLSession(configuration: options))
    }
}

/// REMOTE-FIX-2: one host for Moonlight's requests and its stream, and a
/// tailnet literal never dialled while a name is known.
@MainActor final class SunshineRouteTests: XCTestCase {
    private let magic = "omarchy.tail0000.ts.net"

    func testATailnetRoadDialsTheMagicDNSNameCoreNamed() {
        // A core with REMOTE-FIX-2 names the MagicDNS host on the tailnet.
        XCTAssertEqual(SunshineRoute.dialHost(sessionHost: magic, road: magic), magic)
        XCTAssertNil(SunshineRoute.note(dial: magic))
    }

    func testACoreThatNamedTheLiteralIsDialledByTheRoadsName() {
        // 91c4054 and earlier: `connection.host` is the 100.x the request
        // arrived on. ATS refuses the fork's certificate there (-1200).
        XCTAssertEqual(SunshineRoute.dialHost(sessionHost: "100.119.57.11", road: magic), magic)
        XCTAssertEqual(SunshineRoute.dialHost(sessionHost: "fd7a:115c:a1e0::5a2b:390c", road: magic), magic)
    }

    func testTheLANRoadKeepsItsAddress() {
        XCTAssertEqual(SunshineRoute.dialHost(sessionHost: "192.168.1.10", road: "192.168.1.10"), "192.168.1.10")
        XCTAssertEqual(SunshineRoute.dialHost(sessionHost: "192.168.1.10", road: "omarchy.local"), "192.168.1.10")
        XCTAssertEqual(SunshineRoute.dialHost(sessionHost: "192.168.1.10", road: magic), "192.168.1.10")
        XCTAssertNil(SunshineRoute.note(dial: "192.168.1.10"))
    }

    func testWithoutANameTheLiteralGoesOutAndTheDiagnosticsSayWhy() {
        for road in [nil, "", "100.119.57.11", "[fd7a:115c:a1e0::1]"] as [String?] {
            XCTAssertEqual(SunshineRoute.dialHost(sessionHost: "100.119.57.11", road: road), "100.119.57.11")
        }
        let note = SunshineRoute.note(dial: "100.119.57.11")
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("MagicDNS") == true)
        XCTAssertTrue(note?.contains("-1200") == true)
    }

    func testTheDriverDialsOneHostAndFollowsTheRoad() {
        let driver = SunshineBackendDriver(host: "omarchy", relativeTouchpad: false, dialHost: magic)
        XCTAssertEqual(driver.client.dialHost, magic)
        XCTAssertEqual(driver.roadHost, magic)
        driver.follow(road: "192.168.1.10")
        XCTAssertEqual(driver.client.dialHost, "192.168.1.10")
        XCTAssertEqual(driver.roadHost, "192.168.1.10")
    }

    func testFailureReasonsAreShortAndSayWhatTheTransportSaid() {
        XCTAssertNil(OMRemoteClient.sunshineFailureReason(statusCode: 200, host: magic))
        XCTAssertEqual(OMRemoteClient.sunshineFailureReason(statusCode: NSURLErrorSecureConnectionFailed, host: magic),
                       "TLS handshake failed (-1200)")
        XCTAssertEqual(OMRemoteClient.sunshineFailureReason(statusCode: NSURLErrorSecureConnectionFailed, host: "100.119.57.11"),
                       "TLS refused by iOS on a Tailscale address, which needs the computer's MagicDNS name (-1200)")
        XCTAssertEqual(OMRemoteClient.sunshineFailureReason(statusCode: NSURLErrorTimedOut, host: magic), "timed out (-1001)")
        XCTAssertEqual(OMRemoteClient.sunshineFailureReason(statusCode: NSURLErrorCannotConnectToHost, host: magic),
                       "connection refused (-1004)")
        XCTAssertEqual(OMRemoteClient.sunshineFailureReason(statusCode: 401, host: magic), "HTTP 401")
        XCTAssertEqual(OMRemoteClient.sunshineFailureReason(statusCode: 0, host: magic), "no answer")
    }

    func testTheRemoteTranscriptKeepsTheStepAndTheReason() {
        RemoteSessionTrace.transcript.clear()
        RemoteSessionTrace.sunshineRequest(step: "serverinfo", host: "100.119.57.11", port: 47984,
                                           reason: "TLS handshake failed (-1200)")
        RemoteSessionTrace.sunshineRequest(step: "launch", host: magic, port: 47984, reason: nil)
        let text = RemoteSessionTrace.transcript.transcript
        XCTAssertTrue(text.contains("step=serverinfo host=100.119.57.11 port=47984 outcome=failed reason=TLS handshake failed (-1200)"))
        XCTAssertTrue(text.contains("step=launch host=\(magic) port=47984 outcome=ok"))
        XCTAssertFalse(text.contains("uniqueid"))
        RemoteSessionTrace.transcript.clear()
    }
}
