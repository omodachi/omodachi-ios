import Foundation
import OSLog

/// UX-3 §1. What this device signed, in a form that can be pasted somewhere.
///
/// The round this exists for went like this: the host journal said
/// `auth.approval.signature_rejected` and nothing else, and the device said
/// nothing at all. Between them they could not answer the only question worth
/// asking — *which bytes did the iPad actually sign?* — and the answer, when it
/// was finally read out of the credential registry by hand, was that the device
/// had signed an identity the host had never issued it.
///
/// So the device records it. Every field of the signed message is here verbatim
/// (it is ASCII, printable and newline separated by construction), plus the
/// signature and the public half, and the outcome the host returned.
///
/// **Nothing secret is in it.** The message is built from fields the host sent
/// and one the host stated, and the signature is the one that was posted to the
/// host over the same connection. The public half is already on the host, in
/// `biometric-keys.json`; the private half is in the Secure Enclave and cannot
/// be exported by anything, including this.
enum ApprovalTrace {
    private static let log = Logger(subsystem: "app.omodachi", category: "auth.approval")

    static let transcript = DiagnosticsTranscript()

    /// The message, exactly as it went into the signer, with its newlines made
    /// visible so a paste survives a chat window. `\n` is written as the two
    /// characters, which is also how the contract writes it down.
    private static func escaped(_ message: Data) -> String {
        (String(data: message, encoding: .ascii) ?? "<not ascii>")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func signed(_ message: Data, signature: Data, identity: String, identitySource: String,
                       localIdentity: String) {
        let line = "auth.approval signed_as=\(identity) source=\(identitySource) "
            + "local_id=\(localIdentity) message=\"\(escaped(message))\" "
            + "signature=\(signature.base64EncodedString())"
        log.notice("\(line, privacy: .public)")
        transcript.append(DiagnosticsTranscript.stamp() + " " + line)
    }

    static func outcome(_ approvalID: String, _ outcome: String) {
        let line = "auth.approval approval_id=\(approvalID) outcome=\(outcome)"
        log.notice("\(line, privacy: .public)")
        transcript.append(DiagnosticsTranscript.stamp() + " " + line)
    }

    /// The drift itself, noticed rather than inferred. When the host's answer
    /// and this device's own id disagree, that is the whole bug in one line.
    static func identityDrift(local: String, host: String) {
        let line = "auth.approval identity_drift local_id=\(local) host_says=\(host)"
        log.error("\(line, privacy: .public)")
        transcript.append(DiagnosticsTranscript.stamp() + " " + line)
    }
}
