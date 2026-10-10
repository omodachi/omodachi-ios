import Foundation
import Combine

@MainActor final class HostTrustCoordinator: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let challenge: SSHHostKeyChallenge
        let continuation: CheckedContinuation<Bool, Never>
    }
    @Published private(set) var request: Request?
    private var queue: [Request] = []
    private let pins: HostKeyStore
    /// The `host:port` targets a pairing claim handed this device (N-28).
    private let paired: () -> Set<String>
    /// TAIL-2 P0-4. The `host_id` of the paired host an SSH address belongs
    /// to — its LAN address, its `.local` name, its MagicDNS name, its tailnet
    /// address — or `nil`. A paired host's SSH key is pinned under that id, so
    /// reaching the same machine on another road is not a new identity to
    /// trust on first use.
    private let pairedHost: (String, Int) -> String?

    init(pins: HostKeyStore = HostKeyStore(),
         paired: @escaping () -> Set<String> = { HostTrustCoordinator.pairedSSHIdentities() },
         pairedHost: @escaping (String, Int) -> String? = { HostTrustCoordinator.pairedHostID(host: $0, port: $1) }) {
        self.pins = pins
        self.paired = paired
        self.pairedHost = pairedHost
    }

    /// The `HostKeyStore` name a paired host's SSH key is pinned under.
    static func hostKeyIdentity(hostID: String) -> String { "host-\(hostID)" }

    static func pairedHostID(host: String, port: Int, store: HostPinStore = HostPinStore(),
                             defaults: UserDefaults = AppDefaults.shared) -> String? {
        let host = host.lowercased()
        let records = defaults.data(forKey: PairedHostDirectory.storageKey)
            .flatMap { try? JSONDecoder().decode([PairedHostRecord].self, from: $0) } ?? []
        for record in records {
            guard let pin = store.load(account: record.account), let ssh = pin.ssh, ssh.port == port else { continue }
            let names = [ssh.host.lowercased()] + (ssh.hosts ?? []).map(\.host) + pin.roads.map(\.host)
            if names.contains(host) { return pin.hostID }
        }
        return nil
    }

    /// Every SSH target this device learned from a claim, as `HostKeyStore`
    /// keys them. The claim arrived over a connection whose certificate this
    /// device had already pinned, so the machine is not in question.
    static func pairedSSHIdentities(store: HostPinStore = HostPinStore(),
                                    defaults: UserDefaults = AppDefaults.shared) -> Set<String> {
        let records = defaults.data(forKey: PairedHostDirectory.storageKey)
            .flatMap { try? JSONDecoder().decode([PairedHostRecord].self, from: $0) } ?? []
        return Set(records.compactMap { store.load(account: $0.account)?.ssh }
            .map { "\($0.host):\($0.port)" })
    }

    func validate(_ challenge: SSHHostKeyChallenge) async throws {
        if let hostID = pairedHost(challenge.host, challenge.port) {
            try validatePaired(challenge, hostID: hostID)
            return
        }
        switch try pins.verify(host: challenge.host, port: challenge.port, openSSHPublicKey: challenge.openSSHPublicKey) {
        case .accepted: return
        case .mismatch:
            throw TerminalFailure.hostKeyChanged
        case .firstSeen:
            // N-28: one approval, and no second thing to confirm. A host this
            // device paired with published its own SSH target in the claim, on
            // a connection pinned to its certificate — so the first sight of
            // that host's SSH key is pinned silently. A *changed* key is still
            // a hard failure above; this only removes the TOFU prompt for an
            // identity the pairing already established.
            if paired().contains("\(challenge.host):\(challenge.port)") {
                _ = try pins.confirm(host: challenge.host, port: challenge.port,
                                     openSSHPublicKey: challenge.openSSHPublicKey)
                return
            }
            let accepted = await withCheckedContinuation { continuation in
                let next = Request(challenge: challenge, continuation: continuation)
                if request == nil { request = next } else { queue.append(next) }
            }
            guard accepted else { throw TerminalFailure.hostKeyDeclined }
            _ = try pins.confirm(host: challenge.host, port: challenge.port, openSSHPublicKey: challenge.openSSHPublicKey)
        }
    }
    /// TAIL-2 P0-4. One pin per paired machine, whichever road reached it. A
    /// key already pinned under the address this device used before (a build
    /// from before TAIL-2) must agree with it; a changed key is still a hard
    /// failure, on any road.
    private func validatePaired(_ challenge: SSHHostKeyChallenge, hostID: String) throws {
        let identity = Self.hostKeyIdentity(hostID: hostID)
        switch try pins.verify(host: identity, port: challenge.port, openSSHPublicKey: challenge.openSSHPublicKey) {
        case .accepted: return
        case .mismatch: throw TerminalFailure.hostKeyChanged
        case .firstSeen:
            if case .mismatch = try pins.verify(host: challenge.host, port: challenge.port,
                                                openSSHPublicKey: challenge.openSSHPublicKey) {
                throw TerminalFailure.hostKeyChanged
            }
            _ = try pins.confirm(host: identity, port: challenge.port, openSSHPublicKey: challenge.openSSHPublicKey)
        }
    }

    func resolve(accept: Bool) {
        guard let current = request else { return }
        request = nil
        current.continuation.resume(returning: accept)
        if !queue.isEmpty { request = queue.removeFirst() }
    }
    func rejectAll() {
        let pending = (request.map { [$0] } ?? []) + queue
        request = nil; queue.removeAll()
        for item in pending { item.continuation.resume(returning: false) }
    }
}

enum TerminalFailure: Error, LocalizedError {
    case hostKeyChanged, hostKeyDeclined, commandRestartRequiresConfirmation
    var errorDescription: String? {
        switch self {
        case .hostKeyChanged: Strings.sshHostKeyChanged
        case .hostKeyDeclined: Strings.sshHostKeyDeclined
        case .commandRestartRequiresConfirmation: Strings.sshCommandEnded
        }
    }
}
