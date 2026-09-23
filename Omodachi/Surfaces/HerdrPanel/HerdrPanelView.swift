import SwiftTerm
import SwiftUI
import UIKit

/// Study 01 §05. A touch development bench, not a terminal with a grid bolted
/// on: the left column is the workspace → pane grid, the right is the selected
/// pane's screen, and the strip under it is A-13's semantic control bar.
///
/// What is deliberately absent: the global Omarchy keybindings list (A-21 —
/// that belongs to the Panel) and any injected key code (A-13 — every control
/// is a route).
struct HerdrSurface: View {
    @ObservedObject var store: HerdrStore
    var onTogglePanel: () -> Void = {}
    @EnvironmentObject private var home: HomeStore
    @Environment(\.horizontalSizeClass) private var horizontal
    @State private var closing: HerdrControlRequest?

    /// The column is the study's narrow grid rail; below this the grid folds to
    /// the top strip (iPhone portrait, and an iPad in a narrow split view).
    private static let gridWidth: CGFloat = 248
    private static let foldBelow: CGFloat = 700

    var body: some View {
        GeometryReader { proxy in
            let folded = horizontal == .compact || proxy.size.width < Self.foldBelow
            ZStack(alignment: .bottom) {
                Group {
                    VStack(spacing: 0) {
                        HerdrSessionSwitcher(store: store)
                        rule
                        if folded {
                            HerdrPaneStrip(store: store)
                            rule
                            stage
                        } else {
                            HStack(spacing: 0) {
                                HerdrGridColumn(store: store).frame(width: Self.gridWidth)
                                Rectangle().fill(OmodachiTheme.border)
                                    .frame(width: NativeBarMetrics.edgeRule).accessibilityHidden(true)
                                stage
                            }
                        }
                    }
                }
                // A-13, in two halves. The content ignores the keyboard, so
                // the terminal keeps its frame and its buffer is covered
                // rather than reflowed — no `terminal.resize` for a keystroke
                // session. The bar does not ignore it, so SwiftUI's own
                // avoidance parks it exactly on the keyboard's top edge, and
                // on the Home indicator when there is no keyboard.
                .ignoresSafeArea(.keyboard, edges: .bottom)
                HerdrControlBar(store: store, onTogglePanel: onTogglePanel,
                                onConfirm: { closing = $0 })
            }
        }
        .background(OmodachiTheme.background)
        .onAppear { store.appear() }
        .onDisappear { store.disappear() }
        // core's two-second projection of the owned session: the client
        // re-reads the snapshot, it never patches its own copy.
        .onChange(of: home.herdrLayoutRevision) { _, _ in store.refreshLayout() }
        // HERDR-2 §1: the connection coming up is the other thing that makes a
        // failed read worth repeating. Without it a surface entered during the
        // connect stays on its one failure, because `herdr.layout.changed`
        // fires only when the projection moves and a quiet session never does.
        .onChange(of: home.companionConnected) { _, connected in
            store.hostConnectionChanged(connected: connected)
        }
        .confirmationDialog(Strings.herdrClosePaneTitle, isPresented: Binding(get: { closing != nil },
                                                                 set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible) {
            TextTap(Strings.herdrClosePane, destructive: true) {
                if let request = closing { store.perform(request, confirmed: true) }
                closing = nil
            }
            TextTap(Strings.actionCancel, destructive: false) { closing = nil }
        } message: {
            Text(Strings.herdrClosePaneDetail)
        }
    }

    private var rule: some View {
        Rectangle().fill(OmodachiTheme.border)
            .frame(height: NativeBarMetrics.edgeRule).accessibilityHidden(true)
    }

    @ViewBuilder private var stage: some View {
        VStack(spacing: 0) {
            if let notice = store.notice {
                HerdrNoticeRow(text: notice) { store.dismissNotice() }
            }
            if store.selected == nil {
                ContentUnavailableView {
                    Label(Strings.herdrNoPanes, systemImage: "rectangle.split.2x2")
                } description: {
                    Text(store.loadingLayout ? Strings.herdrLoadingLayout : Strings.herdrNoPanesDetail)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HerdrTerminalRepresentable(store: store,
                                           appearanceRevision: OmodachiTheme.appearanceRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .padding(.bottom, NativeBarMetrics.hit)
    }
}

/// The terminal view lives on the store, so leaving the surface and coming
/// back does not rebuild the emulator or lose the buffer.
struct HerdrTerminalRepresentable: UIViewRepresentable {
    let store: HerdrStore
    /// §3: the terminal's colours and face come from `/v1/theme` and
    /// `/v1/fonts`. Carrying the revision in makes this view a dependency of
    /// both, so `theme.changed` repaints the emulator in place.
    let appearanceRevision: Int
    func makeUIView(context: Context) -> HerdrTerminalView { store.terminal }
    func updateUIView(_ view: HerdrTerminalView, context: Context) {
        store.applyAppearance()
    }
    static func dismantleUIView(_ view: HerdrTerminalView, coordinator: ()) { view.resignFirstResponder() }
}

/// HERDR-2 §2. Which of the host's Herdr sessions this panel is looking at.
///
/// The owned `omodachi` session is where every device starts and is marked as
/// such; the user's own sessions are listed because that is where their work
/// actually is. A session that is stopped or not answering is listed and
/// disabled rather than hidden — a name the user knows is on their machine has
/// to be visible, with the reason it cannot be entered.
struct HerdrSessionSwitcher: View {
    @ObservedObject var store: HerdrStore

    var body: some View {
        HStack(spacing: OmodachiTheme.space("md")) {
            Menu {
                ForEach(store.sessions) { session in
                    TextTap(session.name, selected: session.name == store.selectedSession,
                            enabled: session.running && session.readable) {
                        store.selectSession(session.name)
                    }
                    .accessibilityIdentifier("herdr-session-\(session.name)")
                }
            } label: {
                HStack(spacing: OmodachiTheme.space("sm")) {
                    Text(verbatim: store.sessionTitle)
                        .font(OmodachiTheme.font("body", weight: .semibold))
                        .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
                        .lineLimit(1).truncationMode(.middle)
                    Glyph(Icon.chevronDown, step: "icon-small")
                        .foregroundStyle(OmodachiTheme.secondaryText)
                }
                .padding(.horizontal, OmodachiTheme.rowPaddingX)
                .frame(minHeight: NativeBarMetrics.hit)
                .contentShape(Rectangle())
            }
            .disabled(store.sessions.isEmpty || store.switchingSession)
            .accessibilityLabel(Strings.herdrSession)
            .accessibilityValue(store.sessionTitle)
            .accessibilityIdentifier("herdr-session-switcher")

            Text(detail)
                .font(OmodachiTheme.font("caption"))
                .foregroundStyle(OmodachiTheme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: NativeBarMetrics.hit)
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
    }

    /// One caption, and it is about the session on screen: what core owns, how
    /// big it is, or why it cannot be read.
    private var detail: String {
        if store.switchingSession { return Strings.herdrSessionSwitching }
        guard let current = store.sessions.first(where: { $0.name == store.selectedSession }) else { return "" }
        if !current.running { return Strings.herdrSessionStopped }
        if !current.readable { return Strings.herdrSessionUnreadable }
        if current.isEmpty { return Strings.herdrSessionEmpty }
        let shape = Strings.herdrSessionShape(Format.count(current.workspaces ?? 0),
                                              Format.count(current.panes ?? 0),
                                              Format.count(current.agents ?? 0))
        return current.owned ? Strings.pair(Strings.herdrSessionOwned, shape) : shape
    }
}

// MARK: - Grid

/// iPad landscape: workspaces and their panes as rows. Selected is `selected`
/// fill; a pane carrying an agent shows the agent's kind and Herdr's own status
/// word next to a dot (§1.3).
struct HerdrGridColumn: View {
    @ObservedObject var store: HerdrStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.workspaces) { workspace in
                    HerdrWorkspaceHeader(workspace: workspace,
                                         active: workspace.id == store.selectedWorkspaceID) {
                        store.selectWorkspace(workspace.id)
                    }
                    ForEach(workspace.tabs) { tab in
                        if workspace.tabs.count > 1 { HerdrTabLabel(tab: tab) }
                        ForEach(tab.panes) { pane in
                            HerdrPaneRow(pane: pane, selected: pane.id == store.selected) {
                                store.select(pane.id)
                            }
                        }
                    }
                }
                if store.workspaces.isEmpty {
                    Text(store.loadingLayout ? Strings.herdrLoading : Strings.herdrNoWorkspace)
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .padding(OmodachiTheme.rowPaddingX)
                }
            }
        }
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-grid")
    }
}

struct HerdrWorkspaceHeader: View {
    let workspace: HerdrWorkspaceDTO
    let active: Bool
    let onSelect: () -> Void

    var body: some View {
        Tap(action: onSelect) {
            HStack(spacing: OmodachiTheme.space("md")) {
                Text(workspace.number.map(String.init) ?? workspace.id)
                    .font(OmodachiTheme.font("body", weight: .semibold))
                    .frame(minWidth: 18)
                Text(workspace.label ?? "")
                    .font(OmodachiTheme.font("caption"))
                    .foregroundStyle(OmodachiTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if workspace.focused {
                    Text(Strings.herdrFocused).font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.accent)
                }
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(height: NativeBarMetrics.hit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .control(selected: active)
        .accessibilityIdentifier("herdr-workspace-\(workspace.id)")
    }
}

struct HerdrTabLabel: View {
    let tab: HerdrTabDTO
    var body: some View {
        HStack(spacing: OmodachiTheme.space("sm")) {
            Text(Strings.herdrTab(tab.label ?? tab.id))
            if tab.zoomed { Text(Strings.herdrZoomed).foregroundStyle(OmodachiTheme.accent) }
        }
        .font(OmodachiTheme.font("caption"))
        .foregroundStyle(OmodachiTheme.secondaryText)
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.top, OmodachiTheme.space("sm"))
    }
}

struct HerdrPaneRow: View {
    let pane: HerdrPaneDTO
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Tap(action: onSelect) {
            HStack(spacing: OmodachiTheme.space("md")) {
                Rectangle().fill(OmodachiTheme.current.color(pane.status.role))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pane.displayTitle)
                        .font(OmodachiTheme.font("body"))
                        .lineLimit(1).truncationMode(.middle)
                    Text(pane.agentLabel ?? pane.id)
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(pane.agent == nil ? OmodachiTheme.muted
                                         : OmodachiTheme.current.color(pane.status.role))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if pane.zoomed {
                    Glyph(symbol: "arrow.up.left.and.arrow.down.right", points: OmodachiTheme.fontSize("icon-small"))
                        .foregroundStyle(OmodachiTheme.accent)
                }
            }
            .padding(.horizontal, OmodachiTheme.rowPaddingX)
            .frame(minHeight: NativeBarMetrics.hit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .control(selected: selected)
        .accessibilityIdentifier("herdr-pane-\(pane.id)")
        .accessibilityLabel(Strings.pair(pane.id, pane.displayTitle + (pane.agentLabel.map { ", " + $0 } ?? "")))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// iPhone portrait: the same rows, folded into one horizontally scrollable
/// strip of pane chips above the terminal.
struct HerdrPaneStrip: View {
    @ObservedObject var store: HerdrStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                ForEach(store.workspaces) { workspace in
                    Tap(action: { store.selectWorkspace(workspace.id) }) {
                        Text(workspace.number.map { "w\($0)" } ?? workspace.id) // non-copy: Herdr's own workspace id
                            .font(OmodachiTheme.font("caption", weight: .semibold))
                            .padding(.horizontal, OmodachiTheme.space("lg"))
                            .frame(height: OmodachiTheme.controlHeight)
                    }
                    .control(selected: workspace.id == store.selectedWorkspaceID, bordered: true)
                    .frame(height: NativeBarMetrics.hit)
                    .accessibilityIdentifier("herdr-workspace-\(workspace.id)")

                    ForEach(workspace.tabs.flatMap(\.panes)) { pane in
                        Tap(action: { store.select(pane.id) }) {
                            HStack(spacing: OmodachiTheme.space("sm")) {
                                Rectangle().fill(OmodachiTheme.current.color(pane.status.role))
                                    .frame(width: 6, height: 6)
                                Text(pane.agentLabel ?? pane.displayTitle)
                                    .font(OmodachiTheme.font("caption"))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, OmodachiTheme.space("lg"))
                            .frame(height: OmodachiTheme.controlHeight)
                        }
                        .control(selected: pane.id == store.selected, bordered: true)
                        .frame(height: NativeBarMetrics.hit)
                        .accessibilityIdentifier("herdr-pane-\(pane.id)")
                        .accessibilityAddTraits(pane.id == store.selected ? [.isSelected] : [])
                    }
                }
            }
            .padding(.horizontal, OmodachiTheme.space("sm"))
        }
        .frame(height: NativeBarMetrics.hit)
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("herdr-grid")
    }
}

struct HerdrNoticeRow: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: OmodachiTheme.space("md")) {
            Text(text).font(OmodachiTheme.font("body-small")).lineLimit(2)
            Spacer(minLength: 0)
            Tap(action: onDismiss) { Glyph(symbol: "xmark") }
                
                .frame(width: NativeBarMetrics.hit, height: 26)
                .accessibilityLabel(Strings.actionDismiss)
        }
        .padding(.leading, OmodachiTheme.rowPaddingX)
        .frame(height: 26)
        .background(OmodachiTheme.normalFill)
        .accessibilityIdentifier("herdr-notice")
    }
}
