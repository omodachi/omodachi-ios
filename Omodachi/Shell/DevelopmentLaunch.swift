import Foundation

/// Simulator-only launch controls for reproducible UI/transport tests.
/// Production builds contain no credential or test-host bootstrap path.
/// One store for everything this app persists, resolved once.
///
/// A UI-testing launch gets its own suite, wiped at startup, so a UI run never
/// reads or writes the real one — and neither does anything that reaches for
/// "the app's defaults" from outside `HomeStore`, which is why this is a single
/// `static let` rather than a function that wipes on every call.
enum AppDefaults {
    // `UserDefaults` is thread-safe by contract but not `Sendable`; this is
    // written once at first use and never reassigned.
    nonisolated(unsafe) static let shared: UserDefaults = {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let name = "omodachi.ui-tests"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return defaults
        }
        #endif
        return .standard
    }()
}

@MainActor enum DevelopmentLaunch {
    static func defaults() -> UserDefaults { AppDefaults.shared }

    /// PAIR-5's three cases, seeded before the Shell reads anything, because
    /// the whole point of them is what the app does with records it finds at
    /// launch. Simulator-and-DEBUG only, like everything else in this file.
    ///
    /// The host a fixture names never answers: `.invalid` is reserved and
    /// resolves nowhere, and 127.0.0.1 on a closed port refuses at once. The
    /// 401 that the rejected case needs is the one thing a hermetic run cannot
    /// get from a host, so it comes from `--host-answers-401` instead — the
    /// probe is the real one either way, and the real 401 is in PAIR-5 §5.
    static func seedPairingFixture(defaults: UserDefaults) {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        let endpoint: String
        if arguments.contains("--pair5-offline") { endpoint = "https://127.0.0.1:59999" }
        else if arguments.contains("--pair5-rejected") || arguments.contains("--pair5-credential-gone") {
            endpoint = "https://pair5-host.invalid:8099" // non-copy: a fixture address
        } else { return }
        let account = HostAccount.canonical(endpoint)
        let hostID = String(repeating: "5", count: 32)
        let record = PairedHostRecord(account: account, hostID: hostID,
                                      hostName: "pair5-host", address: account)
        if let data = try? JSONEncoder().encode([record]) {
            defaults.set(data, forKey: PairedHostDirectory.storageKey)
        }
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "pair5-host"
        profile.username = "omodachi-test"
        profile.companionURL = account
        if let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: "omodachi.profile.v1") }
        // The keychain outlives an install, so a fixture that wants "this
        // device holds nothing" has to say so explicitly.
        try? CompanionCredentialStore().removeToken(account: account)
        try? HostPinStore().remove(account: account)
        guard !arguments.contains("--pair5-credential-gone") else { return }
        try? CompanionCredentialStore().saveToken("pair5-fixture-token", account: account)
        try? HostPinStore().save(HostPin(hostID: hostID, hostName: "pair5-host",
                                         fingerprintSHA256: String(repeating: "5", count: 64),
                                         endpoints: [.init(host: URL(string: account)?.host ?? "", port: 8099)]),
                                 account: account)
        #endif
    }
    static func configure(home: HomeStore) {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--import-development-host") { importHost(home: home) }
        guard arguments.contains("--ui-testing") else { return }
        if arguments.contains("--development-companion") { importCompanion(home: home) }
        guard arguments.contains("--ssh-fixture") else { return }
        // Public synthetic fixture key, accepted only by Tools/SSHFixture/server.py.
        var profile = home.profile
        profile.id = UUID(uuidString: "D717A86B-1F69-447B-8310-BEE79942B312")!
        profile.hostname = "127.0.0.1"
        profile.port = 22222
        profile.username = "omodachi-test"
        profile.mock = false
        do {
            try SSHKeyStore().savePrivateKey(Data(repeating: 0x4F, count: 32), account: profile.keyAccount)
            try HostKeyStore().reset(host: profile.hostname, port: profile.port)
            home.profile = profile
        } catch { home.notice = Strings.hostDemoLocalState }
        #endif
    }
    /// Explicit, single-use import for this authorized development device.
    /// It uses the persistent profile and does not reset SSH trust or runtime data.
    private static func importHost(home: HomeStore) {
        #if DEBUG && targetEnvironment(simulator)
        struct Record: Decodable {
            struct Pin: Decodable {
                let hostID: String
                let hostName: String
                let fingerprint: String
                enum CodingKeys: String, CodingKey {
                    case hostID = "host_id", hostName = "host_name", fingerprint = "tls_fingerprint_sha256"
                }
            }
            let profile: HostProfile
            let privateKey: Data?
            let credential: String?
            /// What a real pairing claim would have pinned. Importing it is the
            /// Simulator equivalent of having completed the handshake.
            let pin: Pin?
        }
        // The record can arrive either as a file in the app's own container or,
        // for an XCTest-operated run, in the launch environment. Both are
        // Simulator-and-DEBUG only and neither exists in a release build.
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("host-development.json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let data = try ProcessInfo.processInfo.environment["OMODACHI_DEV_HOST"].map { Data($0.utf8) }
                ?? Data(contentsOf: file)
            guard data.count <= 131_072 else { return }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard !record.profile.mock, (1...65535).contains(record.profile.port),
                  !record.profile.hostname.isEmpty, !record.profile.username.isEmpty else { return }
            if !record.profile.companionURL.isEmpty {
                guard let endpoint = URL(string: record.profile.companionURL) else { return }
                // The Simulator shares the Mac's network, so a LAN address is the
                // ordinary case here; the loopback form still works for a tunnel.
                let config = try CompanionHostConfiguration(endpoint: endpoint)
                if let credential = record.credential {
                    try CompanionCredentialStore().saveToken(credential, account: config.account)
                }
                if let pin = record.pin {
                    try HostPinStore().save(HostPin(hostID: pin.hostID, hostName: pin.hostName,
                                                    fingerprintSHA256: pin.fingerprint,
                                                    endpoints: [.init(host: config.endpoint.host ?? "",
                                                                      port: config.endpoint.port ?? 8099)]),
                                            account: config.account)
                }
            }
            if let key = record.privateKey {
                try SSHKeyStore().savePrivateKey(key, account: record.profile.keyAccount)
            }
            home.profile = record.profile
            if !record.profile.companionURL.isEmpty { Task { await home.connectCompanion() } }
        } catch { home.notice = Strings.hostDemoLocalState }
        #endif
    }

    private static func importCompanion(home: HomeStore) {
        #if DEBUG && targetEnvironment(simulator)
        struct Record: Decodable { let endpoint: URL; let credential: String }
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("companion-development.json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard ["127.0.0.1", "localhost", "::1"].contains(record.endpoint.host ?? "") else { return }
            let config = try CompanionHostConfiguration(endpoint: record.endpoint)
            try CompanionCredentialStore().saveToken(record.credential, account: config.account)
            var profile = home.profile
            profile.hostname = "127.0.0.1"
            profile.mock = false
            profile.companionURL = config.endpoint.absoluteString
            home.profile = profile
            Task { await home.connectCompanion() }
        } catch { home.notice = Strings.hostDemoLocalState }
        #endif
    }
}
