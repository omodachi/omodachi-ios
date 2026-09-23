import Combine
import Foundation
import UIKit
import UserNotifications

/// AUTH-1's device half: the switch, the registration, and answering one prompt.
///
/// What this owns is deliberately small. The host decides *whether* to ask, the
/// key store decides *whether the person is there*, and this object is the wire
/// between them plus the one thing the user sees: a 26-high toast and, when the
/// app is not in front, a local notification saying the computer is waiting.
///
/// Both of AUTH-1's switches have to be on. `hostEnabled` is the host's
/// preference, read from `GET /v1/auth/keys`; `deviceEnabled` is this device's
/// own, which the person turns on in Settings ⑥ and which registers the key.
/// Turning it off unregisters, so a device that has said no is not merely quiet
/// — the host has nothing of it left to ask.
protocol HostApprovalServing: Sendable {
    func fetchApprovalKeys() async throws -> HostApprovalKeys
    func enrollApprovalKey(_ body: HostApprovalEnrollment) async throws -> HostApprovalKeyRecord
    func setApprovalEnabled(_ enabled: Bool) async throws -> HostApprovalKeyRecord
    func revokeApprovalKey() async throws -> HostApprovalRevocation
    func resolveApproval(_ approvalID: String, decision: HostApprovalDecision) async throws -> HostApprovalResolution
    func pendingApprovals() async throws -> HostPendingApprovals
}

extension CompanionHostClient: HostApprovalServing {}

enum HostApprovalStage: Equatable, Sendable {
    case asking
    case submitting
    /// Held briefly so the toast can say what happened before it goes away.
    case finished(HostApprovalResolution.Outcome)
    case failed(String)
}

@MainActor
final class HostApprovalCoordinator: ObservableObject {
    /// The prompt the host is waiting on, or nil. At most one: a second PAM
    /// prompt while one is on screen is rare, and stacking Face ID sheets is
    /// how a person ends up approving the wrong thing.
    @Published private(set) var request: HostApprovalRequest?
    @Published private(set) var stage: HostApprovalStage?
    /// AUTH-1's two switches, as last read from the host.
    @Published private(set) var hostEnabled = false
    @Published private(set) var deviceEnabled = false
    @Published private(set) var registered: HostApprovalKeys.Key?
    @Published private(set) var otherKeys: [HostApprovalKeys.Key] = []
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var supported = true
    /// UX-3 §1. The identity the host says this connection authenticated as,
    /// from `GET /v1/auth/keys`. It is the fallback the approval signs with
    /// when a host from before UX-3 does not state one in the frame, and it is
    /// what Settings ⑥ prints — "which device does the computer think I am" is
    /// the question a whole round was spent unable to answer. Cleared on
    /// detach, so it can never outlive the connection that established it.
    @Published private(set) var hostKnownDeviceID: String?

    let biometry: BiometryKind

    private let keys: any ApprovalSigning
    private let notifier: HostApprovalNotifier
    private var service: (any HostApprovalServing)?
    /// What this device calls itself locally. UX-3 §1: it is a *fallback*, not
    /// the answer. It is minted into `UserDefaults` and can therefore drift
    /// away from the credential the Keychain still connects with — a reinstall
    /// keeps the Keychain and wipes the defaults, and a re-pair mints a second
    /// credential while the first one keeps working. The host's own answer
    /// always wins.
    private var deviceID = ""
    private var account = ""
    private var label = ""
    private var answered = Set<String>()
    private var work: Task<Void, Never>?

    init(keys: any ApprovalSigning = ApprovalKeyStore(),
         notifier: HostApprovalNotifier = HostApprovalNotifier(),
         biometry: BiometryKind = BiometryKind.current()) {
        self.keys = keys
        self.notifier = notifier
        self.biometry = biometry
    }

    // MARK: - Wiring

    func attach(service: (any HostApprovalServing)?, deviceID: String, account: String, label: String) {
        self.service = service
        self.deviceID = deviceID
        self.account = account
        self.label = label
        guard service != nil else { return }
        Task { await refresh() }
    }

    func detach() {
        service = nil
        work?.cancel()
        keys.cancelPrompt()
        work = nil
        dismiss()
        hostKnownDeviceID = nil
        hostEnabled = false
        deviceEnabled = false
        registered = nil
        otherKeys = []
    }

