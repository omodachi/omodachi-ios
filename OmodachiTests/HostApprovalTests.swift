import XCTest
@testable import Omodachi

/// AUTH-1 on the device side: the bytes that get signed, the frames that are
/// trusted enough to raise a Face ID sheet, and the two switches.
final class HostApprovalMessageTests: XCTestCase {
    /// The one test that keeps this app and `omodachi_core/biometric.py` in
    /// agreement. If it ever fails, every approval fails closed and the user
    /// gets the password prompt — which is the right way for a mismatch to
    /// show up, but it is still a mismatch.
    func testApprovalMessageIsExactlyWhatCoreVerifies() {
        let data = ApprovalMessage.approval(hostID: "h", approvalID: "a", nonce: "n",
                                            service: "sudo", user: "root", deviceID: "ipad")
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .ascii) },
                       "omodachi-auth-approval-v1\nh\na\nn\nsudo\nroot\nipad\n")
    }

    func testEnrollmentMessageIsExactlyWhatCoreVerifies() {
        let data = ApprovalMessage.enrollment(hostID: "h", deviceID: "ipad",
                                              challenge: "c", publicKey: "BASE64")
        XCTAssertEqual(data.flatMap { String(data: $0, encoding: .ascii) },
                       "omodachi-auth-enrollment-v1\nh\nipad\nc\nBASE64\n")
    }

    func testAServiceCannotBeMistakenForAnother() {
        let sudo = ApprovalMessage.approval(hostID: "h", approvalID: "a", nonce: "n",
                                            service: "sudo", user: "root", deviceID: "ipad")
        let lock = ApprovalMessage.approval(hostID: "h", approvalID: "a", nonce: "n",
                                            service: "hyprlock", user: "root", deviceID: "ipad")
        XCTAssertNotEqual(sudo, lock)
    }

    func testAFieldWithANewlineOrNonAsciiIsRefused() {
        XCTAssertNil(ApprovalMessage.approval(hostID: "h\nx", approvalID: "a", nonce: "n",
                                              service: "sudo", user: "root", deviceID: "ipad"))
        XCTAssertNil(ApprovalMessage.approval(hostID: "h", approvalID: "", nonce: "n",
                                              service: "sudo", user: "root", deviceID: "ipad"))
        XCTAssertNil(ApprovalMessage.approval(hostID: "主机", approvalID: "a", nonce: "n",
                                              service: "sudo", user: "root", deviceID: "ipad"))
    }
}

final class HostApprovalWireTests: XCTestCase {
    private func event(_ payload: String, type: String = "auth.approval.requested") throws -> SanitizedHostEvent {
        let json = """
        {"event":{"seq":7,"event_id":"evt_00000007","type":"\(type)","device_id":"ios-1",
        "payload":\(payload),"ts":1789430400.0}}
        """
        return try CompanionHostClient.decodeEvent(Data(json.utf8))
    }

    private var good: String {
        """
        {"approval_id":"appr_\(String(repeating: "a", count: 32))",
         "nonce":"\(String(repeating: "n", count: 43))","device_id":"ios-1","service":"sudo",
         "service_title":"Administrator command","user":"alex","requester":"alex",
         "tty":"pts/3","rhost":null,"description":"Administrator command on pts/3",
         "host_id":"\(String(repeating: "0", count: 32))","host_name":"omarchy",
         "requested_at":1789430400,"expires_at":1789430445,"timeout_seconds":45}
        """
    }

    func testAWellFormedApprovalDecodes() throws {
        let decoded = try event(good)
        let request = try XCTUnwrap(decoded.approvalRequest)
        XCTAssertEqual(request.service, "sudo")
        XCTAssertEqual(request.serviceTitle, "Administrator command")
        XCTAssertEqual(request.detail, "Administrator command on pts/3")
        XCTAssertEqual(request.hostName, "omarchy")
        XCTAssertEqual(request.deviceID, "ios-1")
        XCTAssertEqual(request.timeoutSeconds, 45)
        XCTAssertTrue(request.isWellFormed)
    }

