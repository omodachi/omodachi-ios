import Foundation
import LocalAuthentication
import Security

/// AUTH-1: the key this device answers a host's password prompt with.
///
/// A P-256 key pair, generated in the Secure Enclave where there is one. The
/// private half never leaves it, is never exported, and is never sent anywhere
/// — the host is given the public half once and is thereafter only ever shown
/// signatures. Nothing here knows the user's Mac or Linux password; there is no
/// field for it to arrive in.
///
/// Two gates sit in front of every signature:
///
/// 1. `SecAccessControl` with `.biometryCurrentSet`, so the key itself dies the
///    moment the enrolled biometrics change. Adding a face or a finger
///    invalidates the key and the host stops trusting this device until it
///    registers again — which is the behaviour you want from a thing that can
///    stand in for a password.
/// 2. An explicit `LAContext` evaluation with
///    `deviceOwnerAuthenticationWithBiometrics` and **no passcode fallback**,
///    whose authenticated context is then handed to the signing operation. The
///    ACL alone would already prompt, but doing it explicitly is what makes
///    the prompt appear at a moment the app chose, with wording the app wrote,
///    and lets a cancel be a cancel rather than an opaque `errSecAuthFailed`.
///
/// On a simulator there is no enclave. Rather than pretend, the key is an
/// ordinary keychain key under the same access control, and `secureEnclave` is
/// reported as `false` all the way to the host and to Settings. A report that
/// cannot tell the two apart is worth nothing.
enum ApprovalKeyError: Error, Equatable {
    case biometryUnavailable
    case cancelled
    case authenticationFailed
    case keyInvalidated
    case keychain(OSStatus)
    case unsupported

    /// Whether the user chose this outcome. A cancel is not an error to report;
    /// it is an answer, and the host falls back to the password for it.
    var isCancellation: Bool { self == .cancelled }
}

/// Which prompt the person will actually see, so the copy can say it.
enum BiometryKind: String, Sendable, Equatable {
    case none, touchID, faceID, opticID

    var isAvailable: Bool { self != .none }

    static func current(_ context: LAContext = LAContext()) -> BiometryKind {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .none }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }
}

/// The three things the coordinator needs from a key. It is a protocol so the
/// tests can drive every branch — a cancelled biometric, an invalidated key, a
/// refusing keychain — without a real enclave and without a real face.
protocol ApprovalSigning: Sendable {
    func identity(account: String) throws -> ApprovalKeyIdentity
    func sign(_ message: Data, account: String, reason: String) async throws -> Data
    func deleteKey(account: String) throws
    /// Take down a biometric sheet whose prompt has already been settled.
    ///
    /// The host's approval expires on its own, and when it does the sheet on
    /// this device is asking about something nobody is waiting for any more.
    /// Leaving it up is not merely untidy: the *next* prompt cannot raise its
    /// own sheet while it is there, and a person who answers the stale one has
    /// answered a question they can no longer read.
    func cancelPrompt()
}

struct ApprovalKeyIdentity: Equatable, Sendable {
    /// base64 of the uncompressed X9.63 point (`04 || X || Y`), which is what
    /// `SecKeyCopyExternalRepresentation` gives for a P-256 key and what core's
    /// verifier reads.
    let publicKey: String
    let secureEnclave: Bool
}

/// `LAContext` is not `Sendable` and `sign` is async, so the live sheet is held
/// behind a small locked box rather than a bare property: the coordinator takes
/// it down from the main actor while `sign` is still suspended inside it.
private final class PromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var context: LAContext?

    func take() -> LAContext? {
        lock.lock(); defer { lock.unlock() }
        let current = context
        context = nil
        return current
    }

    func replace(with value: LAContext) -> LAContext? {
        lock.lock(); defer { lock.unlock() }
        let previous = context
        context = value
        return previous
    }

    func clear(_ value: LAContext) {
        lock.lock(); defer { lock.unlock() }
        if context === value { context = nil }
    }
}

final class ApprovalKeyStore: ApprovalSigning, @unchecked Sendable {
    static let defaultTagPrefix = "app.omodachi.approval."

