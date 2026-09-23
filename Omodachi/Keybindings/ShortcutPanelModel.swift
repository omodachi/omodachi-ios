import Foundation

/// Caller-owned scope. Global Omarchy shortcuts belong only to controller and
/// Remote, never to Herdr/Agent/SSH merely because they share a host connection.
enum ShortcutSurface: String, Codable, Sendable { case controller, remote, herdr, agent, ssh }
struct ShortcutContext: Equatable, Sendable {
    let hostID: String
    let surface: ShortcutSurface
    var remoteSessionID: String? = nil
    /// The Remote session's own revision. Core's `validate_context` compares
    /// this, not the connection generation (`shortcut_provider.py:105-112`).
    var sessionRevision: Int? = nil
    var connectionGeneration: Int? = nil
    var geometryEpoch: Int? = nil
    var stateRevision: Int? = nil
    var targetToken: String? = nil
    var inputReady = true

    var supportsGlobalShortcuts: Bool { surface == .controller || surface == .remote }
    func sameScope(as other: ShortcutContext) -> Bool {
        hostID == other.hostID && surface == other.surface && remoteSessionID == other.remoteSessionID
            && connectionGeneration == other.connectionGeneration && geometryEpoch == other.geometryEpoch
            && inputReady == other.inputReady
    }
    var canExecute: Bool {
        supportsGlobalShortcuts && (surface == .controller || (remoteSessionID?.isEmpty == false && connectionGeneration != nil && geometryEpoch != nil && inputReady))
    }
}

struct ShortcutEntry: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let keys: String
    let order: Int
    let actionRef: String?
    let enabled: Bool
    let disabledReason: String?
    /// SHORTCUT-1: core's own sentence about this row, which is more use than
    /// its code. Shown verbatim when it is there.
    var disabledReasonDetail: String? = nil
    var requiresTarget = false
    /// CLIP-1 §1. The host publishes no executable binding for this row, so
    /// nothing here can ever run it. Five of this host's rows are like that —
    /// `Universal copy`, `Universal paste`, `Universal cut`, `Zoom in`,
    /// `Reset zoom` — because Omarchy binds them to bare Lua functions, which
    /// its own record format cannot carry.
    var hidden = false
}

public struct ShortcutSnapshot: Equatable, Sendable {
    let revision: String
    let source: String
    let entries: [ShortcutEntry]
    var available = true
    var unavailableReason: String? = nil
}

/// Only already-implemented, available, conveniently reachable GUI actions
/// count. A capability this app plans to have, or advertises without an actual
/// control on screen, does not.
struct ShortcutGUICoverage: Equatable, Sendable {
    var reachableActionRefs: Set<String> = []
    var reachableCapabilities: Set<String> = []
    func covers(_ entry: ShortcutEntry) -> Bool {
        if let ref = entry.actionRef, reachableActionRefs.contains(ref) { return true }
        return entry.resolvedGUICapability.map { reachableCapabilities.contains($0) } ?? false
    }
}

public struct ShortcutExecutionRequest: Equatable, Sendable {
    let requestID: UUID
    let entryID: String
    let actionRef: String
    let revision: String
    let context: ShortcutContext
}

enum ShortcutExecutionStatus: String, Sendable { case accepted, applied, rejected, unknown }
public struct ShortcutExecutionResult: Equatable, Sendable {
    let status: ShortcutExecutionStatus
    var message: String? = nil
    /// ARCH-1 §7 (2). What the host saw happen — a workspace changed, a window
    /// moved, a command started. It is the row's transient state rather than a
    /// sentence this client composed about a request it only knows it sent.
    var observed: ShortcutObservation? = nil
    /// The host's own refusal code, so the two this panel acts on can be told
    /// apart from the ones it only shows: `stale_catalog_revision` is a refresh
    /// and a resend, `no_focused_window` is one line on the row.
    var code: String? = nil
}

/// ARCH-1 §7. Which contract the host is answering under.
enum ShortcutBindingContract: String, Equatable, Sendable {
    /// What core publishes today: a reviewed adapter per action, so a row
    /// without one cannot be run from here and says so.
    case perAction
    /// SHORTCUT-1: core runs every binding, so `enabled` and `disabled_reason`
    /// are the entire greying rule and nothing local greys anything.
    case universal

