import Foundation
import Combine

/// B supplies the actual catalog/provider transport. No invented HTTP endpoint
/// and no fixture fallback is embedded in this component.
protocol ShortcutPanelTransport: Sendable {
    func list(context: ShortcutContext) async throws -> ShortcutSnapshot
    func execute(_ request: ShortcutExecutionRequest) async throws -> ShortcutExecutionResult
}

@MainActor final class ShortcutPanelStore: ObservableObject {
    @Published var model = ShortcutPanelModel()
    @Published private(set) var context: ShortcutContext
    private let transport: any ShortcutPanelTransport
    private var revision: UInt = 0
    private var executionID: UUID?
    /// REMOTE-2 item 5. What this app does itself for a row its own GUI already
    /// covers. Returning false means "this device cannot do it right now",
    /// which becomes a reason on the row rather than silence.
    ///
    /// Before this the covered rows were dropped by a bare `guard` inside
    /// `execute`: `Omarchy menu` was listed, enabled, hittable — and did
    /// nothing at all, said nothing at all (MERGE-1 §7.2). A row is either
    /// executable or dimmed with a reason; "lit and silent" is not a state.
    var performLocally: ((ShortcutGUIMap.Capability) -> Bool)?
    /// A-66 (UX-2 §4). Called once, after a binding the host accepted. A row
    /// that ran on this device instead (`runLocally`) does not call it: it
    /// opened a panel, and closing the panel it just opened is not a favour.
    var ranOnHost: (() -> Void)?

    init(context: ShortcutContext, transport: any ShortcutPanelTransport, coverage: ShortcutGUICoverage = .init()) {
        self.context = context
        self.transport = transport
        self.model.coverage = coverage
    }

    func updateContext(_ next: ShortcutContext, coverage: ShortcutGUICoverage) {
        model.coverage = coverage
        guard next != context else { return }
        let changedHost = next.hostID != context.hostID
        let changedScope = !next.sameScope(as: context)
        context = next
        guard changedScope else { return }
        revision &+= 1
        model.loading = false
        model.executingEntryID = nil
        executionID = nil
        if changedHost {
            model.snapshot = nil
            model.query = ""
            model.scrollEntryID = nil
            model.notice = nil
        }
    }

    func refresh() async {
        guard context.supportsGlobalShortcuts, !model.loading else { return }
        revision &+= 1
        let current = revision, target = context
        model.loading = true
        model.failed = false
        defer { if revision == current { model.loading = false } }
        do {
            let value = try await transport.list(context: target)
            guard revision == current, target.sameScope(as: context) else { return }
            model.snapshot = value
            model.notice = value.available ? nil : (value.unavailableReason ?? Strings.keybindingsUnavailable)
            model.failed = !value.available
        } catch {
            guard revision == current else { return }
            model.failed = true
            model.notice = Strings.keybindingsLoadFailed
        }
    }


    /// MERGE-1. The catalog revision a Remote session is running under is not
    /// the one the list was fetched with: opening the session adds an output
    /// and a workspace, which is a catalog change, and from then on every
    /// invoke came back `stale_catalog_revision` — which the client maps onto
    /// the same `staleTarget` a moved window produces, and the Panel could only
    /// say "not confirmed". That is exactly Leo's item B seen from the inside.
    ///
    /// Core rejects a stale revision *before* it records acceptance and before
    /// it runs anything (`service.invoke`), so refreshing the list once and
    /// resending with the revision the host is actually on cannot execute the
    /// action twice. One retry, never a loop.
    private func send(_ request: ShortcutExecutionRequest, entry: ShortcutEntry,
                      snapshot: ShortcutSnapshot, guarding current: UInt,
                      scope: ShortcutContext) async throws -> ShortcutExecutionResult? {
        do {
            let result = try await transport.execute(request)
            guard current == revision, scope.sameScope(as: context) else { return nil }
            return result
        } catch let error as CompanionHostError {
            guard case .staleTarget = error, current == revision else { throw error }
            ShortcutTrace.executionRetried(entry: entry.id, reason: "\(error)")
            let fresh = try await transport.list(context: scope)
            guard current == revision, scope.sameScope(as: context) else { return nil }
            model.snapshot = fresh
            guard fresh.revision != snapshot.revision,
                  fresh.entries.contains(where: { $0.id == entry.id }) else { throw error }
            let retry = ShortcutExecutionRequest(requestID: UUID(), entryID: request.entryID,
                actionRef: request.actionRef, revision: fresh.revision, context: request.context)
            let result = try await transport.execute(retry)
            guard current == revision, scope.sameScope(as: context) else { return nil }
            return result
        }
    }

