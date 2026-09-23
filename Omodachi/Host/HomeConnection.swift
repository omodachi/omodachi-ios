import Foundation

/// Everything about holding one host connection open: establishing it, the
/// bounded reconnect, and the event subscription that keeps the snapshot fresh.
extension HomeStore {
    // MARK: - Connection

    /// Explicitly invoked after pairing or a settings save. Existing saved
    /// profiles may reconnect at launch.
    func connectCompanion() async {
        guard !profile.mock else { notice = Strings.hostDemoLocalState; return }
        guard connectionState != .connecting else { return }
        connectionWanted = true
        reconnectAttempts = 0
        await establishConnection()
    }

    /// PAIR-5 §2. This device is not paired with that host any more — the
    /// credential was refused, or it is gone. Everything about the connection
    /// stops, and nothing is said: the host list is what the user sees next.
    func releaseHost() {
        connectionWanted = false
        approvals.detach()
        clipboard.detach()
        stopActiveConnection()
        markUnavailable(nil)
        connectionState = .disconnected
        certificateChange = nil
        notice = nil
    }

    func disconnectCompanion() async {
        connectionWanted = false
        approvals.detach()
        clipboard.detach()
        stopActiveConnection()
        markUnavailable(nil)
        // PERF-4 §1 keeps the last host-confirmed reading through a *transient*
        // loss — that is what stopped the menu going grey every time a refresh
        // was slow. This is not one: the user or a host switch asked for the
        // connection to end, so the checkmarks it confirmed go with it.
        state.toggles = [:]
        connectionState = .disconnected
        notice = Strings.hostDisconnected
    }

    func setForeground(_ active: Bool) async {
        guard foreground != active else { return }
        foreground = active
        if !active {
            stopActiveConnection(); markUnavailable(nil); connectionState = .suspended
        } else if connectionWanted, !profile.mock {
            reconnectAttempts = 0
            await establishConnection()
        }
    }

    /// The user explicitly accepting a certificate they rotated themselves.
    func trustRotatedCertificate() async {
        // PAIR-4 §4 / PAIR-5 §1: the pin is keyed by the derived account, and
        // `companionURL` is only *usually* that string.
        let account = HostAccount.canonical(profile.companionURL)
        guard let change = certificateChange, let pin = pinStore.load(account: account) else { return }
        try? pinStore.trustRotatedCertificate(hostID: pin.hostID, fingerprint: change.observed, account: account)
        certificateChange = nil
        await connectCompanion()
    }

    func establishConnection() async {
        guard foreground, connectionWanted, !profile.mock else { return }
        stopActiveConnection()
        let current = connectionGeneration
        guard let endpoint = URL(string: profile.companionURL),
              let configuration = try? CompanionHostConfiguration(endpoint: endpoint) else {
            connectionState = .unavailable
            notice = Strings.hostAddressMissing
            return
        }
        let service = clientFactory(configuration, pinStore.load(account: configuration.account)?.fingerprintSHA256)
        client = service
        connectionState = reconnectAttempts == 0 ? .connecting : .reconnecting
        do {
            try await service.connect()
            let snapshot = try await service.fetchSnapshot()
            guard current == connectionGeneration, foreground, connectionWanted else { await service.disconnect(); return }
            companionConnected = true
            connectionState = .connected
            hostOffline = false
            connectionStarted = Date()
            certificateChange = nil
            apply(snapshot, establishingCursor: true)
            notice = nil
            listen(using: service, generation: current)
            // The theme and the fonts are what the rest of the app paints with,
            // so they are pulled as soon as there is a connection rather than
            // when a view first asks.
            Task { [weak self] in await self?.loadAppearance() }
            // The notification history is read once per connection; the event
            // stream keeps it current from there.
            Task { [weak self] in await self?.loadNotifications() }
            // AUTH-1: read both switches back, and pick up an approval that is
            // still running if this reconnect happened in the middle of one.
            approvals.attach(service: service as? any HostApprovalServing,
                             deviceID: HomeStore.companionDeviceID(defaults: defaults),
                             account: "approval-\(configuration.account)",
                             label: CompanionDeviceName.current())
            // CLIP-1: the same two-switch read. Which half the *host* is on is
            // the only thing ⑥ cannot work out for itself.
            clipboard.attach(service: service as? any ClipboardServing,
                             deviceMode: ShellPreferences.load(defaults: defaults).clipboardSync)
        } catch {
            guard current == connectionGeneration else { return }
            if case let CompanionHostError.certificateChanged(observed, pinned) = error {
                certificateChange = (observed, pinned)
            }
            // PAIR-5 §2. A 401 is not a connection problem to display and retry
            // — it is the host saying this device is not paired with it. The
            // Shell's gate drops what this device holds and shows the list.
            if HomeStore.describesACredentialRejection(error) {
                let account = HostAccount.canonical(profile.companionURL)
                await service.disconnect()
                releaseHost()
                onCredentialRejected?(account)
                return
            }
            markUnavailable(error)
            await service.disconnect()
            client = nil
            // Authentication and configuration errors need a user action;
            // a host that did not answer is retried, and never a mutation.
            if HomeStore.describesAnUnreachableHost(error) { scheduleReconnect() }
        }
    }

