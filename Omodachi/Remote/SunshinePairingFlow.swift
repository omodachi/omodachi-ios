import Foundation

/// Moonlight PIN pairing, finished inside the app.
///
/// Moonlight's own `PairManager` hands out the four-digit PIN and issues the
/// `getservercert` the managed Sunshine fork suspends; core's
/// `/v1/media/pairing/*` bridge is what carries that PIN to the fork and
/// follows the attempt. So the app owns both halves and the user never types a
/// PIN anywhere: they approve the device once, on the host.
///
/// Steps 2-4 live here. Step 1 — generating the client certificate and sending
/// `getservercert` — belongs to `OMRemoteClient.pairHost`, which is what puts
/// the pending request on the fork in the first place.
@MainActor final class SunshinePairingFlow {
    var onProgress: ((String) -> Void)?
    var onFinished: ((Bool) -> Void)?
    private(set) var attemptID: String?
    private var work: Task<Void, Never>?
    var isRunning: Bool { work != nil }

    /// How long to wait for the host operator to approve. The attempt itself
    /// expires on the host after two minutes, so this only has to outlive that.
    private let approvalDeadline: Duration = .seconds(180)

    func start(pin: String, fingerprint: String, service: any MediaPairingServing) {
        cancel()
        work = Task { [weak self] in await self?.run(pin: pin, fingerprint: fingerprint, service: service) }
    }

    func cancel() {
        work?.cancel()
        work = nil
        if let attemptID {
            self.attemptID = nil
            // Best effort: an abandoned attempt expires on the host anyway.
            Task { [service = cancelService] in _ = try? await service?(attemptID) }
        }
    }

    /// Set by the owner so `cancel` can reach the host without this type
    /// holding a client of its own.
    var cancelService: (@Sendable (String) async throws -> MediaPairingAttemptDTO)?

    /// Which of the three calls a failure came from. A pairing that stops is
    /// otherwise reported the same way wherever it stopped.
    private enum Step: String {
        case discover, submit, poll
        var title: String {
            switch self {
            case .discover: Strings.remotePairStepDiscover
            case .submit: Strings.remotePairStepSubmit
            case .poll: Strings.remotePairStepPoll
            }
        }
    }

    private func run(pin: String, fingerprint: String, service: any MediaPairingServing) async {
        defer { work = nil }
        var step = Step.discover
        do {
            RemotePairingTrace.step("flow.start", "fingerprint=\(fingerprint)")
            onProgress?(Strings.remotePairFinding)
            let request = try await discover(fingerprint: fingerprint, service: service)
            RemotePairingTrace.step("discover.ok", "request=\(request.request_id) cert=\(request.client_cert_sha256) status=\(request.status) expires_ms=\(request.expires_in_ms)")
            guard !Task.isCancelled else { return }
            onProgress?(Strings.remotePairSubmitting)
            step = .submit
            var attempt = try await service.submitMediaPairing(requestID: request.request_id,
                                                               fingerprint: fingerprint, pin: pin)
            attemptID = attempt.attempt_id
            RemotePairingTrace.step("submit.ok", "attempt=\(attempt.attempt_id) device=\(attempt.device_id) status=\(attempt.status) reason=\(attempt.reason) paired=\(attempt.paired) media_authorized=\(attempt.media_authorized)")
            onProgress?(attempt.progress)
            step = .poll
            let deadline = ContinuousClock.now.advanced(by: approvalDeadline)
            while !attempt.isTerminal, ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                attempt = try await service.mediaPairingStatus(attemptID: attempt.attempt_id)
                RemotePairingTrace.step("poll", "attempt=\(attempt.attempt_id) status=\(attempt.status) reason=\(attempt.reason) paired=\(attempt.paired) expires_ms=\(attempt.expires_in_ms)")
                onProgress?(attempt.progress)
            }
            if attempt.paired { attemptID = nil }
            // PAIR-3: a wait that ran out while the host was still holding the
            // attempt for a local Approve is not "abandoned" - it is an
            // approval nobody pressed, and the line says where the button is.
            let unfinished = attempt.needsLocalApproval
                ? Strings.remotePairNeverApproved
                : Strings.remotePairGaveUp
            onProgress?(attempt.isTerminal ? attempt.progress : unfinished)
            onFinished?(attempt.paired)
        } catch let error as MediaPairingError {
            RemotePairingTrace.step("flow.failed", "step=\(step.rawValue) code=\(error.code) status=\(error.status)")
            onProgress?(Strings.remotePairStepFailed(step.title, error.userMessage))
            onFinished?(false)
        } catch is CancellationError {
        } catch {
            onProgress?(Strings.remotePairStepUnfinished(step.title))
            onFinished?(false)
        }
    }

    /// The fork registers the pending request only when `getservercert` lands,
    /// which is *after* `PairManager` hands out the PIN. So this is a short
    /// poll on the one code that means "not there yet", never a blind retry.
    private func discover(fingerprint: String, service: any MediaPairingServing) async throws -> MediaPairingRequestDTO {
        var last = MediaPairingError(code: "media_pairing_request_not_unique", status: 409)
        for _ in 0..<40 {
            do { return try await service.discoverMediaPairing(fingerprint: fingerprint) }
            catch let error as MediaPairingError where error.code == "media_pairing_request_not_unique" {
                last = error
                try await Task.sleep(for: .milliseconds(600))
            }
        }
        throw last
    }
}