    /// A frame this client cannot describe must not raise a biometric sheet.
    /// Dropping it costs one password prompt; acting on it would be asking the
    /// user to approve something the app could not name.
    func testAMalformedApprovalIsDropped() throws {
        let cases = [
            good.replacingOccurrences(of: "\"service\":\"sudo\"", with: "\"service\":\"\""),
            good.replacingOccurrences(of: String(repeating: "n", count: 43), with: "short"),
            good.replacingOccurrences(of: "appr_" + String(repeating: "a", count: 32), with: "nope"),
            good.replacingOccurrences(of: "\"timeout_seconds\":45", with: "\"timeout_seconds\":9000"),
            good.replacingOccurrences(of: "\"expires_at\":1789430445", with: "\"expires_at\":1789430000")
        ]
        for payload in cases {
            XCTAssertNil(try event(payload).approvalRequest, payload)
        }
    }

    func testAResolutionDecodes() throws {
        let decoded = try event("""
        {"approval_id":"appr_\(String(repeating: "a", count: 32))","outcome":"timeout","device_id":null}
        """, type: "auth.approval.resolved")
        XCTAssertEqual(decoded.approvalResolution?.outcome, .timeout)
        XCTAssertNil(decoded.approvalResolution?.deviceID)
    }

    func testBothSwitchesAreNeededForTheKeyListToReadAsActive() throws {
        func keys(_ host: Bool, _ device: Bool) throws -> HostApprovalKeys {
            let json = """
            {"contract_revision":"omodachi.v1","enabled":\(host),
             "host_id":"\(String(repeating: "0", count: 32))","host_name":"omarchy","device_id":"ios-1",
             "challenge":"\(String(repeating: "c", count: 43))","enrolled":true,
             "keys":[{"device_id":"ios-1","label":"iPad","enrolled_at":1,"secure_enclave":true,
                      "algorithm":"ecdsa-p256-sha256","enabled":\(device)}]}
            """
            return try JSONDecoder().decode(HostApprovalKeys.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try keys(true, true).active)
        XCTAssertFalse(try keys(true, false).active)
        XCTAssertFalse(try keys(false, true).active)
        XCTAssertFalse(try keys(false, false).active)
        XCTAssertEqual(try keys(true, true).mine?.secureEnclave, true)
    }
}

// MARK: - Fakes

private actor FakeApprovalService: HostApprovalServing {
    var snapshot: HostApprovalKeys
    var pending: [HostApprovalRequest] = []
    private(set) var enrolled: HostApprovalEnrollment?
    private(set) var revoked = false
    private(set) var decisions: [(String, HostApprovalDecision)] = []
    var failEnrollment = false

    init(hostEnabled: Bool, deviceEnabled: Bool?, deviceID: String = "ios-1") {
        let keys = deviceEnabled.map {
            [HostApprovalKeys.Key(deviceID: deviceID, label: "iPad", enrolledAt: 1,
                                  secureEnclave: false, enabled: $0)]
        } ?? []
        snapshot = HostApprovalKeys(enabled: hostEnabled, hostID: String(repeating: "0", count: 32),
                                    hostName: "omarchy", deviceID: deviceID,
                                    challenge: String(repeating: "c", count: 43),
                                    enrolled: deviceEnabled != nil, keys: keys)
    }

    func fetchApprovalKeys() async throws -> HostApprovalKeys { snapshot }

    func enrollApprovalKey(_ body: HostApprovalEnrollment) async throws -> HostApprovalKeyRecord {
        if failEnrollment { throw CompanionHostError.unavailable(code: "biometric_signature_invalid", message: "no") }
        enrolled = body
        snapshot = HostApprovalKeys(enabled: snapshot.enabled, hostID: snapshot.hostID,
                                    hostName: snapshot.hostName, deviceID: snapshot.deviceID,
                                    challenge: snapshot.challenge, enrolled: true,
                                    keys: [.init(deviceID: snapshot.deviceID, label: body.label,
                                                 enrolledAt: 2, secureEnclave: body.secure_enclave,
                                                 enabled: body.enabled)])
        return HostApprovalKeyRecord(deviceID: snapshot.deviceID, enabled: body.enabled,
                                     secureEnclave: body.secure_enclave)
    }

    func setApprovalEnabled(_ enabled: Bool) async throws -> HostApprovalKeyRecord {
        HostApprovalKeyRecord(deviceID: snapshot.deviceID, enabled: enabled, secureEnclave: false)
    }

    func revokeApprovalKey() async throws -> HostApprovalRevocation {
        revoked = true
        snapshot = HostApprovalKeys(enabled: snapshot.enabled, hostID: snapshot.hostID,
                                    hostName: snapshot.hostName, deviceID: snapshot.deviceID,
                                    challenge: snapshot.challenge, enrolled: false, keys: [])
        return HostApprovalRevocation(deviceID: snapshot.deviceID, revoked: true)
    }

    func resolveApproval(_ approvalID: String, decision: HostApprovalDecision) async throws -> HostApprovalResolution {
        decisions.append((approvalID, decision))
        return HostApprovalResolution(approvalID: approvalID,
                                      outcome: decision.decision == "approve" ? .approved : .declined,
                                      deviceID: snapshot.deviceID)
    }

    func pendingApprovals() async throws -> HostPendingApprovals { HostPendingApprovals(approvals: pending) }

    func setFailEnrollment(_ value: Bool) { failEnrollment = value }
    func setPending(_ value: [HostApprovalRequest]) { pending = value }
}

private final class FakeSigner: ApprovalSigning, @unchecked Sendable {
    var outcome: Result<Data, ApprovalKeyError> = .success(Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01]))
    private(set) var signed: [Data] = []
    private(set) var deleted = 0

    func identity(account: String) throws -> ApprovalKeyIdentity {
        ApprovalKeyIdentity(publicKey: Data(repeating: 4, count: 65).base64EncodedString(), secureEnclave: false)
    }

    func sign(_ message: Data, account: String, reason: String) async throws -> Data {
        signed.append(message)
        return try outcome.get()
    }

    func deleteKey(account: String) throws { deleted += 1 }

    private(set) var cancelled = 0
    func cancelPrompt() { cancelled += 1 }
}

