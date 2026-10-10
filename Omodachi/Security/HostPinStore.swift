import Foundation

/// What a completed pairing claim hands the companion to pin: the host's own
/// installation identity and the SHA-256 of the DER certificate it serves.
/// Rotating the certificate does not change `hostID`, so a rotation is visible
/// as exactly one thing — a changed fingerprint for a host we still recognize.
struct HostPin: Codable, Equatable, Sendable {
    struct Endpoint: Codable, Equatable, Sendable {
        let host: String
        let port: Int
        /// TAIL-2: `lan`, `mdns` or `tailnet`, as core typed it. Absent on a
        /// pin from before TAIL-2 and from a core that does not type them; the
        /// kind is then read off the address (`HostRoads.kind(of:)`).
        var kind: RoadKind? = nil
        var url: URL? { DiscoveredHost.url(host: host, port: port) }
        var road: HostRoad { HostRoad(host: host, port: port, kind: kind) }
    }
    /// Where this host's terminal is, straight from the claim. SPEC-I deletes
    /// the Setup field that used to ask the user for it, so this is the only
    /// place the SSH surface can learn its address and account.
    struct SSHEndpoint: Codable, Equatable, Sendable {
        let user: String
        let host: String
        let port: Int
        /// TAIL-2 P0-4: every address the terminal can be reached on, typed,
        /// so it can follow whichever road the companion connection is on.
        /// `host` stays the LAN address core always put first.
        var hosts: [HostRoad]? = nil
        /// TAIL-2 P1-1: Tailscale SSH is on at the host. Over the tailnet port
        /// 22 is answered by tailscaled, not sshd, so this device's key and
        /// approval do not decide anything there.
        var tailscaleSSH: Bool? = nil
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
    /// TAIL-3b. The one road this device reaches the host on: Tailscale, by
    /// its MagicDNS name, or this Wi-Fi, by its address. It is the address
    /// pairing used, and it changes only when the user moves a Wi-Fi host to
    /// Tailscale in Settings — never on its own. A pin from before TAIL-3b has
    /// none, and the account it is stored under says which (`road(account:)`).
    var road: HostRoad? = nil

    static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validHostID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// TAIL-2: every address this host published, typed.
    var roads: [HostRoad] { endpoints.map(\.road) }

    /// TAIL-3b. The road, or — for a pin written before there was one — the
    /// road the account names: `*.ts.net` is Tailscale, anything else Wi-Fi.
    func road(account: String) -> HostRoad {
        road ?? HostRoads.road(forAccount: account) ?? HostRoad(host: "", port: 8099, kind: .lan)
    }

    /// The MagicDNS name this host published, if any: the one tailnet road
    /// this app can dial (ATS).
    var tailnetName: String? {
        roads.first { $0.kind == .tailnet && HostRoads.isMagicDNSName($0.host) }?.host
    }

    var isWellFormed: Bool {
        Self.validHostID(hostID) && Self.validFingerprint(fingerprintSHA256)
            && endpoints.allSatisfy { !$0.host.isEmpty && (1...65535).contains($0.port) }
            && (road.map { !$0.host.isEmpty && (1...65535).contains($0.port) } ?? true)
    }
}

/// Pins live in their own Keychain service, separate from device credentials
/// and SSH material, and are keyed by the same account string the credential
/// uses so one endpoint has exactly one identity.
final class HostPinStore: @unchecked Sendable {
    static let defaultService = "app.omodachi.hostpin"
    private let service: String
    private let records: any KeychainRecordStore

    init(service: String = HostPinStore.defaultService,
         records: any KeychainRecordStore = SystemKeychainRecordStore.shared) {
        self.service = service
        self.records = records
    }

    func load(account: String) -> HostPin? {
        // TAIL-3b: a pin from before the one-road model decodes with no road;
        // `HostPin.road(account:)` reads it off the account it is stored under.
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
