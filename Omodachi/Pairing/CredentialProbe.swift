import Foundation

/// CORE-2 §1. Why the host refused a credential, as its 401 body says
/// (`http-error.schema.json` `error.reason`). Each has its own next step, which
/// is the whole reason the host started saying which one it is:
///
/// * `expired` — past its 30 days (or the grace after a renewal). One ordinary
///   pairing request and one Approve on the computer bring it back.
/// * `revoked` / `purged` — somebody took it back on the computer. The app
///   says so and goes back to the host list; it does not ask again by itself.
/// * `unknown` — not a credential that host signed, or a host from before
///   CORE-2 that does not say. The PAIR-5 cleanup, unchanged.
enum CredentialRejection: String, Equatable, Sendable, CaseIterable {
    case expired = "credential_expired"
    case revoked = "credential_revoked"
    case purged = "device_purged"
    case unknown = "unknown_credential"

    /// The `reason` from a 401 body, or `.unknown` when there is none.
    static func from(body data: Data) -> CredentialRejection {
        struct Envelope: Decodable { struct Error: Decodable { let reason: String? }; let error: Error }
        guard let reason = try? JSONDecoder().decode(Envelope.self, from: data).error.reason else { return .unknown }
        return CredentialRejection(rawValue: reason) ?? .unknown
    }

    /// Revoked and purged are one thing to the person holding the device.
    var tookBack: Bool { self == .revoked || self == .purged }
}

/// What the host said about a credential this device already holds.
enum CredentialVerdict: Equatable, Sendable {
    /// The host answered an authenticated read. The credential is live.
    case live
    /// The host answered 401/403: this credential was refused, and the host
    /// said why when it could (CORE-2). It is rubbish and can go.
    case rejected(CredentialRejection)
    /// Nobody answered, or the answer was not one of the two above. Nothing is
    /// deleted on this verdict — an unreachable host is not a revocation.
    case unreachable

}

/// PAIR-4 §1. One authenticated, side-effect-free GET, which is the only way to
/// answer the question an orphan credential raises: does the host still know
/// it?
///
/// `GET /v1/state` is the same snapshot `HomeStore` reads the moment it
/// connects (`omodachi-core` `network.py:135`, `add_get("/v1/{name}")`). It
/// takes no parameters, starts nothing and changes nothing, and it answers 200
/// on any host this device can actually use — unlike `/v1/remote/capabilities`,
/// which a host with no graphical session refuses for reasons that have
/// nothing to do with the credential. Core's boundary answers a revoked or
/// unknown bearer token with **401 `permission_denied`** (`network.py:59`).
///
/// It is pinned, always. The credential is this device's secret, so it only
/// ever goes onto a connection whose certificate this device already pinned;
/// a credential whose pin is gone is never probed, it is discarded.
actor CredentialProbe {
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
            options.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: options, delegate: delegate, delegateQueue: nil)
        }
    }

    func check(token: String) async -> CredentialVerdict {
        guard !token.isEmpty, token.utf8.count <= 4089,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return .rejected(.unknown) }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/state"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            // A redirect to somewhere else is not this host answering.
            guard let http = response as? HTTPURLResponse,
                  http.url?.scheme == endpoint.scheme, http.url?.host == endpoint.host,
                  http.url?.port == endpoint.port else { return .unreachable }
            switch http.statusCode {
            case 200..<300: return .live
            case 401, 403: return .rejected(CredentialRejection.from(body: data))
            default: return .unreachable
            }
        } catch {
            return .unreachable
        }
    }
}
