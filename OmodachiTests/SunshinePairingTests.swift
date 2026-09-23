import Foundation
import XCTest
@testable import Omodachi

/// The in-app half of Moonlight PIN pairing: find this certificate's pending
/// request on the fork, hand core's bridge the PIN, follow the attempt.
/// Nothing here talks to a real host, a real fork or a real certificate.
private actor FakeMediaHost: MediaPairingServing {
    struct Call: Sendable, Equatable { let name: String; let value: String }
    private(set) var calls: [Call] = []
    /// How many `discover` reads answer `media_pairing_request_not_unique`
    /// before the fork has registered the request.
    var quietDiscoveries = 0
    var discoverFailure: MediaPairingError?
    var submitFailure: MediaPairingError?
    /// Statuses handed back in order, as the host would walk the attempt.
    var walk: [String] = []

    func setQuietDiscoveries(_ value: Int) { quietDiscoveries = value }
    func setDiscoverFailure(_ value: MediaPairingError?) { discoverFailure = value }
    func setSubmitFailure(_ value: MediaPairingError?) { submitFailure = value }
    func setWalk(_ value: [String]) { walk = value }
    func record() -> [Call] { calls }

    func discoverMediaPairing(fingerprint: String) async throws -> MediaPairingRequestDTO {
        calls.append(.init(name: "discover", value: fingerprint))
        if let discoverFailure { throw discoverFailure }
        if quietDiscoveries > 0 {
            quietDiscoveries -= 1
            throw MediaPairingError(code: "media_pairing_request_not_unique", status: 409)
        }
        return .init(request_id: "7f6b8f6e-0b36-4a54-9d7a-2f2e6e2f1a11",
                     client_cert_sha256: fingerprint, status: "pending", expires_in_ms: 110_000)
    }

    func submitMediaPairing(requestID: String, fingerprint: String, pin: String) async throws -> MediaPairingAttemptDTO {
        calls.append(.init(name: "submit", value: "\(requestID)|\(fingerprint)|\(pin)"))
        if let submitFailure { throw submitFailure }
        return attempt(walk.isEmpty ? "awaiting_local_approval" : walk.removeFirst())
    }

    func mediaPairingStatus(attemptID: String) async throws -> MediaPairingAttemptDTO {
        calls.append(.init(name: "status", value: attemptID))
        return attempt(walk.isEmpty ? "failed" : walk.removeFirst())
    }

    func cancelMediaPairing(attemptID: String) async throws -> MediaPairingAttemptDTO {
        calls.append(.init(name: "cancel", value: attemptID))
        return attempt("cancelled")
    }

    private func attempt(_ status: String) -> MediaPairingAttemptDTO {
        .init(attempt_id: "b2f7c0a8-1e04-4f56-8a1c-6bb6fe4c0d92", device_id: "omodachi-spec-e3-ipad",
              request_id: "7f6b8f6e-0b36-4a54-9d7a-2f2e6e2f1a11", client_cert_sha256: String(repeating: "a", count: 64),
              status: status, reason: "", expires_in_ms: 100_000, paired: status == "paired",
              media_authorized: status == "paired", certificate_revocation_supported: false)
    }
}

@MainActor final class SunshinePairingTests: XCTestCase {
    private let fingerprint = String(repeating: "a", count: 64)

    private func settle(_ message: String, _ predicate: @escaping () -> Bool) async {
        for _ in 0..<600 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }

    /// The fork only registers the pending request once `getservercert` lands,
    /// which is after PairManager has already handed out the PIN. A single read
    /// would lose that race every time.
    func testDiscoveryWaitsForTheForkToRegisterTheRequest() async throws {
        let host = FakeMediaHost()
        await host.setQuietDiscoveries(3)
        await host.setWalk(["awaiting_local_approval", "awaiting_client_proof", "paired"])
        let flow = SunshinePairingFlow()
        var paired: Bool?
        var progress: [String] = []
        flow.onProgress = { progress.append($0) }
        flow.onFinished = { paired = $0 }
        flow.start(pin: "4821", fingerprint: fingerprint, service: host)
        await settle("the flow never finished") { paired != nil }
        XCTAssertEqual(paired, true)
        let calls = await host.record()
        XCTAssertEqual(calls.filter { $0.name == "discover" }.count, 4, "three empty reads, then the real one")
        let submit = try XCTUnwrap(calls.first { $0.name == "submit" })
        XCTAssertEqual(submit.value, "7f6b8f6e-0b36-4a54-9d7a-2f2e6e2f1a11|\(fingerprint)|4821")
        XCTAssertTrue(progress.contains(Strings.mediaPairingDone), progress.description)
    }

    /// The PIN is spent once; the flow never submits it twice.
    func testThePINIsSubmittedExactlyOnceAndTheAttemptIsThenPolled() async throws {
        let host = FakeMediaHost()
        await host.setWalk(["awaiting_local_approval", "awaiting_local_approval", "paired"])
        let flow = SunshinePairingFlow()
        var paired: Bool?
        flow.onFinished = { paired = $0 }
        flow.start(pin: "0000", fingerprint: fingerprint, service: host)
        await settle("the flow never finished") { paired != nil }
        let calls = await host.record()
        XCTAssertEqual(calls.filter { $0.name == "submit" }.count, 1)
        XCTAssertEqual(calls.filter { $0.name == "status" }.count, 2)
        XCTAssertEqual(paired, true)
    }

