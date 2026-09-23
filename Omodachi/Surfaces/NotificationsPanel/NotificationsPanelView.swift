import SwiftUI

/// Panel ⑦ — Notifications (A-52, A-45, N-36).
///
/// It is the group that used to sit at the top of the Panel, moved whole: the
/// unread count, 清除全部, the inline ×, the swipe, the "N earlier" tail. Only
/// the container changed — from a collapsible group inside panel ① to a panel
/// of its own behind the bell.
///
/// N-36 puts Do Not Disturb at the head of this page and nowhere else. The bell
/// on the bar swaps to the muted glyph while it is on, which is D-18's rule —
/// the same code point, differently coloured — and an *expression*, not a
/// second switch.
///
/// **DND is read from `state.notifications.dnd`, never remembered here.** Two
/// things can change it, this switch and the desktop's own indicator, so a
/// client that kept its own boolean would go on saying "off" after the user
/// turned it on at the machine (core's `notifications.changed`, ARCH-1 §5 #17).
/// `null` means the host has not been asked yet, and the switch says so instead
/// of drawing "off".
struct NotificationsPanelView: View {
    @EnvironmentObject private var home: HomeStore
    @State private var showingAll = false

    /// A-45's fold: a screenful, then a count.
    private static let preview = 8

    private var rows: [HostNotification] { home.notifications.rows }
    private var visible: [HostNotification] {
        showingAll ? rows : Array(rows.prefix(Self.preview))
    }

    var body: some View {
        PanelArea(identifier: "notifications-panel") {
            PanelTitle(Strings.panelNotifications)
        } accessory: {
            dnd
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if !rows.isEmpty { clearAll }
                if home.notifications.dnd == true {
                    Text(Strings.notificationsDndOn)
                        .font(OmodachiTheme.bodyFont("body-small"))
                        .foregroundStyle(OmodachiTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, OmodachiTheme.rowPaddingX)
                        .padding(.bottom, OmodachiTheme.space("lg"))
                }
                if rows.isEmpty {
                    EmptyState(title: home.notifications.loaded ? Strings.notificationsEmpty : Strings.notificationsLoading,
                               detail: home.notifications.loaded
                                   ? Strings.notificationsEmptyDetail : nil,
                               identifier: "notifications-empty")
                } else {
                    GroupLabel(text: home.notifications.unreadCount > 0
                               ? Strings.notificationsUnreadCount(Format.count(home.notifications.unreadCount)) : Strings.notificationsAll)
                    ForEach(visible) { row in
                        NotificationRow(row: row,
                                        canInvoke: home.notifications.canInvoke(row),
                                        canDismiss: home.notifications.canDismiss(row),
                                        onInvoke: { Task { await home.invokeNotification(row) } },
                                        onDelete: { home.deleteNotification(row) })
                    }
                    if rows.count > visible.count {
                        TextTap(Strings.notificationsEarlier(Format.count(rows.count - visible.count)), role: .muted) { showingAll = true }
                            .accessibilityIdentifier("panel-notifications-more")
                    } else if showingAll, rows.count > Self.preview {
                        TextTap(Strings.actionCollapse, role: .muted) { showingAll = false }
                    }
                }
            }
        }
        .task { if !home.notifications.loaded { await home.loadNotifications() } }
    }

    /// N-36. The one switch. It follows the host's state rather than the finger
    /// (D-15): pressing it POSTs, and the switch moves when core's answer lands.
    @ViewBuilder private var dnd: some View {
        let value = home.notifications.dnd
        Tap(selected: value == true, bordered: true,
            enabled: home.companionConnected && value != nil,
            action: { Task { await home.setDoNotDisturb(!(value ?? false)) } }) {
            HStack(spacing: OmodachiTheme.space("sm")) {
                Glyph(Icon.dnd, step: "icon-small")
                Text(Strings.notificationsDnd).font(OmodachiTheme.font("caption"))
            }
            .foregroundStyle(value == true ? OmodachiTheme.accent : OmodachiTheme.muted)
            .padding(.horizontal, OmodachiTheme.space("xl"))
            .frame(height: OmodachiTheme.controlHeight)
            .frame(minHeight: NativeBarMetrics.hit)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Strings.notificationsDnd)
        .accessibilityValue(value == nil ? Strings.notificationsDndUnknown : (value! ? Strings.quickOn : Strings.quickOff))
        .accessibilityIdentifier("panel-dnd")
    }

    @ViewBuilder private var clearAll: some View {
        HStack {
            Spacer(minLength: 0)
            InlineConfirm(title: Strings.notificationsClear, confirmTitle: Strings.notificationsClearConfirm, kind: .ghost,
                          identifier: "panel-notifications-clear") { home.clearNotifications() }
                .frame(maxWidth: 200)
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.top, OmodachiTheme.space("lg"))
    }
}

