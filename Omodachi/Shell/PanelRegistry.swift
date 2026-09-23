import Foundation
import SwiftUI

/// N-38. The seven panels are the registry's built-in rows, not a hard-coded
/// table.
///
/// Today there are seven, and six of them have an entry on the bar (① is the
/// logo). The point of the registry is what comes next: an Omarchy shell plugin
/// synced from the host can register a panel of its own and appear after these,
/// on the bar and in Settings, without anything here being edited. That needs
/// core to publish a plugin manifest, which is not in this spec — so the shape
/// is here and the source is still a constant.
///
/// The user can turn an entry off (Study 04 §2 item 17). Turning it off removes
/// the slot from the bar; it does not remove the panel, because two things still
/// reach it — Settings, and a summon from the host. **A summon always wins over
/// "disabled"** (N-38 rev 5): clicking that icon on the computer is an explicit
/// intent, and a preference on the iPad is not allowed to veto it.
enum PanelID: String, CaseIterable, Codable, Sendable, Identifiable {
    /// ① Omarchy menu + Keybindings. Opened by the logo, never by an entry.
    case menu
    case remote, agent, herdr, ssh, settings, notifications

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: Strings.panelMenu
        case .remote: Strings.panelRemote
        case .agent: Strings.panelAgent
        case .herdr: Strings.panelHerdr
        case .ssh: Strings.panelSsh
        case .settings: Strings.panelSettings
        case .notifications: Strings.panelNotifications
        }
    }

    /// A-56: which of the two layouts this panel is drawn in. ① is its own
    /// third shape and answers `nil` here.
    var shape: PanelShape? {
        switch self {
        case .menu: nil
        case .remote, .settings, .notifications: .readAndChoose
        case .agent, .herdr, .ssh: .workSurface
        }
    }
}

/// One row of the registry: what the bar draws for a panel and whether it does.
struct PanelEntry: Identifiable, Equatable, Sendable {
    let id: PanelID
    /// A-50's fixed order: Remote / Agent / Herdr / SSH / Settings / Notifications.
    let order: Int
    var enabled: Bool
    /// Settings cannot be turned off — it is the only way back to the switch.
    let canDisable: Bool

    var title: String { id.title }

    var icon: (symbol: String, nerd: String) {
        switch id {
        case .menu: Icon.menu
        case .remote: Icon.remote
        case .agent: Icon.agent
        case .herdr: Icon.herdr
        case .ssh: Icon.ssh
        case .settings: Icon.settings
        case .notifications: Icon.bell
        }
    }

    /// The vendor's own mark, for the two entries that are a window onto
    /// somebody else's product (③ the host's default agent, ④ Herdr). Every
    /// other entry is ours and keeps the study's glyph. `provider` is what core
    /// reports as the default agent's kind; an unknown one gets no mark rather
    /// than the wrong one.
    func brand(provider: String?) -> BrandMark? {
        switch id {
        case .agent: BrandMark.provider(provider)
        case .herdr: .herdr
        default: nil
        }
    }

    static func == (lhs: PanelEntry, rhs: PanelEntry) -> Bool {
        lhs.id == rhs.id && lhs.order == rhs.order && lhs.enabled == rhs.enabled
            && lhs.canDisable == rhs.canDisable
    }
}

/// The registry itself. Entries are per host (`host_id`, not the URL — PAIR-4's
/// lesson), because "which entries do I want on the bar" is as much a property
/// of a machine as its pins are.
@MainActor final class PanelRegistry: ObservableObject {
    /// A-50's order, and the built-in set.
    static let builtIn: [PanelID] = [.remote, .agent, .herdr, .ssh, .settings, .notifications]

    @Published private(set) var entries: [PanelEntry]
    /// The host these switches belong to. Changing it reloads them.
    @Published var hostID: String {
        didSet { if oldValue != hostID { entries = Self.load(hostID: hostID, defaults: defaults) } }
    }

    private let defaults: UserDefaults
    private static let key = "omodachi.panelEntries.v1"

    init(hostID: String = "", defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hostID = hostID
        entries = Self.load(hostID: hostID, defaults: defaults)
    }

    /// What the bar's right segment draws, in order.
    var barEntries: [PanelEntry] { entries.filter(\.enabled) }

    func isEnabled(_ id: PanelID) -> Bool {
        entries.first { $0.id == id }?.enabled ?? true
    }

    func setEnabled(_ id: PanelID, _ value: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].canDisable || value else { return }
        guard entries[index].enabled != value else { return }
        entries[index].enabled = value
        save()
    }

    private func save() {
        var stored = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        stored[hostID] = entries.filter { !$0.enabled }.map(\.id.rawValue)
        defaults.set(stored, forKey: Self.key)
    }

    private static func load(hostID: String, defaults: UserDefaults) -> [PanelEntry] {
        let stored = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        let disabled = Set(stored[hostID] ?? [])
        return builtIn.enumerated().map { index, id in
            PanelEntry(id: id, order: index,
                       enabled: id == .settings || !disabled.contains(id.rawValue),
                       canDisable: id != .settings)
        }
    }
}