    func reason(for entry: ShortcutEntry, model: ShortcutPanelModel,
                context: ShortcutContext) -> String? {
        // Both contracts agree on the two things that are not about a binding
        // at all: this panel not being usable, and the list not being loaded.
        if !context.supportsGlobalShortcuts { return Strings.keybindingsUseSurface }
        if model.loading || model.failed || model.snapshot?.available != true {
            return Strings.keybindingsRefreshFirst
        }
        // The host's own verdict. Under `universal` it is the whole answer,
        // and core's sentence about this row beats our sentence about its code.
        if !entry.enabled {
            return entry.disabledReasonDetail ?? ShortcutPanelModel.explain(entry.disabledReason)
        }
        guard self == .perAction else { return nil }
        if !context.canExecute { return Strings.keybindingsRemoteUpdating }
        if entry.actionRef?.isEmpty != false { return ShortcutPanelModel.explain(entry.disabledReason) }
        return nil
    }
}

struct ShortcutPanelModel: Equatable, Sendable {
    /// ARCH-1 §7. SHORTCUT-1 has landed (core `43d2a4d`), so this is
    /// `universal`: core runs every binding the way the key itself would and
    /// its `enabled` is the whole greying rule. `perAction` is kept for a host
    /// that has not been updated yet, and it is one line.
    var contract: ShortcutBindingContract = .universal
    var query = ""
    var scrollEntryID: String?
    var snapshot: ShortcutSnapshot?
    var coverage = ShortcutGUICoverage()
    var loading = false
    var executingEntryID: String?
    var notice: String?
    var failed = false
    /// The bottom line of the list is expandable; expanding it puts the
    /// duplicated rows back in place rather than opening a second list.
    var showsCoveredEntries = false
    /// CLIP-1 §1. Settings ⑥'s switch. Off, the rows the host marks `hidden`
    /// are not in the list at all; on, they are back and greyed with the
    /// host's own reason, because seeing what the computer has is a reasonable
    /// thing to want even when this device cannot do it.
    var showsUnrunnableEntries = false

    private func matching(_ entries: [ShortcutEntry]) -> [ShortcutEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.enumerated()
            .filter { query.isEmpty || $0.element.label.localizedCaseInsensitiveContains(query)
                || $0.element.keys.localizedCaseInsensitiveContains(query) }
            .sorted { $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order }
            .map(\.element)
    }

    func visibleEntries(in context: ShortcutContext) -> [ShortcutEntry] {
        guard context.supportsGlobalShortcuts, let snapshot else { return [] }
        let listed = snapshot.entries.filter { showsUnrunnableEntries || !$0.hidden }
        guard !showsCoveredEntries else { return matching(listed) }
        return matching(listed.filter { !coverage.covers($0) })
    }

    /// CLIP-1 §1. How many rows the host says cannot run here. It is what the
    /// switch in ⑥ is worth showing a number for, and it is zero on a host
    /// from before CLIP-1.
    func unrunnableCount() -> Int {
        snapshot?.entries.count { $0.hidden } ?? 0
    }

    /// The rows the GUI already offers. They are hidden, not dropped: the
    /// count and the reason are shown, and one tap brings them back.
    func coveredEntries(in context: ShortcutContext) -> [ShortcutEntry] {
        guard context.supportsGlobalShortcuts, let snapshot else { return [] }
        return snapshot.entries.filter { coverage.covers($0) }
    }

    /// REMOTE-2 item 5. A covered row this app has no control for is dimmed
    /// with where the control is, rather than left lit and silent.
    static func coveredElsewhere(_ place: String?) -> String {
        place.map { Strings.keybindingsCoveredHere($0) } ?? Strings.keybindingsUseSurface
    }

    /// Why the *host* would refuse this row. It is the whole of the old
    /// `disabledReason` and it is still what a row that has to travel is
    /// judged by.
    func hostReason(for entry: ShortcutEntry, context: ShortcutContext) -> String? {
        contract.reason(for: entry, model: self, context: context)
    }

    /// ARCH-1 §7. **A row is greyed only when the host says so.**
    ///
    /// This is the one place that decides, and it is an adapter because the
    /// answer is about to change. Core today makes a subset of bindings
    /// executable, so `perAction` still reads the conditions the current
    /// contract needs. SHORTCUT-1 makes core run *every* binding the way the
    /// key itself would — exec, `hyprctl dispatch`, `eval` — and then `enabled`
    /// plus `disabled_reason` are the whole answer, which is `universal`.
    /// Switching is one line in `ShortcutPanelStore`; nothing else moves.
    func disabledReason(for entry: ShortcutEntry, context: ShortcutContext) -> String? {
        hostReason(for: entry, context: context)
    }

    /// Core's own codes (`shortcut_provider.py`), in words. An unrecognised one
    /// is shown as the host wrote it rather than replaced with a guess.
    static func explain(_ code: String?) -> String {
        switch code {
        case "binding_adapter_unavailable":
            ReasonText.message("binding_adapter_unavailable", domain: .host)
        case nil: ReasonText.message("route_unavailable", domain: .host)
        case let other?: other
        }
    }
}
