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

    static func isNarrow(_ width: CGFloat) -> Bool { width > 0 && width < narrowColumn }
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
