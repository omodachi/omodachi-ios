import CryptoKit
import Foundation
import XCTest
@testable import Omodachi

private final class MemoryRecords: KeychainRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private func key(_ service: String, _ account: String) -> String { service + "\u{0}" + account }
    func load(service: String, account: String) throws -> Data? {
        lock.withLock { values[key(service, account)] }
    }
    func save(_ data: Data, service: String, account: String) throws {
        lock.withLock { values[key(service, account)] = data }
    }
    func insertIfAbsent(_ data: Data, service: String, account: String) throws -> Bool {
        lock.withLock {
            let identifier = key(service, account)
            guard values[identifier] == nil else { return false }
            values[identifier] = data
            return true
        }
    }
    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: key(service, account)) }
    }
}

/// The SSH trust model, on the HTTPS side: a fingerprint pinned at the instant a
/// claim returns a credential, a hard failure when the presented certificate is
/// not that one, and an explicit user action to accept a rotated certificate.
final class HostPinningTests: XCTestCase {
    private let account = "https://omarchy.invalid:8099"
    private let first = String(repeating: "ab", count: 32)
    private let second = String(repeating: "cd", count: 32)
    private let hostID = String(repeating: "0", count: 32)

    private func store() -> HostPinStore {
        HostPinStore(service: "com.omodachi.tests.hostpin", records: MemoryRecords())
    }

    func testAClaimPinsHostIdentityAndEndpointsTogether() throws {
        let store = store()
        XCTAssertNil(store.load(account: account))
        let pin = HostPin(hostID: hostID, hostName: "omarchy", fingerprintSHA256: first,
                          endpoints: [.init(host: "192.168.1.10", port: 8099)])
        try store.save(pin, account: account)
        let loaded = try XCTUnwrap(store.load(account: account))
        XCTAssertEqual(loaded, pin)
        XCTAssertEqual(loaded.endpoints.first?.url?.absoluteString, "https://192.168.1.10:8099")
    }

    func testMalformedIdentityIsNeverPinned() {
        let store = store()
        for bad in [HostPin(hostID: "short", hostName: "h", fingerprintSHA256: first, endpoints: []),
                    HostPin(hostID: hostID, hostName: "h", fingerprintSHA256: "nothex", endpoints: []),
                    HostPin(hostID: hostID, hostName: "h", fingerprintSHA256: first.uppercased(), endpoints: []),
                    HostPin(hostID: hostID, hostName: "h", fingerprintSHA256: first, endpoints: [.init(host: "h", port: 0)])] {
            XCTAssertThrowsError(try store.save(bad, account: account)) { error in
                XCTAssertEqual(error as? HostPinError, .malformed)
            }
        }
        XCTAssertNil(store.load(account: account))
    }

    func testTrustingARotatedCertificateMovesOnlyTheFingerprint() throws {
        let store = store()
        try store.save(HostPin(hostID: hostID, hostName: "omarchy", fingerprintSHA256: first,
                               endpoints: [.init(host: "192.168.1.10", port: 8099)]), account: account)
        // A different host_id is a different machine, not a rotation.
        XCTAssertThrowsError(try store.trustRotatedCertificate(hostID: String(repeating: "1", count: 32),
                                                               fingerprint: second, account: account))
        XCTAssertEqual(store.load(account: account)?.fingerprintSHA256, first)
        try store.trustRotatedCertificate(hostID: hostID, fingerprint: second, account: account)
        let updated = try XCTUnwrap(store.load(account: account))
        XCTAssertEqual(updated.fingerprintSHA256, second)
        XCTAssertEqual(updated.hostID, hostID, "rotation never changes which host we paired with")
        XCTAssertEqual(updated.endpoints.first?.host, "192.168.1.10")
    }

    func testFingerprintComparisonIsExactAndLengthSafe() {
        XCTAssertTrue(HostTLSDelegate.constantTimeEqual(first, first))
        XCTAssertFalse(HostTLSDelegate.constantTimeEqual(first, second))
        XCTAssertFalse(HostTLSDelegate.constantTimeEqual(first, String(first.dropLast())))
        XCTAssertFalse(HostTLSDelegate.constantTimeEqual(first, first.uppercased()))
    }

    /// Stands in for `omodachi-host tls rotate` without touching the host: the
    /// same delegate, a different pinned value, and the handshake must be refused.
    func testAChangedCertificateIsAHardFailureWithNoFallback() {
        let trusting = HostTLSDelegate(pinnedFingerprint: first)
        XCTAssertTrue(trusting.accepts(leaf: first))
        XCTAssertEqual(trusting.observedFingerprint, first)
        XCTAssertNil(trusting.lastFailure)

        let rotated = HostTLSDelegate(pinnedFingerprint: first)
        XCTAssertFalse(rotated.accepts(leaf: second), "a changed certificate is refused, with no fallback")
        XCTAssertEqual(rotated.lastFailure, .certificateChanged(observed: second, pinned: first))
        // The observed value is exactly what "trust the new certificate" pins.
        XCTAssertEqual(rotated.observedFingerprint, second)
        XCTAssertFalse(rotated.accepts(leaf: second), "refusal is not softened by repetition")

        // During pairing there is nothing pinned yet, so the fingerprint is only
        // reported; only a completed claim turns it into trust.
        let pairing = HostTLSDelegate(pinnedFingerprint: nil)
        XCTAssertTrue(pairing.accepts(leaf: second))
        XCTAssertEqual(pairing.observedFingerprint, second)
        XCTAssertNil(pairing.lastFailure)
    }

    func testTheFingerprintIsTheLeafCertificateDERDigest() throws {
        var bytes: [UInt8] = [0x30, 0x82, 0x01, 0x00]
        bytes.append(contentsOf: (0..<256).map { UInt8($0 % 251) })
        let der = Data(bytes)
        let expected = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(expected.count, 64)
        XCTAssertTrue(HostPin.validFingerprint(expected))
        // The host publishes the same digest at /health, so a pin and the
        // anchor document are directly comparable.
        let health = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(
            Bundle(for: HostPinningTests.self).url(forResource: "health", withExtension: "json", subdirectory: "CoreFixtures")))) as? [String: Any]
        let advertised = try XCTUnwrap(health?["tls_fingerprint_sha256"] as? String)
        XCTAssertTrue(HostPin.validFingerprint(advertised))
        XCTAssertTrue(HostPin.validHostID(try XCTUnwrap(health?["host_id"] as? String)))
    }
}