    private let tagPrefix: String
    /// Injected so tests can drive every branch without a real enclave, a real
    /// biometric or a real Keychain.
    private let secureEnclaveAvailable: Bool

    init(tagPrefix: String = ApprovalKeyStore.defaultTagPrefix,
         secureEnclaveAvailable: Bool = ApprovalKeyStore.enclaveExists()) {
        self.tagPrefix = tagPrefix
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }

    static func enclaveExists() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private func tag(_ account: String) -> Data { Data((tagPrefix + account).utf8) }

    // MARK: - Lifecycle

    /// A fresh key for this host account, and the public half to register.
    ///
    /// Registering always mints a new key and drops whatever was there. That
    /// is deliberate, and it is the fix for a bug worth remembering: reading
    /// the existing key back needs an `LAContext` it does not have here, so a
    /// second registration used to *add* a key under the same tag — and then
    /// `sign` picked one of the two while the host had been given the other's
    /// public half. Every approval failed `biometric_signature_invalid` with
    /// nothing on either side saying why. One tag, one key, always.
    ///
    /// Nothing is lost by re-minting: the host is about to be told the new
    /// public half in the same breath, and the old key authorized nothing once
    /// the host stopped holding its public half.
    func identity(account: String) throws -> ApprovalKeyIdentity {
        try deleteKey(account: account)
        return try describe(try createKey(account: account))
    }

    func exists(account: String) -> Bool {
        ((try? copyKey(account: account, context: nil)) ?? nil) != nil
    }

