import Foundation
import Combine

/// TAIL-3b L03 / L03b / L04. "Use Tailscale for this computer": the one time a
/// Wi-Fi host's road changes, and only because the user asked.
///
/// The switch happens only after the name answers as *this* host: the same
/// `host_id` on `/health`, the pinned certificate on the handshake, and this
/// device's own credential accepted over it (TAIL-2's same-host proof). No
/// new pairing, no second row; the credential, the pin and the account stay
/// where they are, and only `HostPin.road` moves to the MagicDNS name.
@MainActor final class TailscaleMoveModel: ObservableObject {
    enum State: Equatable {
        case idle
        case checking(String)
        case done
        case notSame(String)
        case noAnswer(String)
        case problem(TailscaleResolution)
    }

    let account: String
    let hostName: String
    @Published var input: String
    @Published private(set) var state: State = .idle
    /// L03 vs L03b: the host told this device its tailnet name.
    let knownName: String?

    private let pins: HostPinStore
    private let credentials: CompanionCredentialStore
    private let resolver: any TailnetNameResolving
    private let readHealth: (URL) async throws -> HostHealth
    private let makeProbe: (URL, String) -> CredentialProbe

    init(account: String, hostName: String,
         pins: HostPinStore = HostPinStore(),
         credentials: CompanionCredentialStore = CompanionCredentialStore(),
         resolver: any TailnetNameResolving = SystemTailnetNameResolver(),
         readHealth: ((URL) async throws -> HostHealth)? = nil,
         makeProbe: ((URL, String) -> CredentialProbe)? = nil) {
        self.account = HostAccount.canonical(account)
        self.hostName = hostName
        self.pins = pins
        self.credentials = credentials
        self.resolver = resolver
        self.readHealth = readHealth ?? { url in try await HostHealthProbe(timeout: 6).read(url) }
        self.makeProbe = makeProbe ?? { CredentialProbe(endpoint: $0, pinnedFingerprint: $1) }
        // Prefilled from what `GET /v1/host/roads` taught this device while
        // it was on the Wi-Fi.
        knownName = pins.load(account: self.account)?.tailnetName
        input = knownName ?? ""
    }

    var running: Bool { if case .checking = state { true } else { false } }

    /// Returns `true` when the host now uses Tailscale.
    @discardableResult
    func run() async -> Bool {
        let resolution = await TailscaleName.resolve(input, resolver: resolver)
        guard let url = resolution.url, let name = url.host else {
            state = .problem(resolution)
            return false
        }
        state = .checking(name)
        guard let pin = pins.load(account: account),
              let token = try? credentials.loadToken(account: account), !token.isEmpty else {
            state = .noAnswer(name)
            return false
        }
        let health: HostHealth
        do { health = try await readHealth(url) }
        catch { state = .noAnswer(name); return false }
        guard health.hostID == pin.hostID, health.fingerprint == pin.fingerprintSHA256 else {
            state = .notSame(name)
            return false
        }
        switch await makeProbe(url, pin.fingerprintSHA256).check(token: token) {
        case .live:
            var updated = pin
            updated.road = HostRoad(host: name, port: url.port ?? 8099, kind: .tailnet)
            do { try pins.save(updated, account: account) } catch { state = .noAnswer(name); return false }
            ManualHostTrace.note("moved \(hostName) to tailscale \(name)")
            state = .done
            return true
        case .rejected:
            // The name answers with this host's certificate but does not take
            // this device's credential: not the host this device is paired with.
            state = .notSame(name)
            return false
        case .unreachable:
            state = .noAnswer(name)
            return false
        }
    }
}
