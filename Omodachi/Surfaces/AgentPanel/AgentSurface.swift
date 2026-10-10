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
    @EnvironmentObject private var home: HomeStore
    @EnvironmentObject private var stores: SurfaceStores

    var body: some View {
        AgentChatView(model: $store.model, attachments: store.attachments,
                      face: home.agentFace(unseenOnly: false),
            onSend: { _ in Task { await store.send() } },
            onCancel: { Task { await store.cancel() } },
            onRetry: { Task { await store.retry() } },
            onPrepareHandoff: { Task { await store.prepareHandoff() } },
            onConfirmHandoff: { Task { await store.confirmPreparedHandoff() } },
            onDeferHandoff: { store.deferHandoff() },
            onSteer: { Task { await store.steer() } },
            onDecide: { id, decision in Task { await store.decide(requestID: id, decision: decision) } },
            onAnswer: { id, input in Task { await store.answer(requestID: id, input: input) } },
            onLoadModels: { Task { await store.loadModels() } },
            onChooseModel: { store.choose(model: $0, effort: $1) },
            onAskNew: { store.askNewConversation() },
            onCancelNew: { store.cancelNewConversation() },
            onConfirmNew: { Task { await store.confirmNewConversation() } },
            onLeavePlan: { Task { await store.leavePlan() } },
            onImplementPlan: { Task { await store.implementPlan() } },
            onCloseDiff: { store.closeDiff() },
            onQueue: { Task { await store.queueDraft() } },
            onQueueItem: { id, action, text in Task { await store.queueItem(id, action, text: text) } },
            onLoadEarlier: { Task { await store.loadEarlier() } },
            onDeclineWhy: { id, reason in Task { await store.declineWithReason(requestID: id, reason: reason) } },
            onOpenLink: { url, source in
                AppLinkTrace.note("open tapped scheme=\(url.scheme ?? "-")") // non-copy: a log line
                stores.links.open(url: url, from: source)
            })
            .task {
                // NOTIFY-2: the alerts are the app's now (`AttentionNotifier`),
                // read from the host's events whatever panel is up. Entering
                // here still asks for the quiet delivery it always asked for,
                // never for more; "Turn on alerts" is the real question.
                AttentionNotifier.shared.prepareQuietly()
                await store.open()
            }
            // REL2-POLISH-1: counted, so the old panel going away after a
            // turn of the phone does not stop the new one's observation.
            .onDisappear { store.panelDisappeared() }
            // MOTION-1: a finished or failed turn shown here has been seen; the
            // bar goes back to the vendor's mark.
            .onAppear { store.panelAppeared(); home.markAgentSeen() }
            .onChange(of: home.state.agentActivity) { _, _ in home.markAgentSeen() }
    }
}
