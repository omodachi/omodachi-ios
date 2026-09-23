import Combine
import Foundation

/// PAIR-5 §2. **The host list is the only source of truth.**
///
/// PAIR-4 settled what happens when a row in the list is tapped: the credential
/// this device is already holding is adopted or thrown away before any pairing
/// request goes out. What it could not settle is the case where the list is
/// never reached — once a directory record exists the Shell draws the Panel and
/// nothing asks the host whether the credential behind that record still works.
/// AGENT-2 §9.4 is that gap: a device whose credential the host refuses sits in
/// the Panel with a red dot and "The host rejected companion authorization" on
/// ①, forever, because the one screen that could settle it is behind the Panel.
///
/// So the check moves to launch. Every account this device thinks it is paired
/// with gets exactly one authenticated, side-effect-free GET (`CredentialProbe`,
/// over the pinned certificate) before the Panel is allowed to be about it:
///
/// * **401/403** — the credential, the pin, that pin's SSH host key and the
///   directory record all go, the profile lets the host go, and the Shell falls
///   back to the list with the row reading 未配对 and one line saying why.
/// * **no credential, or a credential with no pin** — there is nothing that can
///   be checked (a token is only ever put on a certificate this device pinned),
///   so it is the same cleanup. A `simctl keychain reset` lands here.
/// * **no answer** — an unreachable host is not a revocation. Nothing is
///   deleted, the Panel opens, and the bar's dot is grey rather than red.
///
/// A 401 that arrives later, on the live connection, runs the same cleanup
/// through `hostRejected` — which is what removes the resting state entirely.
///
/// CORE-2 §1 adds two things. A refusal now carries the host's reason, so the
/// list can say "expired — one approval brings it back" apart from "revoked on
/// the computer". And the gate keeps credentials alive: `renewIfDue` runs at
/// launch, every time the app comes to the front and every 12 hours, and trades
/// a credential in its last week for a new one without anyone seeing it.
@MainActor final class HostCredentialGate: ObservableObject {
    /// One host whose credential this launch threw away, and why.
    struct StaleCredential: Equatable, Sendable {
        let hostName: String
        let reason: CredentialRejection
    }

    /// What the launch probe made of one account.
    enum Standing: String, Equatable, Sendable {
        /// The host answered an authenticated read. The credential is live.
        case live
        /// Nobody answered. Nothing was deleted and nothing is wrong with the
        /// credential as far as this device can tell.
        case offline
    }

    /// False until every account has been settled once. The Shell does not
    /// block on it — the Panel is the right thing to draw while the host is
    /// being asked — but the list reads it so that "未配对" is never shown for
    /// a host that is about to come back as live.
    @Published private(set) var settled = false
    @Published private(set) var standing: [String: Standing] = [:]
    /// The hosts whose credential this launch threw away. The list shows one
    /// line per reason for them, which is the only difference between this and
    /// a device that was never paired.
    @Published private(set) var discarded: [StaleCredential] = []
    /// CORE-2: the last pass of `renewIfDue`, per account, for tests and for
    /// the report's trace. Never shown.
    private(set) var lastRenewal: [String: RenewalOutcome] = [:]
    private var renewing = false
    private var renewalCheckedAt: Date?
    /// How often a credential is looked at while the app stays open.
    static let renewalInterval: TimeInterval = 12 * 3600
    /// Two triggers that fire together (launch *and* coming to the front) are
    /// one check, not two.
    static let renewalDebounce: TimeInterval = 60

    private let pins: HostPinStore
    private let credentials: CompanionCredentialStore
    private let hostKeys: HostKeyStore
    private let makeProbe: (URL, String) -> CredentialProbe
    private let makeRenewer: (URL, String) -> CredentialRenewer
    /// UI-test seam, DEBUG + Simulator only: a hermetic run has no host that
    /// could answer 401, and a fixture that pretends to be one would be a
    /// second implementation of `CredentialProbe`. See `DevelopmentLaunch`.
    private let forcedVerdict: CredentialVerdict?

    init(pins: HostPinStore = HostPinStore(),
         credentials: CompanionCredentialStore = CompanionCredentialStore(),
         hostKeys: HostKeyStore = HostKeyStore(),
         forcedVerdict: CredentialVerdict? = HostCredentialGate.launchVerdict(),
         makeProbe: @escaping (URL, String) -> CredentialProbe = {
             CredentialProbe(endpoint: $0, pinnedFingerprint: $1)
         },
         makeRenewer: @escaping (URL, String) -> CredentialRenewer = {
             CredentialRenewer(endpoint: $0, pinnedFingerprint: $1)
         }) {
        self.pins = pins
        self.credentials = credentials
        self.hostKeys = hostKeys
        self.forcedVerdict = forcedVerdict
        self.makeProbe = makeProbe
        self.makeRenewer = makeRenewer
    }