private func approval(id: String = "appr_" + String(repeating: "a", count: 32),
                      expiresIn: TimeInterval = 45,
                      statedDeviceID: String? = "ios-1") -> HostApprovalRequest {
    let now = Int(Date().timeIntervalSince1970)
    let stated = statedDeviceID.map { "\"device_id\":\"\($0)\"," } ?? ""
    let json = """
    {"approval_id":"\(id)","nonce":"\(String(repeating: "n", count: 43))",\(stated)"service":"sudo",
     "service_title":"Administrator command","user":"alex","requester":"alex","tty":"pts/3",
     "rhost":null,"description":"Administrator command on pts/3",
     "host_id":"\(String(repeating: "0", count: 32))","host_name":"omarchy",
     "requested_at":\(now),"expires_at":\(now + Int(expiresIn)),"timeout_seconds":45}
    """
    return try! JSONDecoder().decode(HostApprovalRequest.self, from: Data(json.utf8))
}

private func requestEvent(_ value: HostApprovalRequest) -> SanitizedHostEvent {
    SanitizedHostEvent(sequence: 1, eventID: "evt_1", type: "auth.approval.requested",
                       instanceID: nil, snapshot: nil, needsResync: false, approvalRequest: value)
}

@MainActor
final class HostApprovalCoordinatorTests: XCTestCase {
    private func settle(_ times: Int = 6) async {
        for _ in 0..<times { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func attach(_ coordinator: HostApprovalCoordinator,
                        _ service: FakeApprovalService) async {
        coordinator.attach(service: service, deviceID: "ios-1", account: "approval-a", label: "iPad")
        await settle()
    }

    func testBothSwitchesAreReportedFromTheHost() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: false)
        await attach(coordinator, service)
        XCTAssertTrue(coordinator.hostEnabled)
        XCTAssertFalse(coordinator.deviceEnabled)
        XCTAssertNotNil(coordinator.registered)
    }

