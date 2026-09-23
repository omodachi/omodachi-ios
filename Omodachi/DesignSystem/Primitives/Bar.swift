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

    var body: some View {
        Tap(selected: state == .selected, enabled: state != .unavailable, action: action) {
            content()
                .foregroundStyle(state == .selected ? OmodachiTheme.selectedText : OmodachiTheme.barText)
                .frame(width: vertical ? NativeBarMetrics.hit : extent,
                       height: vertical ? extent : NativeBarMetrics.hit)
                .overlay(alignment: .topTrailing) { badgeView }
                .overlay(alignment: .bottomTrailing) { dotView }
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(identifier ?? "bar-slot")
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
        .background(OmodachiTheme.barBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel-topbar")
    }

    @ViewBuilder private var segments: some View {
        leading()
        Spacer(minLength: 0)
        centre()
        Spacer(minLength: 0)
        trailing()
    }

    private var rule: some View {
        Rectangle().fill(OmodachiTheme.border)
            .frame(width: vertical ? NativeBarMetrics.edgeRule : nil,
                   height: vertical ? nil : NativeBarMetrics.edgeRule)
            .accessibilityHidden(true)
    }
}