    /// A host that has not authorized this device is a named, actionable stop,
    /// not a spinner that runs to the deadline.
    func testAnUnauthorizedDeviceStopsWithTheHostsOwnReason() async throws {
        let host = FakeMediaHost()
        await host.setSubmitFailure(MediaPairingError(code: "media_permission_required", status: 403))
        let flow = SunshinePairingFlow()
        var paired: Bool?
        var progress: [String] = []
        flow.onProgress = { progress.append($0) }
        flow.onFinished = { paired = $0 }
        flow.start(pin: "1234", fingerprint: fingerprint, service: host)
        await settle("the flow never finished") { paired != nil }
        XCTAssertEqual(paired, false)
        XCTAssertEqual(progress.last,
                       Strings.remotePairStepFailed(Strings.remotePairStepSubmit, MediaPairingError(code: "media_permission_required", status: 403).userMessage))
    }

    /// `paired` is the only success. A terminal status that is not paired ends
    /// the flow rather than leaving it to the deadline.
    func testATerminalNonPairedStatusEndsTheFlow() async throws {
        let host = FakeMediaHost()
        await host.setWalk(["awaiting_local_approval", "expired"])
        let flow = SunshinePairingFlow()
        var paired: Bool?
        var progress: [String] = []
        flow.onProgress = { progress.append($0) }
        flow.onFinished = { paired = $0 }
        flow.start(pin: "1234", fingerprint: fingerprint, service: host)
        await settle("the flow never finished") { paired != nil }
        XCTAssertEqual(paired, false)
        XCTAssertEqual(progress.last, Strings.mediaPairingExpired)
    }

    /// An unmapped code names itself rather than becoming "something failed".
    func testAnUnmappedCodeNamesItself() {
        XCTAssertTrue(MediaPairingError(code: "media_pairing_invalid_response", status: 502)
            .userMessage.contains("media_pairing_invalid_response"))
    }

    func testEveryBridgeStatusAndErrorCodeHasItsOwnWords() {
        let codes = ["media_pairing_unavailable", "media_pairing_request_not_unique", "media_pairing_request_not_pending",
                     "media_certificate_already_associated", "media_pairing_binding_mismatch", "media_permission_required",
                     "media_pairing_invalid_pin", "media_pairing_capacity", "media_pairing_not_found", "media_pairing_timeout"]
        var seen = Set<String>()
        for code in codes {
            let message = MediaPairingError(code: code, status: 409).userMessage
            XCTAssertFalse(message.isEmpty, code)
            XCTAssertTrue(seen.insert(message).inserted, "duplicate copy for \(code)")
            XCTAssertFalse(message.contains(code), "\(code) should have copy of its own")
        }
    }

    // MARK: - PAIR-1: which Moonlight answer means what

    /// The failure this fixes: the fork still held this device's certificate
    /// while the host held no binding for it, so `PairManager` answered
    /// `alreadyPaired` *before* issuing `getservercert`. Nothing reached the
    /// host, nothing could be approved there, and the app read that silence as
    /// "paired" — it cleared the PIN and left the screen on the refusal that
    /// had started the pairing. The answer is a fresh pairing, not an ending.
    func testAForkThatAlreadyHoldsThisCertificateRepairsInsteadOfEnding() {
        XCTAssertEqual(SunshinePairingMapping.decide(.alreadyPaired(renewing: false), attemptInFlight: false), .renew)
        XCTAssertEqual(SunshinePairingMapping.decide(.alreadyPaired(renewing: false), attemptInFlight: true), .renew)
    }

    /// Once this attempt has already asked for the exchange regardless, a
    /// second "already paired" is a real dead end and has to say what the
    /// operator must do.
    func testASecondAlreadyPairedAfterARenewalIsANamedStop() {
        guard case .stop(let reason) = SunshinePairingMapping.decide(.alreadyPaired(renewing: true),
                                                                     attemptInFlight: true) else {
            return XCTFail("a renewal that still collides has to stop with a reason")
        }
        XCTAssertEqual(reason, ReasonText.message("media_pairing_binding_mismatch", domain: .media), reason)
    }

    /// An inspection answering "paired"/"unpaired" while an attempt owns the
    /// screen must not touch it: swallowing the PIN here is exactly what made
    /// the PIN flash and disappear with nothing pending on the host.
    func testAnInspectionResultNeverInterruptsAnAttemptInFlight() {
        XCTAssertEqual(SunshinePairingMapping.decide(.paired, attemptInFlight: true), .ignore)
        XCTAssertEqual(SunshinePairingMapping.decide(.unpaired, attemptInFlight: true), .ignore)
    }

