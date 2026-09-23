import Foundation

/// STORE-1 §1. The demo a person without an Omarchy computer can walk through —
/// App Review's, first of all (guideline 2.1).
///
/// It is the mock profile the UI tests already draw the Panel over, made
/// reachable from the first screen: nothing here opens a socket, browses
/// Bonjour or touches the Keychain. What it shows is read from the canonical
/// host fixtures in `CoreFixtures/`, bundled with the app for exactly this —
/// `state.json` (whose catalog is the Panel's menu), `notifications.json` and
/// `shortcuts.json`. Every fixture is synthetic; `DemoModeTests` greps them for
/// anything that would name a real person or machine.
enum DemoHost {
    static let hostname = "demo-omarchy" // non-copy: the demo host's name
    static let username = "demo" // non-copy: the demo account
    /// A fixed id, so a demo SSH session is recognisably the demo's own.
    static let profileID = UUID(uuidString: "0D3E0D3E-0D3E-4D3E-8D3E-0D3E0D3E0D3E")!

    static var profile: HostProfile {
        var profile = HostProfile()
        profile.id = profileID
        profile.hostname = hostname
        profile.username = username
        profile.port = 22
        profile.mock = true
        profile.herdrSession = ""
        profile.companionURL = ""
        return profile
    }

    /// The bundle the fixtures are read from; a test may point at its own.
    nonisolated(unsafe) static var bundle = Bundle.main

    static func fixture(_ name: String) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    static func state() -> HostStateDTO? {
        fixture("state").flatMap { try? JSONDecoder().decode(HostStateDTO.self, from: $0) }
    }

    static func notifications() -> [HostNotification] {
        fixture("notifications").flatMap { try? JSONDecoder().decode(HostNotificationPage.self, from: $0) }?
            .notifications ?? []
    }

    static func shortcuts() throws -> ShortcutSnapshot {
        guard let data = fixture("shortcuts") else { throw ShortcutWireError.unavailableContext }
        return try JSONDecoder().decode(ShortcutListDTO.self, from: data).snapshot()
    }
}

extension HomeStore {
    /// STORE-1 §1. Puts the demo profile in place of whatever this device had,
    /// without writing it down: `saveProfile` leaves the stored profile alone
    /// while the demo is on, so leaving it is putting the old value back.
    func enterDemo() {
        guard !demoActive else { return }
        demoReturnProfile = profile
        demoActive = true
        profile = DemoHost.profile
    }

    func exitDemo() {
        guard demoActive else { return }
        let previous = demoReturnProfile ?? HostProfile()
        demoReturnProfile = nil
        // Still inside the demo while the old profile comes back, so the
        // stored copy — which never changed — is not rewritten either.
        profile = previous
        demoActive = false
        resetPresentation()
    }

    /// Called from `resetPresentation` while the demo is on.
    func applyDemoFixtures() {
        if let catalog = DemoHost.state()?.catalog { applyCatalog(catalog) }
        state.hostName = DemoHost.hostname
        state.online = true
        notifications.replace(with: DemoHost.notifications())
    }
}
