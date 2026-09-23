import Foundation

/// What this device holds and what the host holds, side by side.
///
/// UX-4. The two used to be impossible to compare from the device. The private
/// half lives in this device's Keychain under an account derived from the
/// profile id; the public half lives in the host's `authorized_keys`, which
/// only `omodachi-host ssh list` prints, on the computer. So the first anyone
/// knew about them disagreeing was a terminal that would not open.
struct SSHKeyReport: Equatable, Sendable {
    /// The identity the host authenticated this credential as. It is not
    /// necessarily what this device calls itself — that gap is UX-3 §1.
    let deviceID: String
    /// This device's own key, as `ssh-keygen -lf` would print it.
    let localFingerprint: String
    /// Every line the host holds for this device, oldest first. Empty means
    /// the host holds none, which is where an adopted credential ends up.
    let hostFingerprints: [String]

    /// Whether the key this device would offer is one the host would accept.
    var matches: Bool { hostFingerprints.contains(localFingerprint) }
}

/// Why the key could not be read or replaced. Every case is one sentence on
/// screen, because a repair that silently did nothing is the failure this
/// whole spec is about.
enum SSHKeyOfferError: Error, Equatable {
    /// This device has no credential or no pin for that host, so there is no
    /// connection its secret may be put on. Pairing is the way back.
    case notPaired
    /// The Keychain would not give up this device's key.
    case noLocalKey
    /// The host answered and said no. `code` is core's own error code.
    case refused(code: String)
    /// Nobody answered, or the answer was not this host.
    case unreachable
}

/// The two calls UX-4 §2 adds, kept behind a protocol so the SSH runtime and
/// the pairing flow can be tested without a host.
protocol SSHKeyOffering: Sendable {
    /// `GET /v1/ssh/key`. Reads, changes nothing.
    func read(account: String, keyAccount: String) async throws -> SSHKeyReport
    /// `PUT /v1/ssh/key`. Replaces the host's line for this device with the
    /// key this device is actually holding.
    func offer(account: String, keyAccount: String) async throws -> SSHKeyReport
}

/// UX-4 §2. The device tells the host which key it is offering.
///
/// The drift this repairs has one mechanism and two ends. The SSH key is kept
/// under `ssh-<profile id>` and the profile lives in `UserDefaults`, which the
/// app container owns; the companion credential and the TLS pin live in the
/// Keychain, which outlives the container. Reinstall the app and the device
/// comes back holding a live credential for a host it is still paired with,
/// and a brand new private key that host has never seen. PAIR-4's adoption
/// path then settles the credential without sending a pairing request — which
/// is right, nothing needs re-issuing — and the key, which went up *with* that
/// request, never goes up at all.
///
/// So this is the one thing that was missing: a way to say "this is the key
/// now" over a connection the host already trusts.
///
/// It is pinned, always, and it carries the companion credential, so it is
/// built the same way `CredentialProbe` is: an ephemeral session with this
/// host's pinned certificate and nothing else. A credential whose pin is gone
/// is never sent anywhere — it is `notPaired`, and pairing is the way back.
actor SSHKeyOffer: SSHKeyOffering {
    private let pins: HostPinStore
    private let credentials: CompanionCredentialStore
    private let keys: SSHKeyStore
    private let makeSession: @Sendable (String) -> URLSession

    init(pins: HostPinStore = HostPinStore(),
         credentials: CompanionCredentialStore = CompanionCredentialStore(),
         keys: SSHKeyStore = SSHKeyStore(),
         makeSession: (@Sendable (String) -> URLSession)? = nil) {
        self.pins = pins
        self.credentials = credentials
        self.keys = keys
        self.makeSession = makeSession ?? { fingerprint in
            let options = URLSessionConfiguration.ephemeral
            options.urlCredentialStorage = nil
            options.httpCookieStorage = nil
            options.httpShouldSetCookies = false
            options.urlCache = nil
            options.requestCachePolicy = .reloadIgnoringLocalCacheData
            options.timeoutIntervalForRequest = 10
            options.timeoutIntervalForResource = 12
            return URLSession(configuration: options,
                              delegate: HostTLSDelegate(pinnedFingerprint: fingerprint),
                              delegateQueue: nil)
        }
    }

    func read(account: String, keyAccount: String) async throws -> SSHKeyReport {
        try await call(account: account, keyAccount: keyAccount, replacing: false)
    }

    func offer(account: String, keyAccount: String) async throws -> SSHKeyReport {
        try await call(account: account, keyAccount: keyAccount, replacing: true)
    }

    // MARK: - The one request both calls make

    private struct Answer: Decodable {
        let device_id: String
        let fingerprint: String?
        let fingerprints: [String]?
    }

    private struct Offer: Encodable { let public_key: String }

    private func call(account rawAccount: String, keyAccount: String, replacing: Bool) async throws -> SSHKeyReport {
        let account = HostAccount.canonical(rawAccount)
        guard let endpoint = URL(string: account), let host = endpoint.host, !host.isEmpty,
              let pin = pins.load(account: account),
              let token = try? credentials.loadToken(account: account), !token.isEmpty,
              token.utf8.count <= 4089,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SSHKeyOfferError.notPaired }
        // The public half is derived from the private half this device is
        // actually going to authenticate with. Reading it from anywhere else
        // would be able to report a key the SSH transport does not hold, which
        // is the exact bug in a different costume.
        guard let line = CompanionSSHKey.publicKeyLine(account: keyAccount, store: keys),
              let local = Self.fingerprint(of: line) else { throw SSHKeyOfferError.noLocalKey }

        var request = URLRequest(url: endpoint.appendingPathComponent("v1/ssh/key"))
        request.httpMethod = replacing ? "PUT" : "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if replacing {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(Offer(public_key: line))
            guard request.httpBody != nil else { throw SSHKeyOfferError.noLocalKey }
        }

        let session = makeSession(pin.fingerprintSHA256)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw SSHKeyOfferError.unreachable }
        // A redirect somewhere else is not this host answering.
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == endpoint.scheme, http.url?.host == endpoint.host,
              http.url?.port == endpoint.port else { throw SSHKeyOfferError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw SSHKeyOfferError.notPaired }
            throw SSHKeyOfferError.refused(code: Self.errorCode(data))
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw SSHKeyOfferError.refused(code: "invalid_response")
        }
        // A PUT answers with the one key it just wrote; a GET answers with the
        // whole inventory. Both are read the same way so the two paths cannot
        // disagree about what the host is holding.
        let held = answer.fingerprints ?? answer.fingerprint.map { [$0] } ?? []
        return SSHKeyReport(deviceID: answer.device_id, localFingerprint: local, hostFingerprints: held)
    }

    /// `SHA256:…` for one OpenSSH public key line, without a private half
    /// anywhere near it.
    static func fingerprint(of line: String) -> String? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, fields[0] == "ssh-ed25519",
              let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        // The blob is `string "ssh-ed25519" || string <32 raw bytes>`; the raw
        // half is the last 32 bytes and `CompanionSSHKey` re-wraps it, so the
        // two implementations of the wrapping cannot drift apart.
        guard blob.count == 51 else { return nil }
        return CompanionSSHKey.fingerprint(blob.suffix(32))
    }

    private static func errorCode(_ data: Data) -> String {
        struct Envelope: Decodable { struct Error: Decodable { let code: String }; let error: Error }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error.code ?? "unavailable"
    }
}
