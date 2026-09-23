import Foundation
import Network

/// One `_omodachi._tcp` instance as the LAN advertises it. Everything here is
/// public network metadata: a malicious peer can spoof all of it, so nothing in
/// this type establishes authorization or TLS trust. `fingerprintPrefix` is the
/// 16-hex label that tells two hosts apart in a list, never a value to pin.
struct DiscoveredHost: Identifiable, Equatable, Sendable {
    let instanceName: String
    let hostID: String?
    let hostName: String?
    let port: Int?
    let fingerprintPrefix: String?
    let addresses: [String]

    var id: String { hostID ?? instanceName }
    var displayName: String { hostName ?? instanceName }
    /// The address the app should try first: a resolved LAN address when one is
    /// known, otherwise the advertised `.local` name.
    var preferredURL: URL? {
        guard let port else { return nil }
        for address in addresses {
            if let url = Self.url(host: address, port: port) { return url }
        }
        guard let hostName, !hostName.isEmpty else { return nil }
        return Self.url(host: hostName.hasSuffix(".local") ? hostName : hostName + ".local", port: port)
    }
    var originHint: String { preferredURL?.absoluteString ?? instanceName }

    static func url(host: String, port: Int) -> URL? {
        let literal = host.contains(":") ? "[\(host)]" : host
        return URL(string: "https://\(literal):\(port)")
    }
}

/// What the host list is actually showing, which is not the same question as
/// "are there any hosts". Each case is one of Study 03 §12's boards, and each
/// one has to offer an exit (A-33); the view never has to infer a state from a
/// combination of booleans.
enum HostDiscoveryState: Equatable, Sendable {
    /// The browser is up and has found something.
    case results
    /// The browser is up and has found nothing yet.
    case searching
    /// The browser is up and has been running long enough that "nothing here"
    /// is an answer rather than a wait.
    case empty
    /// iOS has not granted local network access. On iPadOS the Settings row for
    /// it does not exist until the app has triggered the system prompt once, so
    /// the first exit is "ask again", not "go to Settings".
    case denied
    /// Any other `NWBrowser` failure, carrying the one line worth showing.
    case unavailable(String)
}

/// Browses `_omodachi._tcp` and resolves each instance to addresses and TXT.
/// Discovery never saves a credential, suppresses a certificate error or pairs;
/// manual HTTPS-address entry stays available whatever this reports.
@MainActor final class HostBrowser: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var failure: String?
    @Published private(set) var browsing = false
    /// How long a browse has to run before an empty LAN is reported as an
    /// answer. Below this it is still "looking".
    static let settleSeconds: TimeInterval = 4

    /// Set when the browser has reported `policyDenied` at least once in this
    /// launch. A denied browser goes quiet rather than failing repeatedly, so
    /// the flag has to outlive the state it was observed in.
    @Published private(set) var permissionDenied = false
    private var startedAt: Date?
    private var settled = false
    private var settleTask: Task<Void, Never>?

    /// Which of Study 03 §12's boards to draw.
    var state: HostDiscoveryState {
        if permissionDenied { return .denied }
        if let failure { return .unavailable(failure) }
        if !hosts.isEmpty { return .results }
        return settled ? .empty : .searching
    }

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private var resolved: [String: [String]] = [:]
    private var advertised: [String: DiscoveredHost] = [:]

    /// The one injection seam the simulator cannot reach: a real permission
    /// refusal. Tests drive the same path `stateUpdateHandler` does.
    func apply(state: NWBrowser.State) {
        switch state {
        case .ready:
            browsing = true
            failure = nil
            permissionDenied = false
        case .waiting(let error), .failed(let error):
            browsing = false
            if Self.isPolicyDenied(error) {
                permissionDenied = true
                failure = nil
            } else {
                failure = Self.explain(error)
            }
        case .cancelled:
            browsing = false
        default:
            break
        }
    }

    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return true }
        if case let .posix(code) = error, code == .EPERM { return true }
        return false
    }

    func start() {
        guard browser == nil else { return }
        startedAt = Date()
        settled = false
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.settled = true }
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_omodachi._tcp", domain: "local."), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.apply(state: state)
                if case .failed = state { self?.stop() }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel(); browser = nil
        for connection in resolvers.values { connection.cancel() }
        resolvers.removeAll()
        browsing = false
        settleTask?.cancel(); settleTask = nil
    }

    /// "Ask again": a fresh browser is the only thing that can make iOS show
    /// the system prompt, and on iPadOS the Settings row does not exist until
    /// it has been shown once.
    func retry() {
        stop()
        permissionDenied = false
        failure = nil
        start()
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            seen.insert(name)
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                for key in ["host_id", "host_name", "port", "fp", "v", "scheme"] {
                    if case let .string(value) = record.getEntry(for: key) { txt[key] = value }
                }
            }
            advertised[name] = DiscoveredHost(
                instanceName: name,
                hostID: txt["host_id"],
                hostName: txt["host_name"],
                port: txt["port"].flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil },
                fingerprintPrefix: txt["fp"],
                addresses: resolved[name] ?? [])
            resolve(result.endpoint, name: name)
        }
        for name in advertised.keys where !seen.contains(name) {
            advertised[name] = nil; resolved[name] = nil
            resolvers.removeValue(forKey: name)?.cancel()
        }
        publish()
    }

    /// NWBrowser reports a service name, not addresses. A short-lived connection
    /// is the supported way to learn the resolved endpoint; it is cancelled as
    /// soon as the path is known and never sends a byte.
    private func resolve(_ endpoint: NWEndpoint, name: String) {
        guard resolvers[name] == nil, resolved[name] == nil else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready, .preparing:
                guard case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else { return }
                let text: String
                switch host {
                case .ipv4(let value): text = "\(value)".split(separator: "%").first.map(String.init) ?? "\(value)"
                case .ipv6(let value): text = "\(value)".split(separator: "%").first.map(String.init) ?? "\(value)"
                case .name(let value, _): text = value
                @unknown default: return
                }
                Task { @MainActor in self?.record(address: text, for: name) }
            case .failed, .cancelled:
                Task { @MainActor in self?.resolvers[name] = nil }
            default: break
            }
        }
        connection.start(queue: .main)
    }

    private func record(address: String, for name: String) {
        var values = resolved[name] ?? []
        guard !values.contains(address) else { return }
        values.append(address)
        resolved[name] = values
        resolvers.removeValue(forKey: name)?.cancel()
        if let existing = advertised[name] {
            advertised[name] = DiscoveredHost(instanceName: existing.instanceName, hostID: existing.hostID,
                hostName: existing.hostName, port: existing.port,
                fingerprintPrefix: existing.fingerprintPrefix, addresses: values)
        }
        publish()
    }

    private func publish() {
        hosts = advertised.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func explain(_ error: NWError) -> String {
        if isPolicyDenied(error) {
            return Strings.discoveryPermissionDenied
        }
        return Strings.discoveryUnavailable
    }
}
