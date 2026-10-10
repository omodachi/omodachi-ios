import Foundation

/// TAIL-2 P0-2 / TAIL-3b. The addresses a host answers on, and the one road
/// this device uses to reach it.
///
/// A host is its `host_id` plus the certificate fingerprint this device pinned
/// — never an address. The same computer answers on its LAN address, on its
/// `.local` name and, when Tailscale is up on it, on its MagicDNS name. Since
/// TAIL-3b each paired host has exactly one road (`HostPin.road`): Tailscale,
/// by its MagicDNS name, or this Wi-Fi, by its address; the app never switches
/// between them on its own. Core (TAIL-2) types every address it publishes; a core from before it
/// sends bare `{host, port}` and the kind is inferred here from the address.
enum RoadKind: String, Codable, Equatable, Sendable, CaseIterable {
    case lan, mdns, tailnet

    /// TAIL-3b: a host is on one of two roads — Tailscale, or this Wi-Fi. A
    /// `.local` name is a spelling of the second.
    var isTailscale: Bool { self == .tailnet }
}

struct HostRoad: Codable, Equatable, Hashable, Sendable {
    let host: String
    let port: Int
    let kind: RoadKind

    init(host: String, port: Int, kind: RoadKind? = nil) {
        self.host = host.lowercased()
        self.port = port
        self.kind = kind ?? HostRoads.kind(of: host)
    }

    var url: URL? { DiscoveredHost.url(host: host, port: port) }
    /// ATS lets this app reach RFC1918 addresses and `.local` names
    /// (`NSAllowsLocalNetworking`) and `*.ts.net` names (the TAIL-2 exception).
    /// A tailnet address literal is neither, so it is never dialled; it is kept
    /// only to recognise a host somebody typed as 100.x.
    var isDialable: Bool { !(kind == .tailnet && HostRoads.isTailnetAddress(host)) }
}

enum HostRoads {
    /// Tailscale's CGNAT range 100.64.0.0/10.
    static func isTailnetIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// Tailscale's ULA prefix fd7a:115c:a1e0::/48.
    static func isTailnetIPv6(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard value.contains(":") else { return false }
        return value.hasPrefix("fd7a:115c:a1e0:")
    }

    static func isTailnetAddress(_ host: String) -> Bool { isTailnetIPv4(host) || isTailnetIPv6(host) }

    static func isMagicDNSName(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return value.hasSuffix(".ts.net") && value.count > ".ts.net".count
    }

    /// The kind of an address that came without one (a core from before TAIL-2,
    /// or an address this device dialled itself).
    static func kind(of host: String) -> RoadKind {
        if isTailnetAddress(host) || isMagicDNSName(host) { return .tailnet }
        if host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasSuffix(".local") { return .mdns }
        return .lan
    }

    static func kind(of url: URL?) -> RoadKind? { url?.host.map { kind(of: $0) } }

    /// The wire's kind word, or the inference for one this build does not know.
    static func kind(_ value: String?, host: String) -> RoadKind {
        value.flatMap(RoadKind.init(rawValue:)) ?? kind(of: host)
    }

    /// TAIL-3b. A host has exactly one road, and this is where it is dialled.
    ///
    /// A Tailscale host is dialled by its MagicDNS name and nothing else: no
    /// LAN address is ever tried for it, so it can never be what makes iOS ask
    /// for Local Network access. A Wi-Fi host is dialled at its address and,
    /// on every other attempt, at its `.local` name when it published one —
    /// the same road (this Wi-Fi), a second spelling of it. The app never
    /// moves a host from one road to the other by itself (Leo, 2026-10-01).
    static func dialURL(road: HostRoad, roads: [HostRoad], attempt: Int) -> URL? {
        if road.kind == .tailnet { return road.url }
        if attempt % 2 == 1,
           let local = roads.first(where: { $0.kind == .mdns && $0.host != road.host }) {
            return DiscoveredHost.url(host: local.host, port: road.port) ?? road.url
        }
        return road.url
    }

    /// The URL an authenticated one-off request (the SSH key check, a
    /// credential probe, Remote) goes to: the host's one road, else the
    /// account itself.
    static func dialURL(account: String, pins: HostPinStore = HostPinStore()) -> URL? {
        let canonical = HostAccount.canonical(account)
        return pins.load(account: canonical)?.road(account: canonical).url ?? URL(string: canonical)
    }

    /// TAIL-3b. Which road a host is on when its pin does not say: the
    /// address it was paired over. A `*.ts.net` name is Tailscale, anything
    /// else is this Wi-Fi.
    static func road(forAccount account: String) -> HostRoad? {
        guard let url = URL(string: account), let host = url.host, !host.isEmpty else { return nil }
        return HostRoad(host: host, port: url.port ?? 8099)
    }

    /// Merge what the host says now into what this device already holds. The
    /// host's own list wins for every address it still publishes. TAIL-3b:
    /// this list is what the host *says* about itself — its tailnet name for
    /// "Use Tailscale for this computer", its `.local` name — and never moves
    /// the road the host is dialled on.
    static func merge(_ stored: [HostRoad], _ fresh: [HostRoad]) -> [HostRoad] {
        guard !fresh.isEmpty else { return stored }
        var result: [HostRoad] = []
        for road in fresh where !result.contains(where: { $0.host == road.host && $0.port == road.port }) {
            result.append(road)
        }
        return Array(result.prefix(24))
    }
}

