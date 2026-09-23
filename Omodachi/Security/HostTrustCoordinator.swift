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

    init(pins: HostKeyStore = HostKeyStore(),
         paired: @escaping () -> Set<String> = { HostTrustCoordinator.pairedSSHIdentities() }) {
        self.pins = pins
        self.paired = paired
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
