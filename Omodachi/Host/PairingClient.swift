import Foundation

struct PairingReceipt: Equatable, Sendable {
    enum Status: String, Sendable { case pending, claimed }
    let requestID: String
    let deviceID: String
    let deviceName: String
    let expiresAt: Date
    let status: Status
}

enum PairingError: Error, LocalizedError, Equatable {
    case invalidInput, existingCredential, unavailable, rejectedOrExpired, invalidResponse, transport, keychain, cancelled
    /// PAIR-2: this host is locked to `pairing_mode = invite`. It is the only
    /// answer that puts an invitation field on screen, and on a default host it
    /// never arrives.
    case invitationRequired
    /// PAIR-5 §5. `409 pairing_device_exists`: the computer still holds an
    /// authorization for *this* device id while this device holds no
    /// credential — which is exactly where `simctl keychain reset`, a restored
    /// backup or a wiped Keychain leaves it. Neither side can fix it alone:
    /// the app cannot revoke without a credential. So the sentence says what
    /// the computer is still holding, names the device so it can be found in a
    /// list, and points at where that list is. (The command that does the same
    /// thing from a terminal is in the PAIR-5 report, not in the app.)
    case deviceAlreadyRegistered(deviceID: String)
    var errorDescription: String? {
        switch self {
        case .invalidInput: Strings.pairErrorInvalidInput
        // PAIR-4 §3: the dead end is gone. The flow settles a credential it
        // already holds before it sends anything (`adoptStoredCredential`), so
        // this is only ever the tail of a race — and it names the same tap
        // rather than a Settings page an unpaired app cannot reach.
        case .existingCredential: Strings.pairErrorExistingCredential
        case .unavailable: Strings.pairErrorUnavailable
        case .rejectedOrExpired: Strings.pairErrorRejected
        case .invalidResponse: Strings.pairErrorInvalidResponse
        case .transport: Strings.pairErrorTransport
        case .keychain: Strings.pairErrorKeychain
        case .cancelled: Strings.pairErrorCancelled
        case .invitationRequired: Strings.pairErrorInvitationRequired
        case let .deviceAlreadyRegistered(deviceID):
            Strings.pairErrorDeviceRegistered(deviceID)
        }
    }
}

