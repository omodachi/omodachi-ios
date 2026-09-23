import Foundation
import SwiftUI

/// Which of the two columns panel ① is showing (A-54). Side by side both are on
/// screen and this says which one the search field belongs to; folded it is the
/// segmented control's selection.
enum PanelColumn: String, CaseIterable, Identifiable, Sendable {
    case menu, keybindings
    var id: String { rawValue }
    var title: String { self == .menu ? Strings.panelPanelTab : Strings.panelKeybindings }
    var icon: (symbol: String, nerd: String) { self == .menu ? Icon.menu : Icon.keyboard }
}

/// What the whole window is showing.
enum SurfaceStage: Equatable, Sendable {
    /// The bar and the panel area. This is the app when no session is running.
    case panels
    /// The stream, full bleed, with no native chrome on it (A-58). It exists
    /// **only** while there is a session (N-32): there is no "Remote screen"
    /// to be stranded on after one ends.
    case picture
}

/// The one navigation decision-maker: seven panels, one panel area, and a
/// summon that toggles.
///
/// Every rule it holds is written down somewhere with a number, and each is
/// exercised by `SurfaceRouterTests`:
///
/// * **A-55** — an entry opens its panel; the same entry again closes it. There
///   is no ×, no back arrow and no push stack. Closing is ① on the panel stage
///   and the picture under Remote (REMOTE-3), because under Remote ① is itself
///   one of the things that is over the picture.
/// * **A-59 / rev 5** — a `panel.summon` from the host is a *toggle*: not open →
///   open that view; open on another view → switch; open on the same view →
///   dismiss. Core's `panel.summon` is a stateless push, so this arbitration can
///   only live here.
/// * **N-38** — a summon beats a disabled entry. The preference hides the slot
///   on the bar; it does not refuse the panel.
/// * **N-32 / rev 5** — `returnTo` is the panel that was on screen when
///   "开始扩展 / 开始接管" was pressed. Opening panels *during* a session never
///   changes it. All four ways a session can end return to it, and if that panel
///   is disabled, or is ② itself, they return to ①.
@MainActor final class SurfaceRouter: ObservableObject {
    @Published private(set) var panel: PanelID = .menu
    @Published var column: PanelColumn = .menu
    @Published private(set) var stage: SurfaceStage = .panels
    /// Under `.picture`: whether the bar and a panel are over the stream.
    @Published private(set) var overlayVisible = false
    /// N-32. Where ending the session goes.
    @Published private(set) var returnTo: PanelID = .menu
    /// A-25: a `keybindings` summon puts the cursor in that list's search field,
    /// which is the whole reason core carries the view.
    @Published private(set) var focusKeybindingsSearch = false
    /// A live session exists. The Shell mirrors the controller into this,
    /// because the router's answers depend on it and it must not reach for a
    /// Remote type (ARCH-1 §1.3).
    @Published var hasSession = false

    private unowned let registry: PanelRegistry

    init(registry: PanelRegistry) { self.registry = registry }

    /// True while the panel area is on screen at all: either the app's own
    /// stage, or the overlay over the picture.
    var panelAreaVisible: Bool { stage == .panels || overlayVisible }

    // MARK: - The bar

    /// A-51 / A-55. Tap an entry: open it. Tap the same one again: close it.
    ///
    /// Off the picture "close it" is ①, which is what A-55 says and what the
    /// panel stage can show. Over the picture it is the picture — see
    /// `closeCurrentPanel`.
    ///
    /// Remote during a session (N-32 ③) is not a wrinkle in that: the entry
    /// opens ②'s session card, and tapping it again closes the overlay. A-55
    /// governs the entry, not the session, so nothing here ends anything.
    func tapEntry(_ id: PanelID) {
        guard panelAreaVisible else { return }
        guard panel != id else { return closeCurrentPanel() }
        show(id)
    }

    /// The logo. It is panel ①'s only entry: tapping it while ① is up has
    /// nowhere else to go, so it is the tap-again of A-55 and the second summon
    /// of A-59 — off the picture it stays on ①, over the picture it closes.
    func tapLogo() {
        guard panelAreaVisible else { return }
        guard panel != .menu else { return closeCurrentPanel() }
        show(.menu)
    }

    /// REMOTE-3. What "再点一次" closes onto.
    ///
    /// A-55 says the same entry again returns to ①; A-59 says a summon of the
    /// view already up dismisses the overlay, and under Remote the picture is
    /// what "closed" means (there is no ① to fall back to — ① *is* what is
    /// over the picture). So the bar's own entries have to answer the way
    /// `consume` does, or the two ways of asking for the same thing disagree:
    /// the host's icon put the panel up and this device's copy of that icon
    /// could not take it down (Leo, on the iPad: "remote 里再次点击 logo icon
    /// 不能回到 remote 桌面").
    ///
    /// The dismissal alone re-opens the input gate: `panelAreaVisible` goes
    /// false, and the Shell mirrors that into INPUT-2's `panelVisible`.
    /// `returnTo` is not a party to any of this (N-32).
    private func closeCurrentPanel() {
        if overlayVisible { dismissOverlay() } else { show(.menu) }
    }

