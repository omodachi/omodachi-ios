import Foundation

/// Workspace selection, focused-window moves and the workspace-layout action.
/// All three share one rule: the host's own entry ID already binds the target,
/// so the client never infers a command and never retargets a stale request.
extension HomeStore {
    func workspace(_ value: Int) async {
        guard value > 0 else { return }
        if profile.mock { mockWorkspace(value); return }
        guard companionConnected, let service = companionClient,
              barModel.workspaces.contains(where: { $0.id == value && $0.canSelect }) else { return }
        // Study 04 A-64: a workspace square acts on the screen in front of the
        // user, and during a session that screen is ours. Core pulls the
        // workspace to the session's own output rather than refusing, so this
        // is sent in a session exactly as it is outside one. A host still
        // running the old core answers `remote_session_required`, and that
        // lands in the same 26-high row as any other refusal.
        let current = connectionGeneration
        let clock = PanelPerfTrace.begin("workspace.select", detail: "id=\(value)")
        // PERF-4 §1: the square moves now. The host is the authority and the
        // snapshot below settles it; what this removes is the ten seconds the
        // bar spent showing the workspace the user had just left.
        let previous = optimisticWorkspace
        setOptimisticWorkspace(value)
        PanelPerfTrace.mark(clock, "bar-optimistic", detail: "active=\(value)")
        // A-12: a workspace tap reports like any other action, in the Panel's
        // own 26-high row rather than in a notice at the bottom of the menu.
        let toast = PanelToast(stage: .accepted, label: Strings.barWorkspaceName(Format.count(value)))
        reportToast(toast)
        do {
            try await service.selectWorkspace(value)
            guard current == connectionGeneration else { return }
            PanelPerfTrace.mark(clock, "host-accepted")
            settleToast(id: toast.id, stage: .applied, detail: nil)
            await refreshCompanionState()
            // The host's own snapshot, taken after the request, is the
            // authority — including when it disagrees. The optimistic square
            // only ever covers the gap between the tap and this line.
            setOptimisticWorkspace(nil)
            PanelPerfTrace.mark(clock, "snapshot-applied", detail: "active=\(state.workspace)")
        } catch {
            PanelPerfTrace.mark(clock, "host-refused")
            guard current == connectionGeneration else { return }
            // The host refused it, so the square goes back where it was until
            // the snapshot below settles it.
            setOptimisticWorkspace(previous)
            // The host refuses a workspace the compositor has not created —
            // an empty persistent row is listed but not selectable — and says
            // so with `workspace_unavailable`.
            let code = (error as? CompanionHostError).flatMap { error -> String? in
                if case let .unavailable(code, _) = error { return code }
                if case let .blocked(code, _) = error { return code }
                return nil
            }
            settleToast(id: toast.id, stage: .failed, detail: code ?? "refused")
            notice = (error as? CompanionHostError)?.errorDescription ?? ReasonText.message("workspace_layout_failed", domain: .workspace)
            await refreshCompanionState()
            setOptimisticWorkspace(nil)
        }
    }

    func moveFocusedWindow(to value: Int) async {
        guard (1...10).contains(value) else { return }
        guard !profile.mock else { notice = Strings.hostDemoLocalState; return }
        guard companionConnected, barModel.available, let service = companionClient,
              let snapshot = latestState, let revision = catalogRevision,
              let item = snapshot.workspace?.items?.first(where: { $0.id == value }) else {
            notice = ReasonText.message("workspace_preflight_unavailable", domain: .workspace)
            return
        }
        guard let entryID = item.moveFocusedEntryID, barActionAvailable(entryID) else {
            notice = ReasonText.message("route_unavailable", domain: .host)
            return
        }
        guard let target = snapshot.focus?.targetToken, !target.isEmpty else {
            notice = ReasonText.message("no_focused_window", domain: .workspace)
            return
        }
        let current = connectionGeneration
        do {
            let result = try await service.invoke(entryID: entryID, catalogRevision: revision, parameters: [:],
                                                  targetToken: target, stateRevision: snapshot.revision)
            guard current == connectionGeneration else { return }
            notice = result.message
            await refreshCompanionState()
        } catch {
            guard current == connectionGeneration else { return }
            notice = (error as? CompanionHostError)?.errorDescription ?? ReasonText.message("workspace_layout_outcome_unknown", domain: .workspace)
            if case CompanionHostError.staleTarget = error { await refreshCompanionState() }
            // A stale move is never retried against the newly focused window.
        }
    }

