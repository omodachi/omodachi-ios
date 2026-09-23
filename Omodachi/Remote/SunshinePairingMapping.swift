import Foundation

/// What Moonlight's own pairing half reports back to the app.
///
/// `alreadyPaired` used to be folded into "re-read the host and report whatever
/// it says". It is not the same fact as the other two: the fork holding this
/// certificate says nothing about the *host* holding a binding for this device,
/// and `PairManager` returns it **before** issuing `getservercert` — so nothing
/// is ever put in front of the operator. Keeping it as its own case is what
/// lets the screen tell "waiting for an approval that exists" apart from
/// "waiting for one that was never asked for".
enum SunshinePairingEvent: Equatable, Sendable {
    case pin(String)
    case paired
    /// `renewing` is true when this attempt had already asked for the exchange
    /// regardless of what the fork holds, so a second "already paired" is a
    /// real dead end rather than something to retry.
    case alreadyPaired(renewing: Bool)
    case unpaired

    /// The PIN is a short-lived pairing secret. It is shown to nobody but the
    /// person holding the device and it never reaches a log.
    var traceName: String {
        switch self {
        case .pin: "pin"
        case .paired: "paired"
        case .alreadyPaired(let renewing): "already_paired(renewing: \(renewing))" // non-copy: a trace value
        case .unpaired: "unpaired"
        }
    }
}

/// What the Remote screen does with one such event.
enum SunshinePairingDecision: Equatable, Sendable {
    /// A real attempt is starting: show this PIN and follow the attempt.
    case show(pin: String)
    /// The fork and the host agree; the streaming identity is usable.
    case succeeded
    /// The fork holds this certificate and the host does not. Drop the fork's
    /// side and pair again, so a request actually appears for the operator.
    case renew
    /// An inspection result that arrived while an attempt owns the screen. The
    /// attempt is the authority; swallowing the PIN here is what left the user
    /// on a stale failure with nothing pending on the host.
    case ignore
    /// A status line, not a failure: nothing was being attempted.
    case note(String)
    /// A named stop, in the words of what the user must now do.
    case stop(String)

    var traceName: String {
        switch self {
        case .show: "show"
        case .succeeded: "succeeded"
        case .renew: "renew"
        case .ignore: "ignore"
        case .note: "note"
        case .stop(let reason): "stop(\(reason))"
        }
    }
}

/// The mapping, kept pure so every branch is exercised without a socket, a
/// certificate or a host.
enum SunshinePairingMapping {
    static func decide(_ event: SunshinePairingEvent, attemptInFlight: Bool) -> SunshinePairingDecision {
        switch event {
        case .pin(let pin):
            return pin.isEmpty ? .stop(Strings.remotePairNoPin) : .show(pin: pin)
        case .paired:
            return attemptInFlight ? .ignore : .succeeded
        case .alreadyPaired(let renewing):
            return renewing
                ? .stop(ReasonText.message("media_pairing_binding_mismatch", domain: .media))
                : .renew
        case .unpaired:
            return attemptInFlight ? .ignore : .note(ReasonText.message("media_pairing_required", domain: .remote))
        }
    }
}
