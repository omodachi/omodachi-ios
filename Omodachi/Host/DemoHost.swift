import Foundation

/// STORE-1 §1, rebuilt by STORE-6. The demo a person without a computer to
/// pair can walk through — App Review's, first of all (guideline 2.1).
///
/// It is the mock profile made reachable from the first screen: nothing here
/// opens a socket, browses Bonjour or touches the Keychain. What it shows is
/// read from `Resources/Demo/`, four files in the shapes the host itself
/// publishes, so every panel draws them through the same decoder and the same
/// view a paired computer's answer goes through:
///
/// * `demo-catalog.json` — the menu. Compiled with core's own catalog compiler
///   from the stock upstream menu of the desktop Omodachi pairs with (its
///   `v4.0.3` source, pinned in core's fixtures), with the rows a desktop
///   without that hardware would hide left out, generic names in the two
///   submenus a real computer fills from what is installed (Apps, fonts), and
///   every row runnable. The rows a host asks a second tap for are the ones
///   core's adapter marks `confirm`.
/// * `demo-shortcuts.json` — the keybinding list, the labels and keys the
///   site's own mock already publishes.
/// * `demo-notifications.json` — five ordinary notifications; the minutes in
///   `timestamp` become times when the demo opens.
/// * `demo-herdr.json` — one session with three panes, and what each pane
///   shows, drawn as terminal text.
///
/// Every line of it is invented or public, and STORE-6 §A5 holds it to one
/// more rule: the demo's own data never names the desktop OS — not as the host
/// name, not as a notification's sender, not as a row. The app's own labels
/// are not demo data and stay as they are. `DemoModeTests` checks both.
///
/// Nothing the demo does claims a computer did it: a row that runs says it ran
/// on the demo computer, Remote says what it needs, and the Agent's
/// conversation says it is the demo's.
enum DemoHost {
    static let hostname = "desktop" // non-copy: the demo computer's name
    static let username = "demo" // non-copy: the demo account
    /// A fixed id, so a demo SSH session is recognisably the demo's own.
    static let profileID = UUID(uuidString: "0D3E0D3E-0D3E-4D3E-8D3E-0D3E0D3E0D3E")!
    /// What the demo's pins are filed under. It is not a host id any pairing
    /// could produce (those are 32 hex characters), so the demo's pins and a
    /// real computer's never meet.
    static let pinHostID = "demo" // non-copy: a pin namespace

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

    /// The bundle the data is read from; a test may point at its own.
    nonisolated(unsafe) static var bundle = Bundle.main

    static func data(_ name: String) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    static func catalog() -> HostCatalogDTO? {
        data("demo-catalog").flatMap { try? JSONDecoder().decode(HostCatalogDTO.self, from: $0) }
    }

    /// The five notifications, stamped relative to `now` so the list reads as
    /// the last hour rather than as a date in the past.
    static func notifications(now: Date = Date()) -> [HostNotification] {
        let rows = data("demo-notifications").flatMap { try? JSONDecoder().decode(HostNotificationPage.self, from: $0) }?
            .notifications ?? []
        let milliseconds = Int(now.timeIntervalSince1970 * 1000)
        return rows.map {
            HostNotification(id: $0.id, app: $0.app, summary: $0.summary, body: $0.body, glyph: $0.glyph,
                             urgency: $0.urgency, timestamp: milliseconds - $0.timestamp * 60_000,
                             hasAction: $0.hasAction, active: $0.active)
        }
    }

    static func shortcuts() throws -> ShortcutSnapshot {
        guard let data = data("demo-shortcuts") else { throw ShortcutWireError.unavailableContext }
        return try JSONDecoder().decode(ShortcutListDTO.self, from: data).snapshot()
    }

    /// Herdr's session, its grid, and the text each pane shows.
    struct Herdr: Decodable, Sendable {
        let layout: HerdrLayoutDTO
        let sessions: HerdrSessionsDTO
        let screens: [String: String]
    }

    static func herdr() -> Herdr? {
        guard var raw = data("demo-herdr") else { return nil }
        if HerdrAgentsFixture.requested { raw = HerdrAgentsFixture.apply(raw) ?? raw }
        if HerdrChoicesFixture.requested { raw = HerdrChoicesFixture.apply(raw) ?? raw }
        if OverviewFixture.requested { raw = OverviewFixture.apply(raw) ?? raw }
        return try? JSONDecoder().decode(Herdr.self, from: raw)
    }

    // MARK: - Pins

