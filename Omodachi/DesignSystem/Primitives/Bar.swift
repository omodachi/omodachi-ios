import SwiftUI

/// The bar's own parts: the long edge, the 44 slot, the badge, the connection
/// dot (A-49, A-51, A-53, D-17, D-18, A-65).
///
/// The bar itself is one row of three segments — left, centre, right — exactly
/// as the host's `Bar.qml` reads `layout.left / center / right`. What goes in
/// them is `Shell/BarModel`'s decision; what they look like is here.

/// A-51's four states, as one value. `D-13` (`BarIconButton.qml 20–21, 36`) is
/// where they come from: unavailable is `.45` opacity and nothing else,
/// selected is the `[controls] selected-fill-alpha` plus the accent glyph, and
/// "something is happening" is a 6px dot in the corner rather than a colour
/// change, because a glyph that changes colour for two different reasons stops
/// meaning either of them.
enum BarSlotState: Equatable, Sendable {
    /// The host cannot do this at all. Drawn at .45 — and disabled, so
    /// VoiceOver says so too (A-65).
    case unavailable
    /// Available, not the panel on screen.
    case idle
    /// This slot's panel is what fills the panel area.
    case selected
}

/// D-17. The badge is drawn *on* the glyph, never beside it, and the slot stays
/// 44 wide in every state — a bar whose width depends on whether something is
/// unread is a bar that jumps while you are reaching for it.
///
/// `Dot` and `Count` are the host's own two settings for the notification
/// widget (`notification-center/Panel.qml 342–375`); `none` is the third choice
/// Study 04 §7 open question 1 offers. Study 04 rev 5 spreads all three to any
/// entry, so the same value carries ③'s pending approvals and ⑤'s dropped
/// connection.
enum BarBadge: Equatable, Sendable {
    case none
    case dot(ThemeColorRole)
    case count(Int, ThemeColorRole)

    var isEmpty: Bool { self == .none }

    /// The host's `99+`, verbatim.
    var text: String? {
        guard case let .count(value, _) = self else { return nil }
        return value > 99 ? "99+" : String(value)
    }

    var role: ThemeColorRole? {
        switch self {
        case .none: nil
        case let .dot(role): role
        case let .count(_, role): role
        }
    }
}

/// How a badge is drawn, chosen once in Settings and applied to every entry.
enum BarBadgeStyle: String, CaseIterable, Codable, Sendable {
    /// The host's own default, and what the two screens agree on.
    case dot
    case count
    case hidden

    var title: String {
        switch self {
        case .dot: Strings.badgeDot
        case .count: Strings.badgeCount
        case .hidden: Strings.badgeHidden
        }
    }

    /// The badge to draw for `count` unread/pending/blocked things.
    func badge(count: Int, role: ThemeColorRole) -> BarBadge {
        guard count > 0 else { return .none }
        switch self {
        case .dot: return .dot(role)
        case .count: return .count(count, role)
        case .hidden: return .none
        }
    }
}

