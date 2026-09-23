import Foundation

/// N-39. What a pinned row is, and what happens when the host stops having it.
///
/// Study 04 rev 5 settles the identity question the earlier revisions left
/// open. A menu row has no stable id of its own — `Models.swift` hands out a
/// `UUID()` — and a keybinding's id disappears the moment the user rebinds it.
/// So a pin stores four things:
///
/// * `hostID` — the host's own installation identity, **not** its URL. PAIR-4's
///   lesson: a URL changes when a machine moves network and the pins would
///   follow the address rather than the machine.
/// * `kind` — menu or keybinding. The two groups never mix.
/// * `stableKey` — the menu row's *path* (`Style › Theme`), or the keybinding's
///   catalog id. Both survive everything but the row itself going away.
/// * `label` — a snapshot, so a pin whose target is gone can still be drawn.
///
/// And when the catalog refreshes and a pin no longer resolves, it is **not
/// deleted**. It is drawn from the snapshot, dimmed, with "主机上已不存在" under
/// it and an unpin that works. A pin quietly disappearing is how a user learns
/// not to trust pinning.
struct PanelPin: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case menu, keybinding }

    let hostID: String
    let kind: Kind
    let stableKey: String
    var label: String

    var id: String { "\(kind.rawValue):\(stableKey)" }
}

/// A pinned row as the panel draws it: either resolved against the live
/// catalog, or a tombstone.
struct ResolvedPin<Target>: Identifiable {
    let pin: PanelPin
    /// `nil` means the host no longer has this row.
    let target: Target?
    var id: String { pin.id }
    var isTombstone: Bool { target == nil }
}

/// The pins, per host, on disk.
///
/// It is a plain store rather than an `ObservableObject` so it can be asserted
/// without a main actor, and the panel holds the published copy.
struct PanelPinStore {
    private let defaults: UserDefaults
    private static let key = "omodachi.pins.v2"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func pins(hostID: String) -> [PanelPin] {
        guard let data = defaults.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([PanelPin].self, from: data) else { return [] }
        return all.filter { $0.hostID == hostID }
    }

    func pins(hostID: String, kind: PanelPin.Kind) -> [PanelPin] {
        pins(hostID: hostID).filter { $0.kind == kind }
    }

    /// Pinning is a toggle: the same row again unpins it. Order is the order
    /// they were pinned in (rev 5 leaves drag reordering to a later study).
    func toggle(_ pin: PanelPin) -> [PanelPin] {
        var all = allPins()
        if let index = all.firstIndex(where: { $0.hostID == pin.hostID && $0.id == pin.id }) {
            all.remove(at: index)
        } else {
            all.append(pin)
        }
        save(all)
        return all.filter { $0.hostID == pin.hostID }
    }

    func isPinned(_ pin: PanelPin) -> Bool {
        allPins().contains { $0.hostID == pin.hostID && $0.id == pin.id }
    }

    /// The label snapshot is refreshed while the row still resolves, so a
    /// tombstone shows the last name the host actually used.
    func refresh(hostID: String, kind: PanelPin.Kind, resolved: [String: String]) {
        var all = allPins()
        var changed = false
        for index in all.indices where all[index].hostID == hostID && all[index].kind == kind {
            guard let label = resolved[all[index].stableKey], label != all[index].label else { continue }
            all[index].label = label
            changed = true
        }
        if changed { save(all) }
    }

    /// Forgetting a host takes its pins with it; nothing else does.
    func forget(hostID: String) {
        save(allPins().filter { $0.hostID != hostID })
    }

    private func allPins() -> [PanelPin] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([PanelPin].self, from: data)) ?? []
    }

    private func save(_ pins: [PanelPin]) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

extension MenuItem {
    /// N-39's `stable_key` for a menu row: where it sits in the merged tree.
    /// Two hosts can both have `Style › Theme`; one host cannot have two.
    var pinKey: String { (path + [label]).joined(separator: " › ") }
}