    /// Whether the host this app is about is the one that did not answer.
    func isOffline(_ account: String) -> Bool {
        standing[HostAccount.canonical(account)] == .offline
    }

    var discardedCredential: Bool { !discarded.isEmpty }

    // MARK: - The launch check

    func check(directory: PairedHostDirectory, home: HomeStore) async {
        for account in Self.accounts(directory: directory, home: home) {
            await settle(account: account, directory: directory, home: home)
        }
        settled = true
    }

    /// Everything this device believes it is paired with: the directory, plus
    /// the profile's own host, which is the second half of the Shell's gate and
    /// therefore has to be checked even when no record mentions it.
    static func accounts(directory: PairedHostDirectory, home: HomeStore) -> [String] {
        var values: [String] = []
        let current = HostAccount.canonical(home.profile.companionURL)
        if !current.isEmpty, !home.profile.mock { values.append(current) }
        for record in directory.records where !values.contains(record.account) {
            values.append(record.account)
        }
        return values
    }

    private func settle(account: String, directory: PairedHostDirectory, home: HomeStore) async {
        migrate(account: account, directory: directory, home: home)
        guard let url = URL(string: account), url.host != nil else {
            discard(account: account, directory: directory, home: home)
            return
        }
        // A token that is not here, and a token whose pin is not here, are the
        // same thing: nothing this device can put on the wire. PAIR-4 §3.2 —
        // handing a credential to whoever answers an unpinned address is how a
        // secret leaks, so it is deleted rather than checked.
        guard let token = token(account: account), let pin = pins.load(account: account) else {
            discard(account: account, directory: directory, home: home)
            return
        }
        let verdict: CredentialVerdict
        if let forcedVerdict { verdict = forcedVerdict }
        else { verdict = await makeProbe(url, pin.fingerprintSHA256).check(token: token) }
        switch verdict {
        case .live: standing[account] = .live
        case let .rejected(reason): discard(account: account, directory: directory, home: home, reason: reason)
        case .unreachable: standing[account] = .offline
        }
    }

    /// The live connection answered 401/403. Same cleanup, same landing: this
    /// is what makes "Host authorization is not connected" impossible to sit in.
    ///
    /// CORE-2: but first the credential this device holds *now* is asked about
    /// once. A renewal replaces the stored credential while the live connection
    /// still carries the one it traded in, and that one stops working when its
    /// grace ends; a 401 for it is not a refusal of this device. So: live →
    /// reconnect with what is stored; refused → the cleanup, with the host's
    /// reason; nobody home → offline, nothing deleted.
    func hostRejected(account: String, directory: PairedHostDirectory, home: HomeStore) async {
        let account = HostAccount.canonical(account)
        guard !account.isEmpty else { return }
        guard let url = URL(string: account), url.host != nil,
              let token = token(account: account), let pin = pins.load(account: account) else {
            discard(account: account, directory: directory, home: home, reason: .unknown)
            return
        }
        let verdict: CredentialVerdict
        if let forcedVerdict { verdict = forcedVerdict }
        else { verdict = await makeProbe(url, pin.fingerprintSHA256).check(token: token) }
        switch verdict {
        case .live:
            standing[account] = .live
            if HostAccount.canonical(home.profile.companionURL) == account { await home.connectCompanion() }
        case let .rejected(reason):
            discard(account: account, directory: directory, home: home, reason: reason)
        case .unreachable:
            standing[account] = .offline
            if HostAccount.canonical(home.profile.companionURL) == account { await home.connectCompanion() }
        }
    }

    // MARK: - CORE-2 §1: keeping a credential alive

    /// Every account this device holds a credential for: ask the host whether
    /// it is in its last week, and if so trade it for a new one. Silent: the
    /// only thing a person can ever see from here is the list line a refusal
    /// leaves behind, exactly as the launch probe's would.
    ///
    /// `force` skips the debounce (the 12-hour timer and tests pass it).
    func renewIfDue(directory: PairedHostDirectory, home: HomeStore, force: Bool = false) async {
        guard !renewing, forcedVerdict == nil else { return }
        if !force, let last = renewalCheckedAt, Date().timeIntervalSince(last) < Self.renewalDebounce { return }
        renewing = true
        defer { renewing = false }
        renewalCheckedAt = Date()
        for account in Self.accounts(directory: directory, home: home) {
            guard let url = URL(string: account), url.host != nil,
                  let token = token(account: account), let pin = pins.load(account: account) else { continue }
            let outcome = await makeRenewer(url, pin.fingerprintSHA256).run(token: token)
            lastRenewal[account] = outcome
            switch outcome {
            case let .renewed(fresh, _):
                // Only if nothing replaced or forgot the credential while the
                // request was out: a forget in between must stay a forget.
                guard self.token(account: account) == token else { continue }
                try? credentials.saveToken(fresh, account: account)
                standing[account] = .live
            case let .rejected(reason):
                guard self.token(account: account) == token else { continue }
                discard(account: account, directory: directory, home: home, reason: reason)
            case .notDue: standing[account] = .live
            case .unreachable, .refused, .unsupported: break
            }
        }
    }