    /// A row the app's own GUI covers runs that GUI entry, here, on this
    /// device — it never goes to the host. `SUPER + SPACE` is the case the
    /// rule was written for: the host's `omarchy-menu toggle` would open a menu
    /// on a desktop the user is looking at through a stream, while the thing
    /// they pointed at is the Panel in their hands.
    /// Answers whether the app's own control took it. `false` is not a
    /// failure: the bar refuses a workspace while a Remote session owns the
    /// host's workspaces, and then the host adapter is the only way there — so
    /// the caller falls through to it rather than telling the user to use a
    /// control that would refuse them too.
    private func runLocally(_ entry: ShortcutEntry) -> Bool {
        // ARCH-1 §7 (1): only the two rows whose destination is this device.
        guard let capability = ShortcutGUIMap.capability(forDisplay: entry.keys)
                .flatMap(ShortcutGUIMap.localCapability),
              performLocally?(capability) == true else { return false }
        // Even a row that worked says so. "It did something" and "it silently
        // did nothing" have to be different on screen and in the log, which is
        // the whole of item 5.
        model.notice = Strings.keybindingsRanHere(capability.description)
        ShortcutTrace.executedLocally(entry: entry.id, capability: "\(capability)")
        return true
    }

    /// ARCH-1 §7 (2). Two of core's refusals are things this panel can act on;
    /// the rest are shown as the host wrote them.
    ///
    /// `stale_catalog_revision` is the one MERGE-1 already handled: refresh the
    /// list and send the same row again, because the row is still the row — only
    /// the revision moved. `no_focused_window` is a single line on the row: the
    /// binding needs a window and there is not one.
    ///
    /// PERF-5. `keybindingsStale` claims a refresh *and a resend*, and the
    /// resend it is claiming is the one in `send(_:)` — which only ever runs
    /// on a thrown `staleTarget`, never on a 200 receipt that happens to carry
    /// the same code. A receipt saying the binding is gone gets the sentence
    /// that is true of it: the list is out of date and this row did not run.
    /// Since PERF-5 the receipt code for that is `stale_binding` — the host
    /// resolves the row by id now and only the binding provider's own lookup
    /// can still refuse it — and `stale_catalog_revision` arrives as a 409,
    /// which is the path that does refresh and resend.
    private static func refusal(_ result: ShortcutExecutionResult) -> String? {
        switch result.code {
        case "no_focused_window": Strings.keybindingsNoFocusedWindow
        case "stale_binding", "stale_target", "stale_catalog_revision": Strings.keybindingsOutOfDate
        default: result.observed?.summary ?? result.message
        }
    }

    func execute(_ entry: ShortcutEntry) async {
        guard model.disabledReason(for: entry, context: context) == nil,
              let snapshot = model.snapshot, snapshot.entries.contains(entry) else { return }
        // ARCH-1 §7 (1). Two rows are this app's own, and only two: the row
        // that opens the Omarchy menu and the row that opens this list. Every
        // other binding — including the workspace rows, which used to be run
        // locally — goes to the host, because the host is what the key itself
        // would have reached.
        if runLocally(entry) { return }
        guard let ref = entry.actionRef, entry.enabled,
              model.hostReason(for: entry, context: context) == nil else {
            model.notice = ShortcutPanelModel.explain(entry.disabledReason)
            return
        }
        let current = revision, target = context
        let request = ShortcutExecutionRequest(requestID: UUID(), entryID: entry.id,
            actionRef: ref, revision: snapshot.revision, context: target)
        model.executingEntryID = entry.id
        executionID = request.requestID
        defer {
            if executionID == request.requestID {
                model.executingEntryID = nil
                executionID = nil
            }
        }
        do {
            let result = try await send(request, entry: entry, snapshot: snapshot, guarding: current, scope: target)
            guard let result else { return }
            // ARCH-1 §7 (2). What the host observed is what the row says. A
            // sentence this client composed about a request it only knows it
            // sent is the thing that reading replaces.
            switch result.status {
            case .accepted:
                model.notice = result.observed?.summary ?? result.message ?? Strings.keybindingsSent
                ranOnHost?()
            case .applied:
                model.notice = result.observed?.summary ?? result.message ?? Strings.keybindingsDone
                ranOnHost?()
            case .rejected: model.notice = Self.refusal(result) ?? Strings.keybindingsGone
            case .unknown: model.notice = result.message ?? Strings.keybindingsUnconfirmed
            }
        } catch {
            guard current == revision else { return }
            // MERGE-1: item B is "say whether this really works", and a bare
            // "not confirmed" says nothing to whoever has to fix it. The reason
            // goes to os_log, not into the notice: the user gets one sentence,
            // the operator gets the host's own word for what went wrong.
            ShortcutTrace.executionFailed(entry: entry.id, reason: "\(error)")
            model.notice = Strings.hostActionOutcomeUnknown
        }
        // Keep query, scroll and panel open. The container owns presentation.
        // Never automatically retry a potentially executed host action.
    }
}
