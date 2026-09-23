import Foundation

/// `GET /health`: the anchor, not authorization (`docs/pairing.md`).
///
/// It is what lets a host the user typed become a row like any discovered one,
/// and it is where the fingerprint on the waiting card comes from — the same
/// value the claim will pin, rather than the 16-hex Bonjour `fp` prefix the
/// discovery document says is "never the value a client pins" (A-36).
///
/// Reading this establishes nothing. Anyone on the LAN can serve a document
/// that looks exactly like it; only a successful claim turns it into trust.
struct HostHealth: Equatable, Sendable {
    let hostID: String?
    let hostName: String?
    let fingerprint: String?
    /// PAIR-2 `pairing.mode`. `invite` is the only value that changes anything
    /// a user sees: the list row says "需要邀请" instead of "未配对". A host from
    /// before PAIR-2 does not publish it, and is treated as open — which is
    /// what it is, once it is updated, and is only ever a label either way.
    var invitationOnly = false
}

enum HostHealthError: Error, LocalizedError, Equatable {
    case unreachable, notAnOmodachiHost

    var errorDescription: String? {
        switch self {
        case .unreachable: Strings.probeUnreachable
        case .notAnOmodachiHost: Strings.probeNotOmodachi
        }
    }
}

actor HostHealthProbe {
    private let session: URLSession
    private let tls = HostTLSDelegate(pinnedFingerprint: nil)

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let options = URLSessionConfiguration.ephemeral
            options.urlCredentialStorage = nil
            options.httpCookieStorage = nil
            options.httpShouldSetCookies = false
            options.urlCache = nil
            options.requestCachePolicy = .reloadIgnoringLocalCacheData
            options.timeoutIntervalForRequest = 8
            options.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: options, delegate: tls, delegateQueue: nil)
        }
    }

    private struct Document: Decodable {
        struct Pairing: Decodable { let mode: String? }
        let contractRevision: String?
        let service: String?
        let hostID: String?
        let hostName: String?
        let fingerprint: String?
        let pairing: Pairing?
        enum CodingKeys: String, CodingKey {
            case contractRevision = "contract_revision", service
            case hostID = "host_id", hostName = "host_name"
            case fingerprint = "tls_fingerprint_sha256", pairing
        }
    }

    func read(_ endpoint: URL) async throws -> HostHealth {
        var request = URLRequest(url: endpoint.appendingPathComponent("health"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw HostHealthError.unreachable }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 16384,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.service == "omodachid" else { throw HostHealthError.notAnOmodachiHost }
        let fingerprint = document.fingerprint.flatMap { HostPin.validFingerprint($0) ? $0 : nil }
        return HostHealth(hostID: document.hostID.flatMap { HostPin.validHostID($0) ? $0 : nil },
                          hostName: document.hostName, fingerprint: fingerprint,
                          invitationOnly: document.pairing?.mode == "invite")
    }
}
