import Foundation

/// LITE-1d. What the host said about Odomo on its authenticated roads: where
/// it is (`nil` without a front door, i.e. no Tailscale serve on the computer)
/// and how many of the host's web devices get its pushes (`nil` when the host
/// cannot say — a core from before LITE-1d, or one with no push).
///
/// The count is per computer, not per person: core knows devices, not who
/// holds them. So the words say "on for this computer", never "on for you".
struct OdomoReading: Equatable, Sendable {
    var url: URL?
    var pushDevices: Int?
}

/// LITE-1d. Where the app shows people Odomo: a card at the top of
/// Notifications, and a row at the top level of Settings. This is the one
/// place that decides what either says.
enum OdomoOffer {
    enum State: Equatable {
        /// The roads have not been read for this host yet: say nothing.
        case unknown
        /// At least one web device of this computer gets Odomo's pushes.
        case on(devices: Int, url: URL?)
        /// Odomo is there, and no device gets its pushes — or the host cannot
        /// say (`counted == false`), in which case the offer stands but no
        /// state is claimed.
        case off(url: URL, counted: Bool)
        /// No front door: Odomo needs Tailscale on the computer.
        case noAddress
    }

    static func state(_ reading: OdomoReading?) -> State {
        guard let reading else { return .unknown }
        if let devices = reading.pushDevices, devices > 0 { return .on(devices: devices, url: reading.url) }
        if let url = reading.url { return .off(url: url, counted: reading.pushDevices != nil) }
        return .noAddress
    }

    /// The Notifications card: offered until a device of this computer has
    /// Odomo's pushes, until the person hides it for this computer
    /// (ODOMO-CARD: "Hide", brought back by the switch in Settings), or once
    /// Odomo is known to be on this device for this computer (`here`).
    static func showsCard(_ state: State, dismissed: Bool, here: Bool = false) -> Bool {
        guard !dismissed, !here else { return false }
        switch state {
        case .off, .noAddress: return true
        case .unknown, .on: return false
        }
    }

    /// ODOMO-CARD. Settings' switch "Show on the Notifications page": on
    /// unless the card was hidden here or Odomo is already on this device.
    static func switchIsOn(dismissed: Bool, here: Bool) -> Bool { !dismissed && !here }

    /// ODOMO-CARD. What a link into the app teaches about Odomo: the host id
    /// it names when it came from Odomo (`from=odomo`) and that host is one
    /// this device is paired with — never an id it does not know.
    ///
    /// On an iPhone or iPad, Odomo only pairs inside the Home Screen web app
    /// (LITE-1e `installGate`): a tab or the Safari view shows the install
    /// page, which has no link into the app. So a link from Odomo that names
    /// a paired host means Odomo is installed on this device for that host.
    /// The app running on a Mac learns nothing: a link there came from a
    /// desktop browser, where Odomo is not gated.
    static func learnsHere(from link: AppLink, records: [PairedHostRecord], onMac: Bool) -> String? {
        guard link.fromOdomo, !onMac, let hostID = link.hostID,
              records.contains(where: { $0.hostID == hostID }) else { return nil }
        return hostID
    }
}

/// LITE-1d / ODOMO-CARD. A per-computer list in the app's defaults (the
/// computer's `host_id`, or the account it is paired under when there is no
/// pin), bounded at 64. Two of them:
///
/// - `key`: "Hide" on the Notifications card (LITE-1d's "Not now", same key,
///   so a card put away before stays put away). Settings' switch clears it.
/// - `hereKey`: Odomo is on this device for that computer, learnt from a link
///   Odomo handed to the app (`OdomoOffer.learnsHere`). Ids only.
struct OdomoOfferMemory {
    static let key = "omodachi.odomo.notNow.v1"
    static let hereKey = "omodachi.odomo.here.v1"
    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = AppDefaults.shared, key: String = OdomoOfferMemory.key) {
        self.defaults = defaults
        self.key = key
    }

    /// The "Odomo is on this device" list.
    static func here(defaults: UserDefaults = AppDefaults.shared) -> OdomoOfferMemory {
        OdomoOfferMemory(defaults: defaults, key: hereKey)
    }

    func contains(_ host: String) -> Bool {
        !host.isEmpty && (defaults.stringArray(forKey: key) ?? []).contains(host)
    }

    func remember(_ host: String) {
        guard !host.isEmpty else { return }
        var values = defaults.stringArray(forKey: key) ?? []
        guard !values.contains(host) else { return }
        values.append(host)
        // A bounded list: a person with more than 64 computers sees the card
        // again for the oldest, which is the honest failure.
        defaults.set(Array(values.suffix(64)), forKey: key)
    }

    func forget(_ host: String) {
        var values = defaults.stringArray(forKey: key) ?? []
        values.removeAll { $0 == host }
        defaults.set(values, forKey: key)
    }

    // LITE-1d's names for the Hide list.
    func isDismissed(_ host: String) -> Bool { contains(host) }
    func dismiss(_ host: String) { remember(host) }
}
