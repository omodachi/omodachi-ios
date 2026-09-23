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
    enum Stage: Equatable {
        case list
        case manual
        case pairing
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

    @Published var stage: Stage = .list
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

    /// PAIR-4 §2: bumped whenever this device's own records change under the
    /// list, so the rows — which read the Keychain while they are being drawn —
    /// are rebuilt after a "忘记这台主机".
    @Published private(set) var revision = 0

    let deviceID: String
    let deviceName: String
    private let pins: HostPinStore
    private let credentials: CompanionCredentialStore
    private let hostKeys: HostKeyStore
    private let directory: PairedHostDirectory?
    private let probe: HostHealthProbe
    private let makeClient: (URL) throws -> PairingClient
    private let makeProbe: (URL, String) -> CredentialProbe
    private var client: PairingClient?
    private var task: Task<Void, Never>?
    private var sshPublicKey: String?
    /// UX-4 §2. Which Keychain account this device's SSH key lives under, so
    /// the key can be re-offered after a claim that did not carry one.
    private var sshKeyAccount: String?
    private let keyOffer: (any SSHKeyOffering)?
    private var modeProbe: Task<Void, Never>?
    private var probedModes: Set<String> = []

    init(deviceID: String, deviceName: String,
         pins: HostPinStore = HostPinStore(),
         credentials: CompanionCredentialStore = CompanionCredentialStore(),
         hostKeys: HostKeyStore = HostKeyStore(),
         directory: PairedHostDirectory? = nil,
         probe: HostHealthProbe = HostHealthProbe(),
         keyOffer: (any SSHKeyOffering)? = SSHKeyOffer(),
         makeClient: @escaping (URL) throws -> PairingClient = { try PairingClient(endpoint: $0) },
         makeProbe: @escaping (URL, String) -> CredentialProbe = {
             CredentialProbe(endpoint: $0, pinnedFingerprint: $1)
         }) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pins = pins
        self.credentials = credentials
        self.hostKeys = hostKeys
        self.directory = directory
        self.probe = probe
        self.keyOffer = keyOffer
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

    func select(_ candidate: HostCandidate, sshPublicKey: String?, sshKeyAccount: String? = nil) {
        cancel()
        self.candidate = candidate
        self.sshPublicKey = sshPublicKey
        self.sshKeyAccount = sshKeyAccount
        fingerprint = nil
        failure = nil
        expiresAt = nil
        claimed = nil
        grants = nil
        stage = .pairing
        probing = true
        task = Task { [weak self] in
            guard let self else { return }
            let health = try? await probe.read(candidate.url)
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
        let verdict = await makeProbe(candidate.url, pin.fingerprintSHA256).check(token: token)
        guard !Task.isCancelled else { return true }
        switch verdict {
        case .live:
            // The host answered an authenticated read over the certificate this
            // device pinned. That is the whole proof: nothing is re-issued, no
            // request is sent, and the host sees no pending approval.
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
        select(candidate, sshPublicKey: sshPublicKey, sshKeyAccount: sshKeyAccount)
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
        stage = .list
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
