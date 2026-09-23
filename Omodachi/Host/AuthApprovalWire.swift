import Foundation

/// AUTH-1 wire types: what the host asks, and what this device answers.
///
/// Everything here is `Decodable` from core's `contracts/auth-approval.schema.json`
/// and `contracts/auth-keys.schema.json`. The one field that matters more than
/// the rest is `nonce`: it is single-use, it is in the signed bytes, and it is
/// the reason a signature cannot be replayed at a second prompt.
public struct HostApprovalRequest: Decodable, Equatable, Sendable, Identifiable {
    public let approvalID: String
    public let nonce: String
    /// UX-3 §1. The identity this device must sign as — the `device_id` of the
    /// credential this connection authenticated with, stated by the host.
    ///
    /// It is in the signed bytes and it is the only signed field the device
    /// cannot derive from the frame. Guessing it locally is what made every
    /// approval on Leo's iPad fail: the app had re-minted its own id while the
    /// credential it still connects with kept the old one, so the host verified
    /// a message the device never signed. Optional because a host from before
    /// this change does not send it; the client then falls back to what
    /// `GET /v1/auth/keys` said, which is the same authority one step removed.
    public let deviceID: String?
    /// The PAM service name (`sudo`, `polkit-1`, …). Kept because it is signed.
    public let service: String
    /// What the host calls that service in words a person can read.
    public let serviceTitle: String
    public let user: String
    public let requester: String
    public let tty: String?
    public let rhost: String?
    /// One line naming the service and, when it differs, who it runs as.
    public let detail: String
    public let hostID: String
    public let hostName: String
    public let requestedAt: Int
    public let expiresAt: Int
    public let timeoutSeconds: Int

    public var id: String { approvalID }

    enum CodingKeys: String, CodingKey {
        case approvalID = "approval_id", nonce, deviceID = "device_id"
        case service, serviceTitle = "service_title"
        case user, requester, tty, rhost, detail = "description"
        case hostID = "host_id", hostName = "host_name"
        case requestedAt = "requested_at", expiresAt = "expires_at", timeoutSeconds = "timeout_seconds"
    }

    /// A frame that cannot be trusted enough to raise a prompt over is not a
    /// frame this client acts on. Every bound here matches the host contract.
    public var isWellFormed: Bool {
        approvalID.hasPrefix("appr_") && approvalID.count == 37
            && nonce.count == 43 && nonce.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            && (deviceID.map { !$0.isEmpty && $0.utf8.count <= 128 } ?? true)
            && !service.isEmpty && service.utf8.count <= 64
            && !serviceTitle.isEmpty && serviceTitle.utf8.count <= 128
            && !user.isEmpty && user.utf8.count <= 128
            && !detail.isEmpty && detail.utf8.count <= 256
            && hostID.count == 32 && !hostName.isEmpty && hostName.utf8.count <= 128
            && timeoutSeconds >= 5 && timeoutSeconds <= 120
            && expiresAt > requestedAt
    }

    /// Seconds left before the host stops waiting and asks for the password.
    public func remaining(now: Date = Date()) -> TimeInterval {
        max(0, TimeInterval(expiresAt) - now.timeIntervalSince1970)
    }
}

public struct HostApprovalResolution: Decodable, Equatable, Sendable {
    public enum Outcome: String, Decodable, Sendable { case approved, declined, timeout }
    public let approvalID: String
    public let outcome: Outcome
    public let deviceID: String?

    enum CodingKeys: String, CodingKey {
        case approvalID = "approval_id", outcome, deviceID = "device_id"
    }
}

/// `GET /v1/auth/keys`: both of AUTH-1's switches in one answer. `enabled` is
/// the host's; each key carries the device's own.
public struct HostApprovalKeys: Decodable, Equatable, Sendable {
    public struct Key: Decodable, Equatable, Sendable, Identifiable {
        public let deviceID: String
        public let label: String
        public let enrolledAt: Int
        public let secureEnclave: Bool
        public let enabled: Bool
        public var id: String { deviceID }

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id", label, enrolledAt = "enrolled_at"
            case secureEnclave = "secure_enclave", enabled
        }
    }

    /// The host preference. False means no approval is ever raised, whatever
    /// this device has registered.
    public let enabled: Bool
    public let hostID: String
    public let hostName: String
    public let deviceID: String
    /// One-shot, 300 s. Enrolling signs it.
    public let challenge: String
    public let enrolled: Bool
    public let keys: [Key]

    enum CodingKeys: String, CodingKey {
        case enabled, hostID = "host_id", hostName = "host_name", deviceID = "device_id"
        case challenge, enrolled, keys
    }

    public var mine: Key? { keys.first { $0.deviceID == deviceID } }
    /// Both switches. Neither alone does anything.
    public var active: Bool { enabled && (mine?.enabled ?? false) }
}

public struct HostApprovalEnrollment: Encodable, Sendable {
    public let public_key: String
    public let label: String
    public let challenge: String
    public let signature: String
    public let enabled: Bool
    public let secure_enclave: Bool
}

public struct HostApprovalDecision: Encodable, Sendable {
    public let decision: String
    public let signature: String?

    public static func approve(signature: String) -> Self { .init(decision: "approve", signature: signature) }
    public static let decline = Self(decision: "decline", signature: nil)
}

public struct HostApprovalKeyState: Encodable, Sendable { public let enabled: Bool }

public struct HostApprovalKeyRecord: Decodable, Equatable, Sendable {
    public let deviceID: String
    public let enabled: Bool
    public let secureEnclave: Bool

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", enabled, secureEnclave = "secure_enclave"
    }
}

public struct HostApprovalRevocation: Decodable, Equatable, Sendable {
    public let deviceID: String
    public let revoked: Bool

    enum CodingKeys: String, CodingKey { case deviceID = "device_id", revoked }
}

public struct HostPendingApprovals: Decodable, Equatable, Sendable {
    public let approvals: [HostApprovalRequest]
}
