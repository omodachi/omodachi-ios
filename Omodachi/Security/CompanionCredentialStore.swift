import Foundation

/// Companion device credentials use a separate Keychain service from both SSH
/// private keys and host-key pins. Tokens never enter UserDefaults or logs.
final class CompanionCredentialStore: CompanionCredentialProviding, @unchecked Sendable {
    static let defaultService = "app.omodachi.companion"

    private let service: String
    private let records: any KeychainRecordStore

    init(service: String = CompanionCredentialStore.defaultService,
         records: any KeychainRecordStore = SystemKeychainRecordStore.shared) {
        self.service = service
        self.records = records
    }

    func loadToken(account: String) throws -> String? {
        let account = try normalizedAccount(account)
        do {
            guard let data = try records.load(service: service, account: account) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch let error as KeychainRecordError {
            throw CompanionCredentialStoreError.keychain(error.statusCode)
        }
    }

    func saveToken(_ token: String, account: String) throws {
        let account = try normalizedAccount(account)
        guard !token.isEmpty else { throw CompanionCredentialStoreError.emptyToken }
        do {
            try records.save(Data(token.utf8), service: service, account: account)
        } catch let error as KeychainRecordError {
            throw CompanionCredentialStoreError.keychain(error.statusCode)
        }
    }

    func removeToken(account: String) throws {
        let account = try normalizedAccount(account)
        do {
            try records.remove(service: service, account: account)
        } catch let error as KeychainRecordError {
            throw CompanionCredentialStoreError.keychain(error.statusCode)
        }
    }

    private func normalizedAccount(_ account: String) throws -> String {
        let value = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CompanionCredentialStoreError.emptyAccount }
        return value
    }
}

enum CompanionCredentialStoreError: Error, Equatable {
    case emptyAccount
    case emptyToken
    case keychain(OSStatus)
}
