import Foundation

/// A-13's semantic controls, as data — since HERDR-3 behind one labelled "⋯"
/// menu rather than a row of unlabelled icons that read as arrow keys.
///
/// The rule this file kept from A-13: **a control sends a route, never a key
/// code.** Keys are the keys row's job (`HerdrKeyCap`, `/keys`); every case
/// here resolves to one `/v1/herdr/…` call or to `.unsupported` with the
/// reason — and the menu shows that reason and
/// says it again when the item is tapped, rather than greying it out silently.
enum HerdrControlAction: String, CaseIterable, Identifiable, Sendable {
    case newWorkspace, newTab, closeTab, close
    /// ⌘[ and ⌘] on a hardware keyboard: the previous and next pane in the
    /// list. They are not in the menu — the list is how a finger moves.
    case previousPane, nextPane

    var id: String { rawValue }

    /// What the "⋯" menu lists, in its order. HERDR-5 took out "Show on the
    /// computer", "Open in Agent" and "Take keyboard" (Leo: what are they
    /// for?): the menu is the pane's and tab's own shape, nothing else.
    /// HERDR-6 added "New workspace…", beside the other thing that is new.
    /// HERDR-13 took out split right, split down and zoom: the phone shows one
    /// pane at a time, so a split read as a new tab and zoom changed nothing
    /// here. Core still has both routes; only the menu dropped them.
    static let menu: [HerdrControlAction] = [.newWorkspace, .newTab, .closeTab, .close]

    var title: String {
        switch self {
        case .previousPane: Strings.herdrActionPreviousPane
        case .nextPane: Strings.herdrActionNextPane
        case .newWorkspace: Strings.herdrActionNewWorkspace
        case .newTab: Strings.herdrActionNewTab
        case .closeTab: Strings.herdrActionCloseTab
        case .close: Strings.herdrActionClosePane
        }
    }

    var symbol: String {
        switch self {
        case .previousPane: "chevron.up"
        case .nextPane: "chevron.down"
        case .newWorkspace: "folder.badge.plus"
        case .newTab: "plus.rectangle"
        case .closeTab: "xmark.rectangle"
        case .close: "xmark"
        }
    }

    /// Closing ends processes the user cannot see from here, so it asks
    /// first.
    var confirms: Bool { self == .close || self == .closeTab }
    var destructive: Bool { confirms }
}

/// What one control resolves to against the layout that is on screen right now.
enum HerdrControlRequest: Equatable, Sendable {
    case pane(pane: String, action: HerdrPaneAction)
    case select(pane: String)
    case workspace(id: String)
    case newTab(workspace: String)
    /// HERDR-6: the new-workspace card. A session's, not a pane's.
    case newWorkspace
    case closeTab(workspace: String, tab: String)
    /// The reason this control does nothing right now, said in full.
    case unsupported(reason: String)
}

enum HerdrControlMapper {
    static func request(_ action: HerdrControlAction,
                        layout: HerdrLayoutDTO?, selected: String?) -> HerdrControlRequest {
        // An empty session can make its first workspace: no pane is needed.
        if action == .newWorkspace { return .newWorkspace }
        guard let layout, let selected, layout.pane(selected) != nil else {
            return .unsupported(reason: Strings.herdrNoSelectedPane)
        }
        switch action {
        case .previousPane, .nextPane:
            // Every pane in the list order, not only this tab's: with one agent
            // per tab, a tab-only cycle has nowhere to go.
            let all = layout.panes.map(\.id)
            guard all.count > 1, let index = all.firstIndex(of: selected) else {
                return .unsupported(reason: Strings.herdrOnlyOnePane)
            }
            let step = action == .nextPane ? 1 : all.count - 1
            return .select(pane: all[(index + step) % all.count])
        case .close: return .pane(pane: selected, action: .close)
        case .newWorkspace: return .newWorkspace
        case .newTab:
            guard let workspace = layout.workspace(of: selected)?.id else {
                return .unsupported(reason: Strings.herdrNoSelectedPane)
            }
            return .newTab(workspace: workspace)
        case .closeTab:
            guard let workspace = layout.workspace(of: selected), let tab = layout.tab(of: selected) else {
                return .unsupported(reason: Strings.herdrNoSelectedPane)
            }
            // Closing the last tab would close the workspace with it, which
            // is more than this item says it does.
            guard workspace.tabs.count > 1 else { return .unsupported(reason: Strings.herdrOnlyOneTab) }
            return .closeTab(workspace: workspace.id, tab: tab.id)
        }
    }
}
