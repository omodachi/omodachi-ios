import CryptoKit
import Foundation

enum HostTLSFailure: Error, Equatable {
    /// The presented leaf is not the certificate this device pinned. There is no
    /// fallback and no "continue anyway": the user must trust the new one first.
    case certificateChanged(observed: String, pinned: String)
    case noCertificate
}

/// Pinning, and only pinning, decides whether we talk to a host. The system
/// trust evaluation is irrelevant here — the host certificate is self-signed by
/// design (docs/pairing.md), so a CA verdict would reject every real host and
/// accept any LAN peer with a public CA name.
final class HostTLSDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
    /// `nil` means "not paired yet": the pairing handshake accepts whatever the
    /// host serves and reports its fingerprint so the claim can pin it.
    private let lock = NSLock()
    private var pinnedFingerprint: String?
    private var observed: String?
    private var mismatch: HostTLSFailure?

    init(pinnedFingerprint: String?) {
        self.pinnedFingerprint = pinnedFingerprint
    }

    /// The fingerprint the host actually presented on the last handshake.
    var observedFingerprint: String? { lock.withLock { observed } }
    /// Set when a handshake was refused, so a transport error can be reported as
    /// the specific thing it was.
    var lastFailure: HostTLSFailure? { lock.withLock { mismatch } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    /// Credentials and task data stay bound to the exact host that was paired.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = Self.leafFingerprint(trust) else {
            lock.withLock { mismatch = .noCertificate }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard accepts(leaf: leaf) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// The whole pinning decision, with no SecTrust plumbing around it.
    /// `nil` pinned means the pairing handshake: report, do not judge.
    func accepts(leaf: String) -> Bool {
        lock.withLock {
            observed = leaf
            guard let expected = pinnedFingerprint else { mismatch = nil; return true }
            guard Self.constantTimeEqual(expected, leaf) else {
                mismatch = .certificateChanged(observed: leaf, pinned: expected)
                return false
            }
            mismatch = nil
            return true
        }
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