    /// The device's switch being off is enough. Even if a frame reaches this
    /// client, nothing is asked of the person.
    func testAnApprovalIsIgnoredWhileTheDeviceSwitchIsOff() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: false)
        await attach(coordinator, service)
        coordinator.handle(requestEvent(approval()))
        await settle()
        XCTAssertNil(coordinator.request)
        XCTAssertTrue(signer.signed.isEmpty)
        let decisions = await service.decisions
        XCTAssertTrue(decisions.isEmpty)
    }

    func testAnApprovalIsSignedAndSubmittedWhenBothSwitchesAreOn() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true)
        await attach(coordinator, service)
        let value = approval()
        coordinator.handle(requestEvent(value))
        await settle()
        XCTAssertEqual(signer.signed.count, 1)
        // Exactly the bytes core will verify, built from the event's own fields.
        XCTAssertEqual(signer.signed.first,
                       ApprovalMessage.approval(hostID: value.hostID, approvalID: value.approvalID,
                                                nonce: value.nonce, service: value.service,
                                                user: value.user, deviceID: "ios-1"))
        let decisions = await service.decisions
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.0, value.approvalID)
        XCTAssertEqual(decisions.first?.1.decision, "approve")
        XCTAssertNotNil(decisions.first?.1.signature)
    }

    /// UX-3 §1, the regression that cost Leo a round.
    ///
    /// The app's local id had drifted away from the credential it connects
    /// with. Enrolment signed the host's answer and worked; every approval
    /// signed the local guess and was refused. Both of the host's answers are
    /// exercised here, and the local id is deliberately wrong in each, because
    /// a test whose fake agrees with the app about the device id is exactly the
    /// test that let this ship.
    func testTheApprovalIsSignedAsTheIdentityTheHostStatesInTheFrame() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true, deviceID: "ios-credential")
        coordinator.attach(service: service, deviceID: "ios-stale-local",
                           account: "approval-a", label: "iPad")
        await settle()
        let value = approval(statedDeviceID: "ios-credential")
        coordinator.handle(requestEvent(value))
        await settle()
        XCTAssertEqual(signer.signed.first,
                       ApprovalMessage.approval(hostID: value.hostID, approvalID: value.approvalID,
                                                nonce: value.nonce, service: value.service,
                                                user: value.user, deviceID: "ios-credential"))
    }

    /// A host from before UX-3 sends no `device_id` in the frame. The key list
    /// it answered at connect time is the same authority one step removed, and
    /// it is still better than the local guess.
    func testAHostThatStatesNoIdentityFallsBackToTheKeyList() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true, deviceID: "ios-credential")
        coordinator.attach(service: service, deviceID: "ios-stale-local",
                           account: "approval-a", label: "iPad")
        await settle()
        let value = approval(statedDeviceID: nil)
        XCTAssertNil(value.deviceID)
        coordinator.handle(requestEvent(value))
        await settle()
        XCTAssertEqual(signer.signed.first,
                       ApprovalMessage.approval(hostID: value.hostID, approvalID: value.approvalID,
                                                nonce: value.nonce, service: value.service,
                                                user: value.user, deviceID: "ios-credential"))
    }

    /// Enrolment always used the host's answer, which is why the key registered
    /// on the real iPad while every approval with it failed. Pinning it keeps
    /// the two halves signing as the same identity.
    func testEnrolmentAndApprovalSignAsTheSameIdentity() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: nil, deviceID: "ios-credential")
        coordinator.attach(service: service, deviceID: "ios-stale-local",
                           account: "approval-a", label: "iPad")
        await settle()
        coordinator.setDeviceEnabled(true)
        await settle(10)
        let enrolmentBytes = signer.signed.first
        XCTAssertEqual(enrolmentBytes,
                       ApprovalMessage.enrollment(hostID: String(repeating: "0", count: 32),
                                                  deviceID: "ios-credential",
                                                  challenge: String(repeating: "c", count: 43),
                                                  publicKey: Data(repeating: 4, count: 65).base64EncodedString()))
        let value = approval(statedDeviceID: "ios-credential")
        coordinator.handle(requestEvent(value))
        await settle()
        let approvalBytes = try? XCTUnwrap(signer.signed.last)
        let text = approvalBytes.flatMap { String(data: $0, encoding: .ascii) }
        XCTAssertEqual(text?.split(separator: "\n").last.map(String.init), "ios-credential")
    }

    /// A cancelled Face ID submits a decline, not nothing: the host's password
    /// prompt comes back at once instead of after the whole timeout.
    func testACancelledBiometricDeclinesRatherThanWaiting() async {
        let signer = FakeSigner()
        signer.outcome = .failure(.cancelled)
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true)
        await attach(coordinator, service)
        coordinator.handle(requestEvent(approval()))
        await settle()
        let decisions = await service.decisions
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.1.decision, "decline")
        XCTAssertNil(decisions.first?.1.signature)
    }

    /// A biometric that is simply unavailable submits nothing at all. There is
    /// no answer to give, and the host's timeout is the correct outcome.
    func testAnUnavailableBiometricSubmitsNothing() async {
        let signer = FakeSigner()
        signer.outcome = .failure(.biometryUnavailable)
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true)
        await attach(coordinator, service)
        coordinator.handle(requestEvent(approval()))
        await settle()
        let decisions = await service.decisions
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertEqual(coordinator.stage, .failed(Strings.approvalErrorNoBiometry))
    }

    func testTheSameApprovalIsNeverAnsweredTwice() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true)
        await attach(coordinator, service)
        let value = approval()
        coordinator.handle(requestEvent(value))
        await settle()
        coordinator.handle(requestEvent(value))
        await settle()
        let decisions = await service.decisions
        XCTAssertEqual(decisions.count, 1)
    }

    func testAnAlreadyExpiredApprovalIsNotShown() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true)
        await attach(coordinator, service)
        coordinator.handle(requestEvent(approval(expiresIn: 0)))
        await settle()
        XCTAssertNil(coordinator.request)
        XCTAssertTrue(signer.signed.isEmpty)
    }

    /// Turning the switch on registers the public key, signed over the host's
    /// challenge. Turning it off unregisters and deletes the local key.
    func testTheSwitchRegistersAndUnregisters() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: nil)
        await attach(coordinator, service)
        XCTAssertFalse(coordinator.deviceEnabled)
        coordinator.setDeviceEnabled(true)
        await settle(10)
        let enrolled = await service.enrolled
        XCTAssertEqual(enrolled?.enabled, true)
        XCTAssertEqual(enrolled?.secure_enclave, false)
        XCTAssertEqual(enrolled?.challenge, String(repeating: "c", count: 43))
        XCTAssertTrue(coordinator.deviceEnabled)

        coordinator.setDeviceEnabled(false)
        await settle(10)
        let revoked = await service.revoked
        XCTAssertTrue(revoked)
        XCTAssertEqual(signer.deleted, 1)
        XCTAssertFalse(coordinator.deviceEnabled)
        XCTAssertNil(coordinator.registered)
    }

    /// A reconnect that lands in the middle of a prompt picks it up rather
    /// than leaving the host waiting for an event this device already missed.
    func testAReconnectPicksUpAnApprovalThatIsStillRunning() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true)
        await service.setPending([approval()])
        await attach(coordinator, service)
        await settle(10)
        XCTAssertEqual(signer.signed.count, 1)
    }

    func testAHostWithoutTheFeatureIsNotAnError() async {
        struct Missing: HostApprovalServing {
            func fetchApprovalKeys() async throws -> HostApprovalKeys {
                throw CompanionHostError.unavailable(code: "route_unavailable", message: "no")
            }
            func enrollApprovalKey(_ body: HostApprovalEnrollment) async throws -> HostApprovalKeyRecord { fatalError() }
            func setApprovalEnabled(_ enabled: Bool) async throws -> HostApprovalKeyRecord { fatalError() }
            func revokeApprovalKey() async throws -> HostApprovalRevocation { fatalError() }
            func resolveApproval(_ approvalID: String, decision: HostApprovalDecision) async throws -> HostApprovalResolution { fatalError() }
            func pendingApprovals() async throws -> HostPendingApprovals { HostPendingApprovals(approvals: []) }
        }
        let coordinator = HostApprovalCoordinator(keys: FakeSigner(), biometry: .faceID)
        coordinator.attach(service: Missing(), deviceID: "ios-1", account: "a", label: "iPad")
        await settle()
        XCTAssertFalse(coordinator.supported)
        XCTAssertNil(coordinator.failure)
    }

    /// A host that gives up must take the sheet down with it.
    func testATimeoutFromTheHostTakesTheBiometricSheetDown() async {
        let signer = FakeSigner()
        let coordinator = HostApprovalCoordinator(keys: signer, biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true)
        await attach(coordinator, service)
        let value = approval()
        coordinator.handle(requestEvent(value))
        await settle(2)
        let before = signer.cancelled
        coordinator.handle(SanitizedHostEvent(
            sequence: 2, eventID: "evt_2", type: "auth.approval.resolved", instanceID: nil,
            snapshot: nil, needsResync: false,
            approvalResolution: HostApprovalResolution(approvalID: value.approvalID,
                                                       outcome: .timeout, deviceID: nil)))
        await settle(2)
        XCTAssertGreaterThan(signer.cancelled, before, "the sheet was left up after the host gave up")
    }

    func testDetachForgetsEverything() async {
        let coordinator = HostApprovalCoordinator(keys: FakeSigner(), biometry: .faceID)
        let service = FakeApprovalService(hostEnabled: true, deviceEnabled: true)
        await attach(coordinator, service)
        coordinator.detach()
        XCTAssertFalse(coordinator.hostEnabled)
        XCTAssertFalse(coordinator.deviceEnabled)
        XCTAssertNil(coordinator.request)
        XCTAssertTrue(coordinator.otherKeys.isEmpty)
    }
}