    func stopActiveConnection() {
        connectionGeneration = UUID()
        streamTask?.cancel(); streamTask = nil
        refreshTask?.cancel(); refreshTask = nil; refreshNeeded = false
        reconnectTask?.cancel(); reconnectTask = nil
        let previous = client
        client = nil
        companionConnected = false
        connectionState = .disconnected
        if let previous { Task { await previous.disconnect() } }
    }

    func scheduleReconnect() {
        guard connectionWanted, foreground, !profile.mock, reconnectTask == nil else { return }
        reconnectAttempts += 1
        // PAIR-5 §2. It used to give up after five tries and leave a sentence
        // asking the user to go and press something. "主机离线" is a state a
        // computer comes back from by itself, so the backoff grows to 15 s and
        // then holds there: the row in ① goes away on its own, and the retry
        // on it is for someone who does not want to wait.
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 15)
        let current = connectionGeneration
        connectionState = reconnectAttempts > 5 ? .offline : .reconnecting
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.connectionGeneration == current, self.connectionWanted, self.foreground else { return }
            self.reconnectTask = nil
            await self.establishConnection()
        }
    }

    // MARK: - Events

    /// The subscription carries no replay ring and no instance-substitution
    /// check. A snapshot frame re-establishes the cursor; a break or a resync
    /// re-reads `GET /v1/state` and resubscribes from that snapshot's cursor.
    func listen(using service: any CompanionServing, generation current: UUID) {
        let cursor = lastCursor, instance = instanceID
        streamTask = Task { [weak self] in
            let events = await service.events(since: cursor, instanceID: instance)
            do {
                for try await event in events {
                    guard !Task.isCancelled, let self, self.connectionGeneration == current else { return }
                    self.consume(event, using: service, generation: current)
                    if event.needsResync { break }
                }
                guard !Task.isCancelled, let self, self.connectionGeneration == current else { return }
                self.markUnavailable(CompanionHostError.transport(message: Strings.hostReconnecting))
                self.scheduleReconnect()
            } catch {
                guard !Task.isCancelled, let self, self.connectionGeneration == current else { return }
                self.markUnavailable(error)
                self.scheduleReconnect()
            }
        }
    }

    func consume(_ event: SanitizedHostEvent, using service: any CompanionServing, generation current: UUID) {
        if Date().timeIntervalSince(connectionStarted) > 30 { reconnectAttempts = 0 }
        if event.needsResync { instanceID = nil; lastCursor = 0; return }
        if let summon = event.panelSummon { panelSummon = summon }
        if let change = event.remoteSession { remoteSessionChange = change }
        if let snapshot = event.snapshot { apply(snapshot, establishingCursor: true); return }
        if let cursor = event.sequence { lastCursor = max(lastCursor, cursor) }
        if event.type == "ready" { return }
        // The host says a theme or a font moved; the client re-reads and the
        // whole app repaints without a restart (SPEC-F2 §1).
        if event.type == "theme.changed" || event.type == "fonts.changed" {
            let fonts = event.type == "fonts.changed"
            Task { [weak self] in
                guard let self, self.connectionGeneration == current else { return }
                await self.loadAppearance(refreshingFonts: fonts)
            }
            return
        }
        if event.type == "herdr.layout.changed" { noteHerdrLayoutChanged(); return }
        // The shell keeps ten notifications and deletes the icons of the ones
        // it evicts, so the row itself rides the event rather than being
        // fetched afterwards and losing the race.
        if event.type == "notification.posted" {
            if let row = event.notification { present(row) }
            return
        }
        if event.type == "voice.transcript" {
            if let value = event.transcript { voiceTranscript = value }
            return
        }
        // AUTH-1. A password prompt is waiting on the host right now, so this
        // never coalesces into the one-per-second state refresh below: by the
        // time a refresh landed the host would already have timed out.
        if event.type == "auth.approval.requested" || event.type == "auth.approval.resolved" {
            approvals.handle(event)
            return
        }
        // CLIP-1. The text is not in the event — the coordinator fetches it —
        // and this never coalesces into the state refresh below, because a
        // clipboard a second late is a clipboard somebody already pasted past.
        if event.type == "clipboard.changed" {
            clipboard.hostClipboardChanged()
            return
        }
        // Events invalidate a snapshot; they never carry terminal output into UI.
        // Several events coalesce into at most one state GET per second.
        let relevant = ["state.changed", "catalog.changed", "agent.changed", "herdr.changed", "action.result",
                        "bar.changed", "workspace.changed", "focus.changed", "wake.changed",
                        "remote.session.changed", "remote_bar.changed", "remote.capabilities",
                        // ARCH-1 §5 #17: the desktop moved Do Not Disturb.
                        "notifications.changed"]
        guard relevant.contains(event.type) || event.type.hasPrefix("agent.") else { return }
        refreshNeeded = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.connectionGeneration == current, self.refreshNeeded else { break }
                let delay = max(0.25, 1 - Date().timeIntervalSince(self.lastRefresh))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard self.connectionGeneration == current, self.companionConnected else { return }
                self.refreshNeeded = false
                let clock = PanelPerfTrace.begin("refresh.state")
                do {
                    let snapshot = try await service.fetchState()
                    guard self.connectionGeneration == current else { return }
                    PanelPerfTrace.mark(clock, "state-received", detail: "revision=\(snapshot.revision)")
                    self.lastRefresh = Date()
                    self.apply(snapshot)
                } catch {
                    PanelPerfTrace.mark(clock, "state-failed", detail: "\(error)")
                    guard self.connectionGeneration == current else { return }
                    self.markUnavailable(error); self.scheduleReconnect(); break
                }
            }
            if let self, self.connectionGeneration == current { self.refreshTask = nil }
        }
    }

    /// PERF-4 §2. The follow-up read after an action, and the only one that
    /// should be used for one: `GET /v1/state` already carries the catalog —
    /// 587 KB of the 588 KB it returns — so `fetchSnapshot`'s four parallel
    /// requests downloaded the same half-megabyte of menu rows twice and added
    /// `capabilities` and `herdr`, neither of which an action changes.
    func refreshCompanionState() async {
        guard !profile.mock, companionConnected, let service = client else { return }
        let current = connectionGeneration
        let clock = PanelPerfTrace.begin("refresh.state.action")
        do {
            let snapshot = try await service.fetchState()
            guard current == connectionGeneration else { return }
            PanelPerfTrace.mark(clock, "state-received", detail: "revision=\(snapshot.revision)")
            apply(snapshot)
            PanelPerfTrace.mark(clock, "state-applied")
        } catch {
            guard current == connectionGeneration else { return }
            PanelPerfTrace.mark(clock, "state-failed", detail: "\(error)")
            markUnavailable(error)
        }
    }
}