    /// With nothing in flight the same two answers are the inspection's own
    /// result: one is success, the other is a status line and not a failure.
    func testWithNothingInFlightTheInspectionAnswersForItself() {
        XCTAssertEqual(SunshinePairingMapping.decide(.paired, attemptInFlight: false), .succeeded)
        guard case .note = SunshinePairingMapping.decide(.unpaired, attemptInFlight: false) else {
            return XCTFail("an unpaired host is a status line, not a failed session")
        }
    }

    func testAPINIsShownAndAnEmptyOneIsAStop() {
        XCTAssertEqual(SunshinePairingMapping.decide(.pin("4821"), attemptInFlight: false), .show(pin: "4821"))
        guard case .stop = SunshinePairingMapping.decide(.pin(""), attemptInFlight: false) else {
            return XCTFail("a pairing with no PIN cannot be presented as one that is waiting")
        }
    }

    /// "Waiting for the host" has to say how long it will still be waiting;
    /// without it a request that has already expired looks identical to one
    /// that has not.
    func testWaitingStatesCarryTheHostsOwnDeadline() throws {
        func attempt(_ status: String, _ expiresMS: Int) throws -> MediaPairingAttemptDTO {
            let body = #"""
            {"attempt_id":"b2f7c0a8-1e04-4f56-8a1c-6bb6fe4c0d92","device_id":"omodachi-spec-e3-ipad",
             "request_id":"7f6b8f6e-0b36-4a54-9d7a-2f2e6e2f1a11","client_cert_sha256":"\#(String(repeating: "a", count: 64))",
             "status":"\#(status)","reason":"","expires_in_ms":\#(expiresMS),"paired":false,
             "media_authorized":false,"certificate_revocation_supported":false}
            """#
            return try JSONDecoder().decode(MediaPairingAttemptDTO.self, from: Data(body.utf8))
        }
        XCTAssertEqual(try attempt("awaiting_local_approval", 96_400).remainingSeconds, 96)
        // PAIR-3: the panel has a card for this now, so the line names the
        // button and where it is instead of counting down to a `cancelled`.
        XCTAssertEqual(try attempt("awaiting_local_approval", 96_400).progress,
                       Strings.mediaPairingAwaitingApproval(Format.count(96)))
        XCTAssertTrue(try attempt("awaiting_local_approval", 96_400).needsLocalApproval)
        XCTAssertFalse(try attempt("pending", 1_400).needsLocalApproval)
        XCTAssertEqual(try attempt("pending", 1_400).progress, Strings.mediaPairingPinDelivered(Format.count(1)))
        // A terminal state says what happened, never a countdown to nothing.
        XCTAssertEqual(try attempt("expired", 0).progress, Strings.mediaPairingExpired)
    }

    /// `paired == true` in the attempt, not merely `status == "paired"`: the
    /// host reports the binding and the device allowance separately.
    func testPairedStatusWithoutTheBindingIsNotSuccess() throws {
        let body = #"""
        {"attempt_id":"b2f7c0a8-1e04-4f56-8a1c-6bb6fe4c0d92","device_id":"omodachi-spec-e3-ipad",
         "request_id":"7f6b8f6e-0b36-4a54-9d7a-2f2e6e2f1a11","client_cert_sha256":"\#(String(repeating: "a", count: 64))",
         "status":"paired","created_at":1789686000.0,"expires_at":1789686120.0,"updated_at":1789686060.0,
         "reason":"","expires_in_ms":60000,"paired":false,"media_authorized":false,
         "certificate_revocation_supported":false}
        """#
        let attempt = try JSONDecoder().decode(MediaPairingAttemptDTO.self, from: Data(body.utf8))
        XCTAssertTrue(attempt.isTerminal)
        XCTAssertFalse(attempt.paired)
        XCTAssertEqual(attempt.progress, Strings.mediaPairingNotAuthorized)
    }

    /// PAIR-3 §3.1. `pin_resubmission_required` means the one-time code was
    /// already spent, so no Approve can rescue this attempt. It used to read
    /// like any other "waiting for the host", which sent the user to press a
    /// button that would not have helped.
    func testASpentPinSaysToStartOverRatherThanToWait() throws {
        let body = #"""
        {"attempt_id":"b2f7c0a8-1e04-4f56-8a1c-6bb6fe4c0d92","device_id":"omodachi-spec-e3-ipad",
         "request_id":"7f6b8f6e-0b36-4a54-9d7a-2f2e6e2f1a11","client_cert_sha256":"\#(String(repeating: "a", count: 64))",
         "status":"awaiting_local_approval","reason":"pin_resubmission_required","expires_in_ms":60000,
         "paired":false,"media_authorized":false,"certificate_revocation_supported":false}
        """#
        let attempt = try JSONDecoder().decode(MediaPairingAttemptDTO.self, from: Data(body.utf8))
        XCTAssertTrue(attempt.needsPinResubmission)
        XCTAssertFalse(attempt.isTerminal)
        XCTAssertEqual(attempt.progress,
                       ReasonText.message("pin_resubmission_required", domain: .media))
    }
}
