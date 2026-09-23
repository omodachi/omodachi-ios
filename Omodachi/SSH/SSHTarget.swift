import Foundation

/// Where the SSH surface actually dials (§2).
///
/// Since SPEC-I the whole target comes from the pairing claim: core publishes
/// `ssh: {user, host, port}` next to the credential, so the account is the
/// host's own login rather than something the user typed, and the port is the
/// SSH port rather than a companion endpoint's 8099 read as if it were one.
///
/// The older fallbacks stay for a pin written before SPEC-I and for a host
/// reachable under a name it did not pair on: the address is then `host_name`
/// or one of the claim's `endpoints` (`docs/pairing.md`), and the account is
/// whatever the profile carries.
struct SSHTarget: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        /// `ssh` from the pairing claim: user, host and port together, which
        /// is the only source that answers all three without a guess.
        case pairedTarget
        /// A host the user pointed this device at by hand, which still wins
        /// over the claim's own name for reaching a tunnel or a Tailscale name.
        case profile
        /// The `endpoints` from the pairing claim.
        case pairedEndpoint
        /// `host_name` from the pairing claim, when it carried no endpoints.
        case pairedHostName
    }

    let username: String
    let host: String
    let port: Int
    let source: Source

    /// §3: the lightweight bar's name for this surface.
    var label: String { "\(username)@\(host)" }
    /// What `HostKeyStore` pins the host key under.
    var identity: String { "\(host):\(port)" }
}

enum SSHTargetResolver {
    /// `nil` means there is nothing to dial and the surface says so rather than
    /// opening a terminal that cannot connect.
    static func resolve(profile: HostProfile, pin: HostPin?) -> SSHTarget? {
        // What pairing handed over, whole. Nothing here was typed by anyone.
        if let target = pin?.ssh, isValidAccount(target.user), isValidHost(target.host),
           (1...65535).contains(target.port) {
            return SSHTarget(username: target.user, host: target.host, port: target.port, source: .pairedTarget)
        }
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidAccount(username) else { return nil }
        let port = (1...65535).contains(profile.port) ? profile.port : 22

        let candidates: [(String, SSHTarget.Source)] =
            [(profile.hostname, .profile)]
            + (pin?.endpoints.map { ($0.host, SSHTarget.Source.pairedEndpoint) } ?? [])
            + [(pin?.hostName ?? "", .pairedHostName)]
        for (value, source) in candidates {
            let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidHost(host) else { continue }
            return SSHTarget(username: username, host: host, port: port, source: source)
        }
        return nil
    }

    /// A host has to survive being put in a `URL` and in an OpenSSH pin key, so
    /// the separators that would change its meaning are refused rather than
    /// escaped.
    static func isValidHost(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && !value.contains(where: \.isWhitespace)
            && !value.contains("/") && !value.contains("@")
            && !value.contains(":") && !value.contains("?") && !value.contains("#")
    }

    static func isValidAccount(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && !value.contains(where: \.isWhitespace)
            && !value.contains("@") && !value.contains(":") && !value.contains("/")
    }

    /// The profile one `SessionDescriptor` should carry, with the resolved
    /// address written into it. The profile `id` is untouched, so the Keychain
    /// account holding the private key does not move when pairing does.
    static func profile(_ profile: HostProfile, for target: SSHTarget) -> HostProfile {
        var value = profile
        value.hostname = target.host
        value.port = target.port
        value.username = target.username
        return value
    }
}

/// There is nothing left for the user to do on the host.
///
/// SPEC-F3 shipped with this printing an `authorized_keys` append command,
/// because `omodachi-host ssh authorize` did not exist. CORE-1 added it and
/// SPEC-I wired it to Approve: the public key rides along with the pairing
/// request and the host writes it during the one approval. So the only thing
/// left to say is whether that grant landed.
enum SSHAuthorizationHint {
    static let coreCommandAvailable = true

    /// What the terminal says when pairing did not manage to authorize the key.
    static func unauthorized(grants: HostPin.Grants?) -> String? {
        guard let grants, !grants.ssh else { return nil }
        return Strings.sshKeyNotAuthorized
    }
}
