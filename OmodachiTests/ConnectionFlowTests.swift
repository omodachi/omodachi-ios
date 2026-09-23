import Network
import XCTest
@testable import Omodachi

/// SPEC-I: the connection flow Study 03 §12–§16 describes, checked where the
/// Simulator cannot reach — a refused local-network permission, the reason
/// table that has to read exactly as the study wrote it, and the defaults that
/// used to disagree with the host.
@MainActor final class ConnectionFlowTests: XCTestCase {

    // MARK: - §12 the three empty states

    /// §3.2: a real permission refusal cannot be produced in the Simulator, so
    /// the state is driven through the same entry point `NWBrowser` uses.
    func testARefusedLocalNetworkPermissionIsItsOwnEmptyState() {
        let browser = HostBrowser()
        XCTAssertEqual(browser.state, .searching)
        browser.apply(state: .waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        XCTAssertEqual(browser.state, .denied)
        XCTAssertTrue(browser.permissionDenied)
        // A denied browser goes quiet rather than failing again, so a later
        // `.cancelled` must not quietly turn the board back into "searching".
        browser.apply(state: .cancelled)
        XCTAssertEqual(browser.state, .denied)
        // "再问一次" is the only thing that can make iOS show the prompt, and on
        // iPadOS the Settings row does not exist until it has.
        browser.apply(state: .ready)
        XCTAssertEqual(browser.state, .searching)
        XCTAssertFalse(browser.permissionDenied)
    }

    func testEPERMIsTheSameRefusalUnderADifferentName() {
        let browser = HostBrowser()
        browser.apply(state: .failed(.posix(.EPERM)))
        XCTAssertEqual(browser.state, .denied)
    }

    func testAnyOtherFailureKeepsItsOwnSentenceAndTheManualExit() {
        let browser = HostBrowser()
        browser.apply(state: .waiting(.dns(DNSServiceErrorType(-65563))))
        guard case let .unavailable(reason) = browser.state else {
            return XCTFail("expected an unavailable state, got \(browser.state)")
        }
        XCTAssertEqual(reason, Strings.discoveryUnavailable, "every empty state carries an exit (A-33)")
        XCTAssertFalse(browser.permissionDenied)
    }

    // MARK: - §12 ⑤ manual add (A-34)

    func testManualAddTakesAHostnameOrAnAddressAndFillsInTheRest() {
        let cases: [(String, String)] = [
            ("omarchy", "https://omarchy:8099"),
            ("omarchy.local", "https://omarchy.local:8099"),
            ("192.168.1.10", "https://192.168.1.10:8099"),
            ("  192.168.1.10  ", "https://192.168.1.10:8099"),
            ("192.168.1.10:9443", "https://192.168.1.10:9443"),
            ("https://omarchy", "https://omarchy:8099"),
            ("https://omarchy:8099/", "https://omarchy:8099"),
        ]
        for (input, expected) in cases {
            let candidate = HostCandidate.manual(input)
            XCTAssertEqual(candidate?.url.absoluteString, expected, "for \(input)")
        }
        // An IPv6 literal is full of colons; only the bracketed form has a port.
        XCTAssertEqual(HostCandidate.manual("[fd00::1]")?.url.absoluteString, "https://[fd00::1]:8099")
        XCTAssertEqual(HostCandidate.manual("[fd00::1]:9443")?.url.absoluteString, "https://[fd00::1]:9443")
    }

    func testManualAddRefusesAnythingThatIsNotAHost() {
        for bad in ["", "   ", "omarchy/path", "user@omarchy", "omarchy?q=1", "omarchy#x",
                    "omarchy:0", "omarchy:70000", "omar chy"] {
            XCTAssertNil(HostCandidate.manual(bad), "\(bad) is not a host")
        }
    }

    // MARK: - PAIR-2 §3.1/§3.4 one tap is the whole request

    /// The tap on a host row is the entire user action: the request goes out
    /// with no `invitation` field, and the card has an expiry to count down
    /// from before anything else happens.
    func testOneTapSendsTheRequestWithNoInvitationAndStartsTheCountdown() async throws {
        let flow = try PairingFixture.flow()
        PairingFixture.reset()
        PairingFixture.reply(#"{"service":"omodachid","host_id":"\#(String(repeating: "a", count: 32))","tls_fingerprint_sha256":"\#(String(repeating: "b", count: 64))","pairing":{"mode":"open"}}"#)
        let expiry = Int(Date().timeIntervalSince1970) + 300
        PairingFixture.reply(#"{"request_id":"pair_\#(String(repeating: "0", count: 32))","device_id":"ios-fixture","device_name":"Fixture","status":"pending","expires_at":\#(expiry),"request_secret":"\#(String(repeating: "B", count: 43))"}"#)
        // Everything after the request is a claim poll that never resolves here.
        for _ in 0..<4 {
            PairingFixture.reply(#"{"request_id":"pair_\#(String(repeating: "0", count: 32))","device_id":"ios-fixture","device_name":"Fixture","status":"pending","expires_at":\#(expiry)}"#)
        }
        flow.select(PairingFixture.candidate, sshPublicKey: nil)
        for _ in 0..<300 where flow.expiresAt == nil { try? await Task.sleep(for: .milliseconds(20)) }
        flow.cancel()
        XCTAssertNil(flow.failure, "an open host must not refuse a request that carries nothing")
        XCTAssertEqual(flow.expiresAt.map { Int($0.timeIntervalSince1970) }, expiry,
                       "the card counts down from the host's own expiry")
        let bodies = PairingFixture.bodies
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(bodies.first)) as? [String: Any])
        XCTAssertNil(json["invitation"], "nothing was typed, so nothing was sent")
        XCTAssertEqual(json["device_id"] as? String, "ios-fixture")
        // Not in the request and not in the claim that follows it either.
        XCTAssertFalse(bodies.contains { String(decoding: $0, as: UTF8.self).contains("invitation") })
    }

    // MARK: - PAIR-2 §3.3 the chip on an unpaired row

    func testALockedHostSaysSoOnItsRowAndAnOpenOneIsJustUnpaired() throws {
        var candidate = try XCTUnwrap(HostCandidate.manual("omarchy"))
        XCTAssertEqual(candidate.statusLabel, Strings.hostPairingNew)
        candidate.invitationOnly = true
        XCTAssertEqual(candidate.statusLabel, Strings.hostPairingInviteNeeded)
        // A host this device has already paired with is paired, whatever its
        // mode: the chip answers "can I use this", not "how does it pair".
        candidate.pairing = .paired
        XCTAssertEqual(candidate.statusLabel, Strings.hostPairingPaired)
    }

    /// `/health` is the anchor, and PAIR-2 puts exactly one new word in it.
    func testHealthCarriesThePairingModeAndAPrePairTwoHostIsOpen() async throws {
        let open = try await HealthFixture.read(#"{"service":"omodachid","host_id":"\#(String(repeating: "a", count: 32))","tls_fingerprint_sha256":"\#(String(repeating: "b", count: 64))","pairing":{"mode":"open"}}"#)
        XCTAssertFalse(open.invitationOnly)
        let locked = try await HealthFixture.read(#"{"service":"omodachid","host_id":null,"tls_fingerprint_sha256":null,"pairing":{"mode":"invite"}}"#)
        XCTAssertTrue(locked.invitationOnly)
        // No `pairing` object at all, and a mode this build has never seen, are
        // the same answer: not locked, because nothing said it was.
        let old = try await HealthFixture.read(#"{"service":"omodachid","host_id":null,"tls_fingerprint_sha256":null}"#)
        XCTAssertFalse(old.invitationOnly)
        let future = try await HealthFixture.read(#"{"service":"omodachid","host_id":null,"tls_fingerprint_sha256":null,"pairing":{"mode":"something_new"}}"#)
        XCTAssertFalse(future.invitationOnly)
    }

    // MARK: - §13 the fingerprint (A-36)

    func testTheFingerprintIsEightDigitsInTwoGroupsOfFour() {
        let full = "4f3a91c2" + String(repeating: "a", count: 56)
        XCTAssertEqual(FingerprintText.short(full), "4f3a 91c2")
        // The other 56 never go on screen.
        XCTAssertFalse(FingerprintText.short(full).contains("aaaa"))
    }

    // MARK: - §14 the paired-host directory (N-26)

    func testTheDirectoryRemembersAndForgetsOneAccountAtATime() {
        let name = "omodachi.spec-i.directory"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let directory = PairedHostDirectory(defaults: defaults)
        XCTAssertTrue(directory.records.isEmpty)
        directory.remember(.init(account: "https://omarchy:8099", hostID: String(repeating: "a", count: 32),
                                 hostName: "omarchy", address: "10.0.0.9:8099"))
        directory.remember(.init(account: "https://studio:8099", hostID: String(repeating: "b", count: 32),
                                 hostName: "studio", address: "10.0.0.23:8099"))
        // Re-pairing the same account replaces its row rather than adding one.
        directory.remember(.init(account: "https://omarchy:8099", hostID: String(repeating: "c", count: 32),
                                 hostName: "omarchy", address: "10.0.0.10:8099"))
        XCTAssertEqual(directory.records.map(\.hostName), ["omarchy", "studio"])
        XCTAssertEqual(directory.records.first?.address, "10.0.0.10:8099")
        XCTAssertEqual(PairedHostDirectory(defaults: defaults).records.count, 2, "it survives a relaunch")
        directory.forget(account: "https://omarchy:8099")
        XCTAssertEqual(directory.records.map(\.hostName), ["studio"])
        defaults.removePersistentDomain(forName: name)
    }

    // MARK: - §15 the reason table, as written (N-23)

    /// Study 03 §15's table is the contract. Every row is checked verbatim so a
    /// reason can never again be spliced into a Chinese sentence as snake_case.
    func testEveryCapabilityReasonHasTheSentenceTheStudyWrote() {
        // I18N-1 §2: the sentences moved into `ReasonText` so that a reader in
        // either language gets one. The row is still the contract — the reason
        // has a sentence of its own, and it is never the code.
        let expected: [String: String] = [
            "sunshine_desktop_unavailable": ReasonText.message("sunshine_desktop_unavailable", domain: .remote),
            "sunshine_control_unavailable": ReasonText.message("sunshine_control_unavailable", domain: .remote),
            "backend_not_installed": ReasonText.message("backend_not_installed", domain: .remote),
            "sunshine_assets_missing": ReasonText.message("sunshine_assets_missing", domain: .remote),
            "wayvnc_0_10_1_required": ReasonText.message("wayvnc_0_10_1_required", domain: .remote),
            "remote_runtime_unavailable": ReasonText.message("remote_runtime_unavailable", domain: .remote),
            "media_pairing_required": ReasonText.message("media_pairing_required", domain: .remote),
            "dynamic_resolution_policy_denied": ReasonText.message("dynamic_resolution_policy_denied", domain: .remote),
        ]
        for (reason, sentence) in expected {
            XCTAssertEqual(RemoteReasonCopy.sentence(reason), sentence, "for \(reason)")
            XCTAssertNotEqual(RemoteReasonCopy.sentence(reason), reason, "for \(reason)")
            XCTAssertFalse(RemoteReasonCopy.sentence(reason).isEmpty, "for \(reason)")
        }
        // `sunshine_assets_missing` arrives with `available: true`: it is a
        // notice about quality, not a refusal.
        XCTAssertTrue(RemoteReasonCopy.entry("sunshine_assets_missing").isAdvisory)
        XCTAssertFalse(RemoteReasonCopy.entry("sunshine_desktop_unavailable").isAdvisory)
        // `host_waking` never reaches the screen; the app wakes and retries.
        XCTAssertTrue(RemoteReasonCopy.entry("host_waking").sentence.isEmpty)
        // Each one names the exits the study gives it.
        XCTAssertEqual(RemoteReasonCopy.entry("sunshine_desktop_unavailable").exits, [.useVNC, .howToFix])
        XCTAssertEqual(RemoteReasonCopy.entry("media_pairing_required").exits, [.repairSunshinePairing])
        XCTAssertEqual(RemoteReasonCopy.entry("wayvnc_0_10_1_required").exits, [],
                       "with no exit the app writes one sentence and stops")
    }

    func testAnUnknownReasonShowsItselfRatherThanDisappearing() {
        // I18N-1 §2: it still names itself, now inside a sentence rather than
        // as a bare identifier on a Chinese panel.
        XCTAssertTrue(RemoteReasonCopy.sentence("something_core_added_later").contains("something_core_added_later"))
        XCTAssertTrue(RemoteReasonCopy.entry("something_core_added_later").exits.isEmpty)
    }

    // MARK: - §15 the default backend (Study 03 open question 5)

    private func capabilities(sunshine: Bool, vnc: Bool, defaultBackend: String?) throws -> RemoteCapabilitiesDTO {
        let json = """
        {"backends":{"sunshine":{"available":\(sunshine),"reason":null},
                     "vnc":{"available":\(vnc),"reason":null}},
         "modes":["extend","takeover"],"placement_options":["right"],
         "lock_local_input_supported":true,"encoder_limits":null
         \(defaultBackend.map { ",\"default_backend\":\"\($0)\"" } ?? "")}
        """
        return try JSONDecoder().decode(RemoteCapabilitiesDTO.self, from: Data(json.utf8))
    }

    func testAutoIsTheHostsAnswerAndNotAConstantOfOurOwn() throws {
        let both = try capabilities(sunshine: true, vnc: true, defaultBackend: "sunshine")
        XCTAssertEqual(RemoteBackendChoice.auto.resolve(both), .sunshine)
        XCTAssertEqual(RemoteBackendChoice.vnc.resolve(both), .vnc, "an explicit choice is still a choice")

        // The host says sunshine but reports it unusable: auto falls through to
        // what is actually available rather than to a refusal.
        let down = try capabilities(sunshine: false, vnc: true, defaultBackend: "sunshine")
        XCTAssertEqual(RemoteBackendChoice.auto.resolve(down), .vnc)

        // A host from before SPEC-I does not publish the field at all.
        let old = try capabilities(sunshine: true, vnc: true, defaultBackend: nil)
        XCTAssertNil(old.default_backend)
        XCTAssertEqual(RemoteBackendChoice.auto.resolve(old), .sunshine)

        // Nothing available: the name is still shown, and it is the host's.
        let none = try capabilities(sunshine: false, vnc: false, defaultBackend: "vnc")
        XCTAssertEqual(none.resolvedDefault, .vnc)
    }

    // MARK: - §15 ⑧ who is holding the host (core §1.2)

    func testTheOccupiedMessageNamesTheDeviceRatherThanSayingSomebody() {
        let owner = RemoteRequestError.Owner(sessionID: "rs_" + String(repeating: "0", count: 32),
                                             deviceID: "iphone-b", deviceName: "Leo 的 iPhone",
                                             mode: .takeover, backend: .sunshine,
                                             startedAt: Date(timeIntervalSince1970: 1_789_747_000))
        let named = RemoteRequestError(code: "remote_session_exists", status: 409, owner: owner)
        XCTAssertTrue(named.userMessage.contains("Leo 的 iPhone"))
        XCTAssertTrue(named.userMessage.contains(RemoteMode.takeover.title))
        // A host that did not say who still gets a sentence, just a vaguer one.
        let anonymous = RemoteRequestError(code: "remote_session_exists", status: 409)
        XCTAssertEqual(anonymous.userMessage, ReasonText.message("remote_session_exists", domain: .remote))
    }

    // MARK: - N-25 lock_local_input

    func testTheLockOnlyEverLeavesTheDeviceUnderTakeover() throws {
        let geometry = RemoteGeometryRequest(
            viewport_points: RemotePoints(width: 1194, height: 834), orientation: "landscape_left",
            logical_long_edge: 1280, quality: RemoteQuality())
        func locked(_ mode: RemoteMode, _ requested: Bool) throws -> Bool {
            let body = RemoteCreateRequest(backend: .sunshine, mode: mode, geometry: geometry,
                                           lockLocalInput: requested, ttlSeconds: 60)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
            return try XCTUnwrap(json["lock_local_input"] as? Bool)
        }
        XCTAssertFalse(try locked(.extend, false))
        XCTAssertFalse(try locked(.extend, true), "the extra screen never locks: it does not touch the local screen")
        XCTAssertFalse(try locked(.takeover, false), "default off (N-25)")
        XCTAssertTrue(try locked(.takeover, true))
    }

    // MARK: - N-28 the key that rides along

    func testOnlyASingleLineOpenSSHKeyIsOfferedToTheHost() {
        let body = "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"
        XCTAssertTrue(PairingClient.validPublicKey("ssh-ed25519 \(body) omodachi-ios"))
        XCTAssertTrue(PairingClient.validPublicKey("ssh-ed25519 \(body)"))
        for bad in ["", "ssh-ed25519", "ssh-dss \(body)", "ssh-ed25519 !!!!",
                    "ssh-ed25519 \(body)\nssh-ed25519 \(body)", "ssh-ed25519 \(body) a b"] {
            XCTAssertFalse(PairingClient.validPublicKey(bad), "\(bad)")
        }
    }

    func testTheGeneratedPublicKeyIsTheOpenSSHWireFormat() {
        let line = CompanionSSHKey.openSSHPublicKey(Data(repeating: 0, count: 32))
        XCTAssertTrue(PairingClient.validPublicKey(line))
        XCTAssertTrue(line.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
    }

    // MARK: - A pin written before SPEC-I still decodes

    func testAPinFromBeforeSPECIKeepsWorkingWithoutAnSSHTarget() throws {
        let json = """
        {"hostID":"\(String(repeating: "a", count: 32))","hostName":"omarchy",
         "fingerprintSHA256":"\(String(repeating: "b", count: 64))",
         "endpoints":[{"host":"192.168.1.10","port":8099}]}
        """
        let pin = try JSONDecoder().decode(HostPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.ssh)
        XCTAssertNil(pin.grants)
        XCTAssertTrue(pin.isWellFormed)
        var profile = HostProfile()
        profile.hostname = "omarchy"
        profile.username = "alex"
        XCTAssertEqual(SSHTargetResolver.resolve(profile: profile, pin: pin)?.source, .profile)
    }
}

/// N-28's last promise: a paired host's SSH key is not a second thing to
/// approve. The pairing claim named that target over a connection whose
/// certificate this device had already pinned.
@MainActor final class PairedHostKeyTrustTests: XCTestCase {
    private final class MemoryKeychain: KeychainRecordStore, @unchecked Sendable {
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

    private func challenge(host: String, port: Int = 22) -> SSHHostKeyChallenge {
        SSHHostKeyChallenge(host: host, port: port, algorithm: "ssh-ed25519",
                            openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
                            fingerprintSHA256: "SHA256:fixture")
    }

    func testAPairedTargetIsPinnedWithoutAPrompt() async throws {
        let keys = HostKeyStore(service: "test.hostkeys", records: MemoryKeychain())
        let trust = HostTrustCoordinator(pins: keys, paired: { ["192.168.1.10:22"] })
        try await trust.validate(challenge(host: "192.168.1.10"))
        XCTAssertNil(trust.request, "a paired host must not raise a TOFU sheet")
        XCTAssertNotNil(try keys.pinnedFingerprint(host: "192.168.1.10:22"))
    }

    func testAHostNobodyPairedWithStillAsks() async throws {
        let keys = HostKeyStore(service: "test.hostkeys", records: MemoryKeychain())
        let trust = HostTrustCoordinator(pins: keys, paired: { [] })
        let task = Task { try await trust.validate(challenge(host: "10.0.0.99")) }
        for _ in 0..<200 where trust.request == nil { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(trust.request, "an unpaired host is still a decision")
        trust.resolve(accept: false)
        do { try await task.value; XCTFail("a declined key must not connect") }
        catch {}
    }
}


/// One `/health` document, served locally, so the probe under test is the real
/// one. It carries no credential and reaches no network.
enum HealthFixture {
    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "health.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static func read(_ json: String) async throws -> HostHealth {
        Stub.body = Data(json.utf8)
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [Stub.self]
        let probe = HostHealthProbe(session: URLSession(configuration: options))
        return try await probe.read(URL(string: "https://health.invalid:8099/")!)
    }
}


/// A local host that answers `/health` and one pairing request, so the flow
/// model's own behaviour is under test rather than a network.
@MainActor enum PairingFixture {
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static let lock = NSLock()
        nonisolated(unsafe) static var replies: [Data] = []
        nonisolated(unsafe) static var requestBodies: [Data] = []
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pairing-flow.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(contentsOf: buffer[0..<read])
                }
                stream.close()
                Self.lock.withLock { Self.requestBodies.append(data) }
            } else if let body = request.httpBody {
                Self.lock.withLock { Self.requestBodies.append(body) }
            }
            let body = Self.lock.withLock { Self.replies.isEmpty ? Data("{}".utf8) : Self.replies.removeFirst() }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static let endpoint = URL(string: "https://pairing-flow.invalid:8099/")!
    static var candidate: HostCandidate {
        HostCandidate(id: endpoint.absoluteString, name: "omarchy", hostIDSuffix: nil,
                      address: "pairing-flow.invalid:8099", url: endpoint)
    }
    static func reset() {
        Stub.lock.withLock { Stub.replies = []; Stub.requestBodies = [] }
    }
    static func reply(_ json: String) {
        Stub.lock.withLock { Stub.replies.append(Data(json.utf8)) }
    }
    /// Only the pairing POSTs; the first request is the `/health` probe.
    static var bodies: [Data] { Stub.lock.withLock { Stub.requestBodies } }

    static func session() -> URLSession {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [Stub.self]
        return URLSession(configuration: options)
    }

    static func flow() throws -> ConnectionFlowModel {
        let service = "com.omodachi.tests.flow.\(UUID().uuidString)"
        let records = FlowMemoryRecords()
        // PAIR-4: the flow now reads this device's stored credential before it
        // sends anything, so the fixture's Keychain has to be in memory too —
        // a test must never be able to see the Simulator's own records.
        return ConnectionFlowModel(deviceID: "ios-fixture", deviceName: "Fixture",
                                   pins: HostPinStore(service: service + ".pin", records: records),
                                   credentials: CompanionCredentialStore(service: service, records: records),
                                   hostKeys: HostKeyStore(service: service + ".hostkey", records: records),
                                   probe: HostHealthProbe(session: session()),
                                   makeClient: { url in
            try PairingClient(endpoint: url, records: records, service: service,
                              pins: HostPinStore(service: service + ".pin", records: records),
                              session: session())
        })
    }
}

private final class FlowMemoryRecords: KeychainRecordStore, @unchecked Sendable {
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
