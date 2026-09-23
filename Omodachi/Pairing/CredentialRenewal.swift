import Foundation

/// CORE-2 §1. What the host says about this device's own credential
/// (`GET /v1/pairing/credential`, `pairing-credential.schema.json`).
struct CredentialStanding: Equatable, Sendable, Decodable {
    let deviceID: String
    let issuedAt: Int
    /// `nil` only for a credential the host has not seen since it started
    /// keeping issue times, which cannot be the one asking.
    let expiresAt: Int?
    let renewableAt: Int?
    /// The host's own answer to "is it inside its last week". The app does not
    /// do this arithmetic itself: the host owns the TTL and the window, and a
    /// device whose clock is wrong would otherwise renew at the wrong time.
    let renewable: Bool
    let superseded: Bool

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", issuedAt = "issued_at", expiresAt = "expires_at"
        case renewableAt = "renewable_at", renewable, superseded
    }
}

/// What one renewal pass did for one host.
enum RenewalOutcome: Equatable, Sendable {
    /// The credential is fine and not in its last week (or already traded in).
    case notDue(expiresAt: Int?)
    /// A new credential was issued; the old one works until the grace ends.
    case renewed(token: String, expiresAt: Int)
    /// The host refused the credential outright. Same cleanup as the launch
    /// probe's refusal, with the host's reason.
    case rejected(CredentialRejection)
    /// The host answered with a code instead of a credential
    /// (`credential_renewal_not_due`, `plugin_credential`, …). Nothing changes;
    /// the next pass asks again.
    case refused(code: String)
    /// A host from before CORE-2: it has no credential routes. Nothing to do.
    case unsupported
    /// Nobody answered. Nothing is touched.
    case unreachable
}

/// CORE-2 §1. Keeps a credential alive without the person ever seeing it.
///
/// A device credential lives 30 days. In its last 7 the host will trade it for
/// a fresh one (`POST /v1/pairing/renew`), and keeps the old one working for
/// 24 h so a reply lost on the way back costs nothing — the device still holds
/// a working credential and simply asks again next time. The app asks every
/// time it comes to the front and every 12 hours (`HostCredentialGate`).
///
/// Like `CredentialProbe`, the token only ever goes onto a connection whose
/// certificate this device pinned.
actor CredentialRenewer {
    private let endpoint: URL
    private let session: URLSession
    private let tls: HostTLSDelegate

    init(endpoint: URL, pinnedFingerprint: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        let delegate = HostTLSDelegate(pinnedFingerprint: pinnedFingerprint)
        tls = delegate
        if let session { self.session = session }
        else {
            let options = URLSessionConfiguration.ephemeral
            options.urlCredentialStorage = nil
            options.httpCookieStorage = nil
            options.httpShouldSetCookies = false
            options.urlCache = nil
            options.requestCachePolicy = .reloadIgnoringLocalCacheData
            options.timeoutIntervalForRequest = 10
            options.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: options, delegate: delegate, delegateQueue: nil)
        }
    }

    /// One pass: read the standing, and renew when the host says it is time.
    func run(token: String) async -> RenewalOutcome {
        guard Self.validToken(token) else { return .rejected(.unknown) }
        let standing: CredentialStanding
        switch await send("GET", path: "v1/pairing/credential", token: token) {
        case let .answer(status, data):
            switch status {
            case 200..<300:
                guard let value = try? JSONDecoder().decode(CredentialStanding.self, from: data) else {
                    return .refused(code: "invalid_response")
                }
                standing = value
            case 401, 403: return .rejected(CredentialRejection.from(body: data))
            case 404, 405: return .unsupported
            default: return .refused(code: PairingClient.errorCode(data) ?? "unavailable")
            }
        case .noAnswer: return .unreachable
        }
        guard standing.renewable, !standing.superseded else { return .notDue(expiresAt: standing.expiresAt) }
        switch await send("POST", path: "v1/pairing/renew", token: token, body: Data("{}".utf8)) {
        case let .answer(status, data):
            switch status {
            case 200..<300:
                struct Renewed: Decodable {
                    let deviceID: String
                    let credential: String
                    let credentialExpiresAt: Int
                    enum CodingKeys: String, CodingKey {
                        case deviceID = "device_id", credential, credentialExpiresAt = "credential_expires_at"
                    }
                }
                guard let renewed = try? JSONDecoder().decode(Renewed.self, from: data),
                      renewed.deviceID == standing.deviceID, Self.validToken(renewed.credential),
                      renewed.credential != token,
                      TimeInterval(renewed.credentialExpiresAt) > Date().timeIntervalSince1970
                else { return .refused(code: "invalid_response") }
                return .renewed(token: renewed.credential, expiresAt: renewed.credentialExpiresAt)
            case 401, 403: return .rejected(CredentialRejection.from(body: data))
            case 404, 405: return .unsupported
            default: return .refused(code: PairingClient.errorCode(data) ?? "unavailable")
            }
        case .noAnswer: return .unreachable
        }
    }

    private enum Reply { case answer(Int, Data), noAnswer }

    private func send(_ method: String, path: String, token: String, body: Data? = nil) async -> Reply {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            // A redirect to somewhere else is not this host answering.
            guard let http = response as? HTTPURLResponse, data.count <= 16384,
                  http.url?.scheme == endpoint.scheme, http.url?.host == endpoint.host,
                  http.url?.port == endpoint.port else { return .noAnswer }
            return .answer(http.statusCode, data)
        } catch {
            return .noAnswer
        }
    }

    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 4089
            && !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
