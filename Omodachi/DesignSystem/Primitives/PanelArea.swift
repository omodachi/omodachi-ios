import SwiftUI

/// The panel area: one block, one panel in it at a time (A-55).
///
/// rev 3's sentence is the whole of it — "看似是二级关系但实际上不是". There is no
/// left column and right page, no ×, no back arrow and no push stack. A panel
/// fills this block; tapping its entry again puts ① back.
///
/// A-56 sorts the seven into two shapes:
///
/// * **read and choose** — Remote, Settings, Notifications. One column, capped
///   at the study's body measure and centred in the block, and the page ends
///   where its content ends. Nothing is stretched to the bottom.
/// * **work surface** — Agent, Herdr, SSH. The whole block, because a terminal's
///   column count, a pane grid and a tool-call block all use width.
///
/// Panel ① is its own third shape (A-54) and lays itself out.
enum PanelShape: Equatable, Sendable {
    case readAndChoose
    case workSurface
}

enum PanelMeasure {
    /// A-23's body measure, inherited: 760 points of content column.
    static let column: CGFloat = 760
    /// A-54's necessary condition, as arithmetic: the menu's 360, the shell's
    /// own `gaps_in` 5, and the Keybindings list's minimum 420. Study 04 rev 5
    /// adds it to the orientation test because `UIRequiresFullScreen=false`
    /// leaves landscape windows 320 points wide under Stage Manager.
    static let sideBySide: CGFloat = 360 + 5 + 420
    /// A-54's left half.
    static let menuColumn: CGFloat = 360
    /// A-19's right half: the key block is right-aligned and never wraps.
    static let keybindingsColumn: CGFloat = 420
    /// A-56's narrow case: below this a panel stops putting things side by side
    /// and stacks them instead. iPhone portrait is 349, the Duo's outer screen
    /// 422, and neither can hold two cards.
    static let narrowColumn: CGFloat = 470

    /// A-54: side by side needs landscape **and** the room for both columns.
    static func sideBySide(landscape: Bool, width: CGFloat) -> Bool {
        landscape && width >= sideBySide
    }

    /// SHELL-FIX-1. Which way up the *window* is. A panel's own rectangle is
    /// not an orientation: the soft keyboard takes a third of an iPad's
    /// height off it, and on an 11" or 13" iPad held upright what is left is
    /// wider than tall — ① rebuilt itself side by side under the keyboard,
    /// the search field it was typing into went with the old layout, and the
    /// keyboard went down again (Leo, iPad portrait). `window` is the Shell's
    /// window size (`EnvironmentValues.windowSize`); `area` is only the
    /// fallback for a view drawn outside the Shell (a preview, a test).
    static func isLandscape(window: CGSize, area: CGSize) -> Bool {
        let size = window.width > 0 && window.height > 0 ? window : area
        return size.width >= size.height
    }

    static func isNarrow(_ width: CGFloat) -> Bool { width > 0 && width < narrowColumn }

    /// DUO-1 (Leo, 2026-10-13: "对于duo 我们menu/keybinding 不如正好分割成屏幕一半一半？").
    /// On an open foldable held wide, ① puts the menu and Keybindings one in
    /// each half of the screen, divided at the fold (variant B). Held tall it
    /// keeps the width rule — one column behind the segmented control (Leo,
    /// round 2: the two halves were too short stacked). This is the one
    /// switch: `false` puts back variant A held wide too, which there is the
    /// width rule's 360 | the rest. `--fold-split-off` turns it off in a
    /// simulator build so both can be put side by side.
    static var splitsAtFold: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--fold-split-off") { return false } // non-copy: a launch flag
        #endif
        return true
    }
    /// The least a half may be across before the fold stops splitting ①: the
    /// Keybindings list's key block alone is about this wide.
    static let foldColumnMinimum: CGFloat = 280

    /// Where ① divides on an open foldable, in its own coordinates, or nil to
    /// use the width rule. `panel` is ①'s rectangle in the window's
    /// coordinates, the same space `fold` is in. Only a fold that runs top to
    /// bottom divides ①; one that runs across (held tall) does not.
    static func foldSplit(_ fold: FoldLine?, panel: CGRect, enabled: Bool = splitsAtFold) -> FoldSplit? {
        guard enabled, let fold, fold.axis == .vertical, panel.width > 0, panel.height > 0 else { return nil }
        let lead = fold.position - panel.minX
        guard lead >= foldColumnMinimum, panel.width - lead >= foldColumnMinimum else { return nil }
        return .columns(lead: lead)
    }
}

