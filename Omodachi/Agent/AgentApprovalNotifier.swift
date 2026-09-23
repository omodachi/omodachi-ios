import Foundation
import UIKit
import UserNotifications

/// "Your agent is waiting for you", delivered when this app is not what the
/// user is looking at.
///
/// There is no APNs in this product and none is implied here: this is a local
/// notification raised by a live event stream the app is already holding
/// (`omodachi-core/docs/notifications.md`, "What this is not"). If iOS has
/// suspended the app there is no stream and therefore no notification — that is
/// the honest limit, not something a title here should paper over.
///
/// Authorization is **provisional**: it is granted without a permission dialog
/// and delivers quietly, so opening the Agent surface never costs the user a
/// modal for something they have not asked for yet.
@MainActor final class AgentApprovalNotifier {
    static let shared = AgentApprovalNotifier()

    private let center: UNUserNotificationCenter?
    private var requested = false
    /// One notification per request id, so a re-raised prompt does not stack.
    private var posted: Set<String> = []

    /// `UNUserNotificationCenter.current()` traps in a process with no bundle
    /// proxy, which is what a unit-test host looks like. The suites that touch
    /// this type pass their own centre or none at all.
    init(center: UNUserNotificationCenter? = nil) {
        self.center = center ?? (Bundle.main.bundleIdentifier == nil ? nil : .current())
    }

    func prepare() {
        guard let center, !requested else { return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    /// Foreground is deliberately silent: the card is already on screen, and a
    /// banner over it would be the same fact twice.
    func approvalRequested(_ approval: AgentChatApproval, agentName: String) {
        guard let center, UIApplication.shared.applicationState != .active,
              posted.insert(approval.requestID).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = Strings.agentWaitingForYou(agentName)
        content.body = approval.summary.isEmpty ? approval.title : approval.summary
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: "agent-approval-\(approval.requestID)",
                                         content: content, trigger: nil))
    }

    /// Answered — here or on the host — so the pending banner is withdrawn.
    func resolved(requestID: String) {
        guard let center, posted.remove(requestID) != nil else { return }
        center.removeDeliveredNotifications(withIdentifiers: ["agent-approval-\(requestID)"])
        center.removePendingNotificationRequests(withIdentifiers: ["agent-approval-\(requestID)"])
    }
}
