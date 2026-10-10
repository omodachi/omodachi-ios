import Foundation

/// TAIL-3b. What a name pasted on the Tailscale page stands for, before
/// anything is dialled (S02 shows it under the field).
///
/// Everything that page accepts ends up as a MagicDNS name: the full name as
/// is, a short name through the system resolver (forward to a tailnet address,
/// then that address's reverse name), a 100.x / fd7a: address through a paired
/// host that published it or the reverse lookup. Anything that does not become
/// a `*.ts.net` name is refused there and then (E04b) — TAIL-2 quietly kept such
/// a name as a LAN name, which on this page would have made a "Tailscale host"
/// that is really dialled on the Wi-Fi, and asked for Local Network access.
enum TailscaleResolution: Equatable, Sendable {
    case empty
    case resolving
    /// The MagicDNS URL this input will connect as.
    case resolved(URL)
    /// E04b: an address or a name that is not on Tailscale (a LAN IP, a
    /// `.local` name, another domain, a short name that resolves off-tailnet).
    case notTailscale(String)
    /// E04: a short name nothing on the tailnet answers to.
    case noName(String)
    /// E05: a tailnet address with no MagicDNS name behind it.
    case noPtr(String)

    var url: URL? { if case let .resolved(url) = self { url } else { nil } }
}

enum TailscaleName {
    /// `known` maps a tailnet address to a paired host's MagicDNS name, so a
    /// host this device already knows needs no lookup.
    static func resolve(_ input: String, resolver: any TailnetNameResolving,
                        known: [String: String] = [:]) async -> TailscaleResolution {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return .empty }
        guard let candidate = HostCandidate.manual(typed), let host = candidate.url.host else {
            return .notTailscale(typed)
        }
        let port = candidate.url.port ?? 8099
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if HostRoads.isMagicDNSName(bare) {
            let name = bare.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let url = DiscoveredHost.url(host: name, port: port) else { return .notTailscale(typed) }
            return .resolved(url)
        }
        if HostRoads.isTailnetAddress(bare) {
            if let name = known[bare], let url = DiscoveredHost.url(host: name, port: port) {
                ManualHostTrace.note("tailnet-address known-host \(bare) -> \(name)")
                return .resolved(url)
            }
            let answer = await resolver.reverseName(of: bare)
            let name = answer?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard let name, HostRoads.isMagicDNSName(name), SSHTargetResolver.isValidHost(name),
                  let url = DiscoveredHost.url(host: name, port: port) else {
                ManualHostTrace.note("tailnet-address unresolved \(bare) ptr=\(answer ?? "none")")
                return .noPtr(bare)
            }
            ManualHostTrace.note("tailnet-address ptr \(bare) -> \(name)")
            return .resolved(url)
        }
        if ConnectionFlowModel.isShortName(bare) {
            let addresses = await resolver.forwardAddresses(of: bare)
            guard !addresses.isEmpty else {
                ManualHostTrace.note("short-name unresolved \(bare)")
                return .noName(bare)
            }
            for address in addresses where HostRoads.isTailnetAddress(address) {
                guard let answer = await resolver.reverseName(of: address) else { continue }
                let full = answer.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                if HostRoads.isMagicDNSName(full), SSHTargetResolver.isValidHost(full),
                   ConnectionFlowModel.firstLabel(full) == bare,
                   let url = DiscoveredHost.url(host: full, port: port) {
                    ManualHostTrace.note("short-name upgraded \(bare) -> \(full)")
                    return .resolved(url)
                }
            }
            // It resolves, but not to this tailnet machine: a LAN name. On the
            // Tailscale page that is a refusal, never a quiet Wi-Fi host.
            ManualHostTrace.note("short-name not-tailscale \(bare)")
            return addresses.contains(where: HostRoads.isTailnetAddress) ? .noName(bare) : .notTailscale(bare)
        }
        return .notTailscale(bare)
    }
}