    /// Read both switches back from the host. Also the recovery path: a device
    /// that reconnects into a prompt that is still running picks it up here.
    func refresh() async {
        guard let service else { return }
        do {
            let value = try await service.fetchApprovalKeys()
            supported = true
            failure = nil
            hostKnownDeviceID = value.deviceID
            hostEnabled = value.enabled
            registered = value.mine
            deviceEnabled = value.mine?.enabled ?? false
            otherKeys = value.keys.filter { $0.deviceID != value.deviceID }
            if deviceEnabled, let pending = try? await service.pendingApprovals().approvals.first,
               pending.isWellFormed, request == nil {
                present(pending)
            }
        } catch CompanionHostError.unavailable(let code, _) where code == "biometric_unavailable" {
            supported = false
        } catch {
            // A host that does not have AUTH-1 answers 404 on this route. It is
            // not an error to show anybody; it is a host without the feature.
            supported = false
        }
    }

    // MARK: - The device's own switch

    /// Turning it on generates the key if there is none and registers its
    /// public half. Turning it off unregisters: the host keeps nothing.
    func setDeviceEnabled(_ enabled: Bool) {
        guard let service, !busy else { return }
        busy = true
        failure = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                if enabled {
                    let snapshot = try await service.fetchApprovalKeys()
                    let identity = try self.keys.identity(account: self.account)
                    guard let message = ApprovalMessage.enrollment(
                        hostID: snapshot.hostID, deviceID: snapshot.deviceID,
                        challenge: snapshot.challenge, publicKey: identity.publicKey) else {
                        throw ApprovalKeyError.unsupported
                    }
                    // Registering asks for the biometric too. It is the one
                    // moment the person is told, in the system's own words,
                    // what this key will be used for.
                    let signature = try await self.keys.sign(
                        message, account: self.account,
                        reason: Strings.approvalEnrollReason(snapshot.hostName))
                    _ = try await service.enrollApprovalKey(HostApprovalEnrollment(
                        public_key: identity.publicKey, label: self.label,
                        challenge: snapshot.challenge,
                        signature: signature.base64EncodedString(),
                        enabled: true, secure_enclave: identity.secureEnclave))
                } else {
                    _ = try await service.revokeApprovalKey()
                    try? self.keys.deleteKey(account: self.account)
                }
                await self.refresh()
            } catch let error as ApprovalKeyError where error.isCancellation {
                await self.refresh()
            } catch {
                self.failure = Self.message(for: error)
                await self.refresh()
            }
        }
    }

    /// Unregister another device's key from here. Settings shows every key the
    /// host holds, because "which devices can answer my password prompt" is a
    /// question you want answered in one place.
    func revokeOther(_ key: HostApprovalKeys.Key) {
        // Only the host's local administrator can revoke a key that is not
        // this device's own (`omodachi-host auth revoke`). Saying so is more
        // use than a button that fails.
        failure = Strings.approvalRevokeOnHost(key.label)
    }

    // MARK: - One prompt

    func handle(_ event: SanitizedHostEvent) {
        if let resolution = event.approvalResolution {
            guard resolution.approvalID == request?.approvalID else { return }
            notifier.clear(resolution.approvalID)
            if case .submitting = stage { return }   // our own answer is landing
            // The host stopped waiting. Take the biometric sheet down with it:
            // a sheet that outlives its prompt blocks the next one and asks a
            // question whose answer no longer goes anywhere.
            work?.cancel()
            keys.cancelPrompt()
            finish(resolution.outcome)
            return
        }
        guard let value = event.approvalRequest, value.isWellFormed else { return }
        present(value)
    }

    private func present(_ value: HostApprovalRequest) {
        guard !answered.contains(value.approvalID), value.remaining() > 1 else { return }
        guard deviceEnabled else { return }
        request = value
        stage = .asking
        if UIApplication.shared.applicationState != .active {
            notifier.post(value)
        }
        prompt(value)
    }

    /// Ask for the biometric, sign, submit. A cancel or a failed match submits
    /// nothing at all: the host's own timeout then returns the user to the
    /// password prompt, which is the same outcome as never having answered.
    private func prompt(_ value: HostApprovalRequest) {
        work?.cancel()
        work = Task { [weak self] in
            guard let self, let service = self.service else { return }
            do {
                let (identity, source) = await self.signingIdentity(for: value)
                guard let message = ApprovalMessage.approval(
                    hostID: value.hostID, approvalID: value.approvalID, nonce: value.nonce,
                    service: value.service, user: value.user, deviceID: identity) else {
                    throw ApprovalKeyError.unsupported
                }
                let signature = try await self.keys.sign(
                    message, account: self.account,
                    reason: Strings.approvalPromptReason(value.hostName, value.serviceTitle))
                ApprovalTrace.signed(message, signature: signature, identity: identity,
                                     identitySource: source, localIdentity: self.deviceID)
                guard !Task.isCancelled, self.request?.approvalID == value.approvalID else { return }
                self.stage = .submitting
                self.answered.insert(value.approvalID)
                let result = try await service.resolveApproval(
                    value.approvalID, decision: .approve(signature: signature.base64EncodedString()))
                ApprovalTrace.outcome(value.approvalID, result.outcome.rawValue)
                self.notifier.clear(value.approvalID)
                self.finish(result.outcome)
            } catch let error as ApprovalKeyError where error.isCancellation {
                self.answered.insert(value.approvalID)
                await self.decline(value)
            } catch is CancellationError {
                return
            } catch {
                self.answered.insert(value.approvalID)
                ApprovalTrace.outcome(value.approvalID, "error: \(error)")
                self.notifier.clear(value.approvalID)
                self.stage = .failed(Self.message(for: error))
                self.scheduleDismiss()
            }
        }
    }

    /// Which `device_id` goes into the signed bytes, in order of authority.
    ///
    /// The frame itself is best: the host wrote that field while addressing
    /// *this* subscription, so it cannot be anything but the credential the
    /// connection holds. `GET /v1/auth/keys` is the same authority one step
    /// removed, and is what a host from before UX-3 gives. The local id is the
    /// last resort, and it is the one that was wrong on the real iPad — so when
    /// neither host answer is in hand, the host is asked once before a sheet is
    /// raised. A round trip is cheaper than a Face ID the host will refuse.
    private func signingIdentity(for value: HostApprovalRequest) async -> (String, String) {
        var answer: (String, String)?
        if let stated = value.deviceID, !stated.isEmpty {
            answer = (stated, "frame")
        } else if let known = hostKnownDeviceID, !known.isEmpty {
            answer = (known, "keys")
        } else if let service, let fetched = try? await service.fetchApprovalKeys(),
                  !fetched.deviceID.isEmpty {
            hostKnownDeviceID = fetched.deviceID
            answer = (fetched.deviceID, "keys")
        }
        guard let answer else { return (deviceID, "local") }
        if answer.0 != deviceID {
            ApprovalTrace.identityDrift(local: deviceID, host: answer.0)
        }
        return answer
    }

    /// An explicit no. Telling the host is better than letting it wait: the
    /// password prompt comes back immediately instead of after the timeout.
    private func decline(_ value: HostApprovalRequest) async {
        stage = .submitting
        _ = try? await service?.resolveApproval(value.approvalID, decision: .decline)
        notifier.clear(value.approvalID)
        finish(.declined)
    }

    func declineCurrent() {
        guard let value = request else { return }
        work?.cancel()
        answered.insert(value.approvalID)
        Task { await decline(value) }
    }

    private func finish(_ outcome: HostApprovalResolution.Outcome) {
        stage = .finished(outcome)
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        work = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        if let value = request { notifier.clear(value.approvalID) }
        keys.cancelPrompt()
        request = nil
        stage = nil
    }

    static func message(for error: Error) -> String {
        switch error {
        case ApprovalKeyError.biometryUnavailable: Strings.approvalErrorNoBiometry
        case ApprovalKeyError.keyInvalidated: Strings.approvalErrorKeyInvalid
        case ApprovalKeyError.cancelled: Strings.approvalErrorCancelled
        default: Strings.approvalErrorGeneric
        }
    }
}

