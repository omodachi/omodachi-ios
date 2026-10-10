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
        restartHealthClock()
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
            // TAIL-3b I3. The event stream is how core knows the App is in
            // front (`native_connected`): while one is open it holds the web
            // pushes to this person's Odomo. So it is closed — a WebSocket
            // close frame, not a socket left to time out — the moment the App
            // leaves the front, and opened again when it comes back.
            let previous = client
            stopActiveConnection(); markUnavailable(nil); connectionState = .suspended
            await previous?.disconnect()
        } else if connectionWanted, !profile.mock {
            reconnectAttempts = 0
            restartHealthClock()
            await establishConnection()
        }
    }

    /// NOTIFY-2. `PUT /v1/presence`: whether this app is in front, and which
    /// kinds it alerts by itself, so Odomo is held back for exactly those. A
    /// core from before the route answers 404 and nothing changes.
    @discardableResult
    func reportPresence(foreground: Bool) async -> PresenceDTO? {
        guard !profile.mock, companionConnected, let reporter = client as? any PresenceReporting else { return nil }
        let alerts = foreground ? (attention?.alertKinds ?? []) : []
        let value = await reporter.reportPresence(PresenceBody(foreground: foreground, alerts: alerts))
        if let value {
            AttentionNotifier.note("presence \(value.foreground ? "front" : "back") quiets=\(value.quiets.count)") // non-copy: a log line
        }
        return value
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
        guard let accountURL = URL(string: profile.companionURL),
              let paired = try? CompanionHostConfiguration(endpoint: accountURL) else {
            connectionState = .unavailable
            notice = Strings.hostAddressMissing
            return
        }
        // TAIL-2 P0-2 / TAIL-3b. The account — what the credential and the pin
        // are stored under — is the address this device paired over, and it
        // never moves. Where to *dial* is the host's one road.
        let account = paired.account
        let pin = pinStore.load(account: account)
        connectionState = reconnectAttempts == 0 ? .connecting : .reconnecting
        let endpoint = chooseRoad(account: account, pin: pin)
        guard current == connectionGeneration, foreground, connectionWanted else { return }
        guard let configuration = try? CompanionHostConfiguration(endpoint: endpoint, account: account) else {
            connectionState = .unavailable
            notice = Strings.hostAddressMissing
            return
        }
        let service = clientFactory(configuration, pin?.fingerprintSHA256)
        client = service
        // HERDR-11 §3: every frame and every answered beat ping is proof of life.
        await service.setLiveness { [weak self] in Task { @MainActor in self?.noteLive() } }
        do {
            try await service.connect()
            let snapshot = try await service.fetchSnapshot()
            guard current == connectionGeneration, foreground, connectionWanted else { await service.disconnect(); return }
            noteLive()
            companionConnected = true
            connectionState = .connected
            hostOffline = false
            road = HostRoad(host: configuration.endpoint.host ?? "", port: configuration.endpoint.port ?? 8099)
            // TAIL-2 P0-2 / TAIL-3b: learn what the host says about itself —
            // its MagicDNS name above all, which "Use Tailscale for this
            // computer" offers, and its Odomo address. It never changes where
            // this device dials.
            if let pin { Task { [weak self] in await self?.refreshRoads(using: service, pin: pin, account: account) } }
            Task { [weak self] in await self?.refreshSSHTarget(using: service, account: account) }
            connectionStarted = Date()
            certificateChange = nil
            // NOTIFY-2: a new connection is a new first look for the alerts,
            // and core is told again what this app alerts while in front.
            if let hostID = pin?.hostID { attention?.connected(hostID: hostID, hostName: state.hostName) }
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
            Task { [weak self] in await self?.reportPresence(foreground: true) }
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

    /// TAIL-3b. The host's one road — never a second one, never a probe of
    /// several (TAIL-2's rotation and last-good memory are gone). A Tailscale
    /// host is dialled by its MagicDNS name only, so no LAN address is ever
    /// tried for it; a Wi-Fi host by its address, and on every other attempt
    /// by its `.local` name.
    func chooseRoad(account: String, pin: HostPin?) -> URL {
        let fallback = URL(string: account) ?? URL(string: profile.companionURL)!
        guard let pin else { return fallback }
        return HostRoads.dialURL(road: pin.road(account: account), roads: pin.roads,
                                 attempt: reconnectAttempts) ?? fallback
    }

    /// `GET /v1/host/roads` on the connection just made — pinned and
    /// credentialed — so the host's own list of addresses, its MagicDNS name
    /// included, goes into the pin. At home this is where the tailnet name is
    /// learnt. A core without the route answers 404: no update, nothing said.
    func refreshRoads(using service: any CompanionServing, pin: HostPin, account: String) async {
        guard let reader = service as? any HostRoadsReading,
              let roads = await reader.fetchHostRoads() else { return }
        // TAIL-3b I2 / LITE-1d: where this host's Odomo is and whether a
        // device already gets its pushes, for the Notifications card and the
        // Settings rows.
        if roads.host_id == pin.hostID { odomo = DevelopmentLaunch.harness(roads.odomoReading) }
        storeRoads(roads, pin: pin, account: account)
    }

    /// LITE-1d: read the roads again on the live connection — after the
    /// Safari view with Odomo in it closes, so a phone that just turned on
    /// Odomo's notifications stops being offered them. Coming back from the
    /// Home Screen web app reconnects, which reads them anyway.
    func refreshOdomo() async {
        guard let service = client, companionConnected, let pin = hostPin else { return }
        await refreshRoads(using: service, pin: pin, account: HostAccount.canonical(profile.companionURL))
    }

    /// LITE-1d / ODOMO-CARD: "Hide" on the Notifications card (and the
    /// switch in Settings turned off), for this computer.
    func dismissOdomoOffer(memory: OdomoOfferMemory = OdomoOfferMemory()) {
        memory.dismiss(odomoHostKey)
        odomoNotNowRevision += 1
    }

    /// Read in a view's body; `odomoNotNowRevision` is what redraws it.
    func odomoOfferDismissed(memory: OdomoOfferMemory = OdomoOfferMemory()) -> Bool {
        memory.isDismissed(odomoHostKey)
    }

    /// ODOMO-CARD: Settings' switch turned on — the card is offered again for
    /// this computer (unless a device already gets Odomo's pushes). It also
    /// forgets "Odomo is on this device": someone who turns it on wants the
    /// offer, e.g. after taking Odomo off the Home Screen; the next link from
    /// Odomo teaches it again.
    func showOdomoOffer(memory: OdomoOfferMemory = OdomoOfferMemory(),
                        here: OdomoOfferMemory = OdomoOfferMemory.here()) {
        memory.forget(odomoHostKey)
        if let hostID = hostPin?.hostID { here.forget(hostID) }
        odomoNotNowRevision += 1
    }

    /// ODOMO-CARD: Odomo is on this device for this computer — learnt from a
    /// link it handed to the app. Keyed by `host_id` only, as the link is.
    func odomoOnThisDevice(here: OdomoOfferMemory = OdomoOfferMemory.here()) -> Bool {
        guard let hostID = hostPin?.hostID else { return false }
        return here.contains(hostID)
    }

    /// ODOMO-CARD: remember that Odomo is on this device for `hostID` (a host
    /// this device is paired with; `OdomoOffer.learnsHere` decides).
    func learnOdomoHere(_ hostID: String, here: OdomoOfferMemory = OdomoOfferMemory.here()) {
        guard !here.contains(hostID) else { return }
        here.remember(hostID)
        odomoNotNowRevision += 1
    }

    /// Only the same installation (`host_id`) under the pinned certificate may
    /// change what this device knows about the host. TAIL-3b: the road it is
    /// dialled on is not part of that — `current.road` is kept as it is.
    func storeRoads(_ document: HostRoadsDTO, pin: HostPin, account: String) {
        guard document.host_id == pin.hostID,
              document.tls_fingerprint_sha256 == nil || document.tls_fingerprint_sha256 == pin.fingerprintSHA256 else { return }
        let fresh = document.roads
        guard !fresh.isEmpty else { return }
        guard var current = pinStore.load(account: account), current.hostID == pin.hostID else { return }
        let merged = HostRoads.merge(current.roads, fresh)
        let endpoints = merged.map { HostPin.Endpoint(host: $0.host, port: $0.port, kind: $0.kind) }
        guard endpoints != current.endpoints else { return }
        current.endpoints = endpoints
        try? pinStore.save(current, account: account)
    }

    /// TAIL-2 P0-4 / P1-1. Where the terminal is now, and whether Tailscale
    /// SSH answers port 22 on the tailnet, read once per connection from
    /// `GET /v1/ssh/key`'s `target`. A host from before TAIL-2 has no target
    /// and the pin keeps what the claim said.
    func refreshSSHTarget(using service: any CompanionServing, account: String) async {
        guard let reader = service as? any SSHTargetReading,
              let target = try? await reader.fetchSSHTarget(),
              var current = pinStore.load(account: account) else { return }
        guard let updated = target.endpoint(keeping: current.ssh), updated != current.ssh else { return }
        current.ssh = updated
        try? pinStore.save(current, account: account)
        objectWillChange.send()
    }

    func stopActiveConnection() {
        connectionGeneration = UUID()
        streamTask?.cancel(); streamTask = nil
        refreshTask?.cancel(); refreshTask = nil; refreshNeeded = false
        reconnectTask?.cancel(); reconnectTask = nil
        let previous = client
        client = nil
        companionConnected = false
        road = nil
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
        noteLive()
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
        // NOTIFY-2: the two events the app's own alerts are about, read here at
        // the app level so they speak whichever panel is on screen.
        // NOTIFY-1: and whether the person is at the computer, and what
        // finished with nobody looking.
        if ["agent.changed", "herdr.layout.changed", "desk.changed", "unseen.changed"].contains(event.type) { // non-copy: event types
            attention?.handle(event)
        }
        // OVERVIEW-1: the list moved (or, from an older core, one of the
        // things it is built from did).
        if overviewEvent(event) { return }
        if event.type == "herdr.layout.changed" { noteHerdrLayoutChanged(session: event.herdrAttention?.session); return }
        // The shell keeps ten notifications and deletes the icons of the ones
        // it evicts, so the row itself rides the event rather than being
        // fetched afterwards and losing the race.
        if event.type == "notification.posted" {
            if let row = event.notification { present(row) }
            return
        }
        // NOTIFY-3: left the desktop's screen (history), or decided (gone).
        if event.type == "notification.updated" {
            if let row = event.notification { notificationUpdated(row) }
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
                    // HERDR-11 §4: the catalog this device holds is named, so
                    // core leaves its ~587 KB of rows out when it is current.
                    let snapshot = try await service.fetchState(knownCatalog: self.catalogRevision)
                    guard self.connectionGeneration == current else { return }
                    PanelPerfTrace.mark(clock, "state-received", detail: "revision=\(snapshot.revision)")
                    self.noteLive()
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
            let snapshot = try await service.fetchState(knownCatalog: catalogRevision)
            guard current == connectionGeneration else { return }
            PanelPerfTrace.mark(clock, "state-received", detail: "revision=\(snapshot.revision)")
            noteLive()
            apply(snapshot)
            PanelPerfTrace.mark(clock, "state-applied")
        } catch {
            guard current == connectionGeneration else { return }
            PanelPerfTrace.mark(clock, "state-failed", detail: "\(error)")
            markUnavailable(error)
        }
    }
}
