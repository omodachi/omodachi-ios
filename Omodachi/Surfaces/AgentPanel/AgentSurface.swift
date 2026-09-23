import SwiftUI

/// Panel ③ — Agent (A-56 "work surface", A-63).
///
/// A-63: entering the panel *is* the ensure. There is no "connect" button and
/// no question; while it is starting there is one 26-high progress row, and
/// when it has started that row goes away rather than turning into "已连接".
/// N-33 deleted the four status sentences this used to carry.
///
/// N-35 rev 5: the composer has no microphone. The uplink code is still in the
/// app (`Voice/`), nothing calls it, and the study that brings it back has to
/// settle core's resource model first.
struct AgentPanelView: View {
    @ObservedObject var store: AgentChatStore

    var body: some View {
        AgentChatView(model: $store.model,
            onSend: { _ in Task { await store.send() } },
            onCancel: { Task { await store.cancel() } },
            onRetry: { Task { await store.retry() } },
            onPrepareHandoff: { Task { await store.prepareHandoff() } },
            onConfirmHandoff: { Task { await store.confirmPreparedHandoff() } },
            onDeferHandoff: { store.deferHandoff() },
            onLoadSlash: { Task { await store.loadSlashCommands() } },
            onSelectSlash: { store.selectSlash($0) },
            onSteer: { Task { await store.steer() } },
            onDecide: { id, decision in Task { await store.decide(requestID: id, decision: decision) } },
            onAnswer: { id, input in Task { await store.answer(requestID: id, input: input) } },
            onLoadModels: { Task { await store.loadModels() } },
            onChooseModel: { store.choose(model: $0, effort: $1) })
            .task {
                AgentApprovalNotifier.shared.prepare()
                store.onApprovalRequested = { approval in
                    AgentApprovalNotifier.shared.approvalRequested(
                        approval, agentName: store.model.identity?.agentID ?? Strings.panelAgent)
                }
                await store.open()
            }
            // A prompt that stopped waiting — answered here or on the host —
            // has no reason to keep a banner in Notification Centre.
            .onChange(of: store.model.approvals) { _, approvals in
                for approval in approvals where !approval.isPending {
                    AgentApprovalNotifier.shared.resolved(requestID: approval.requestID)
                }
            }
            .onDisappear {
                store.onApprovalRequested = nil
                store.leave()
            }
    }
}