/// One 44×44 slot on the bar: an entry, a quick action, or the logo.
///
/// A-65 is built in rather than left to the caller: `label` is the name of the
/// destination ("Remote"), `value` is its state ("进行中", "1 条待审批"), the
/// glyph is hidden, and `state == .unavailable` disables the control so
/// "dimmed" and "not available" are one fact.
struct BarSlot<Content: View>: View {
    var state: BarSlotState = .idle
    var badge: BarBadge = .none
    /// The 6px corner dot: something is running, or wants attention.
    var dot: ThemeColorRole?
    let label: String
    var value: String?
    var identifier: String?
    /// The slot's extent along the bar. 44 normally; A-60's ladder narrows the
    /// Remote quick actions to 32 on a screen that cannot hold five of them.
    var extent: CGFloat = NativeBarMetrics.hit
    var vertical = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.barEdge) private var edge
    @Environment(\.barSegment) private var segment
    /// LITE-1c: the slot's name, shown beside it after a touch-and-hold.
    @State private var naming = false
    @State private var gate = BarHoldGate()
    @State private var linger: Task<Void, Never>?
    @State private var settle: Task<Void, Never>?

    var body: some View {
        Tap(selected: state == .selected, enabled: state != .unavailable, action: {
            if gate.release() { action() }
        }) {
            content()
                .foregroundStyle(state == .selected ? OmodachiTheme.selectedText : OmodachiTheme.barText)
                .frame(width: vertical ? NativeBarMetrics.hit : extent,
                       height: vertical ? extent : NativeBarMetrics.hit)
                .overlay(alignment: .topTrailing) { badgeView }
                .overlay(alignment: .bottomTrailing) { dotView }
                .contentShape(Rectangle())
        }
        // LITE-1c: the bar is icons only (the Omarchy look), so its names are
        // one gesture away — a pointer's hover on iPad, a touch-and-hold
        // everywhere. A hold shows the name and does not act on release.
        .help(label)
        // The lift of a touch, so a hold never outlives its touch: the gate
        // opens again shortly after every lift, whether or not the button ran
        // on it. (A touch-down is not seen reliably — on iPad a drag's first
        // change arrives only after the hold — so the lift is what counts.)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    settle?.cancel()
                    settle = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(BarHoldGate.settle))
                        guard !Task.isCancelled else { return }
                        gate.settle()
                    }
                })
        .simultaneousGesture(
            LongPressGesture(minimumDuration: BarNameBubble.hold)
                .onEnded { _ in
                    gate.hold()
                    showName()
                })
        .overlay(alignment: BarNameBubble.anchor(edge: edge, segment: segment).slot) {
            if naming {
                // A point on the slot's inner edge, with the bubble hung off
                // it outward, so the bubble's own size never moves the slot.
                Color.clear.frame(width: 0, height: 0)
                    .overlay(alignment: BarNameBubble.anchor(edge: edge, segment: segment).bubble) {
                        BarNameBubble(text: label, edge: edge)
                    }
                    .transition(.opacity)
            }
        }
        .zIndex(naming ? 1 : 0)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(identifier ?? "bar-slot")
    }

    private func showName() {
        naming = true
        linger?.cancel()
        linger = Task { @MainActor in
            try? await Task.sleep(for: .seconds(BarNameBubble.linger))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { naming = false }
        }
    }

    /// D-17: over the glyph, top trailing, and it never changes the slot's box.
    @ViewBuilder private var badgeView: some View {
        if let role = badge.role {
            let colour = OmodachiTheme.current.color(role)
            if let text = badge.text {
                Text(text)
                    .font(OmodachiTheme.font("caption").monospacedDigit())
                    .foregroundStyle(OmodachiTheme.barBackground)
                    .padding(.horizontal, OmodachiTheme.space("xxs"))
                    .frame(minWidth: 14, minHeight: 12)
                    .background(colour)
                    .padding([.top, .trailing], OmodachiTheme.space("xs"))
                    .accessibilityHidden(true)
            } else {
                Rectangle().fill(colour)
                    .frame(width: 6, height: 6)
                    .padding([.top, .trailing], OmodachiTheme.space("lg"))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var dotView: some View {
        if let dot {
            Rectangle().fill(OmodachiTheme.current.color(dot))
                .frame(width: 6, height: 6)
                .padding([.bottom, .trailing], OmodachiTheme.space("xs"))
                .accessibilityHidden(true)
        }
    }
}

extension BarSlot where Content == Glyph {
    init(icon: (symbol: String, nerd: String), state: BarSlotState = .idle,
         badge: BarBadge = .none, dot: ThemeColorRole? = nil,
         label: String, value: String? = nil, identifier: String? = nil,
         extent: CGFloat = NativeBarMetrics.hit, vertical: Bool = false,
         action: @escaping () -> Void) {
        self.init(state: state, badge: badge, dot: dot, label: label, value: value,
                  identifier: identifier, extent: extent, vertical: vertical,
                  action: action) {
            Glyph(icon, points: extent < NativeBarMetrics.hit ? 16 : NativeBarMetrics.glyph)
        }
    }
}

/// LITE-1c. Whether a release is a tap or the end of a hold. The button's
/// own action reads it on the lift; it also opens by itself `settle` seconds
/// after every lift, so a hold whose lift never reached the button (the
/// finger slid off) cannot swallow a later tap or a VoiceOver activation.
struct BarHoldGate: Equatable, Sendable {
    /// Long enough for the button's action, which runs on the lift, to read
    /// the gate first.
    static let settle: Double = 0.3

    private(set) var held = false

    mutating func hold() { held = true }
    mutating func settle() { held = false }
    /// `true` when the release should run the slot's action.
    mutating func release() -> Bool {
        defer { held = false }
        return !held
    }
}

/// Which of the bar's three segments a slot is in, so its name bubble opens
/// toward the screen rather than off its edge.
enum BarSegment: Sendable { case leading, centre, trailing }

extension EnvironmentValues {
    @Entry var barEdge: HostBarPosition = .top
    @Entry var barSegment: BarSegment = .centre
}

/// LITE-1c. The slot's name in a small box beside it, on the content side of
/// the bar: the theme's menu background and popup border, no radius, the
/// host type. It never takes a touch and VoiceOver already has the label.
struct BarNameBubble: View {
    /// How long a touch is held before the name shows.
    static let hold: Double = 0.45
    /// How long the name stays.
    static let linger: Double = 1.5
    static let gap: CGFloat = 4

    let text: String
    let edge: HostBarPosition

    var body: some View {
        Text(text)
            .font(OmodachiTheme.font("body-small"))
            .foregroundStyle(OmodachiTheme.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, OmodachiTheme.space("sm"))
            .padding(.vertical, OmodachiTheme.space("xs"))
            // A popup's colours (`[popups] border`), on the menu background
            // laid over the bar's, so whatever is under it never shows through.
            .background(OmodachiTheme.background)
            .background(OmodachiTheme.barBackground)
            .overlay(Rectangle().strokeBorder(OmodachiTheme.popupBorder,
                                              lineWidth: OmodachiTheme.controlBorderWidth))
            .padding(edge == .top ? .top : edge == .bottom ? .bottom : edge == .left ? .leading : .trailing, Self.gap)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .accessibilityIdentifier("bar-name")
    }

    /// Where the bubble hangs off its slot: `slot` is the point on the
    /// slot's inner edge (the content side of the bar), `bubble` is the
    /// bubble's own point placed on it. Along a top or bottom bar the two end
    /// segments line the bubble up with the slot's outer side, so a name near
    /// a screen edge is never cut off; along a side bar it is centred.
    static func anchor(edge: HostBarPosition, segment: BarSegment) -> (slot: Alignment, bubble: Alignment) {
        switch edge {
        case .top, .bottom:
            let along: HorizontalAlignment = switch segment {
            case .leading: .leading
            case .centre: .center
            case .trailing: .trailing
            }
            return edge == .top
                ? (Alignment(horizontal: along, vertical: .bottom), Alignment(horizontal: along, vertical: .top))
                : (Alignment(horizontal: along, vertical: .top), Alignment(horizontal: along, vertical: .bottom))
        case .left, .right:
            // Along a side bar the box is shorter than the slot, so it is
            // centred on it whatever the segment.
            let along: VerticalAlignment = .center
            return edge == .left
                ? (Alignment(horizontal: .trailing, vertical: along), Alignment(horizontal: .leading, vertical: along))
                : (Alignment(horizontal: .leading, vertical: along), Alignment(horizontal: .trailing, vertical: along))
        }
    }
}

/// A-37. The connection to the host, as the 6px dot under the logo. It is the
/// whole of "are we connected" — N-33 deleted the four sentences that used to
/// say it in words, and this is where their information went.
struct BarConnectionDot: View {
    let role: ThemeColorRole
    /// The words VoiceOver reads, since 6 points of colour are not a label.
    let label: String
    var vertical = false

    var body: some View {
        Rectangle().fill(OmodachiTheme.current.color(role))
            .frame(width: 6, height: 6)
            .frame(width: vertical ? NativeBarMetrics.hit : 10,
                   height: vertical ? 10 : NativeBarMetrics.hit)
            .accessibilityElement()
            .accessibilityLabel(Strings.barConnection)
            .accessibilityValue(label)
            .accessibilityIdentifier("bar-connection")
    }
}

/// The bar's surface: the background, the 2px edge rule (D-01) and the safe-area
/// split (A-32). One row of three segments, on whichever long edge the device is
/// holding (A-02).
struct BarSurface<Leading: View, Centre: View, Trailing: View>: View {
    let edge: HostBarPosition
    var contentInsets = EdgeInsets()
    /// The bar's own menu (which edge it sits on). LITE-1c: it hangs off the
    /// bar's background, so a touch-and-hold on the bar's empty stretch opens
    /// it while one on a slot names the slot instead.
    var menu: AnyView?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let centre: () -> Centre
    @ViewBuilder let trailing: () -> Trailing

    private var vertical: Bool { NativeBarMetrics.isVertical(edge) }

    var body: some View {
        Group {
            if vertical {
                HStack(spacing: 0) {
                    if edge == .right { rule }
                    VStack(spacing: 0) { segments }
                        .frame(width: NativeBarMetrics.thickness)
                        .padding(contentInsets)
                    if edge == .left { rule }
                }
            } else {
                VStack(spacing: 0) {
                    if edge == .bottom { rule }
                    HStack(spacing: 0) { segments }
                        .frame(height: NativeBarMetrics.thickness)
                        .padding(contentInsets)
                    if edge == .top { rule }
                }
            }
        }
        .background {
            if let menu {
                OmodachiTheme.barBackground.contextMenu { menu }
            } else {
                OmodachiTheme.barBackground
            }
        }
        .environment(\.barEdge, edge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel-topbar")
    }

    @ViewBuilder private var segments: some View {
        leading().environment(\.barSegment, .leading)
        Spacer(minLength: 0)
        centre().environment(\.barSegment, .centre)
        Spacer(minLength: 0)
        trailing().environment(\.barSegment, .trailing)
    }

    private var rule: some View {
        Rectangle().fill(OmodachiTheme.border)
            .frame(width: vertical ? NativeBarMetrics.edgeRule : nil,
                   height: vertical ? nil : NativeBarMetrics.edgeRule)
            .accessibilityHidden(true)
    }
}
