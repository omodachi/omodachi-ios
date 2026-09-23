import Foundation

/// A-13's semantic control bar, as data.
///
/// The rule the study states and this file enforces: **a control sends a route,
/// never a key code.** Herdr's own prefix bindings are a keyboard product; a
/// touch client that injected `Ctrl+B v` would be guessing at the user's config
/// and would break the moment they rebind it. Every case below resolves to one
/// `/v1/herdr/panes/{pane}/…` or `/v1/herdr/workspaces/{id}/select` call, or to
/// an explicit `.unsupported` with the reason — there is no third outcome.
enum HerdrControlAction: String, CaseIterable, Identifiable, Sendable {
    case previousPane, nextPane, splitRight, splitDown, zoom, close, newTab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previousPane: Strings.herdrActionPreviousPane
        case .nextPane: Strings.herdrActionNextPane
        case .splitRight: Strings.herdrActionSplitRight
        case .splitDown: Strings.herdrActionSplitDown
        case .zoom: Strings.herdrActionZoom
        case .close: Strings.herdrActionClosePane
        case .newTab: Strings.herdrActionNewTab
        }
    }

    var symbol: String {
        switch self {
        case .previousPane: "chevron.left"
        case .nextPane: "chevron.right"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        case .close: "xmark"
        case .newTab: "plus"
        }
    }

    /// Closing a pane ends a process the user cannot see from here, so it asks
    /// first. Splitting and zooming are reversible from the same bar.
    var confirms: Bool { self == .close }
}

/// What one control resolves to against the layout that is on screen right now.
enum HerdrControlRequest: Equatable, Sendable {
    case pane(pane: String, action: HerdrPaneAction)
    case select(pane: String)
    case workspace(id: String)
    /// The host bridge has no route for this control. The reason is shown on
    /// the disabled button rather than the control being quietly dropped.
    case unsupported(reason: String)
}

enum HerdrControlMapper {
    /// `POST /v1/herdr/panes/{p}/{split,zoom,focus,close}` and
    /// `POST /v1/herdr/workspaces/{id}/select` are the whole surface
    /// (`docs/herdr.md`). **There is no tab route**, so `newTab` maps to
    /// `.unsupported` and says so; SPEC-F3's report carries it as a core gap.
    static var noTabRoute: String { ReasonText.message("herdr_action_unsupported", domain: .herdr) }

    static func request(_ action: HerdrControlAction,
                        layout: HerdrLayoutDTO?, selected: String?) -> HerdrControlRequest {
        guard let layout, let selected, layout.pane(selected) != nil else {
            return .unsupported(reason: Strings.herdrNoSelectedPane)
        }
        switch action {
        case .previousPane, .nextPane:
            let siblings = layout.tab(of: selected)?.panes.map(\.id) ?? []
            guard siblings.count > 1, let index = siblings.firstIndex(of: selected) else {
                return .unsupported(reason: Strings.herdrOnlyOnePane)
            }
            let step = action == .nextPane ? 1 : siblings.count - 1
            return .select(pane: siblings[(index + step) % siblings.count])
        case .splitRight: return .pane(pane: selected, action: .split(direction: .right))
        case .splitDown: return .pane(pane: selected, action: .split(direction: .down))
        case .zoom: return .pane(pane: selected, action: .zoom(mode: .toggle))
        case .close: return .pane(pane: selected, action: .close)
        case .newTab: return .unsupported(reason: noTabRoute)
        }
    }

    /// Tapping a pane in the grid is absolute focus, which 0.8.2's CLI cannot
    /// do — the bridge answers it with the protocol's own `pane.focus`
    /// (`SPEC-F1-report.md §3`). A direction is never inferred from a tap.
    static func focus(pane: String) -> HerdrControlRequest {
        .pane(pane: pane, action: .focus(direction: nil))
    }
}