    /// The pins the demo opens with — the three menu rows and two keybindings
    /// the store screenshots show — kept in a suite of their own that entering
    /// the demo resets, so pinning in the demo is real and leaves nothing
    /// behind in the app's own pins.
    static let pinSuite = "app.omodachi.demo-pins" // non-copy: a defaults suite name
    nonisolated(unsafe) static var pinDefaults = UserDefaults(suiteName: pinSuite) ?? .standard
    static var pinStore: PanelPinStore { PanelPinStore(defaults: pinDefaults) }
    static let pinnedMenuPaths = [["Trigger", "Capture"], ["Style", "Theme"], ["System", "Lock"]] // non-copy: row paths
    static let pinnedKeybindings = ["Full screen", "Screenshot"] // non-copy: row labels

    static func seedPins() {
        pinDefaults.removePersistentDomain(forName: pinSuite)
        let store = pinStore
        for path in pinnedMenuPaths {
            _ = store.toggle(PanelPin(hostID: pinHostID, kind: .menu,
                                      stableKey: path.joined(separator: " › "), label: path.last ?? ""))
        }
        let entries = (try? shortcuts().entries) ?? []
        for label in pinnedKeybindings {
            guard let entry = entries.first(where: { $0.label == label }) else { continue }
            _ = store.toggle(PanelPin(hostID: pinHostID, kind: .keybinding, stableKey: entry.id, label: entry.label))
        }
    }
}

extension HomeStore {
    /// STORE-1 §1. Puts the demo profile in place of whatever this device had,
    /// without writing it down: `saveProfile` leaves the stored profile alone
    /// while the demo is on, so leaving it is putting the old value back.
    func enterDemo() {
        guard !demoActive else { return }
        DemoHost.seedPins()
        demoReturnProfile = profile
        demoActive = true
        profile = DemoHost.profile
        // TUTORIAL-1: the demo is a first look, so it gets the tour too
        // (once per device, like a first pairing).
        tour.arm()
    }

    func exitDemo() {
        guard demoActive else { return }
        tour.suspend()
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
        if let catalog = DemoHost.catalog() { applyCatalog(catalog) }
        state.hostName = DemoHost.hostname
        state.online = true
        notifications.replace(with: DemoHost.notifications())
        notifications.dnd = false
    }

    /// STORE-6 §A2. What a row the demo runs says: the same `applied` a real
    /// host's success draws, with where it ran in place of the host's detail.
    func demoRan(_ label: String) {
        reportToast(.init(stage: .applied, label: label, detail: Strings.demoRanHere))
    }
}

/// HERDR-7, simulator UI runs only (`--ui-testing --herdr-agents-fixture`):
/// the demo's Herdr session with agents in it. The shipped demo has three
/// shell panes and no agent, so nothing in it shows how a pane that runs an
/// agent is drawn; this puts codex (waiting for you), a shell, claude
/// (working) and codex (done) side by side, in the shapes Herdr publishes,
/// so the UI tests and the screenshots see every state through the same
/// decoder and view a paired computer's answer goes through.
enum HerdrAgentsFixture {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--herdr-agents-fixture")
        #else
        return false
        #endif
    }

    /// Pane id → (agent kind, Herdr's status word). `w1:p4` is new, a copy of
    /// `w1:p3` with its own id.
    static let agents: [String: (kind: String, status: String)] = [ // non-copy: Herdr's wire values
        "w1:p1": ("codex", "blocked"), "w1:p3": ("claude", "working"), "w1:p4": ("codex", "done"),
    ]

    static func apply(_ data: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var layout = root["layout"] as? [String: Any],
              var workspaces = layout["workspaces"] as? [[String: Any]], !workspaces.isEmpty,
              var tabs = workspaces[0]["tabs"] as? [[String: Any]], !tabs.isEmpty,
              var panes = tabs[0]["panes"] as? [[String: Any]], panes.count >= 3,
              var screens = root["screens"] as? [String: String],
              var sessions = root["sessions"] as? [String: Any],
              var list = sessions["sessions"] as? [[String: Any]], !list.isEmpty
        else { return nil }
        var copy = panes[2]
        copy["id"] = "w1:p4" // non-copy: a pane id
        copy["focused"] = false
        panes.append(copy)
        screens["w1:p4"] = screens["w1:p3"] // non-copy: pane ids
        panes = panes.map { pane in
            var pane = pane
            guard let id = pane["id"] as? String, let agent = agents[id] else { return pane }
            pane["agent"] = ["name": agent.kind, "kind": agent.kind, "status": agent.status] // non-copy: wire keys
            pane["agent_status"] = agent.status // non-copy: a wire key
            return pane
        }
        tabs[0]["panes"] = panes
        workspaces[0]["tabs"] = tabs
        layout["workspaces"] = workspaces
        list[0]["panes"] = panes.count // non-copy: a wire key
        list[0]["agents"] = agents.count // non-copy: a wire key
        sessions["sessions"] = list
        root["layout"] = layout
        root["screens"] = screens
        root["sessions"] = sessions
        return try? JSONSerialization.data(withJSONObject: root)
    }
}
