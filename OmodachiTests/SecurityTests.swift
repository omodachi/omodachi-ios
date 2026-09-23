import CryptoKit
import Foundation
import XCTest
@testable import Omodachi

private final class MemoryKeychain: KeychainRecordStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func save(_ value: Data, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values["\(service)|\(account)"] = value
    }

    func insertIfAbsent(_ value: Data, service: String, account: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = "\(service)|\(account)"
        if values[key] != nil { return false }
        values[key] = value
        return true
    }

    func load(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values["\(service)|\(account)"]
    }

    func remove(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: "\(service)|\(account)")
    }
}

final class SecurityTests: XCTestCase {
    func testSSHKeyRoundTripAndRemoval() throws {
        let records = MemoryKeychain()
        let store = SSHKeyStore(service: "test.ssh", records: records)
        let key = Data("-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----".utf8)

        try store.savePrivateKey(key, account: "alex@omarchy")
        XCTAssertEqual(try store.loadPrivateKey(account: "alex@omarchy"), key)
        try store.removePrivateKey(account: "alex@omarchy")
        XCTAssertNil(try store.loadPrivateKey(account: "alex@omarchy"))
    }

    func testSSHKeyImportsDocumentPickerFileIntoKeychain() throws {
        let records = MemoryKeychain()
        let store = SSHKeyStore(service: "test.ssh", records: records)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = Data("fixture-private-key".utf8)
        try key.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }

        try store.importPrivateKey(from: url, account: "alex@omarchy")
        XCTAssertEqual(try store.loadPrivateKey(account: "alex@omarchy"), key)
    }

    func testSSHKeyRejectsEmptyValues() {
        let store = SSHKeyStore(service: "test.ssh", records: MemoryKeychain())
        XCTAssertThrowsError(try store.savePrivateKey(Data(), account: "user")) { error in
            XCTAssertEqual(error as? SSHKeyStoreError, .emptyKey)
        }
        XCTAssertThrowsError(try store.savePrivateKey(Data("key".utf8), account: "  ")) { error in
            XCTAssertEqual(error as? SSHKeyStoreError, .emptyAccount)
        }
    }

    func testCompanionTokenUsesIndependentStoreAndCanBeRemoved() throws {
        let records = MemoryKeychain()
        let store = CompanionCredentialStore(service: "test.companion", records: records)
        try store.saveToken("device-token", account: "https://omarchy.local")
        XCTAssertEqual(try store.loadToken(account: "https://omarchy.local"), "device-token")
        try store.removeToken(account: "https://omarchy.local")
        XCTAssertNil(try store.loadToken(account: "https://omarchy.local"))
    }

    func testHostKeyFirstSeenRequiresExplicitConfirmation() throws {
        let records = MemoryKeychain()
        let store = HostKeyStore(service: "test.hostkeys", records: records)
        let key = Data("host-public-key-1".utf8)
        let fingerprint = try store.fingerprint(for: key)

        XCTAssertEqual(try store.verify(host: "omarchy:22", hostKey: key), .firstSeen(fingerprint: fingerprint))
        XCTAssertNil(try store.pinnedFingerprint(host: "omarchy:22"))

        XCTAssertEqual(try store.confirm(host: "omarchy:22", hostKey: key), fingerprint)
        XCTAssertEqual(try store.verify(host: "omarchy:22", hostKey: key), .accepted(fingerprint: fingerprint))
    }

    func testHostKeyChangeIsHardRejectedUntilIndependentReset() throws {
        let records = MemoryKeychain()
        let store = HostKeyStore(service: "test.hostkeys", records: records)
        let oldKey = Data("host-public-key-1".utf8)
        let newKey = Data("host-public-key-2".utf8)
        let oldFingerprint = try store.confirm(host: "omarchy:22", hostKey: oldKey)
        let newFingerprint = try store.fingerprint(for: newKey)

        XCTAssertEqual(
            try store.verify(host: "omarchy:22", hostKey: newKey),
            .mismatch(expected: oldFingerprint, actual: newFingerprint)
        )
        XCTAssertThrowsError(try store.confirm(host: "omarchy:22", hostKey: newKey)) { error in
            XCTAssertEqual(error as? HostKeyStoreError, .alreadyPinned(expected: oldFingerprint, actual: newFingerprint))
        }
        XCTAssertEqual(try store.pinnedFingerprint(host: "omarchy:22"), oldFingerprint)

        try store.reset(host: "omarchy:22")
        XCTAssertEqual(try store.verify(host: "omarchy:22", hostKey: newKey), .firstSeen(fingerprint: newFingerprint))
    }

    func testFingerprintUsesOpenSSHSHA256Format() throws {
        let key = Data("host-public-key-1".utf8)
        let expected = "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        XCTAssertEqual(try HostKeyStore(records: MemoryKeychain()).fingerprint(for: key), expected)
    }
}