    /// Open a panel because something other than its entry asked: Settings'
    /// list, a toast on the picture, a hardware shortcut.
    func show(_ id: PanelID) {
        panel = id
        if id != .menu { focusKeybindingsSearch = false }
    }

    // MARK: - The host's own bar (A-59)

    /// The three destinations a `panel.summon` can name, as this app's panels.
    /// `overview` and `keybindings` are both panel ①; they differ in which half
    /// of it has the cursor.
    struct SummonTarget: Equatable {
        let panel: PanelID
        let column: PanelColumn?
    }

    static func target(for view: PanelSummon.View) -> SummonTarget {
        switch view {
        case .overview: SummonTarget(panel: .menu, column: .menu)
        case .keybindings: SummonTarget(panel: .menu, column: .keybindings)
        case .settings: SummonTarget(panel: .settings, column: nil)
        }
    }

    /// What a summon did, so a caller can act on the dismissal (the input gate
    /// has to reopen) without re-deriving it.
    enum SummonOutcome: Equatable { case opened, switched, dismissed }

    /// A-59 rev 5's toggle, and the only place it exists.
    ///
    /// Core's `panel.summon` is a stateless push (`service.py`), so "click the
    /// icon again to put it away" is not something the protocol can answer — the
    /// device has to remember what is open. And it must: while the overlay is up
    /// the input gate is closed (INPUT-2's `panelVisible`), so the icon in the
    /// picture cannot be clicked again from the iPad. The other two ways to
    /// dismiss are tapping the picture and tapping that same entry on our own
    /// bar (REMOTE-3, `closeCurrentPanel`).
    @discardableResult
    func consume(_ summon: PanelSummon) -> SummonOutcome {
        let target = Self.target(for: summon.view)
        let already = panelAreaVisible && panel == target.panel
            && (target.column == nil || column == target.column)
        if already {
            dismissOverlay()
            return .dismissed
        }
        let outcome: SummonOutcome = panelAreaVisible ? .switched : .opened
        // N-38 rev 5: a disabled entry hides the slot, never the panel.
        panel = target.panel
        if let wanted = target.column {
            column = wanted
            focusKeybindingsSearch = wanted == .keybindings
        } else {
            focusKeybindingsSearch = false
        }
        if stage == .picture { overlayVisible = true }
        return outcome
    }

    /// The other half of the toggle: a tap on the picture. It also happens when
    /// the session ends under an open overlay.
    func dismissOverlay() {
        guard stage == .picture else { return }
        overlayVisible = false
        focusKeybindingsSearch = false
    }

    // MARK: - Remote (N-32)

    /// Called the moment "开始扩展 / 开始接管" is pressed — **not** when panel ②
    /// is opened. Entering ② is not a place you came from; it is the place you
    /// press the button.
    func rememberReturn() {
        returnTo = panel == .remote ? .menu : panel
    }

    /// The session is up and the picture is what the user is looking at.
    func enterPicture() {
        hasSession = true
        stage = .picture
        overlayVisible = false
    }

    /// One of N-32's four endings: the user pressed 结束, the heartbeat expired,
    /// the host released it, or the daemon restarted. They are the same ending.
    func endSession() {
        hasSession = false
        stage = .panels
        overlayVisible = false
        focusKeybindingsSearch = false
        panel = resolvedReturn()
        returnTo = .menu
    }

    /// N-32 ⑤: a `returnTo` whose entry the user has since switched off, or that
    /// is ② itself, lands on ①.
    private func resolvedReturn() -> PanelID {
        guard returnTo != .remote, returnTo != .menu else { return .menu }
        return registry.isEnabled(returnTo) ? returnTo : .menu
    }

    /// Back to the picture from an overlay panel, without ending anything.
    func resumePicture() {
        guard hasSession else { return }
        stage = .picture
        overlayVisible = false
    }

    /// The panel area, over the picture, opened by something other than a
    /// summon — the ⌘⇧M alias, or a tap on the toast.
    func openOverlay(_ id: PanelID) {
        guard stage == .picture else { show(id); return }
        panel = id
        overlayVisible = true
    }

    func clearKeybindingsFocus() { focusKeybindingsSearch = false }

    // MARK: - A-66 (UX-2 §4)

    /// A row that ran something on the host hands the picture back.
    ///
    /// Leo, on the real iPad: the panel he summoned to launch an application
    /// stayed on top of the thing he had just launched, and every call needed
    /// a second gesture to get out of the way. Under Remote the panel is a
    /// layer over the machine, so the moment a call has gone out the machine
    /// is what the user wants to see. Opening a submenu and typing in the
    /// search field are not calls and do not close anything; a call that
    /// failed keeps the panel, because the reason is drawn on the row.
    ///
    /// Off the picture there is nothing to hand back, so this does nothing:
    /// the panel stage is the app.
    func invokedHostAction() {
        guard stage == .picture, overlayVisible else { return }
        dismissOverlay()
    }
}