    func makeWorkspaceLayoutOffer(_ snapshot: HostStateDTO) -> WorkspaceLayoutOffer? {
        guard companionConnected, !profile.mock, let catalog = snapshot.catalog,
              let entry = catalog.entries.first(where: { $0.id == WorkspaceLayoutRequest.entryID }),
              let checked = entry.conditions?.checked else { return nil }
        return .init(connection: connectionGeneration, workspaceID: snapshot.workspace?.active, stateRevision: snapshot.revision,
            catalogRevision: catalog.revision, visible: entry.visible == true, supported: entry.descriptor?.supported == true,
            ready: entry.descriptor?.ready == true, route: entry.descriptor?.route,
            checkedStatus: checked.status, checkedReason: checked.reason, checkedValueIsNull: checked.valueIsNull,
            bindingFieldPresent: snapshot.workspace?.layoutBindingFieldPresent ?? false, binding: snapshot.workspace?.layoutBinding)
    }

    func canRetryWorkspaceLayout(_ selection: WorkspaceLayoutSelection) -> Bool {
        companionConnected && workspaceLayoutRetry == selection
            && selection.canRetrySameRequest(connection: connectionGeneration, serverInstanceID: latestState?.instanceID)
    }

    func applyWorkspaceLayout(_ selection: WorkspaceLayoutSelection, retrySameRequest: Bool = false) async {
        guard !workspaceLayoutBusy else { return }
        guard companionConnected, !profile.mock, let service = companionClient,
              selection.connection == connectionGeneration else {
            notice = ReasonText.message("stale_plan", domain: .workspace)
            workspaceLayoutRetry = nil; return
        }
        // Stable scope allows unrelated global heartbeat churn, but an old
        // selection may not silently adopt a changed workspace/layout/instance.
        let stillValid = retrySameRequest ? canRetryWorkspaceLayout(selection) : selection.matchesCurrent(workspaceLayoutOffer)
        guard stillValid else {
            notice = ReasonText.message("stale_plan", domain: .workspace)
            workspaceLayoutRetry = nil; return
        }
        workspaceLayoutBusy = true; workspaceLayoutRetry = nil
        let current = connectionGeneration
        defer { if current == connectionGeneration { workspaceLayoutBusy = false } }
        do {
            // Never substitute the latest active workspace, revision or a
            // focused-window token. A retry uses this same request_id and body.
            let response = try await service.invokeWorkspaceLayout(selection.request)
            guard current == connectionGeneration else { return }
            notice = WorkspaceLayoutResultPolicy.message(request: selection.request,
                responseRequestID: response.requestID, entryID: response.entryID,
                status: response.status.rawValue, effects: response.workspaceEffects)
            await refreshCompanionState()
        } catch let error as WorkspaceLayoutRequestError {
            guard current == connectionGeneration else { return }
            notice = error.message; await refreshCompanionState()
        } catch {
            guard current == connectionGeneration else { return }
            notice = Strings.workspaceLayoutRetryUnknown(Format.count(selection.request.params.workspaceID))
            workspaceLayoutRetry = selection
            await refreshCompanionState()
        }
    }

    /// Whether the host has confirmed an attachable default agent. Every branch
    /// is a host observation; nothing here is a client guess.
    static func taskBlockReason(_ agent: DefaultAgentCapabilityDTO?, status: CompanionOperationStatus?) -> String? {
        if status == .working || agent?.agentStatus == .working { return ReasonText.message("agent_busy", domain: .agent) }
        if status == .blocked || agent?.agentStatus == .blocked { return ReasonText.message("agent_blocked", domain: .agent) }
        guard let agent else { return ReasonText.message("agent_state_unknown", domain: .agent) }
        let configured = agent.configuredKind ?? agent.omarchyDefaultAgent
        guard let configured, !configured.isEmpty else { return ReasonText.message("default_agent_unset", domain: .agent) }
        if agent.kindMismatch == true || agent.actualKind.map({ $0 != configured }) == true {
            return ReasonText.message("agent_kind_mismatch", domain: .agent)
        }
        guard agent.kindSupported == true else { return ReasonText.message("agent_kind_unsupported", domain: .agent) }
        guard agent.defaultAgentExists == true, agent.paneAvailable == true, agent.readyToAttach == true,
              agent.paneID?.isEmpty == false,
              agent.defaultAgentProbe == "available", agent.herdrAvailable == true else {
            return ReasonText.message("agent_state_unknown", domain: .agent)
        }
        return nil
    }
}