/// "Your computer is waiting" while the app is not in front. No actions on the
/// notification: approving needs the biometric, and the biometric needs the
/// app, so the notification's only job is to get the person to open it.
final class HostApprovalNotifier: @unchecked Sendable {
    private let center: UNUserNotificationCenter?
    private var requested = false

    init(center: UNUserNotificationCenter? = nil) {
        // Nil-bundle safe, like `AgentApprovalNotifier`: a unit test host has
        // no bundle identifier and `UNUserNotificationCenter.current()` traps.
        self.center = center ?? (Bundle.main.bundleIdentifier == nil ? nil : .current())
    }

    func prepare() {
        guard let center, !requested else { return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    private func identifier(_ approvalID: String) -> String { "host-approval-\(approvalID)" }

    func post(_ value: HostApprovalRequest) {
        guard let center else { return }
        prepare()
        let content = UNMutableNotificationContent()
        content.title = Strings.approvalNotificationTitle(value.hostName)
        content.body = value.detail
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: identifier(value.approvalID),
                                         content: content, trigger: nil))
    }

    func clear(_ approvalID: String) {
        guard let center else { return }
        center.removeDeliveredNotifications(withIdentifiers: [identifier(approvalID)])
        center.removePendingNotificationRequests(withIdentifiers: [identifier(approvalID)])
    }
}