    private func discard(account: String, directory: PairedHostDirectory, home: HomeStore,
                         reason: CredentialRejection = .unknown) {
        let name = pins.load(account: account)?.hostName
            ?? directory.record(account: account)?.hostName
            ?? URL(string: account)?.host
            ?? account
        HostForget.run(account: account, directory: directory,
                       pins: pins, credentials: credentials, hostKeys: hostKeys)
        standing[account] = nil
        let line = StaleCredential(hostName: name, reason: reason)
        if !discarded.contains(line) { discarded.append(line) }
        guard HostAccount.canonical(home.profile.companionURL) == account else { return }
        var profile = home.profile
        profile.companionURL = ""
        home.profile = profile
        home.releaseHost()
    }

    // MARK: - PAIR-5 §3: a credential an older build wrote

    /// Before PAIR-4 the directory record and the profile keyed themselves by
    /// `url.absoluteString` — whatever the discovery or the typed address
    /// happened to spell — while the Keychain keyed the credential by the
    /// normalized account. A build that wrote both from the same unnormalized
    /// string left the credential under `https://Omarchy:8099/`, which
    /// `HostAccount.derive` will never ask for again.
    ///
    /// So before the probe: if the canonical key holds nothing, the spellings
    /// this host has been written under are read once, and the first hit is
    /// moved — credential and pin together — to the one key. It happens once,
    /// because afterwards the old key is empty.
    private func migrate(account: String, directory: PairedHostDirectory, home: HomeStore) {
        let spellings = Self.spellings(account: account, directory: directory, home: home)
        let legacy = LegacyHostAccount.keys(canonical: account, spellings: spellings)
        guard !legacy.isEmpty else { return }
        if token(account: account) == nil {
            for key in legacy {
                guard let carried = self.token(account: key) else { continue }
                do { try credentials.saveToken(carried, account: account) } catch { continue }
                try? credentials.removeToken(account: key)
                break
            }
        }
        guard pins.load(account: account) == nil else { return }
        for key in legacy {
            guard let pin = pins.load(account: key) else { continue }
            do { try pins.save(pin, account: account) } catch { continue }
            try? pins.remove(account: key)
            break
        }
    }

    private func token(account: String) -> String? {
        // `try?` on a throwing function that already returns an optional
        // flattens, so this is one unwrap and not two.
        guard let value = try? credentials.loadToken(account: account), !value.isEmpty else { return nil }
        return value
    }

    private static func spellings(account: String, directory: PairedHostDirectory, home: HomeStore) -> [String] {
        var values = [home.profile.companionURL, home.profile.hostname]
        if let record = directory.record(account: account) {
            values.append(contentsOf: [record.address, record.hostName])
        }
        return values.filter { !$0.isEmpty }
    }

    private static func launchVerdict() -> CredentialVerdict? {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        // CORE-2: `--host-answers-401=<reason>` names the refusal, so the list
        // line for each reason can be drawn without a host that answers it.
        if let named = arguments.first(where: { $0.hasPrefix("--host-answers-401=") }) {
            let reason = String(named.dropFirst("--host-answers-401=".count))
            return .rejected(CredentialRejection(rawValue: reason) ?? .unknown)
        }
        return arguments.contains("--host-answers-401") ? .rejected(.unknown) : nil
        #else
        return nil
        #endif
    }
}

/// PAIR-5 §3. The keys a build before PAIR-4 could have written one host's
/// credential and pin under, derived from the spellings that host is known by
/// on this device. It is deliberately a small, closed set: every key it
/// produces is an `https` origin for the same host and port as the canonical
/// account, so a migration can never move a credential between two machines.
enum LegacyHostAccount {
    static func keys(canonical: String, spellings: [String]) -> [String] {
        guard let url = URL(string: canonical), let host = url.host else { return [] }
        let port = url.port ?? 443
        var names = [host]
        for spelling in spellings {
            // A spelling may be a whole URL, a `host:port`, or a bare name.
            var text = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let colon = text.lastIndex(of: ":"), !text.hasSuffix("]"),
               text.filter({ $0 == ":" }).count == 1 {
                guard Int(text[text.index(after: colon)...]) == port else { continue }
                text = String(text[..<colon])
            }
            // Same machine, different spelling — and nothing else.
            guard !text.isEmpty, text.lowercased() == host, !names.contains(text) else { continue }
            names.append(text)
        }
        var keys: [String] = []
        for name in names {
            for value in ["https://\(name):\(port)", "https://\(name):\(port)/"]
            where value != canonical && !keys.contains(value) {
                keys.append(value)
            }
        }
        return keys
    }
}
