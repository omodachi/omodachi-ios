import Foundation

/// OVERVIEW-1: what an older core says that the list can be built from.
struct OverviewLegacyInputs: Equatable, Sendable {
    /// The last state had no `overview`: the app builds the list itself.
    var active = false
    var agentStatus: String?
    var agentKind: String?
    var blocked: [String: [HerdrAttentionEvent.Pane]] = [:]
    var unseen: UnseenReading?
    var defaultPane: String?

    var reading: OverviewReading {
        OverviewReading.fallback(agentStatus: agentStatus, agentKind: agentKind, blocked: blocked,
                                 unseen: unseen, defaultPane: defaultPane)
    }
}

extension HomeStore {
    /// What the bar, the Herdr panel and its list read: core's list, the
    /// fallback for an older core, or — in the demo — the fixture or nothing.
    var overviewShown: OverviewReading {
        if demoActive || profile.mock { return OverviewFixture.reading ?? .empty }
        return overview
    }

    /// A state read: core's list when it sends one; otherwise remember what
    /// an older core said and build the smaller list from it.
    func applyOverview(_ snapshot: HostStateDTO) {
        if let reading = snapshot.overview {
            overviewLegacy.active = false
            if overview != reading { overview = reading }
            return
        }
        overviewLegacy.active = true
        overviewLegacy.agentStatus = snapshot.agent?.statusText
        overviewLegacy.agentKind = snapshot.agent?.kind
        overviewLegacy.defaultPane = latestDefaultAgent?.paneID
        if let blocked = snapshot.herdr?.blocked { overviewLegacy.blocked = blocked }
        if let unseen = snapshot.unseen { overviewLegacy.unseen = unseen }
        refreshLegacyOverview()
    }

    /// An event. `true` when it was the list itself (nothing else to do).
    func overviewEvent(_ event: SanitizedHostEvent) -> Bool {
        if event.type == "overview.changed" { // non-copy: event type
            if let reading = event.overview {
                overviewLegacy.active = false
                if overview != reading { overview = reading }
            }
            return true
        }
        guard overviewLegacy.active else { return false }
        var moved = false
        if event.type == "agent.changed", let status = event.agentStatus { // non-copy: event type
            overviewLegacy.agentStatus = status
            moved = true
        }
        if let change = event.herdrAttention {
            if change.stopped { overviewLegacy.blocked[change.session] = nil }
            else { overviewLegacy.blocked[change.session] = change.blocked }
            moved = true
        }
        if let unseen = event.notify?.unseen {
            overviewLegacy.unseen = unseen
            moved = true
        }
        if moved { refreshLegacyOverview() }
        return false
    }

    private func refreshLegacyOverview() {
        let reading = overviewLegacy.reading
        if overview != reading { overview = reading }
    }
}
