import CryptoKit
import Foundation

/// The result intentionally distinguishes first sighting from an accepted pin
/// and from a changed key. A first sighting never mutates storage.
enum HostKeyVerification: Equatable, Sendable {
    case firstSeen(fingerprint: String)
    case accepted(fingerprint: String)
    case mismatch(expected: String, actual: String)
}

enum HostKeyStoreError: Error, Equatable {
    case emptyHost
    case emptyKey
    case alreadyPinned(expected: String, actual: String)
    case keychain(OSStatus)
}

/// Persists SHA-256 host-key pins independently from SSH private keys. Call
/// `confirm` only after presenting the first-seen fingerprint to the user.
final class HostKeyStore: @unchecked Sendable {
    static let defaultService = "com.omodachi.ios.ssh.hostkeys"

    private let service: String
    private let records: any KeychainRecordStore

    init(service: String = HostKeyStore.defaultService,
         records: any KeychainRecordStore = SystemKeychainRecordStore.shared) {
        self.service = service
        self.records = records
    }

    func fingerprint(for hostKey: Data) throws -> String {
        guard !hostKey.isEmpty else { throw HostKeyStoreError.emptyKey }
        let digest = SHA256.hash(data: hostKey)
        let encoded = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:" + encoded
    }

    /// Verifies without changing the pin. `.firstSeen` requires explicit user
    /// confirmation; `.mismatch` is a hard rejection until reset is called.
    func verify(host: String, hostKey: Data) throws -> HostKeyVerification {
        let host = try normalizedHost(host)
        let actual = try fingerprint(for: hostKey)
        do {
            guard let stored = try records.load(service: service, account: host) else {
                return .firstSeen(fingerprint: actual)
            }
            return stored == Data(actual.utf8)
                ? .accepted(fingerprint: actual)
                : .mismatch(expected: String(decoding: stored, as: UTF8.self), actual: actual)
        } catch let error as KeychainRecordError {
            throw HostKeyStoreError.keychain(error.statusCode)
        }
    }

    /// Convenience overload for SSH libraries that provide an OpenSSH public
    /// key line instead of the raw key blob. The base64 blob is hashed when it
    /// can be decoded; malformed input is still treated as key material and
    /// therefore cannot silently produce an empty fingerprint.
    func verify(host: String, port: Int, openSSHPublicKey: String) throws -> HostKeyVerification {
        let identity = hostIdentity(host: host, port: port)
        let key = Self.openSSHKeyBlob(openSSHPublicKey)
        return try verify(host: identity, hostKey: key)
    }

    func confirm(host: String, port: Int, openSSHPublicKey: String) throws -> String {
        let identity = hostIdentity(host: host, port: port)
        return try confirm(host: identity, hostKey: Self.openSSHKeyBlob(openSSHPublicKey))
    }

    func reset(host: String, port: Int) throws {
        try reset(host: hostIdentity(host: host, port: port))
    }

    /// Explicitly accepts a first-seen key. It also replaces a pin after the
    /// caller has independently confirmed a reset/rekey operation.
    func confirm(host: String, hostKey: Data) throws -> String {
        let host = try normalizedHost(host)
        let actual = try fingerprint(for: hostKey)
        do {
            if let existing = try records.load(service: service, account: host) {
                let expected = String(decoding: existing, as: UTF8.self)
                if expected == actual { return actual }
                // A changed key must go through the separately named reset
                // operation; this prevents an accidental accept-on-mismatch.
                throw HostKeyStoreError.alreadyPinned(expected: expected, actual: actual)
            }
            try records.save(Data(actual.utf8), service: service, account: host)
            return actual
        } catch let error as HostKeyStoreError {
            throw error
        } catch let error as KeychainRecordError {
            throw HostKeyStoreError.keychain(error.statusCode)
        }
    }

    func pinnedFingerprint(host: String) throws -> String? {
        let host = try normalizedHost(host)
        do {
            guard let value = try records.load(service: service, account: host) else { return nil }
            return String(decoding: value, as: UTF8.self)
        } catch let error as KeychainRecordError {
            throw HostKeyStoreError.keychain(error.statusCode)
        }
    }

    /// Reset is intentionally separate from verification and confirmation.
    /// Callers should present a re-pair/rekey flow before calling `confirm`.
    func reset(host: String) throws {
        let host = try normalizedHost(host)
        do {
            try records.remove(service: service, account: host)
        } catch let error as KeychainRecordError {
            throw HostKeyStoreError.keychain(error.statusCode)
        }
    }

    private func hostIdentity(host: String, port: Int) -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleanHost):\(port)"
    }

    private static func openSSHKeyBlob(_ line: String) -> Data {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, let decoded = Data(base64Encoded: String(parts[1])) else {
            return Data(line.utf8)
        }
        return decoded
    }

    private func normalizedHost(_ host: String) throws -> String {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw HostKeyStoreError.emptyHost }
        return value
    }
}
