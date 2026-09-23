import Foundation
import XCTest
@testable import Omodachi

private final class PairingFixtureStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, Data, URL?)] = []
    private var captured: [URLRequest] = []
    func reset() { lock.lock(); defer { lock.unlock() }; replies = []; captured = [] }
    func add(_ body: [String: Any], status: Int = 200, responseURL: URL? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        lock.lock(); defer { lock.unlock() }; replies.append((status, data, responseURL))
    }
    func receive(_ request: URLRequest) -> (Int, Data, URL?) {
        lock.lock(); defer { lock.unlock() }; captured.append(request)
        return replies.isEmpty ? (503, Data("{}".utf8), nil) : replies.removeFirst()
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
}
private final class PairingURLProtocol: URLProtocol, @unchecked Sendable {
    static let storage = PairingFixtureStorage()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pairing.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data, responseURL) = Self.storage.receive(request)
        let response = HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class PairingClientTests: XCTestCase {
    private let invitation = String(repeating: "A", count: 43)
    private let requestSecret = String(repeating: "B", count: 43)
    private let requestID = "pair_" + String(repeating: "a", count: 32)
    private let endpoint = URL(string: "https://PAIRING.invalid/")!
    private let account = "https://pairing.invalid"
    private var expires: Int { Int(Date().timeIntervalSince1970) + 200 }
    private static let hostID = String(repeating: "a", count: 32)
    private static let fingerprint = String(repeating: "ab", count: 32)
    private var pinStore = HostPinStore(service: "unused", records: PairingMemoryRecords())
    private func setup() throws -> (PairingClient, CompanionCredentialStore) {
        PairingURLProtocol.storage.reset()
        let service = "com.omodachi.tests.pairing.\(UUID().uuidString)"
        pinStore = HostPinStore(service: service + ".pin", records: PairingMemoryRecords())
        let options = URLSessionConfiguration.ephemeral; options.protocolClasses = [PairingURLProtocol.self]
        return (try PairingClient(endpoint: endpoint, service: service, pins: pinStore,
                                  session: URLSession(configuration: options)), CompanionCredentialStore(service: service))
    }
    private func response(status: String = "pending", expiry: Int, initial: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["request_id": requestID, "device_id": "ios-fixture", "device_name": "Fixture iPad", "status": status, "expires_at": expiry]
        if initial { value["request_secret"] = requestSecret }
        if status == "claimed" {
            value["credential"] = "pairing-fixture-credential"
            value["issued_at"] = Int(Date().timeIntervalSince1970)
            value["credential_expires_at"] = Int(Date().timeIntervalSince1970) + 3600
            // The claim is the moment the host identity arrives to be pinned.
            value["host_id"] = Self.hostID
            value["host_name"] = "omarchy-fixture"
            value["tls_fingerprint_sha256"] = Self.fingerprint
            value["endpoints"] = [["host": "192.168.1.10", "port": 8099]]
        }
        return value
    }
    func testPendingApprovedClaimWritesOnlyNormalizedSystemKeychainAccount() async throws {
        let (client, store) = try setup(); defer { try? store.removeToken(account: account) }
        let expiry = expires
        try PairingURLProtocol.storage.add(response(expiry: expiry, initial: true))
        try PairingURLProtocol.storage.add(response(expiry: expiry))
        try PairingURLProtocol.storage.add(response(status: "claimed", expiry: expiry))
        let pending = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad")
        XCTAssertEqual(pending.status, .pending)
        XCTAssertNil(try store.loadToken(account: account))
        let stillPending = try await client.claim()
        XCTAssertEqual(stillPending.status, .pending)
        XCTAssertNil(try store.loadToken(account: account))
        let success = try await client.claim()
        XCTAssertEqual(success.status, .claimed)
        XCTAssertEqual(try store.loadToken(account: account), "pairing-fixture-credential")
        XCTAssertNil(try store.loadToken(account: endpoint.absoluteString))
        // Pinned in the same step, keyed by the same normalized account.
        let pin = try XCTUnwrap(pinStore.load(account: account))
        XCTAssertEqual(pin.hostID, Self.hostID)
        XCTAssertEqual(pin.fingerprintSHA256, Self.fingerprint)
        XCTAssertEqual(pin.hostName, "omarchy-fixture")
        XCTAssertEqual(pin.endpoints, [.init(host: "192.168.1.10", port: 8099)])
        XCTAssertNil(pinStore.load(account: endpoint.absoluteString))
        let requests = PairingURLProtocol.storage.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, "/v1/pairing/requests")
        XCTAssertEqual(requests[1].url?.path, "/v1/pairing/requests/\(requestID)/claim")
        for request in requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "pairing.invalid")
        }
        do { _ = try await client.claim(); XCTFail("One-use claim repeated") }
        catch { XCTAssertEqual(error as? PairingError, .cancelled) }
        XCTAssertEqual(PairingURLProtocol.storage.requests.count, 3)
    }
    func testExistingCredentialRefusesRequestWithoutOverwrite() async throws {
        let (client, store) = try setup(); defer { try? store.removeToken(account: account) }
        try store.saveToken("existing-fixture", account: account)
        do { _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad"); XCTFail("Existing token replaced") }
        catch { XCTAssertEqual(error as? PairingError, .existingCredential) }
        XCTAssertEqual(try store.loadToken(account: account), "existing-fixture")
        XCTAssertTrue(PairingURLProtocol.storage.requests.isEmpty)
    }
    func testCredentialAddedWhileWaitingRefusesClaimAndPreservesIt() async throws {
        let (client, store) = try setup(); defer { try? store.removeToken(account: account) }
        try PairingURLProtocol.storage.add(response(expiry: expires, initial: true))
        _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad")
        try store.saveToken("other-fixture", account: account)
        do { _ = try await client.claim(); XCTFail("Existing token replaced") }
        catch { XCTAssertEqual(error as? PairingError, .existingCredential) }
        XCTAssertEqual(try store.loadToken(account: account), "other-fixture")
        XCTAssertEqual(PairingURLProtocol.storage.requests.count, 1)
    }
    func testRejectedClaimClearsSecretAndDoesNotStoreCredential() async throws {
        let (client, store) = try setup()
        try PairingURLProtocol.storage.add(response(expiry: expires, initial: true))
        try PairingURLProtocol.storage.add(["error": ["code": "pairing_request_unavailable", "message": "PRIVATE"]], status: 409)
        _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad")
        do { _ = try await client.claim(); XCTFail("Rejected claim accepted") }
        catch { XCTAssertEqual(error as? PairingError, .rejectedOrExpired); XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        XCTAssertNil(try store.loadToken(account: account))
        do { _ = try await client.claim(); XCTFail("Secret retained after rejection") }
        catch { XCTAssertEqual(error as? PairingError, .cancelled) }
    }
    func testInvalidSecretsAndDeviceIdentifiersNeverReachNetwork() async throws {
        let (client, _) = try setup()
        // The one path that still carries an invitation validates it as before.
        for secret in ["", String(repeating: "A", count: 42), String(repeating: "A", count: 44), String(repeating: "A", count: 42) + "\n", String(repeating: "中", count: 43)] {
            do { _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad", invitation: secret); XCTFail("Invalid invitation accepted") }
            catch { XCTAssertEqual(error as? PairingError, .invalidInput) }
        }
        for id in ["", "../bad", "-invalid", String(repeating: "a", count: 129)] {
            do { _ = try await client.begin(deviceID: id, deviceName: "Fixture iPad"); XCTFail("Invalid device accepted") }
            catch { XCTAssertEqual(error as? PairingError, .invalidInput) }
        }
        XCTAssertTrue(PairingURLProtocol.storage.requests.isEmpty)
    }
    func testMalformedRequestSecretAndExpiredRequestFailClosed() async throws {
        for invalid in ["secret", "", String(repeating: "x", count: 44)] {
            let (client, store) = try setup()
            var body = response(expiry: expires, initial: true); body["request_secret"] = invalid
            try PairingURLProtocol.storage.add(body)
            do { _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad"); XCTFail("Invalid claim secret accepted") }
            catch { XCTAssertEqual(error as? PairingError, .invalidResponse) }
            XCTAssertNil(try store.loadToken(account: account))
        }
        let (client, _) = try setup()
        try PairingURLProtocol.storage.add(response(expiry: Int(Date().timeIntervalSince1970) - 1, initial: true))
        do { _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad"); XCTFail("Expired invitation accepted") }
        catch { XCTAssertEqual(error as? PairingError, .invalidResponse) }
    }
    func testOtherOriginResponseAndInsecureEndpointRejected() async throws {
        XCTAssertThrowsError(try PairingClient(endpoint: URL(string: "http://pairing.invalid")!))
        let (client, store) = try setup()
        try PairingURLProtocol.storage.add(response(expiry: expires, initial: true), responseURL: URL(string: "https://other.invalid/v1/pairing/requests"))
        do { _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad"); XCTFail("Other origin accepted") }
        catch { XCTAssertEqual(error as? PairingError, .invalidResponse) }
        XCTAssertNil(try store.loadToken(account: account))
    }
    /// PAIR-2 §3.1: the default request carries no invitation at all, and the
    /// body proves it — this is the field the user used to have to type.
    func testTheDefaultRequestCarriesNoInvitation() async throws {
        let (client, _) = try setup()
        try PairingURLProtocol.storage.add(response(expiry: expires, initial: true))
        _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad")
        let sent = try XCTUnwrap(PairingURLProtocol.storage.requests.first)
        let body = try XCTUnwrap(sent.httpBody ?? sent.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            return data
        })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["invitation"])
        XCTAssertEqual(json["device_id"] as? String, "ios-fixture")
    }

    /// PAIR-2 §3.2: a locked host is the only thing that produces an invitation
    /// field, and it does so by saying so — the app never asks first.
    func testALockedHostIsItsOwnErrorAndThenTakesTheInvitation() async throws {
        let (client, _) = try setup()
        try PairingURLProtocol.storage.add(["error": ["code": "pairing_invitation_required", "message": "PRIVATE"]], status: 403)
        do { _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad"); XCTFail("a locked host accepted a bare request") }
        catch {
            XCTAssertEqual(error as? PairingError, .invitationRequired)
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
        }
        XCTAssertEqual(ConnectionFlowModel.describe(.invitationRequired), .locked)
        // Any other 403 is still the ordinary refusal, with no field offered.
        try PairingURLProtocol.storage.add(["error": ["code": "pairing_invitation_invalid_or_expired", "message": "x"]], status: 403)
        do { _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad"); XCTFail("accepted") }
        catch { XCTAssertEqual(error as? PairingError, .rejectedOrExpired) }
        // And with the invitation in hand the request goes out carrying it.
        try PairingURLProtocol.storage.add(response(expiry: expires, initial: true))
        _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad", invitation: invitation)
        let sent = try XCTUnwrap(PairingURLProtocol.storage.requests.last?.httpBodyStream)
        sent.open(); defer { sent.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while sent.hasBytesAvailable {
            let read = sent.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["invitation"] as? String, invitation)
    }

    func testCancellationClearsPendingClaimSecret() async throws {
        let (client, store) = try setup()
        try PairingURLProtocol.storage.add(response(expiry: expires, initial: true))
        _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad")
        await client.cancel()
        do { _ = try await client.claim(); XCTFail("Cancelled claim sent") }
        catch { XCTAssertEqual(error as? PairingError, .cancelled) }
        XCTAssertEqual(PairingURLProtocol.storage.requests.count, 1)
        XCTAssertNil(try store.loadToken(account: account))
    }
}


/// A claim that does not carry the host identity is not a pairing this client
/// can complete: there would be nothing to pin, and an unpinned connection is
/// exactly what the trust model exists to prevent.
extension PairingClientTests {
    func testAClaimWithoutHostIdentityIsRefusedAndPinsNothing() async throws {
        let (client, store) = try setup(); defer { try? store.removeToken(account: account) }
        let expiry = expires
        var claimed = response(status: "claimed", expiry: expiry)
        claimed["tls_fingerprint_sha256"] = nil
        claimed.removeValue(forKey: "tls_fingerprint_sha256")
        try PairingURLProtocol.storage.add(response(expiry: expiry, initial: true))
        try PairingURLProtocol.storage.add(claimed)
        _ = try await client.begin(deviceID: "ios-fixture", deviceName: "Fixture iPad")
        do { _ = try await client.claim(); XCTFail("an unpinnable claim must fail") }
        catch { XCTAssertEqual(error as? PairingError, .invalidResponse) }
        XCTAssertNil(pinStore.load(account: account))
        XCTAssertNil(try store.loadToken(account: account))
    }
}

private final class PairingMemoryRecords: KeychainRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private func key(_ service: String, _ account: String) -> String { service + "\u{0}" + account }
    func load(service: String, account: String) throws -> Data? { lock.withLock { values[key(service, account)] } }
    func save(_ data: Data, service: String, account: String) throws { lock.withLock { values[key(service, account)] = data } }
    func insertIfAbsent(_ data: Data, service: String, account: String) throws -> Bool {
        lock.withLock {
            let identifier = key(service, account)
            guard values[identifier] == nil else { return false }
            values[identifier] = data
            return true
        }
    }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: key(service, account)) } }
}
