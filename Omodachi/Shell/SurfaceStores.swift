import Foundation

/// The Agent chat and Shortcut surfaces own their own stores. They outlive a
/// navigation away and back — a chat thread must not be re-attached and a
/// terminal must not restart because the Panel closed — so one holder keeps
/// them for the app's lifetime instead of the host connection store.
@MainActor final class SurfaceStores: ObservableObject {
    private unowned let home: HomeStore
    private var chats: [String: AgentChatStore] = [:]
    private var shortcuts: [String: ShortcutPanelStore] = [:]
    private var herdrStore: HerdrStore?
    private var voiceStores: [String: VoiceDictationStore] = [:]

    /// LINKS-1: where every tapped link goes — the Agent's, the Herdr
    /// mirror's and the SSH panel's. The Shell gives it the Safari view and
    /// Remote (`ShellView`), which only the Shell holds.
    let links = LinkOpener()

    init(home: HomeStore) { self.home = home }

    /// The Herdr surface keeps one store for the app's lifetime: its terminal
    /// buffer and the pane it was on must survive a trip to the Panel, and the
    /// host stream is released on the way out rather than by deallocating it.
    func herdr() -> HerdrStore {
        if let herdrStore { return herdrStore }
        let store = HerdrStore(home: home)
        store.links = links
        // HERDR-9: the simulator's UI fixture takes the writes and answers them.
        if HerdrChoicesFixture.requested {
            // HERDR-10: the Chinese card answers its own keys.
            var cjk = HerdrCJKFixture.requested ? HerdrCJKFixture.questionOne : ""
            store.writeOverride = { [weak store] pane, write in
                guard let store else { return }
                store.fixtureSent.append(HerdrChoicesFixture.line(pane: pane, write: write))
                if HerdrCJKFixture.requested, case .keys(let keys) = write, pane == store.selected {
                    if let next = HerdrCJKFixture.reaction(keys: keys, screen: cjk) {
                        cjk = next
                        store.showFixtureScreen(next)
                    }
                    return
                }
                if case .keys(let keys) = write, pane == store.selected,
                   let next = HerdrChoicesFixture.reaction(pane: pane, keys: keys) {
                    store.showFixtureScreen(next)
                }
            }
        }
        herdrStore = store
        return store
    }

    /// STORE-6 §A3: the demo's conversation, which says it is one.
    private var demoChat: AgentChatStore?

    func chat() -> AgentChatStore {
        if AgentChatToolFixtureTransport.requested {
            // AGENT-FIX-2: a scripted agent for the tool-turn UI test.
            if let demoChat { return demoChat }
            let store = AgentChatStore(transport: AgentChatToolFixtureTransport())
            demoChat = store
            return store
        }
        if AgentChatQueueFixtureTransport.requested {
            // AGENT-QUEUE-1: the queue, the checklist, a decline's reason and
            // earlier messages.
            if let demoChat { return demoChat }
            let store = AgentChatStore(transport: AgentChatQueueFixtureTransport())
            demoChat = store
            return store
        }
        if AgentChatPlanFixtureTransport.requested {
            // AGENT-PLAN-1: Plan mode, a question and a proposed plan.
            if let demoChat { return demoChat }
            let store = AgentChatStore(transport: AgentChatPlanFixtureTransport())
            demoChat = store
            return store
        }
        if AgentChatCollieFixtureTransport.requested {
            // AGENT-COLLIE-1: change cards, runs, a question and a long
            // conversation for the UI tests.
            if let demoChat { return demoChat }
            let store = AgentChatStore(transport: AgentChatCollieFixtureTransport())
            demoChat = store
            return store
        }
        if AgentChatLinksFixture.requested {
            if let demoChat { return demoChat }
            let store = AgentChatStore(transport: AgentChatDemoTransport(rows: AgentChatLinksFixture.rows))
            demoChat = store
            return store
        }
        if home.demoActive {
            if let demoChat { return demoChat }
            let store = AgentChatStore(transport: AgentChatDemoTransport())
            demoChat = store
            return store
        }
        let hostID = home.profile.companionURL
        if let existing = chats[hostID] { return existing }
        let store = AgentChatStore(transport: AgentChatBridge(home: home, hostID: hostID),
                                   uploader: { [home] in try home.chatClient(for: hostID) })
        chats[hostID] = store
        return store
    }

    /// One microphone per host, shared by every surface that offers voice: the
    /// host has exactly one virtual input and the arbiter refuses a second
    /// claim, so two stores would only produce `audio_input_busy` against
    /// ourselves. `nil` until there is a host connection to speak into.
    func voice() -> VoiceDictationStore? {
        let hostID = home.profile.companionURL
        guard home.companionConnected, !home.profile.mock, !hostID.isEmpty else { return nil }
        if let existing = voiceStores[hostID] { return existing }
        let store = VoiceDictationStore(client: { [home] in try home.chatClient(for: hostID) })
        voiceStores[hostID] = store
        return store
    }

    /// REMOTE-2 item 5. The app's own answer for a keybinding row its GUI
    /// covers. The router owns it — it is the thing that can open a Panel or a
    /// workspace — and it is handed to every per-host store from here so that
    /// switching host cannot quietly produce a store without one.
    var performLocalShortcut: ((ShortcutGUIMap.Capability) -> Bool)?
    /// A-66 (UX-2 §4), handed out the same way and for the same reason.
    var hostActionRan: (() -> Void)?
    /// OVERVIEW-1: a row of the "Needs you" list that belongs to another
    /// panel (the Agent's) goes there. Set by the Shell, which owns the router.
    var openPanel: ((PanelID) -> Void)?

