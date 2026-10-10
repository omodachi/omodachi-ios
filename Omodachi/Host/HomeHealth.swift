import Foundation

/// HERDR-11 §3. The one connection clock (`ConnectionHealth`) on the store
/// every surface already reads, and what the network path coming back does.
extension HomeStore {
    /// Whether the clock means anything now: a real host is wanted and the app
    /// is in front. The demo, a mock profile and a deliberate disconnect are
    /// never "reconnecting".
    var healthApplies: Bool {
        connectionWanted && foreground && !profile.mock && !demoActive && !profile.companionURL.isEmpty
    }

    /// The host just proved it is there.
    func noteLive() {
        lastLiveAt = Date()
        if health != .live { recomputeHealth() }
    }

    /// From cold: the clock counts from now, with no proof yet.
    func restartHealthClock() {
        wantedSince = Date()
        lastLiveAt = nil
        recomputeHealth()
    }

    func recomputeHealth(now: Date = Date()) {
        let value: ConnectionHealth
        if let forced = ConnectionHealthFixture.forced {
            value = forced
        } else if !healthApplies {
            value = .live
        } else {
            value = ConnectionHealth.judge(now: now, since: lastLiveAt ?? wantedSince,
                                           pathSatisfied: networkPath.satisfied)
        }
        if value != health { health = value }
    }

    /// One tick a second while the app is up; the arithmetic is the clock.
    func startHealth() {
        networkPath.onChange = { [weak self] satisfied, returned, moved in
            self?.networkChanged(satisfied: satisfied, returned: returned, moved: moved)
        }
        if !ProcessInfo.processInfo.arguments.contains("--no-network-watch") { networkPath.start() } // non-copy: a launch flag
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.recomputeHealth()
            }
        }
    }

    /// The network came back, or moved to another interface: reconnect now
    /// rather than wait out the backoff (which grows to 15 s). A connection
    /// that is still proving itself alive is left alone.
    func networkChanged(satisfied: Bool, returned: Bool, moved: Bool) {
        recomputeHealth()
        guard satisfied, healthApplies else { return }
        let stale = !companionConnected || !health.isLive
        guard (returned && stale) || (moved && !health.isLive) else { return }
        reconnectAttempts = 0
        reconnectTask?.cancel(); reconnectTask = nil
        noteNetworkReturned()
        Task { [weak self] in await self?.establishConnection() }
    }

    /// The red banner's own action: try now.
    func retryConnectionNow() {
        guard healthApplies else { return }
        reconnectAttempts = 0
        reconnectTask?.cancel(); reconnectTask = nil
        noteNetworkReturned()
        Task { [weak self] in await self?.establishConnection() }
    }

    /// The banner's words, with this computer's name in them.
    var healthMessage: String? {
        let host = state.hostName.isEmpty ? profile.hostname : state.hostName
        if health == .trouble, lastLiveAt == nil { return Strings.connectionConnecting(host) }
        return health.message(host: host)
    }
}
