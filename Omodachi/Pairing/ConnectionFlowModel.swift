import Foundation
import Combine

/// The hosts this device has paired with, so the Panel's switcher (N-26) and
/// Settings (N-27) can list more than the one currently connected.
///
/// The record is a label, not a credential: the credential and the pin already
/// live in their own Keychain services keyed by the same account string, so
/// this only has to remember which accounts exist and what to call them.
struct PairedHostRecord: Codable, Equatable, Identifiable, Sendable {
    /// PAIR-4 §4: always `HostAccount.canonical`. A record written by an older
    /// build is migrated to it when the directory loads.
    var account: String
    var hostID: String
    var hostName: String
    var address: String
    var id: String { account }

    var url: URL? { URL(string: account) }
    var candidate: HostCandidate? {
        guard let url else { return nil }
        return HostCandidate(id: hostID, name: hostName, hostIDSuffix: String(hostID.suffix(6)),
                             address: address, url: url, pairing: .paired)
    }
}

@MainActor final class PairedHostDirectory: ObservableObject {
    static let storageKey = "omodachi.pairedHosts.v1"
    private let defaults: UserDefaults
    @Published private(set) var records: [PairedHostRecord]

    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([PairedHostRecord].self, from: $0) } ?? []
        // PAIR-4 §4. A record written before the account had one derivation
        // (`https://Omarchy:8099`, `https://omarchy:8099/`) is rewritten to the
        // key the Keychain uses, here, once, so the row that describes it and
        // the credential that belongs to it can find each other again.
        var migrated: [PairedHostRecord] = []
        for var record in stored {
            record.account = HostAccount.canonical(record.account)
            if let index = migrated.firstIndex(where: { $0.account == record.account }) {
                migrated[index] = record
            } else {
                migrated.append(record)
            }
        }
        records = migrated
        if migrated != stored, let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func remember(_ record: PairedHostRecord) {
        var record = record
        record.account = HostAccount.canonical(record.account)
        var values = records.filter { $0.account != record.account }
        values.append(record)
        write(values.sorted { $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending })
    }

    func forget(account: String) {
        let account = HostAccount.canonical(account)
        write(records.filter { $0.account != account })
    }

    /// PAIR-4 §1: the directory's half of "is this host paired". The Keychain
    /// holds the other half, and the two disagreeing is the whole bug.
    func record(account: String) -> PairedHostRecord? {
        let account = HostAccount.canonical(account)
        return records.first { $0.account == account }
    }

    private func write(_ values: [PairedHostRecord]) {
        records = values
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// Study 03 §12–§13 as one state machine: the list and the waiting card are the
/// same panel (A-35), so they are the same model, and there is no success page
/// — a claim goes straight to the Panel.
@MainActor final class ConnectionFlowModel: ObservableObject {
    /// TAIL-3b: the first screen is the Tailscale page; the Wi-Fi road
    /// (Bonjour list, add by address) is behind "I don't use Tailscale".
    enum Stage: Equatable {
        case tailscale
        case wifi
        case manual
        case pairing
    }

    /// TAIL-3b E03–E06: why a name on the Tailscale page did not get as far
    /// as a pairing card. Said on that page, under the field.
    enum TailscaleProblem: Equatable {
        case notTailscale(String)
        case noName(String)
        case noPtr(String)
        case asleep(String)
        case noHost(String)
    }

    /// Every failure names one next step (N-24). `certificateChanged` is the
    /// only hard one: no "continue anyway" exists (N-21).
    enum Failure: Equatable {
        /// PAIR-2: the host answered `pairing_invitation_required`. It is the
        /// only state in which this app shows an invitation field, and a host
        /// on the shipped default never produces it.
        case locked
        case expired
        case rejected
        case certificateChanged(pinned: String, observed: String)
        case message(String)
    }

    @Published var stage: Stage = .tailscale
    /// TAIL-3b. What is in the Tailscale page's field, and what it resolves to.
    @Published var tailscaleInput = "" { didSet { if oldValue != tailscaleInput { inputChanged() } } }
    @Published private(set) var resolution: TailscaleResolution = .empty
    @Published private(set) var tailscaleProblem: TailscaleProblem?
    /// Where the pairing in progress started, so a failure goes back there.
    private(set) var origin: Stage = .tailscale
    private var resolveTask: Task<Void, Never>?
    @Published private(set) var candidate: HostCandidate?
    @Published private(set) var fingerprint: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var failure: Failure?
    @Published private(set) var running = false
    @Published private(set) var probing = false
    @Published var manualInput = ""
    /// Only ever typed into on a host that answered `pairing_invitation_required`.
    @Published var lockedInvitation = ""
    /// Which hosts said `pairing.mode == "invite"` on `/health`, keyed by the
    /// account URL. It is a list label, nothing more; the request finds out for
    /// real, and a host that never answered simply reads as unpaired.
    @Published private(set) var invitationOnlyHosts: Set<String> = []
    /// Set when the claim landed; the host list's owner swaps to the Panel.
    @Published private(set) var claimed: PairedHostRecord?
    /// The two grants the claim reported besides the credential itself.
    @Published private(set) var grants: HostPin.Grants?
    /// TAIL-3b E08: core said this device already holds a credential there.
    @Published private(set) var alreadyPaired = false

    /// PAIR-4 §2: bumped whenever this device's own records change under the
    /// list, so the rows — which read the Keychain while they are being drawn —
    /// are rebuilt after a "忘记这台主机".
    @Published private(set) var revision = 0

    /// REMOTE-PAIR-1: settles to the id a live credential was issued to when
    /// one is adopted, so a pairing started later from this screen goes up
    /// under the id the host already knows.
    private(set) var deviceID: String
    let deviceName: String
    private let pins: HostPinStore
    private let credentials: CompanionCredentialStore
    private let hostKeys: HostKeyStore
    private let directory: PairedHostDirectory?
    private let probe: HostHealthProbe
    private let makeClient: (URL) throws -> PairingClient
    private let makeProbe: (URL, String) -> CredentialProbe
    /// REMOTE-PAIR-1: `CompanionDeviceIdentity.adopt`, and how long a refusal
    /// with no reason waits to be asked about again. Tests replace both.
    private let adoptIdentity: (String) -> String?
    private let confirmationDelay: Duration
    private var client: PairingClient?
    private var task: Task<Void, Never>?
    private var sshPublicKey: String?
    /// UX-4 §2. Which Keychain account this device's SSH key lives under, so
    /// the key can be re-offered after a claim that did not carry one.
    private var sshKeyAccount: String?
    private let keyOffer: (any SSHKeyOffering)?
    /// TAIL-2 P0-0 (c): the reverse lookup a typed tailnet address goes through.
    private let nameResolver: any TailnetNameResolving
    private var modeProbe: Task<Void, Never>?
    private var probedModes: Set<String> = []

    init(deviceID: String, deviceName: String,
         pins: HostPinStore = HostPinStore(),
         credentials: CompanionCredentialStore = CompanionCredentialStore(),
         hostKeys: HostKeyStore = HostKeyStore(),
         directory: PairedHostDirectory? = nil,
         probe: HostHealthProbe = HostHealthProbe(),
         keyOffer: (any SSHKeyOffering)? = SSHKeyOffer(),
         nameResolver: any TailnetNameResolving = SystemTailnetNameResolver(),
         makeClient: @escaping (URL) throws -> PairingClient = { try PairingClient(endpoint: $0) },
         makeProbe: @escaping (URL, String) -> CredentialProbe = {
             CredentialProbe(endpoint: $0, pinnedFingerprint: $1)
         },
         adoptIdentity: @escaping (String) -> String? = { CompanionDeviceIdentity.adopt(credential: $0) },
         confirmationDelay: Duration = .seconds(2)) {
        self.deviceID = deviceID
        self.adoptIdentity = adoptIdentity
        self.confirmationDelay = confirmationDelay
        self.deviceName = deviceName
        self.pins = pins
        self.credentials = credentials
        self.hostKeys = hostKeys
        self.directory = directory
        self.probe = probe
        self.keyOffer = keyOffer
        self.nameResolver = nameResolver
        self.makeClient = makeClient
        self.makeProbe = makeProbe
    }

    /// N-20: the chip comes from this device's own records, nothing on the wire.
    ///
    /// PAIR-4 §1: there are two of those records and they can disagree. The
    /// credential lives in the Keychain, which survives the app being deleted
    /// and reinstalled; the directory record lives in the app container, which
    /// does not. A row whose credential is here and whose directory record is
    /// not is not "unpaired" — it is the state that used to have no exit, and
    /// it now says so: 已配对（待确认）, and one tap settles it.
    func decorate(_ candidate: HostCandidate) -> HostCandidate {
        var value = candidate
        let account = candidate.account
        value.invitationOnly = invitationOnlyHosts.contains(account)
        let pin = pins.load(account: account)
        // The same address serving a different installation is not this pin's
        // host, so it is still an unpaired row rather than a wrong green chip.
        if let pin, let suffix = candidate.hostIDSuffix, !pin.hostID.hasSuffix(suffix) { return value }
        guard storedCredential(account: account) != nil else { return value }
        value.pairing = pin != nil && directory?.record(account: account) != nil ? .paired : .unconfirmed
        return value
    }

    /// PAIR-4 §2: whether this device is holding *anything* for that row — a
    /// credential, a pin, or a directory record. Every such row offers 忘记这台
    /// 主机 inline, including the ones whose chip still reads 未配对 because the
    /// only thing left is a pin.
    func hasStoredIdentity(_ candidate: HostCandidate) -> Bool {
        let account = candidate.account
        return storedCredential(account: account) != nil
            || pins.load(account: account) != nil
            || directory?.record(account: account) != nil
    }

    private func storedCredential(account: String) -> String? {
        guard let token = try? credentials.loadToken(account: account), !token.isEmpty else { return nil }
        return token
    }

    /// PAIR-4 §2. Everything this device holds for one host, gone, without
    /// asking the host anything: credential, pin, the SSH host key that pin
    /// named, and the directory record. The host's own three grants are
    /// revoked on the computer, and the row says so.
    @discardableResult
    func forget(account: String) -> Bool {
        let complete = HostForget.run(account: account, directory: directory,
                                      pins: pins, credentials: credentials, hostKeys: hostKeys)
        revision += 1
        return complete
    }

    /// PAIR-2 §3.3: the row says "需要邀请" instead of "未配对" when this host is
    /// locked. `/health` is unauthenticated and cheap, and each host is asked
    /// once per appearance of the list.
    func probePairingModes(_ candidates: [HostCandidate]) {
        let unknown = candidates.filter { !probedModes.contains($0.account) }
        guard !unknown.isEmpty else { return }
        for candidate in unknown { probedModes.insert(candidate.account) }
        modeProbe?.cancel()
        modeProbe = Task { [weak self] in
            guard let self else { return }
            for candidate in unknown {
                guard !Task.isCancelled else { return }
                guard let health = try? await probe.read(candidate.url) else { continue }
                if health.invitationOnly { invitationOnlyHosts.insert(candidate.account) }
                else { invitationOnlyHosts.remove(candidate.account) }
            }
        }
    }

    // MARK: - TAIL-3b the Tailscale page

    /// S02: the name the field will connect as, shown before Connect. Looked
    /// up 350 ms after the last keystroke (or at once for a paste).
    private func inputChanged(delay: Duration = .milliseconds(350)) {
        resolveTask?.cancel()
        tailscaleProblem = nil
        let typed = tailscaleInput
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { resolution = .empty; return }
        resolution = .resolving
        resolveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let answer = await self.resolveTailscale(typed)
            guard !Task.isCancelled, self.tailscaleInput == typed else { return }
            self.resolution = answer
        }
    }

    func resolveTailscale(_ input: String) async -> TailscaleResolution {
        await TailscaleName.resolve(input, resolver: nameResolver, known: knownTailnetNames())
    }

    /// The Paste button: the pasteboard is read only on this tap.
    func paste(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        tailscaleInput = String(text.prefix(255))
        inputChanged(delay: .zero)
    }

    /// Connect on the Tailscale page. Only a name that became a `*.ts.net`
    /// name is dialled; anything else is said on the page (E04b / E04 / E05).
    func connectTailscale(sshPublicKey: String?, sshKeyAccount: String? = nil) {
        resolveTask?.cancel()
        let typed = tailscaleInput
        tailscaleProblem = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let answer: TailscaleResolution
            if case .resolved = self.resolution { answer = self.resolution }
            else { answer = await self.resolveTailscale(typed) }
            guard !Task.isCancelled, self.tailscaleInput == typed else { return }
            self.resolution = answer
            switch answer {
            case let .resolved(url):
                let candidate = HostCandidate(id: url.absoluteString, name: ConnectionFlowModel.firstLabel(url.host ?? ""),
                                              hostIDSuffix: nil, address: url.host ?? "", url: url)
                self.select(self.decorate(candidate), sshPublicKey: sshPublicKey, sshKeyAccount: sshKeyAccount,
                            from: .tailscale)
            case let .notTailscale(name): self.tailscaleProblem = .notTailscale(name)
            case let .noName(name): self.tailscaleProblem = .noName(name)
            case let .noPtr(address): self.tailscaleProblem = .noPtr(address)
            case .empty, .resolving: break
            }
        }
    }

    /// E03 / E04 / E06 from the first read of the name.
    static func problem(_ error: Error, name: String) -> TailscaleProblem {
        switch error as? HostHealthError {
        case .noSuchName?: .noName(name)
        case .refused?, .notAnOmodachiHost?: .noHost(name)
        default: .asleep(name)
        }
    }

    func select(_ candidate: HostCandidate, sshPublicKey: String?, sshKeyAccount: String? = nil,
                from origin: Stage? = nil) {
        cancel()
        // Only the Tailscale page names itself; every other selection is a
        // row on the Wi-Fi road (the list, or "Add by name or address").
        self.origin = origin ?? .wifi
        self.candidate = candidate
        self.sshPublicKey = sshPublicKey
        self.sshKeyAccount = sshKeyAccount
        fingerprint = nil
        failure = nil
        expiresAt = nil
        claimed = nil
        grants = nil
        alreadyPaired = false
        tailscaleProblem = nil
        stage = .pairing
        probing = true
        task = Task { [weak self] in
            guard let self else { return }
            // TAIL-2 P0-0 (c). ATS lets this app reach a `*.ts.net` name,
            // never a tailnet address literal, so a typed 100.x would only
            // ever fail in the TLS handshake as "could not finish securely".
            // It becomes a MagicDNS name — a paired host's own, else the
            // system resolver's reverse answer — or the sentence that says
            // what to type.
            var candidate = candidate
            if let host = candidate.url.host, HostRoads.isTailnetAddress(host) {
                let typed = [host.contains(":") ? "[\(host)]" : host, candidate.url.port.map(String.init)]
                    .compactMap { $0 }.joined(separator: ":")
                guard let named = await resolveTailscale(typed).url else {
                    guard !Task.isCancelled else { return }
                    probing = false
                    failure = .message(PairingError.tailnetAddress.localizedDescription)
                    return
                }
                guard !Task.isCancelled else { return }
                candidate = Self.candidate(candidate, renamedTo: named)
                self.candidate = candidate
            }
            // TAIL-3b. A bare name is resolved on the Tailscale page, never
            // here: on the Wi-Fi road ("Add by name or address") it is a LAN
            // name, as typed.
            let health: HostHealth?
            do { health = try await probe.read(candidate.url) }
            catch {
                guard !Task.isCancelled else { return }
                // On the Tailscale page a name that does not get this far is
                // said there (E03/E04/E06), not on a pairing card.
                if self.origin == .tailscale {
                    probing = false
                    tailscaleProblem = Self.problem(error, name: Self.firstLabel(candidate.url.host ?? ""))
                    stage = .tailscale
                    return
                }
                health = nil
            }
            guard !Task.isCancelled else { return }
            probing = false
            fingerprint = health?.fingerprint
            let account = candidate.account
            if let health {
                if health.invitationOnly { invitationOnlyHosts.insert(account) }
                else { invitationOnlyHosts.remove(account) }
                probedModes.insert(account)
            }
            let pin = pins.load(account: account)
            // A host whose certificate no longer matches the one this device
            // pinned is a hard stop, before any request is sent (N-21).
            if let pin, let observed = health?.fingerprint, observed != pin.fingerprintSHA256 {
                failure = .certificateChanged(pinned: pin.fingerprintSHA256, observed: observed)
                return
            }
            // PAIR-4 §1/§3: a credential this device is already holding is
            // settled here — adopted or thrown away — before any request goes
            // out. It is never a refusal with nowhere to go.
            if await adoptStoredCredential(candidate: candidate, pin: pin) { return }
            guard !Task.isCancelled else { return }
            // TAIL-2 P0-2. No pin under *this* address — but the host may be
            // one this device is already paired with, reached on another road
            // (its MagicDNS name away from home, its LAN address back home).
            // A host is its `host_id` and its certificate, not an address.
            if pin == nil, let health, await adoptOnAnotherRoad(candidate: candidate, health: health) { return }
            guard !Task.isCancelled else { return }
            guard !Task.isCancelled else { return }
            await self.requestPairing()
        }
    }

    /// PAIR-4 §1. Returns `true` when this tap is already finished: the
    /// credential was adopted and the Panel is next, or the host could not be
    /// asked and the card says which. `false` means there is nothing left in
    /// the way of an ordinary pairing request.
    private func adoptStoredCredential(candidate: HostCandidate, pin: HostPin?) async -> Bool {
        let account = candidate.account
        guard let token = storedCredential(account: account) else { return false }
        // The credential is this device's secret, so it is only ever put on a
        // connection whose certificate this device pinned. A credential whose
        // pin is gone therefore cannot be checked without handing it to
        // whoever answers that address — so it is not checked, it is deleted,
        // and the tap becomes the ordinary pairing it would have been.
        guard let pin else {
            forget(account: account)
            return false
        }
        let verdict = await makeProbe(candidate.url, pin.fingerprintSHA256)
            .checkConfirmed(token: token, retryAfter: confirmationDelay)
        guard !Task.isCancelled else { return true }
        switch verdict {
        case .live:
            // The host answered an authenticated read over the certificate this
            // device pinned. That is the whole proof: nothing is re-issued, no
            // request is sent, and the host sees no pending approval.
            //
            // REMOTE-PAIR-1: and the credential names the id the host knows
            // this device by. A reinstall that adopts it without that is how
            // the id and the credential came apart on Leo's iPhone.
            if let adopted = adoptIdentity(token) { deviceID = adopted }
            //
            // UX-4 §2: and that last part is exactly what left the SSH key
            // behind. The key goes up *with* a pairing request, and this path
            // sends none — correctly, nothing needs re-issuing — so a device
            // that was reinstalled adopts a live credential while holding a
            // private key the host has never seen. One round trip settles it.
            await reconcileSSHKey(account: account)
            grants = pin.grants
            claimed = PairedHostRecord(account: account, hostID: pin.hostID,
                                       hostName: pin.hostName.isEmpty ? candidate.name : pin.hostName,
                                       address: candidate.address)
            return true
        case .rejected:
            // The computer revoked this device. The credential is rubbish and
            // holding on to it is exactly what used to block re-pairing.
            forget(account: account)
            return false
        case .unreachable:
            // Not a revocation. Nothing is deleted, and the card offers the
            // two exits every other failure has.
            failure = .message(Strings.pairCredentialUnverified)
            return true
        }
    }

    /// The same row, reached under another name.
    private static func candidate(_ candidate: HostCandidate, renamedTo url: URL) -> HostCandidate {
        HostCandidate(id: url.absoluteString, name: candidate.name, hostIDSuffix: candidate.hostIDSuffix,
                      address: [url.host, url.port.map(String.init)].compactMap { $0 }.joined(separator: ":"),
                      url: url, pairing: candidate.pairing)
    }

    /// A host name with no dot that is not an address: what the Tailscale app
    /// shows as a machine's name.
    nonisolated static func isShortName(_ host: String) -> Bool {
        !host.isEmpty && !host.contains(".") && !host.contains(":")
            && host.unicodeScalars.contains { CharacterSet.letters.contains($0) || $0 == "-" }
    }

    nonisolated static func firstLabel(_ name: String) -> String {
        String(name.lowercased().split(separator: ".", maxSplits: 1).first ?? "")
    }

    /// TAIL-2 P0-0. Every tailnet address a paired host published, mapped to
    /// that host's MagicDNS name: a typed 100.x of a known host needs no lookup.
    private func knownTailnetNames() -> [String: String] {
        var names: [String: String] = [:]
        for record in directory?.records ?? [] {
            guard let pin = pins.load(account: record.account), let name = pin.tailnetName else { continue }
            for road in pin.roads where HostRoads.isTailnetAddress(road.host) { names[road.host.lowercased()] = name }
        }
        return names
    }

    /// TAIL-2 P0-2. The paired host whose `host_id` and pinned fingerprint
    /// this `/health` names, if there is one.
    private func pairedHost(matching health: HostHealth) -> (record: PairedHostRecord, pin: HostPin)? {
        guard let hostID = health.hostID, let fingerprint = health.fingerprint else { return nil }
        for record in directory?.records ?? [] {
            if let pin = pins.load(account: record.account), pin.hostID == hostID,
               pin.fingerprintSHA256 == fingerprint {
                return (record, pin)
            }
        }
        return nil
    }

    /// TAIL-2 P0-2. Returns `true` when this tap is finished: the credential
    /// this device holds for that host was checked on *this* road and adopted
    /// — no pairing request, no second row — or the check could not be made
    /// and the card says so. The credential only ever goes onto a connection
    /// pinned to the certificate it was issued with, so the document's
    /// `host_id` is a hint and the pinned handshake is the proof.
    private func adoptOnAnotherRoad(candidate: HostCandidate, health: HostHealth) async -> Bool {
        guard let (record, pin) = pairedHost(matching: health),
              let token = storedCredential(account: record.account) else { return false }
        let verdict = await makeProbe(candidate.url, pin.fingerprintSHA256)
            .checkConfirmed(token: token, retryAfter: confirmationDelay)
        guard !Task.isCancelled else { return true }
        switch verdict {
        case .live:
            if let adopted = adoptIdentity(token) { deviceID = adopted }
            // TAIL-3b. Reaching an already-paired Wi-Fi host by its Tailscale
            // name is the user choosing Tailscale for it: the one road moves,
            // and nothing else (no pairing, no second row). The other way —
            // a Tailscale host found again on the Wi-Fi — changes nothing:
            // there is no "back to Wi-Fi only" (forget it and pair again).
            let typed = HostRoad(host: candidate.url.host ?? "", port: candidate.url.port ?? 8099)
            if typed.kind.isTailscale, !pin.road(account: record.account).kind.isTailscale {
                var updated = pin
                updated.road = typed
                try? pins.save(updated, account: record.account)
                ManualHostTrace.note("moved \(record.hostName) to tailscale \(typed.host)")
            }
            await reconcileSSHKey(account: record.account)
            grants = pin.grants
            claimed = PairedHostRecord(account: record.account, hostID: pin.hostID,
                                       hostName: pin.hostName.isEmpty ? record.hostName : pin.hostName,
                                       address: record.address)
            return true
        case .rejected:
            // The host no longer knows this device; an ordinary request follows.
            return false
        case .unreachable:
            failure = .message(Strings.pairCredentialUnverified)
            return true
        }
    }

    /// UX-4 §2. After a claim or an adoption, check that the key this device
    /// would authenticate with is one the host actually holds, and offer it if
    /// it is not.
    ///
    /// It is a read first and a write only on disagreement, so the ordinary
    /// pairing — where the key went up with the request — costs one GET and
    /// changes nothing on the host. Nothing here can fail the pairing: a host
    /// that will not answer this leaves the device paired, and the SSH panel's
    /// own repair (UX-4 §2, `TerminalRuntime`) is the second chance.
    private func reconcileSSHKey(account: String) async {
        guard let keyOffer, let keyAccount = sshKeyAccount else { return }
        guard let report = try? await keyOffer.read(account: account, keyAccount: keyAccount),
              !report.matches else { return }
        _ = try? await keyOffer.offer(account: account, keyAccount: keyAccount)
    }

    /// PAIR-2 §3.2: the only invitation touchpoint left. It exists for a host
    /// that answered `pairing_invitation_required`, and nothing else reaches it.
    func submitLockedInvitation() {
        let code = lockedInvitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PairingClient.validSecret(code) else {
            failure = .message(Strings.pairInvitationShape)
            return
        }
        task = Task { [weak self] in await self?.requestPairing(invitation: code) }
    }

    /// The default path sends no invitation at all: the request becomes pending
    /// on the host and the waiting card starts counting down immediately.
    private func requestPairing(invitation: String? = nil) async {
        guard let candidate else { return }
        running = true
        failure = nil
        defer { running = false }
        do {
            let client = try makeClient(candidate.url)
            self.client = client
            let receipt = try await client.begin(deviceID: deviceID, deviceName: deviceName,
                                                 sshPublicKey: sshPublicKey, invitation: invitation)
            lockedInvitation = ""
            invitationOnlyHosts.remove(candidate.account)
            expiresAt = receipt.expiresAt
            alreadyPaired = receipt.alreadyPaired
            if let observed = await client.observedFingerprint { fingerprint = observed }
            await poll(client: client, candidate: candidate, receipt: receipt)
        } catch let error as PairingError {
            failure = Self.describe(error)
        } catch is CancellationError {
        } catch {
            failure = .message(PairingError.transport.localizedDescription)
        }
    }

    private func poll(client: PairingClient, candidate: HostCandidate, receipt: PairingReceipt) async {
        while !Task.isCancelled {
            do {
                let result = try await client.claim()
                if result.status == .claimed {
                    // UX-4 §2. The request carried the key, so this normally
                    // agrees and costs one read. It is here anyway because a
                    // claim whose `grants.ssh` is false, or whose key the host
                    // could not write, ends up in the same place a drift does
                    // — and finding that out now beats finding it out from a
                    // terminal that will not open.
                    await reconcileSSHKey(account: candidate.account)
                    let pin = pins.load(account: candidate.account)
                    grants = pin?.grants
                    claimed = PairedHostRecord(account: candidate.account,
                                               hostID: pin?.hostID ?? "",
                                               hostName: pin?.hostName ?? candidate.name,
                                               address: candidate.address)
                    return
                }
            } catch let error as PairingError {
                failure = Self.describe(error)
                return
            } catch is CancellationError {
                return
            } catch {
                failure = .message(PairingError.transport.localizedDescription)
                return
            }
            if let expiresAt, expiresAt <= Date() {
                failure = .expired
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// N-21: only the fingerprint moves. `host_id` and the credential do not,
    /// so trusting a rotation never means pairing again.
    func trustRotatedCertificate() {
        guard let candidate, case let .certificateChanged(_, observed) = failure,
              let pin = pins.load(account: candidate.account) else { return }
        do {
            try pins.trustRotatedCertificate(hostID: pin.hostID, fingerprint: observed,
                                             account: candidate.account)
            failure = nil
            claimed = PairedHostRecord(account: candidate.account, hostID: pin.hostID,
                                       hostName: pin.hostName, address: candidate.address)
        } catch {
            failure = .message(Strings.pairFingerprintSaveFailed)
        }
    }

    func retry() {
        guard let candidate else { return }
        select(candidate, sshPublicKey: sshPublicKey, sshKeyAccount: sshKeyAccount, from: origin)
    }

    func cancel() {
        task?.cancel()
        task = nil
        modeProbe?.cancel()
        modeProbe = nil
        let previous = client
        client = nil
        running = false
        probing = false
        Task { await previous?.cancel() }
    }

    func backToList() {
        cancel()
        stage = origin == .wifi || origin == .manual ? .wifi : .tailscale
        candidate = nil
        failure = nil
        expiresAt = nil
        fingerprint = nil
        lockedInvitation = ""
    }

    static func describe(_ error: PairingError) -> Failure {
        switch error {
        case .invitationRequired: .locked
        case .rejectedOrExpired: .rejected
        case .cancelled: .message(PairingError.cancelled.localizedDescription)
        default: .message(error.localizedDescription)
        }
    }
}