/// DUO-1. Where a foldable's fold runs through the window, in the window's
/// points. Nil everywhere but a foldable that is open (or half open).
struct FoldLine: Equatable, Sendable {
    enum Axis: Equatable, Sendable {
        /// Top to bottom — the open Duo held wide. The halves are left and right.
        case vertical
        /// Side to side — the open Duo held tall. The halves are top and bottom.
        case horizontal
    }
    var axis: Axis
    /// x for a vertical fold, y for a horizontal one.
    var position: CGFloat

    /// iOS 27.1 reports *whether* the hinge is open (`UIHinge.status`) and its
    /// angle, but not where the fold is: the SDK has no fold rectangle. A book
    /// fold runs across the middle of the display's long side, so that is
    /// where it is put. `screen` is the display in the window's coordinates.
    static func middle(of screen: CGRect) -> FoldLine {
        screen.width >= screen.height ? FoldLine(axis: .vertical, position: screen.midX)
                                      : FoldLine(axis: .horizontal, position: screen.midY)
    }
}

/// DUO-1. How ① divides at the fold, in ①'s own coordinates.
enum FoldSplit: Equatable, Sendable {
    /// Menu on the left `lead` points, Keybindings on the rest.
    case columns(lead: CGFloat)
}

/// The container every panel is drawn in: a 44-high title row, optional search,
/// and the content in whichever of the two shapes this panel is.
struct PanelArea<Title: View, Accessory: View, Content: View>: View {
    var shape: PanelShape = .readAndChoose
    /// The identifier a test reaches this panel by.
    let identifier: String
    @ViewBuilder var title: () -> Title
    /// The right end of the 44-high title row: a segmented control (A-54), a
    /// DND switch (N-36), an edit button (N-39). Never a × (A-55).
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            switch shape {
            case .workSurface:
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .readAndChoose:
                ScrollView {
                    content()
                        .frame(maxWidth: PanelMeasure.column, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, OmodachiTheme.space("xxl"))
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(OmodachiTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// `.phead`, 44 high (Study 01 §01). rev 4 put the segmented control in it
    /// rather than on a row of its own, so the 44 it used to cost is three menu
    /// rows on a phone.
    private var header: some View {
        HStack(spacing: OmodachiTheme.space("sm")) {
            title()
            Spacer(minLength: OmodachiTheme.space("lg"))
            accessory()
        }
        .padding(.leading, OmodachiTheme.rowPaddingX)
        .padding(.trailing, OmodachiTheme.space("sm"))
        .frame(height: NativeBarMetrics.hit)
    }
}

extension PanelArea where Accessory == EmptyView {
    init(shape: PanelShape = .readAndChoose, identifier: String,
         @ViewBuilder title: @escaping () -> Title,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(shape: shape, identifier: identifier, title: title,
                  accessory: { EmptyView() }, content: content)
    }
}

extension PanelArea where Title == PanelTitle, Accessory == EmptyView {
    init(_ name: String, shape: PanelShape = .readAndChoose, identifier: String,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(shape: shape, identifier: identifier,
                  title: { PanelTitle(name) }, accessory: { EmptyView() }, content: content)
    }
}

/// The panel's own name in the title row.
struct PanelTitle: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Text(name)
            .font(OmodachiTheme.font("heading"))
            .kerning(-0.2)
            .foregroundStyle(OmodachiTheme.current.color(.brightForeground))
            .lineLimit(1).truncationMode(.tail)
            .accessibilityAddTraits(.isHeader)
    }
}

extension EnvironmentValues {
    /// SHELL-FIX-1: the window's size, from the Shell's window reader. Never
    /// keyboard-avoided: the keyboard is a layer over the window, not a turn.
    @Entry var windowSize: CGSize = .zero
    /// DUO-1: the fold of an open foldable, from the Shell's fold reader.
    @Entry var fold: FoldLine? = nil
}