/// A-18: the menu row stays 50 high on every device; only the number of visible
/// rows changes. Swiping left dismisses, which is the one gesture the desktop
/// has no equivalent for and the phone does.
struct NotificationRow: View {
    let row: HostNotification
    let canInvoke: Bool
    let canDismiss: Bool
    var onInvoke: () -> Void
    /// A-45. Take this row off the list. Available on history rows too.
    var onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var urgencyRole: ThemeColorRole {
        switch row.urgency {
        case .critical: .red
        case .normal: .muted
        case .low: .darkForeground
        }
    }

    var body: some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < 0 {
                    Text(Strings.actionDelete)
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.danger)
                        .padding(.trailing, OmodachiTheme.rowPaddingX)
                }
            }
            // A-45: the swipe is the gesture, the button at the end of the row
            // is the affordance. A gesture nobody is told about is not a
            // delete control, which is why Leo's reading was that there is none.
            .overlay(alignment: .trailing) {
                Tap(action: onDelete) {
                    Glyph(symbol: "xmark", points: OmodachiTheme.fontSize("icon-small"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .frame(width: NativeBarMetrics.hit, height: NativeBarMetrics.hit)
                        .contentShape(Rectangle())
                }
                
                .accessibilityLabel(Strings.notificationsDelete)
                .accessibilityIdentifier("notification-delete-\(row.id)")
            }
            // Without this the drag only lands on the glyphs themselves, and a
            // swipe that starts in the empty half of the row does nothing.
            .contentShape(Rectangle())
            .gesture(dismissGesture)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: offset)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notification-\(row.id)")
            .accessibilityLabel(Strings.pair(row.app, row.summary + " " + row.body))
            .accessibilityActions {
                if canInvoke { TextTap(Strings.notificationsInvoke, action: onInvoke) }
                TextTap(Strings.actionDelete, action: onDelete)
            }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                offset = min(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width < -60 { onDelete() }
                offset = 0
            }
    }

    @ViewBuilder private var content: some View {
        let body = HStack(alignment: .top, spacing: OmodachiTheme.space("lg")) {
            Rectangle()
                .fill(OmodachiTheme.current.color(urgencyRole))
                .frame(width: OmodachiTheme.popupBorderWidth)
                .opacity(row.active ? 1 : 0.4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: OmodachiTheme.space("sm")) {
                    Text(row.app)
                        .font(OmodachiTheme.font("caption"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                    Text(row.date, format: .dateTime.hour().minute())
                        .font(OmodachiTheme.font("caption").monospacedDigit())
                        .foregroundStyle(OmodachiTheme.tertiaryText)
                    Spacer(minLength: 0)
                    if !row.active {
                        Text(Strings.notificationsHistory)
                            .font(OmodachiTheme.font("caption"))
                            .foregroundStyle(OmodachiTheme.tertiaryText)
                    }
                }
                // A-07: a notification is prose. Upstream's own card says so.
                Text(row.summary)
                    .font(OmodachiTheme.bodyFont("subtitle"))
                    .lineLimit(1).truncationMode(.tail)
                if !row.body.isEmpty {
                    Text(row.body)
                        .font(OmodachiTheme.bodyFont("body-small"))
                        .foregroundStyle(OmodachiTheme.secondaryText)
                        .lineLimit(2).truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, OmodachiTheme.rowPaddingX)
        .padding(.vertical, OmodachiTheme.space("md"))
        .frame(minHeight: 50, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(row.active ? 1 : 0.6)

        if canInvoke {
            Tap(action: onInvoke) { body.contentShape(Rectangle()) }
                
                .padding(.trailing, NativeBarMetrics.hit)
        } else {
            body
        }
    }
}

/// A-12. The host's own notification, as a 26-high inline row beside the
/// lightweight bar. It is the same geometry the Panel's action result uses,
/// because it is the same kind of statement: something happened, briefly.
struct HostNotificationToastView: View {
    let notification: HostNotification

    var body: some View {
        HStack(spacing: OmodachiTheme.space("lg")) {
            Glyph(symbol: notification.urgency == .critical ? "exclamationmark" : "bell", points: OmodachiTheme.fontSize("caption"))
                .foregroundStyle(OmodachiTheme.current.color(notification.urgency == .critical ? .red : .muted))
            Text(notification.summary.isEmpty ? notification.app : notification.summary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: OmodachiTheme.space("sm"))
            Text(notification.app)
                .foregroundStyle(OmodachiTheme.tertiaryText)
                .lineLimit(1)
        }
        .font(OmodachiTheme.bodyFont("body-small"))
        .foregroundStyle(OmodachiTheme.text)
        .padding(.horizontal, OmodachiTheme.space("xl"))
        .frame(height: 26)
        .background(OmodachiTheme.normalFill)
        .background(OmodachiTheme.background)
        .overlay(Rectangle().strokeBorder(OmodachiTheme.controlBorder, lineWidth: OmodachiTheme.controlBorderWidth))
        // 5 in from the stage edge, half of `general.gaps_out`, the same shell
        // edge distance the Panel's own toast uses.
        .padding(.horizontal, 5)
        .accessibilityIdentifier("notification-toast")
        .accessibilityLabel(Strings.pair(notification.app, notification.summary))
    }
}
