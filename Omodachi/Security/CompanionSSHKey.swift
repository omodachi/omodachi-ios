import CryptoKit
import Foundation

/// The key pair this device offers when it pairs.
///
/// SPEC-I deletes the whole "SSH 密钥" section from Setup: there is no key to
/// generate by hand, no public half to copy and no `authorized_keys` line to
/// paste. The app makes one Ed25519 key the first time it pairs, sends the
/// public half with `POST /v1/pairing/requests`, and the host writes it during
/// the same Approve that issues the device credential (`docs/pairing.md`).
///
/// Nothing here ever exports the private half. It is written once, to this
/// device's Keychain, with the same account the SSH surface reads from.
enum CompanionSSHKey {
    /// The public key to send with a pairing request, making one if this device
    /// has none yet. `nil` when the Keychain refuses, which is not a reason to
    /// abandon pairing - the claim will simply report `grants.ssh == false` and
    /// the terminal says so instead of hanging.
    static func publicKeyLine(account: String, store: SSHKeyStore = SSHKeyStore()) -> String? {
        do {
            if let stored = try store.loadPrivateKey(account: account) {
                return try? openSSHPublicKey(privateKey(stored).publicKey.rawRepresentation)
            }
            let key = CryptoKit.Curve25519.Signing.PrivateKey()
            try store.savePrivateKey(key.rawRepresentation, account: account)
            return openSSHPublicKey(key.publicKey.rawRepresentation)
        } catch {
            return nil
        }
    }

    /// Whether this device already holds a private key for that account.
    static func exists(account: String, store: SSHKeyStore = SSHKeyStore()) -> Bool {
        ((try? store.loadPrivateKey(account: account)) ?? nil) != nil
    }

    static func privateKey(_ data: Data) throws -> CryptoKit.Curve25519.Signing.PrivateKey {
        if data.count == 32 { return try CryptoKit.Curve25519.Signing.PrivateKey(rawRepresentation: data) }
        #if canImport(Citadel)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try CryptoKit.Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: nil)
        #else
        throw SSHKeyStoreError.unreadableFile
        #endif
    }

    /// One line of OpenSSH, which is the only format core's `ssh_keys` module
    /// accepts and the only thing `sshd` will read back.
    static func openSSHPublicKey(_ key: Data) -> String {
        var blob = Data()
        for value in [Data("ssh-ed25519".utf8), key] {
            var count = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &count) { blob.append(contentsOf: $0) }
            blob.append(value)
        }
        return "ssh-ed25519 \(blob.base64EncodedString()) omodachi-ios" // non-copy: an OpenSSH public key line
    }

    /// `SHA256:…`, exactly as OpenSSH prints it and exactly as
    /// `omodachi-host ssh list` reports it.
    ///
    /// UX-3 §2: the SSH trace used to name the Keychain account this key was
    /// read from, which is a local string that matches nothing on the host. A
    /// fingerprint is comparable — it is the difference between "the device
    /// found *a* key" and "the device offered *the* key the host holds".
    static func fingerprint(_ publicKey: Data) -> String {
        var blob = Data()
        for value in [Data("ssh-ed25519".utf8), publicKey] {
            var count = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &count) { blob.append(contentsOf: $0) }
            blob.append(value)
        }
        let digest = Data(CryptoKit.SHA256.hash(data: blob))
        // OpenSSH prints base64 with the padding removed.
        return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}
