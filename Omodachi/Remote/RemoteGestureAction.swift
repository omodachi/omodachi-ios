import Foundation

/// GEST-1 §1 / §3. What happens after the picture has recognised a gesture.
///
/// N-37 is the whole of the design: a gesture is an **alias of a row**, so this
/// runs exactly the route that row runs — the keybinding catalog's own invoke
/// for `Toggle scratchpad` and `Full screen`, and core's relative-workspace
/// route for the two swipes, where the host names the neighbour rather than the
/// client guessing it from a snapshot that may already be stale.
///
/// It composes nothing of its own: no command, no dispatcher, no key. The
/// 26-high row (A-12, Study 04 §11d's shape) reports what the host said, once.
@MainActor struct RemoteGestureRunner {
    let home: HomeStore
    let shortcuts: ShortcutPanelStore
    let controller: RemoteSessionController

    func run(_ gesture: RemotePictureGesture) {
        guard let binding = controller.gestureBindings[gesture] else { return }
        guard let row = binding.row else {
            // N-37: the picture should not have fired at all, because the
            // gesture is not registered. Saying so is still better than silence.
            RemoteSessionTrace.gesture("\(gesture)", row: "none", outcome: "unbound")
            controller.reportGestureToast(.init(stage: .failed, label: gesture.title,
                                                detail: binding.unavailable ?? Strings.gestureNoHostBinding))
            return
        }
        switch row {
        case .relativeWorkspace(let step):
            Task { await workspace(step, gesture: gesture) }
        case .shortcut(let id, let actionRef, let label):
            Task { await shortcut(id: id, actionRef: actionRef, label: label, gesture: gesture) }
        }
    }

    /// A-64 rev 5 / review #24. `e+1` / `e-1`, resolved on the host. Inside a
    /// session core pulls the workspace onto the output the session owns, so
    /// this is the same request in and out of Remote (SHORTCUT-1 §7).
    private func workspace(_ step: RemoteWorkspaceStep, gesture: RemotePictureGesture) async {
        let label = RemoteGestureRow.relativeWorkspace(step: step).label
        guard home.companionConnected, let service = home.companionClient else {
            controller.reportGestureToast(.init(stage: .failed, label: label,
                                                detail: ReasonText.message("route_unavailable", domain: .host)))
            return
        }
        let toast = PanelToast(stage: .accepted, label: label)
        controller.reportGestureToast(toast)
        let current = home.connectionGeneration
        do {
            try await service.selectRelativeWorkspace(step)
            guard current == home.connectionGeneration else { return }
            RemoteSessionTrace.gesture("\(gesture)", row: step.rawValue, outcome: "applied")
            await home.refreshCompanionState()
            // The host's own snapshot names where it landed; this client never
            // predicts the neighbour, so the number can only come from there.
            let active = home.state.workspace
            controller.settleGestureToast(id: toast.id, stage: .applied,
                                          detail: active > 0 ? Strings.barWorkspaceName(Format.count(active)) : nil)
        } catch {
            guard current == home.connectionGeneration else { return }
            RemoteSessionTrace.gesture("\(gesture)", row: step.rawValue, outcome: "refused")
            let code = (error as? CompanionHostError).flatMap { error -> String? in
                if case let .unavailable(code, _) = error { return code }
                if case let .blocked(code, _) = error { return code }
                return nil
            }
            controller.settleGestureToast(id: toast.id, stage: .failed,
                                          detail: code ?? (error as? CompanionHostError)?.errorDescription
                                              ?? ReasonText.message("workspace_layout_failed", domain: .workspace))
        }
    }

    /// The catalog row itself, through the transport the Keybindings list uses.
    /// Same request shape, same revision, same receipt — the gesture is the row.
    private func shortcut(id: String, actionRef: String, label: String, gesture: RemotePictureGesture) async {
        guard let snapshot = shortcuts.model.snapshot, home.companionConnected else {
            controller.reportGestureToast(.init(stage: .failed, label: label,
                                                detail: Strings.keybindingsRefreshFirst))
            return
        }
        let toast = PanelToast(stage: .accepted, label: label)
        controller.reportGestureToast(toast)
        let request = ShortcutExecutionRequest(requestID: UUID(), entryID: id, actionRef: actionRef,
                                               revision: snapshot.revision, context: shortcuts.context)
        do {
            let result = try await home.runShortcut(request)
            switch result.status {
            case .accepted, .applied:
                RemoteSessionTrace.gesture("\(gesture)", row: id, outcome: result.status.rawValue)
                controller.settleGestureToast(id: toast.id, stage: .applied, detail: result.observed?.summary)
            case .rejected:
                RemoteSessionTrace.gesture("\(gesture)", row: id, outcome: "rejected")
                controller.settleGestureToast(id: toast.id, stage: .failed,
                                              detail: result.message ?? ShortcutPanelModel.explain(result.code))
            case .unknown:
                RemoteSessionTrace.gesture("\(gesture)", row: id, outcome: "unknown")
                controller.settleGestureToast(id: toast.id, stage: .failed,
                                              detail: result.message ?? Strings.keybindingsUnconfirmed)
            }
        } catch {
            RemoteSessionTrace.gesture("\(gesture)", row: id, outcome: "failed")
            controller.settleGestureToast(id: toast.id, stage: .failed, detail: Strings.hostActionOutcomeUnknown)
        }
    }
}
