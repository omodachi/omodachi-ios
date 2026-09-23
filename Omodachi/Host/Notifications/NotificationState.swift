import Foundation
import Combine

/// The host's notifications on the store, so the Panel's list and the
/// lightweight bar's toast are the same reading of the same rows.
///
/// There is no background push here and none is implied: a phone sees a
/// notification while it is holding the event stream, which is the limit
/// `omodachi-core/docs/notifications.md` states and the README repeats.
extension HomeStore {
    /// `GET /v1/notifications` plus the current Do Not Disturb state. Called
    /// when the Panel's notification group first appears and after a reconnect,
    /// never on a timer: the event stream is what keeps it fresh.
    func loadNotifications() async {
        if demoActive, profile.mock { notifications.replace(with: DemoHost.notifications()); return }
        guard !profile.mock, companionConnected, let client = client as? CompanionHostClient else { return }
        let current = connectionGeneration
        do {
            let page = try await client.notifications()
            guard current == connectionGeneration else { return }
            notifications.replace(with: page.notifications)
            // DND is not read here: it arrives with every state snapshot
            // (`state.notifications.dnd`) and is pushed when the desktop
            // changes it. One reader, one source.
        } catch {
            guard current == connectionGeneration else { return }
            notifications.loaded = true
            notice = (error as? CompanionHostError)?.errorDescription ?? ReasonText.message("notifications_unavailable", domain: .host)
        }
    }

    /// Fire the shell's own default action. Core accepts this only for the
    /// newest active notification, so the button is only drawn there; a refusal
    /// is reported rather than retried against another row.
    func invokeNotification(_ row: HostNotification) async {
        guard notifications.canInvoke(row), let client = client as? CompanionHostClient else { return }
        let current = connectionGeneration
        do {
            let result = try await client.notificationAction(id: row.id, invoke: true)
            guard current == connectionGeneration else { return }
            // Invoking takes the popup off screen on the host as well.
            if result.result == "ok" { notifications.markInactive(id: row.id) }
            reportToast(.init(stage: result.result == "ok" ? .applied : .failed,
                              label: row.summary.isEmpty ? row.app : row.summary,
                              detail: result.result == "ok" ? nil : result.result))
        } catch {
            guard current == connectionGeneration else { return }
            reportToast(.init(stage: .failed, label: row.summary.isEmpty ? row.app : row.summary, detail: "refused"))
        }
    }

    func dismissNotification(_ row: HostNotification) async {
        guard notifications.canDismiss(row), let client = client as? CompanionHostClient else { return }
        let current = connectionGeneration
        do {
            let result = try await client.notificationAction(id: row.id, invoke: false)
            guard current == connectionGeneration else { return }
            // `none` is the host's honest answer for a notification DND
            // silenced: it went straight to history and was never on screen.
            notifications.markInactive(id: row.id)
            if result.result != "ok" && result.result != "none" {
                reportToast(.init(stage: .failed, label: row.summary.isEmpty ? row.app : row.summary, detail: result.result))
            }
        } catch {
            guard current == connectionGeneration else { return }
            reportToast(.init(stage: .failed, label: row.summary.isEmpty ? row.app : row.summary, detail: "refused"))
        }
    }

    /// A-45. Take one row off *this* list. An active row is also dismissed on
    /// the desktop, best effort: the local removal is not conditional on the
    /// host answering, because a mirror that refuses to let go of a row until a
    /// network round trip succeeds is the behaviour Leo read as "不能删除".
    func deleteNotification(_ row: HostNotification) {
        let wasActive = row.active
        notifications.remove(id: row.id)
        guard wasActive, let client = client as? CompanionHostClient else { return }
        let current = connectionGeneration
        Task { [weak self] in
            _ = try? await client.notificationAction(id: row.id, invoke: false)
            _ = current
            _ = self
        }
    }

    /// A-45's "清除全部". Same rule, for the whole group.
    func clearNotifications() {
        let active = notifications.rows.filter(\.active)
        notifications.removeAll()
        guard let client = client as? CompanionHostClient else { return }
        Task {
            for row in active { _ = try? await client.notificationAction(id: row.id, invoke: false) }
        }
    }

    /// The same target the bar indicator and `SUPER+ALT+.` use, so the switch
    /// here and the switch there are one state.
    /// N-36 / D-15. The switch does not move when the finger lifts: it POSTs,
    /// and the value it draws is whatever comes back — and then whatever the
    /// host's own state says, which is the same thing arriving twice rather
    /// than two sources disagreeing. Nothing is assumed on the way.
    func setDoNotDisturb(_ enabled: Bool) async {
        guard let client = client as? CompanionHostClient else { return }
        let current = connectionGeneration
        do {
            let value = try await client.setNotificationDND(enabled)
            guard current == connectionGeneration else { return }
            notifications.dnd = value
        } catch {
            guard current == connectionGeneration else { return }
            notice = Strings.notificationsDndUnchanged
        }
    }

    /// A-12. One 26-high inline row on the lightweight bar, for two seconds.
    /// The desktop's 5s/8s + hover-pause machinery has no touch equivalent and
    /// is not copied (`ui-study-01.md` §2.8).
    func present(_ row: HostNotification) {
        notifications.post(row)
        guard foreground else { return }
        notificationToast = row
        let id = row.id
        notificationToastTask?.cancel()
        notificationToastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.notificationToast?.id == id else { return }
            self.notificationToast = nil
        }
    }
}