/// PAIR-2: the request carries no invitation. The host's `pairing_mode` decides
/// whether it needs one, and only a host that says `pairing_invitation_required`
/// ever gets one — `begin` takes it as an optional argument for that one case.
///
/// The claim secret lives only in memory. No automatic approval, authorization
/// header, redirect, credential overwrite, or TLS exception.
actor PairingClient {
    let configuration: CompanionHostConfiguration
    private let records: any KeychainRecordStore
    private let service: String
    private let session: URLSession
    /// Pairing is the one moment a companion has nothing pinned. The delegate
    /// therefore accepts the certificate and reports it, exactly like SSH's
    /// first connection; only the claim below turns it into trust.
    private let tls = HostTLSDelegate(pinnedFingerprint: nil)
    /// The fingerprint the host presented during this handshake, shown to the
    /// user so they can compare it with `omodachi-host tls show`.
    private(set) var observedFingerprint: String?
    private var generation = UUID()
    private var pending: Pending?
    private struct Pending {
        let receipt: PairingReceipt
        let secret: String
    }
    private struct Response: Decodable {
        struct Endpoint: Decodable { let host: String; let port: Int }
        let requestID: String
        let deviceID: String
        let deviceName: String
        let status: String
        let expiresAt: Int
        let requestSecret: String?
        let credential: String?
        let issuedAt: Int?
        let credentialExpiresAt: Int?
        /// The host identity a claim hands over for the companion to pin.
        let hostID: String?
        let hostName: String?
        let fingerprint: String?
        let endpoints: [Endpoint]?
        /// SPEC-I: what the one approval actually landed, and where the
        /// terminal it granted lives.
        struct Grants: Decodable { let companion: Bool; let media: Bool; let ssh: Bool }
        struct SSH: Decodable { let user: String?; let host: String?; let port: Int? }
        let grants: Grants?
        let ssh: SSH?
        enum CodingKeys: String, CodingKey {
            case requestID = "request_id", deviceID = "device_id", deviceName = "device_name", status
            case expiresAt = "expires_at", requestSecret = "request_secret", credential
            case issuedAt = "issued_at", credentialExpiresAt = "credential_expires_at"
            case hostID = "host_id", hostName = "host_name", fingerprint = "tls_fingerprint_sha256", endpoints
            case grants, ssh
        }
    }
    private let pins: HostPinStore
    init(endpoint: URL, records: any KeychainRecordStore = SystemKeychainRecordStore.shared,
         service: String = CompanionCredentialStore.defaultService,
         pins: HostPinStore = HostPinStore(), session: URLSession? = nil) throws {
        configuration = try CompanionHostConfiguration(endpoint: endpoint)
        self.records = records
        self.service = service
        self.pins = pins
        if let session { self.session = session }
        else {
            let options = URLSessionConfiguration.ephemeral
            options.urlCredentialStorage = nil
            options.httpCookieStorage = nil
            options.httpShouldSetCookies = false
            options.urlCache = nil
            options.requestCachePolicy = .reloadIgnoringLocalCacheData
            options.timeoutIntervalForRequest = 15
            options.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: options, delegate: tls, delegateQueue: nil)
        }
    }
    static func validSecret(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func validDeviceID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alnum(_ c: UInt8) -> Bool { (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) }
        return (1...128).contains(bytes.count) && alnum(bytes[0]) && bytes.allSatisfy { alnum($0) || [46, 95, 58, 45].contains($0) }
    }
    /// One line of OpenSSH, checked here so a host never has to refuse the
    /// request that the waiting card already promised a terminal for.
    static func validPublicKey(_ value: String) -> Bool {
        let fields = value.split(separator: " ", omittingEmptySubsequences: true)
        guard (2...3).contains(fields.count), value.utf8.count <= 16384,
              !value.contains(where: { $0.isNewline }), fields[0] == "ssh-ed25519" else { return false }
        let body = fields[1]
        return (32...16384).contains(body.utf8.count)
            && Data(base64Encoded: String(body)) != nil
    }
    private static func validRequestID(_ value: String) -> Bool {
        value.hasPrefix("pair_") && value.utf8.count == 37 && value.dropFirst(5).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func ensureEmptyCredential() throws {
        do {
            if try records.load(service: service, account: configuration.account) != nil { throw PairingError.existingCredential }
        } catch let error as PairingError { throw error }
        catch { throw PairingError.keychain }
    }
    func begin(deviceID: String, deviceName: String, sshPublicKey: String? = nil,
               invitation: String? = nil) async throws -> PairingReceipt {
        pending = nil
        generation = UUID()
        let current = generation
        guard invitation.map(Self.validSecret) ?? true, Self.validDeviceID(deviceID),
              (1...80).contains(deviceName.unicodeScalars.count),
              !deviceName.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PairingError.invalidInput }
        try ensureEmptyCredential()
        // One request, three grants. The public half of a key pair costs
        // nothing to carry, and carrying it is what removes the second
        // approval the old flow asked the user for (docs/pairing.md).
        var body = ["device_id": deviceID, "device_name": deviceName]
        if let invitation { body["invitation"] = invitation }
        if let sshPublicKey, Self.validPublicKey(sshPublicKey) { body["ssh_public_key"] = sshPublicKey }
        let response = try await post(path: "v1/pairing/requests", body: body, deviceID: deviceID)
        observedFingerprint = tls.observedFingerprint
        try Task.checkCancellation()
        guard current == generation else { throw PairingError.cancelled }
        let expiry = Date(timeIntervalSince1970: TimeInterval(response.expiresAt))
        guard Self.validRequestID(response.requestID), response.deviceID == deviceID, response.deviceName == deviceName,
              response.status == "pending", response.credential == nil,
              let secret = response.requestSecret, Self.validSecret(secret),
              expiry > Date(), expiry.timeIntervalSinceNow <= 305 else { throw PairingError.invalidResponse }
        let receipt = PairingReceipt(requestID: response.requestID, deviceID: deviceID, deviceName: deviceName, expiresAt: expiry, status: .pending)
        pending = Pending(receipt: receipt, secret: secret)
        return receipt
    }
    func claim() async throws -> PairingReceipt {
        guard let request = pending else { throw PairingError.cancelled }
        guard request.receipt.expiresAt > Date() else { pending = nil; throw PairingError.rejectedOrExpired }
        let current = generation
        do {
            try ensureEmptyCredential()
            let response = try await post(path: "v1/pairing/requests/\(request.receipt.requestID)/claim", body: ["request_secret": request.secret])
            let observed = tls.observedFingerprint
            observedFingerprint = observed
            try Task.checkCancellation()
            guard current == generation else { throw PairingError.cancelled }
            guard response.requestID == request.receipt.requestID, response.deviceID == request.receipt.deviceID,
                  response.deviceName == request.receipt.deviceName,
                  response.expiresAt == Int(request.receipt.expiresAt.timeIntervalSince1970),
                  request.receipt.expiresAt > Date(), response.requestSecret == nil else { throw PairingError.invalidResponse }
            if response.status == "pending" {
                guard response.credential == nil else { throw PairingError.invalidResponse }
                return request.receipt
            }
            guard response.status == "claimed", let token = response.credential,
                  !token.isEmpty, token.utf8.count <= 4089,
                  !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let issued = response.issuedAt, let expires = response.credentialExpiresAt,
                  issued > 0, expires > issued, TimeInterval(expires) > Date().timeIntervalSince1970 else { throw PairingError.invalidResponse }
            // The host identity is pinned at the instant the credential arrives,
            // which is the only moment discovery or /health could be trusted.
            guard let hostID = response.hostID, let fingerprint = response.fingerprint,
                  HostPin.validHostID(hostID), HostPin.validFingerprint(fingerprint),
                  observed == nil || observed == fingerprint else { throw PairingError.invalidResponse }
            pending = nil
            // Atomic add, unlike saveToken's explicit replacement behavior in Setup.
            do {
                guard try records.insertIfAbsent(Data(token.utf8), service: service, account: configuration.account) else { throw PairingError.existingCredential }
            } catch let error as PairingError { throw error }
            catch { throw PairingError.keychain }
            do {
                try pins.save(HostPin(hostID: hostID, hostName: response.hostName ?? configuration.endpoint.host ?? "",
                                      fingerprintSHA256: fingerprint,
                                      endpoints: (response.endpoints ?? []).map { .init(host: $0.host, port: $0.port) },
                                      ssh: Self.sshEndpoint(response.ssh),
                                      grants: response.grants.map {
                                          .init(companion: $0.companion, media: $0.media, ssh: $0.ssh)
                                      }),
                              account: configuration.account)
            } catch { throw PairingError.keychain }
            return PairingReceipt(requestID: request.receipt.requestID, deviceID: request.receipt.deviceID,
                                  deviceName: request.receipt.deviceName, expiresAt: request.receipt.expiresAt, status: .claimed)
        } catch {
            pending = nil // A lost claim response may already have consumed its one use.
            throw error
        }
    }
    /// A host that answered without an SSH target leaves the surface where it
    /// was before SPEC-I: resolving from the profile. Half a target is no
    /// target, so a missing user or host discards both rather than guessing.
    private static func sshEndpoint(_ value: Response.SSH?) -> HostPin.SSHEndpoint? {
        guard let value, let user = value.user, let host = value.host,
              SSHTargetResolver.isValidAccount(user), SSHTargetResolver.isValidHost(host) else { return nil }
        let port = value.port ?? 22
        guard (1...65535).contains(port) else { return nil }
        return HostPin.SSHEndpoint(user: user, host: host, port: port)
    }

    func cancel() { generation = UUID(); pending = nil }
    /// `http-error.schema.json`: one bounded code, and nothing else is read.
    static func errorCode(_ data: Data) -> String? {
        struct Envelope: Decodable { struct Error: Decodable { let code: String }; let error: Error }
        guard let code = try? JSONDecoder().decode(Envelope.self, from: data).error.code,
              code.utf8.count <= 64 else { return nil }
        return code
    }
    private func post(path: String, body: [String: String], deviceID: String = "") async throws -> Response {
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, data.count <= 16384,
                  http.url?.scheme == configuration.endpoint.scheme, http.url?.host == configuration.endpoint.host,
                  http.url?.port == configuration.endpoint.port else { throw PairingError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                do { return try JSONDecoder().decode(Response.self, from: data) }
                catch { throw PairingError.invalidResponse }
            // A locked host is the one refusal with somewhere to go, so it is
            // the one refusal read out of the body rather than off the status.
            case 403 where Self.errorCode(data) == "pairing_invitation_required":
                throw PairingError.invitationRequired
            // PAIR-5 §5: the other refusal that has somewhere to go, and the
            // only one whose next step is on the computer.
            case 409 where Self.errorCode(data) == "pairing_device_exists":
                throw PairingError.deviceAlreadyRegistered(deviceID: deviceID)
            case 400, 401, 403, 404, 409, 410: throw PairingError.rejectedOrExpired
            case 429, 503: throw PairingError.unavailable
            default: throw PairingError.transport
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as PairingError { throw error }
        catch { throw PairingError.transport }
    }
}
