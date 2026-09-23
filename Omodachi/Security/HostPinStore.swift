import Foundation

/// What a completed pairing claim hands the companion to pin: the host's own
/// installation identity and the SHA-256 of the DER certificate it serves.
/// Rotating the certificate does not change `hostID`, so a rotation is visible
/// as exactly one thing — a changed fingerprint for a host we still recognize.
struct HostPin: Codable, Equatable, Sendable {
    struct Endpoint: Codable, Equatable, Sendable {
        let host: String
        let port: Int
        var url: URL? { DiscoveredHost.url(host: host, port: port) }
    }
    /// Where this host's terminal is, straight from the claim. SPEC-I deletes
    /// the Setup field that used to ask the user for it, so this is the only
    /// place the SSH surface can learn its address and account.
    struct SSHEndpoint: Codable, Equatable, Sendable {
        let user: String
        let host: String
        let port: Int
    }
    /// What the one approval actually landed. `ssh` false means the terminal
    /// will not open, and a screen that says so beats a terminal that hangs.
    struct Grants: Codable, Equatable, Sendable {
        var companion: Bool
        var media: Bool
        var ssh: Bool
        static let none = Grants(companion: false, media: false, ssh: false)
    }

    let hostID: String
    var hostName: String
    var fingerprintSHA256: String
    var endpoints: [Endpoint]
    /// Both are absent on a pin written before SPEC-I. Decoding keeps working;
    /// the SSH surface falls back to the profile exactly as it did then.
    var ssh: SSHEndpoint?
    var grants: Grants?

    static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validHostID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    var isWellFormed: Bool {
        Self.validHostID(hostID) && Self.validFingerprint(fingerprintSHA256)
            && endpoints.allSatisfy { !$0.host.isEmpty && (1...65535).contains($0.port) }
    }
}

/// Pins live in their own Keychain service, separate from device credentials
/// and SSH material, and are keyed by the same account string the credential
/// uses so one endpoint has exactly one identity.
final class HostPinStore: @unchecked Sendable {
    static let defaultService = "com.omodachi.ios.hostpin"
    private let service: String
    private let records: any KeychainRecordStore

    init(service: String = HostPinStore.defaultService,
         records: any KeychainRecordStore = SystemKeychainRecordStore.shared) {
        self.service = service
        self.records = records
    }

    func load(account: String) -> HostPin? {
        guard let data = try? records.load(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(HostPin.self, from: data)
    }

    func save(_ pin: HostPin, account: String) throws {
        guard pin.isWellFormed, !account.isEmpty else { throw HostPinError.malformed }
        do { try records.save(try JSONEncoder().encode(pin), service: service, account: account) }
        catch let error as KeychainRecordError { throw HostPinError.keychain(error.statusCode) }
    }

    func remove(account: String) throws {
        do { try records.remove(service: service, account: account) }
        catch let error as KeychainRecordError { throw HostPinError.keychain(error.statusCode) }
    }

    /// The user explicitly trusting a rotated certificate. Only the fingerprint
    /// moves: an unknown host, or a different `host_id`, is never "the same host
    /// with a new certificate" and has to pair again.
    func trustRotatedCertificate(hostID: String, fingerprint: String, account: String) throws {
        guard var pin = load(account: account), pin.hostID == hostID,
              HostPin.validFingerprint(fingerprint) else { throw HostPinError.malformed }
        pin.fingerprintSHA256 = fingerprint
        try save(pin, account: account)
    }
}

enum HostPinError: Error, Equatable {
    case malformed
    case keychain(OSStatus)
}