    /// STORE-6 §A3: the demo's keybindings, its own store with the list already
    /// in it, so the demo's pinned keybindings resolve on the first frame
    /// rather than drawing as rows the host no longer has.
    private var demoShortcuts: ShortcutPanelStore?

    func shortcut() -> ShortcutPanelStore {
        if home.demoActive {
            if let demoShortcuts { return demoShortcuts }
            let store = ShortcutPanelStore(context: ShortcutContext(hostID: home.profile.companionURL, surface: .controller),
                                           transport: ShortcutBridge(home: home))
            store.model.snapshot = try? DemoHost.shortcuts()
            store.performLocally = { [weak self] capability in self?.performLocalShortcut?(capability) ?? false }
            demoShortcuts = store
            return store
        }
        let hostID = home.profile.companionURL
        if let existing = shortcuts[hostID] { return existing }
        let store = ShortcutPanelStore(context: ShortcutContext(hostID: hostID, surface: .controller),
                                       transport: ShortcutBridge(home: home))
        store.performLocally = { [weak self] capability in self?.performLocalShortcut?(capability) ?? false }
        store.ranOnHost = { [weak self] in self?.hostActionRan?() }
        shortcuts[hostID] = store
        return store
    }

    /// The host is the authority on which workspace actions this surface can
    /// actually reach; the store never guesses from its own cached listing.
    func refreshShortcutContext() {
        let store = shortcut()
        // Two kinds of coverage, both from what is actually on screen: the
        // catalog entries the bar can invoke, and the explicit key-combination
        // map in `ShortcutPanel/ShortcutGUIMap.swift`. A workspace the bar is
        // not drawing right now is not covered, so its binding stays listed.
        let refs = Set(home.workspaceRows.compactMap { $0.canSelect ? $0.selectEntryID : nil })
        let drawn = Set(NativeWorkspacePolicy.visible(home.barModel.workspaces)
            .filter(\.canSelect).map(\.id))
        store.updateContext(.init(hostID: home.profile.companionURL, surface: .controller,
                                  stateRevision: home.stateRevision, targetToken: home.focusTargetToken,
                                  inputReady: home.companionConnected),
                            coverage: .fromGUI(panelAvailable: home.companionConnected,
                                               keybindingsAvailable: true,
                                               reachableWorkspaces: drawn,
                                               actionRefs: refs))
        // The list is built the moment its view appears, which is usually
        // before the host connection finishes. Without this the first snapshot
        // fails and stays failed until someone presses Retry.
        if home.companionConnected, store.model.snapshot == nil || store.model.failed, !store.model.loading {
            Task { await store.refresh() }
        }
    }
}

private struct ShortcutBridge: ShortcutPanelTransport {
    let home: HomeStore
    func list(context: ShortcutContext) async throws -> ShortcutSnapshot { try await home.loadShortcuts() }
    func execute(_ request: ShortcutExecutionRequest) async throws -> ShortcutExecutionResult { try await home.runShortcut(request) }
}

private struct AgentChatBridge: AgentChatTransport {
    let home: HomeStore
    let hostID: String
    private func client() async throws -> CompanionHostClient { try await home.chatClient(for: hostID) }
    func prepareHandoff() async throws -> AgentChatHandoffPlan { try await client().prepareChatHandoff() }
    func confirmHandoff(planID: String) async throws -> AgentChatHandoffResult { try await client().confirmChatHandoff(planID: planID) }
    func ensureDefault() async throws -> AgentChatSnapshot { try await client().ensureChat() }
    func snapshot(for identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        let value = try await client().chatSnapshot()
        guard value.identity == identity else { throw AgentChatFailure.identityChanged }
        return value
    }
    func events(for identity: AgentChatIdentity, after sequence: Int) async throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        try await client().chatEvents(identity: identity, after: sequence)
    }
    func send(_ text: String, requestID: UUID, to identity: AgentChatIdentity) async throws { try await client().chatSend(text, id: requestID) }
    func send(_ text: String, requestID: UUID, model: String?, effort: String?, to identity: AgentChatIdentity) async throws {
        try await client().chatSend(text, id: requestID, model: model, effort: effort)
    }
    func steer(_ text: String, requestID: UUID, in identity: AgentChatIdentity) async throws {
        try await client().chatSteer(text, id: requestID)
    }
    func send(_ text: String, requestID: UUID, model: String?, effort: String?,
              attachments: [AttachmentRef], to identity: AgentChatIdentity) async throws -> AgentSendReceipt {
        try await client().chatSend(text, id: requestID, model: model, effort: effort, attachments: attachments)
    }
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        try await client().chatResolveApproval(requestID: requestID, decision: decision, input: input)
    }
    func models() async throws -> AgentModelCatalog { try await client().chatModels() }
    func setMode(_ mode: String) async throws -> AgentChatUsage { try await client().chatMode(mode) }
    // AGENT-QUEUE-1
    func queue(_ text: String, requestID: UUID, in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]? {
        try await client().chatQueue(text, id: requestID)
    }
    func queueItem(_ id: String, action: AgentQueueAction, text: String?,
                   in identity: AgentChatIdentity) async throws -> [AgentQueuedMessage]? {
        try await client().chatQueueItem(id, action: action, text: text)
    }
    func history(before: String?, limit: Int, in identity: AgentChatIdentity) async throws -> AgentHistoryPage {
        try await client().chatHistory(before: before, limit: limit)
    }
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?, reason: String?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        try await client().chatResolveApproval(requestID: requestID, decision: decision, input: input, reason: reason)
    }
    func newConversation(expected identity: AgentChatIdentity) async throws -> AgentChatSnapshot {
        try await client().chatNew(expected: identity.providerSessionID)
    }
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws { try await client().chatInterrupt(turnID) }
}
