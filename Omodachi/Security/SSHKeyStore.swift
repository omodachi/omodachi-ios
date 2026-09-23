import Foundation
import Security

/// A small abstraction around Keychain generic-password records. It keeps the
/// public stores testable without ever requiring tests to write the user's
/// real Keychain.
protocol KeychainRecordStore: Sendable {
    func save(_ value: Data, service: String, account: String) throws
    func insertIfAbsent(_ value: Data, service: String, account: String) throws -> Bool
    func load(service: String, account: String) throws -> Data?
    func remove(service: String, account: String) throws
}

final class SystemKeychainRecordStore: KeychainRecordStore, @unchecked Sendable {
    static let shared = SystemKeychainRecordStore()

    private init() {}

    func save(_ value: Data, service: String, account: String) throws {
        // Update preserves the old credential if a replacement fails. Never
        // delete first: a failed add must not destroy an existing key.
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let query = identity(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainRecordError.status(status) }
        if try insertIfAbsent(value, service: service, account: account) { return }
        let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard retry == errSecSuccess else { throw KeychainRecordError.status(retry) }
    }

    func insertIfAbsent(_ value: Data, service: String, account: String) throws -> Bool {
        var query = identity(service: service, account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = value
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw KeychainRecordError.status(status) }
        return true
    }

    private func identity(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainRecordError.status(status) }
        return result as? Data
    }

    func remove(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainRecordError.status(status)
        }
    }
}

enum KeychainRecordError: Error, Equatable {
    case status(OSStatus)
}

enum SSHKeyStoreError: Error, Equatable {
    case emptyKey
    case emptyAccount
    case unreadableFile
    case keychain(OSStatus)
}

/// Stores an SSH private key on this device only. Passwords are deliberately
/// outside this type: authentication is delegated to the reviewed SSH layer.
final class SSHKeyStore: @unchecked Sendable {
    static let defaultService = "app.omodachi.ssh.keys"

    private let service: String
    private let records: any KeychainRecordStore

    init(service: String = SSHKeyStore.defaultService,
         records: any KeychainRecordStore = SystemKeychainRecordStore.shared) {
        self.service = service
        self.records = records
    }

    func savePrivateKey(_ key: Data, account: String) throws {
        guard !key.isEmpty else { throw SSHKeyStoreError.emptyKey }
        let account = try normalizedAccount(account)
        do {
            try records.save(key, service: service, account: account)
        } catch let error as KeychainRecordError {
            throw SSHKeyStoreError.keychain(error.statusCode)
        }
    }

    /// Call this from a UIDocumentPicker completion handler. The security
    /// scoped URL is read immediately and only the key bytes enter Keychain.
    func importPrivateKey(from url: URL, account: String) throws {
        guard url.isFileURL else { throw SSHKeyStoreError.unreadableFile }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let key = try Data(contentsOf: url, options: [])
            try savePrivateKey(key, account: account)
        } catch let error as SSHKeyStoreError {
            throw error
        } catch {
            throw SSHKeyStoreError.unreadableFile
        }
    }

    func loadPrivateKey(account: String) throws -> Data? {
        let account = try normalizedAccount(account)
        do {
            return try records.load(service: service, account: account)
        } catch let error as KeychainRecordError {
            throw SSHKeyStoreError.keychain(error.statusCode)
        }
    }

    func removePrivateKey(account: String) throws {
        let account = try normalizedAccount(account)
        do {
            try records.remove(service: service, account: account)
        } catch let error as KeychainRecordError {
            throw SSHKeyStoreError.keychain(error.statusCode)
        }
    }

    private func normalizedAccount(_ account: String) throws -> String {
        let value = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SSHKeyStoreError.emptyAccount }
        return value
    }
}

extension KeychainRecordError {
    var statusCode: OSStatus {
        switch self { case let .status(status): return status }
    }
}