    func deleteKey(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(account),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ApprovalKeyError.keychain(status)
        }
    }

    // MARK: - Signing

    /// Ask for the biometric, then sign. Nothing else in the app may call
    /// `SecKeyCreateSignature` on this key.
    ///
    /// `reason` is what the system prompt shows, so it names the host and what
    /// is being approved: a prompt that only says "Omodachi" tells the person
    /// nothing about what they are about to let through.
    /// The sheet currently on screen, so it can be taken down from outside.
    private let prompt = PromptBox()

    func cancelPrompt() { prompt.take()?.invalidate() }

    func sign(_ message: Data, account: String, reason: String) async throws -> Data {
        let context = LAContext()
        prompt.replace(with: context)?.invalidate()
        defer { prompt.clear(context) }
        context.localizedReason = reason
        // No passcode, no watch, no "Enter Password" button. Standing in for a
        // host password with a device passcode is a downgrade, not a feature.
        context.localizedFallbackTitle = ""
        var probe: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &probe) else {
            throw ApprovalKeyError.biometryUnavailable
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                   localizedReason: reason) else {
                throw ApprovalKeyError.authenticationFailed
            }
        } catch let error as ApprovalKeyError {
            throw error
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: throw ApprovalKeyError.cancelled
            case .biometryNotAvailable, .biometryNotEnrolled: throw ApprovalKeyError.biometryUnavailable
            case .biometryLockout: throw ApprovalKeyError.authenticationFailed
            default: throw ApprovalKeyError.authenticationFailed
            }
        } catch {
            throw ApprovalKeyError.authenticationFailed
        }
        guard let key = try copyKey(account: account, context: context) else {
            throw ApprovalKeyError.keyInvalidated
        }
        return try Self.signature(key, over: message)
    }

    /// The one call that turns bytes into a signature, and the one place the
    /// wire format is decided.
    ///
    /// `.ecdsaSignatureMessageX962SHA256` hashes the message with SHA-256 and
    /// emits **DER** `SEQUENCE { INTEGER r, INTEGER s }` — not the raw `r || s`
    /// some ECDSA APIs give. `omodachi_core/biometric.py` parses DER, strictly
    /// and with no fallback, so the two have to be checked against each other
    /// rather than assumed. UX-3 §1 puts a test on this path with a software
    /// P-256 key, because a simulator has no enclave to make a real one with
    /// and the format is a property of the algorithm, not of where the key
    /// lives.
    static func signature(_ key: SecKey, over message: Data) throws -> Data {
        var failure: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                                    message as CFData, &failure) as Data? else {
            failure?.release()
            throw ApprovalKeyError.keyInvalidated
        }
        return signature
    }

    // MARK: - Keychain

    private func copyKey(account: String, context: LAContext?) throws -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(account),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        } else {
            // Do not let a stray fetch raise a prompt of its own.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        // `errSecInteractionNotAllowed` from the no-context path means the key
        // is there and guarded, which is the answer the caller wanted.
        if status == errSecInteractionNotAllowed, context == nil { return nil }
        guard status == errSecSuccess, let key = result else { throw ApprovalKeyError.keychain(status) }
        return (key as! SecKey)
    }

    private func createKey(account: String) throws -> SecKey {
        // Never leave two keys under one tag; `sign` looks the key up by tag.
        try deleteKey(account: account)
        var accessError: Unmanaged<CFError>?
        // `.biometryCurrentSet`, not `.biometryAny`: enrolling a new face or
        // finger must invalidate this key. Otherwise somebody who can add
        // their own biometric to an unlocked device inherits the ability to
        // approve the owner's host prompts.
        var flags: SecAccessControlCreateFlags = [.biometryCurrentSet]
        if secureEnclaveAvailable { flags.insert(.privateKeyUsage) }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &accessError) else {
            accessError?.release()
            throw ApprovalKeyError.unsupported
        }
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag(account),
            kSecAttrAccessControl as String: access
        ]
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]
        if secureEnclaveAvailable {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        } else {
            // A simulator key is an ordinary keychain key. It is still guarded
            // by the same access control, and it is still reported as *not*
            // enclave-backed everywhere it is shown.
            privateAttributes[kSecAttrLabel as String] = tagPrefix + account
        }
        attributes[kSecPrivateKeyAttrs as String] = privateAttributes
        var failure: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &failure) else {
            let code = (failure?.takeRetainedValue()).map { CFErrorGetCode($0) } ?? -1
            throw ApprovalKeyError.keychain(OSStatus(code))
        }
        return key
    }

    private func describe(_ key: SecKey) throws -> ApprovalKeyIdentity { try Self.identity(of: key) }

    /// The public half as the host is given it: base64 of the uncompressed
    /// X9.63 point, `04 || X || Y`, 65 bytes. `SecKeyCopyExternalRepresentation`
    /// gives exactly that for a P-256 key — not an SPKI DER wrapping — and core
    /// accepts either, so this asserts the shorter one rather than trusting it.
    static func identity(of key: SecKey) throws -> ApprovalKeyIdentity {
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw ApprovalKeyError.unsupported }
        var failure: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(publicKey, &failure) as Data? else {
            failure?.release()
            throw ApprovalKeyError.unsupported
        }
        guard raw.count == 65, raw.first == 0x04 else { throw ApprovalKeyError.unsupported }
        let attributes = SecKeyCopyAttributes(key) as? [String: Any]
        let token = attributes?[kSecAttrTokenID as String] as? String
        return ApprovalKeyIdentity(publicKey: raw.base64EncodedString(),
                                   secureEnclave: token == (kSecAttrTokenIDSecureEnclave as String))
    }
}

/// The exact bytes core verifies. `omodachi_core/biometric.py` builds the same
/// string; if these two ever disagree, every approval fails closed and the
/// password comes back, which is the right way for a mismatch to show up.
enum ApprovalMessage {
    static let approvalContext = "omodachi-auth-approval-v1"
    static let enrollmentContext = "omodachi-auth-enrollment-v1"

    /// ASCII, newline separated, with a trailing newline. A field containing a
    /// newline would let one field pretend to be two, so any such field makes
    /// this return nil and the approval is simply not answered.
    static func approval(hostID: String, approvalID: String, nonce: String,
                         service: String, user: String, deviceID: String) -> Data? {
        join([approvalContext, hostID, approvalID, nonce, service, user, deviceID])
    }

    static func enrollment(hostID: String, deviceID: String, challenge: String,
                           publicKey: String) -> Data? {
        join([enrollmentContext, hostID, deviceID, challenge, publicKey])
    }

    private static func join(_ parts: [String]) -> Data? {
        for part in parts where part.isEmpty || part.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value > 0x7e
        }) { return nil }
        return (parts.joined(separator: "\n") + "\n").data(using: .ascii)
    }
}
