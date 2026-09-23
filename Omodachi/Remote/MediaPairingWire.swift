import Foundation

/// `/v1/media/pairing/*` exactly as `omodachi-core/src/omodachi_core/media_pairing.py`
/// serves it. The bridge is a relay: the app already holds a device credential,
/// so all core does is carry this device's four-digit Moonlight PIN to the
/// managed Sunshine fork's own pairing operations and follow the attempt to a
/// terminal state. There is no Sunshine web page, no password, no second
/// identity and no PIN for the user to copy anywhere.

/// The unique pending request the fork holds for this device's certificate.
/// The fork suspends its `getservercert` response until the PIN, so the request
/// UUID is otherwise invisible to the app.
struct MediaPairingRequestDTO: Decodable, Equatable, Sendable {
    let request_id: String
    let client_cert_sha256: String
    let status: String
    let expires_in_ms: Int
}

/// One attempt, from `awaiting_local_approval` through to `paired`.
struct MediaPairingAttemptDTO: Decodable, Equatable, Sendable {
    let attempt_id: String
    let device_id: String
    let request_id: String
    let client_cert_sha256: String
    let status: String
    let reason: String
    let expires_in_ms: Int
    let paired: Bool
    let media_authorized: Bool
    let certificate_revocation_supported: Bool

    /// `paired` is the only success: the attempt reached `paired` **and** the
    /// binding and the device allowance agree. Everything else is in flight or
    /// over.
    var isTerminal: Bool {
        ["paired", "failed", "cancelled", "expired", "revocation_pending"].contains(status)
    }
    /// How long the host will still hold this request. A wait with no end in
    /// sight is indistinguishable from one that is already over.
    var remainingSeconds: Int { max(0, Int((Double(expires_in_ms) / 1000).rounded())) }

    /// PAIR-3: the attempt is stopped on the host waiting for a local Approve.
    /// It is not a failure and not a timeout - it is a thing somebody has to
    /// press, and the app has to say where.
    var needsLocalApproval: Bool { status == "awaiting_local_approval" }
    /// The one-time code was already spent, so no Approve can rescue this
    /// attempt; pairing has to start again from the device.
    var needsPinResubmission: Bool { reason == "pin_resubmission_required" }

    /// What the user is waiting on, in the words of the thing they must do.
    var progress: String {
        if needsPinResubmission { return ReasonText.message("pin_resubmission_required", domain: .media) }
        return switch status {
        // PAIR-3: the panel has a card for this now, so the line says which
        // button, where. Before, this was a countdown to a `cancelled` the
        // user had no way to prevent.
        case "awaiting_local_approval": Strings.mediaPairingAwaitingApproval(Format.count(remainingSeconds))
        case "submitting", "pending": Strings.mediaPairingPinDelivered(Format.count(remainingSeconds))
        case "awaiting_client_proof": Strings.mediaPairingExchanging
        case "paired": paired ? Strings.mediaPairingDone : Strings.mediaPairingNotAuthorized
        case "expired": Strings.mediaPairingExpired
        case "cancelled": Strings.mediaPairingCancelled
        case "failed": Strings.mediaPairingFailed
        case "revocation_pending": ReasonText.message("media_revocation_pending", domain: .media)
        default: Strings.mediaPairingStatus(status)
        }
    }
}

/// The bounded code set the media-pairing bridge raises. Like
/// `RemoteRequestError`, nothing here echoes host text back to the user.
struct MediaPairingError: Error, Equatable, Sendable {
    let code: String
    let status: Int

    var userMessage: String { ReasonText.message(code, domain: .media, status: status) }
}

/// The media half of the host client, as a seam, so the pairing state machine
/// can be exercised against a fake without a socket or a certificate.
protocol MediaPairingServing: Sendable {
    func discoverMediaPairing(fingerprint: String) async throws -> MediaPairingRequestDTO
    func submitMediaPairing(requestID: String, fingerprint: String, pin: String) async throws -> MediaPairingAttemptDTO
    func mediaPairingStatus(attemptID: String) async throws -> MediaPairingAttemptDTO
    func cancelMediaPairing(attemptID: String) async throws -> MediaPairingAttemptDTO
}
