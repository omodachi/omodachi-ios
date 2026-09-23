import Foundation

/// PAIR-4 §4. The one derivation of the string that keys everything this device
/// stores about a host.
///
/// Until now there were two of them. The companion credential and the TLS pin
/// were keyed by `CompanionHostConfiguration(endpoint:).account` — scheme
/// forced to `https`, host lower-cased, path dropped — while the directory
/// record, the invitation-mode set and every host row keyed themselves by
/// `candidate.url.absoluteString`, whatever that happened to be.
/// `https://Omarchy:8099` and `https://omarchy:8099/` are one host to the first
/// and two hosts to the second, and that gap is not cosmetic: the row reads
/// "未配对" off a pin it cannot find while the pairing request it starts is
/// refused by a credential it *does* find, which is a state with no exit.
///
/// So there is one function, and everything that needs an account calls it.
enum HostAccount {
    /// The account for an endpoint, or `nil` when that endpoint is not a host
    /// this app can talk to at all (not https, has a path, a user, a query…).
    static func derive(_ endpoint: URL) -> String? {
        (try? CompanionHostConfiguration(endpoint: endpoint))?.account
    }

    /// For a string that was already written as an account — a directory record
    /// from an older build, a profile's `companionURL`. A value that will not
    /// parse is handed back unchanged rather than dropped: it then keeps
    /// matching exactly what it matched before, and nothing is silently lost.
    static func canonical(_ value: String) -> String {
        URL(string: value).flatMap(derive) ?? value
    }
}

/// PAIR-4 §2. "忘记这台主机" is one operation with four pieces, and it never
/// asks whether the host is reachable — the whole point is that it works when
/// the host is gone, has revoked this device, or was never really this host.
///
/// The host's own side (the Sunshine certificate and the `authorized_keys`
/// line) is revoked on the computer with `omodachi-host devices revoke`; this
/// is only what the device holds. N-14: the caller supplies the two taps.
@MainActor enum HostForget {
    /// `true` when every local record for that account is gone. A Keychain that
    /// refuses is the one case worth telling the user about; the directory
    /// record is dropped either way so a refusal can never re-create the dead
    /// end this whole spec is about.
    @discardableResult
    static func run(account rawAccount: String,
                    directory: PairedHostDirectory?,
                    pins: HostPinStore = HostPinStore(),
                    credentials: CompanionCredentialStore = CompanionCredentialStore(),
                    hostKeys: HostKeyStore = HostKeyStore(),
                    approvalKeys: ApprovalKeyStore = ApprovalKeyStore()) -> Bool {
        let account = HostAccount.canonical(rawAccount)
        // Read the SSH target before the pin that carries it is deleted.
        let ssh = pins.load(account: account)?.ssh
        var complete = true
        // The credential first: it is the record that refuses a new pairing.
        do { try credentials.removeToken(account: account) } catch { complete = false }
        do { try pins.remove(account: account) } catch { complete = false }
        if let ssh { try? hostKeys.reset(host: ssh.host, port: ssh.port) }
        // AUTH-1: the approval key goes with everything else. It authorizes
        // nothing once the host no longer holds its public half, but a key
        // left behind for a host this device has forgotten is still a key
        // nobody asked to keep.
        try? approvalKeys.deleteKey(account: "approval-\(account)")
        directory?.forget(account: account)
        return complete
    }
}