/// TAIL-3b. The words for a host's road: one word under the host name (H-A),
/// and a sentence with the address for VoiceOver and Settings.
enum HostRoadWords {
    static func word(_ road: HostRoad) -> String { road.kind.isTailscale ? Strings.roadTailscale : Strings.roadLAN }
    static func a11y(_ road: HostRoad) -> String {
        road.kind.isTailscale ? Strings.roadA11yTailscale(road.host) : Strings.roadA11yLAN(road.host)
    }
    static func sentence(_ road: HostRoad) -> String {
        road.kind.isTailscale ? Strings.hostRoadTailscale(road.host) : Strings.hostRoadLAN(road.host)
    }
}

/// TAIL-2 P0-4 / P1-1. `GET /v1/ssh/key`'s `target`: where the terminal is
/// now. The same shape as the claim's `ssh`.
struct SSHTargetDTO: Decodable, Equatable, Sendable {
    struct Road: Decodable, Equatable, Sendable { let host: String; let kind: String? }
    let user: String?
    let host: String?
    let port: Int?
    let hosts: [Road]?
    let tailscale_ssh: Bool?

    /// The pin's SSH endpoint with this target written in. A target with no
    /// usable user or host changes only the two TAIL-2 fields of what the
    /// claim already said.
    func endpoint(keeping current: HostPin.SSHEndpoint?) -> HostPin.SSHEndpoint? {
        let port = port.flatMap { (1...65535).contains($0) ? $0 : nil } ?? current?.port ?? 22
        let roads = hosts?.prefix(24).compactMap { road -> HostRoad? in
            SSHTargetResolver.isValidHost(road.host)
                ? HostRoad(host: road.host, port: port, kind: HostRoads.kind(road.kind, host: road.host)) : nil
        }
        if let user, let host, SSHTargetResolver.isValidAccount(user), SSHTargetResolver.isValidHost(host) {
            return HostPin.SSHEndpoint(user: user, host: host, port: port, hosts: roads ?? current?.hosts,
                                       tailscaleSSH: tailscale_ssh ?? current?.tailscaleSSH)
        }
        guard let current else { return nil }
        return HostPin.SSHEndpoint(user: current.user, host: current.host, port: current.port,
                                   hosts: roads ?? current.hosts, tailscaleSSH: tailscale_ssh ?? current.tailscaleSSH)
    }
}

protocol SSHTargetReading: Sendable {
    /// `nil` from a host from before TAIL-2, which publishes no target.
    func fetchSSHTarget() async throws -> SSHTargetDTO?
}

/// TAIL-2 P0-2. `GET /v1/host/roads` (authenticated): every road to the host
/// and, while Tailscale runs there, its MagicDNS name. Read over the pinned,
/// credentialed connection after each connect — never from the
/// unauthenticated `/health`, which only anchors host_id and fingerprint.
struct HostRoadsDTO: Decodable, Equatable, Sendable {
    struct Endpoint: Decodable, Equatable, Sendable { let host: String; let port: Int; let kind: String? }
    struct Tailnet: Decodable, Equatable, Sendable { let dns_name: String?; let ips: [String]? }
    let host_id: String?
    let tls_fingerprint_sha256: String?
    let endpoints: [Endpoint]?
    let tailnet: Tailnet?
    /// LITE-1b: where the host's Odomo is (`tailscale serve`), only
    /// while the front door is up. TAIL-3b I2 opens it in Safari.
    var odomo_url: String? = nil
    /// LITE-1d: `{url, push_devices}` — the same address, and how many of the
    /// host's web devices get Odomo's pushes. A count, never ids.
    struct Odomo: Decodable, Equatable, Sendable { let url: String?; let push_devices: Int? }
    var odomo: Odomo? = nil

    /// I2. Only an Odomo address of the shape core publishes: https, a
    /// `*.ts.net` name, an optional port, `/odomo/`. Anything else is ignored.
    var odomoURL: URL? {
        guard let value = odomo_url ?? odomo?.url, value.utf8.count <= 300, let url = URL(string: value),
              url.scheme == "https", let host = url.host, HostRoads.isMagicDNSName(host),
              url.path == "/odomo/" || url.path == "/odomo", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// LITE-1d. What the app knows about Odomo on this host; a count outside
    /// what core can send (0…64) is no count.
    var odomoReading: OdomoReading {
        OdomoReading(url: odomoURL, pushDevices: odomo?.push_devices.flatMap { (0...64).contains($0) ? $0 : nil })
    }

    /// Every road, typed, the MagicDNS name included once.
    var roads: [HostRoad] {
        var values = (endpoints ?? []).prefix(24).compactMap { value -> HostRoad? in
            guard !value.host.isEmpty, value.host.utf8.count <= 255, (1...65535).contains(value.port) else { return nil }
            return HostRoad(host: value.host, port: value.port, kind: HostRoads.kind(value.kind, host: value.host))
        }
        if let name = tailnetName, !values.contains(where: { $0.host == name }), let port = values.first?.port {
            values.append(HostRoad(host: name, port: port, kind: .tailnet))
        }
        return values
    }

    var tailnetName: String? {
        guard let name = tailnet?.dns_name?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased(),
              HostRoads.isMagicDNSName(name) else { return nil }
        return name
    }
}

protocol HostRoadsReading: Sendable {
    /// `nil` from a core from before the route (404) or on any failure: no
    /// update, nothing said.
    func fetchHostRoads() async -> HostRoadsDTO?
}
