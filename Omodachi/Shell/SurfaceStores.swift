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

    init(home: HomeStore) { self.home = home }

    /// The Herdr surface keeps one store for the app's lifetime: its terminal
    /// buffer and the pane it was on must survive a trip to the Panel, and the
    /// host stream is released on the way out rather than by deallocating it.
    func herdr() -> HerdrStore {
        if let herdrStore { return herdrStore }
        let store = HerdrStore(home: home)
        herdrStore = store
        return store
    }

    func chat() -> AgentChatStore {
        let hostID = home.profile.companionURL
        if let existing = chats[hostID] { return existing }
        let store = AgentChatStore(transport: AgentChatBridge(home: home, hostID: hostID))
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

    func shortcut() -> ShortcutPanelStore {
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
    func slashCommands() async throws -> AgentSlashCatalog { try await client().chatSlashCommands() }
    func executeSlash(commandID: String, revision: String, arguments: String, requestID: UUID) async throws -> AgentSlashResult {
        try await client().chatExecuteSlash(id: commandID, revision: revision, arguments: arguments, requestID: requestID)
    }
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
    func resolveApproval(requestID: String, decision: String?, input: [String: [String]]?,
                         in identity: AgentChatIdentity) async throws -> AgentChatApprovalResolution {
        try await client().chatResolveApproval(requestID: requestID, decision: decision, input: input)
    }
    func models() async throws -> AgentModelCatalog { try await client().chatModels() }
    func interrupt(turnID: String, in identity: AgentChatIdentity) async throws { try await client().chatInterrupt(turnID) }
}
