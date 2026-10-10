import Foundation

/// REMOTE-INPUT-1. How typed text reaches the host.
///
/// Leo typed "y" on the iPad and the host showed "U+": the soft keyboard's
/// text went as Moonlight's UTF-8 event, which the Sunshine fork types on
/// Linux as Ctrl+Shift+U + hex — the GTK/IBus trick that fcitx5 (Omarchy's
/// input method) and most terminals do not finish. Now there are two roads:
///
/// * **keys** — everything a US keyboard produces goes down the stream as the
///   key plus Shift, which is what a hardware keyboard already did;
/// * **host text** — what no key produces (中文 committed by this device's own
///   input method, emoji, accents) goes to core, which types it with `wtype`
///   into the focused window.
///
/// A key is a *position*; the host's keymap decides what it spells. Core says
/// which keymap that is, and on a host that is not plain `us` every printable
/// character takes the host-text road instead (Space, Return and Tab stay
/// keys: they are the same key on every layout).
struct RemoteTypingRoute: Equatable, Sendable {
    /// Core can type text here (`text_input.available`).
    var hostText: Bool
    /// US key positions spell what was typed.
    var asciiAsKeys: Bool
    /// Characters that need Shift go as host text, so no Shift goes down the
    /// stream (see `KeyboardInputEngine.type`). Whenever there is a text road.
    var shiftedAsText: Bool { hostText }

    static let keysOnly = RemoteTypingRoute(hostText: false, asciiAsKeys: true)

    static func from(_ capabilities: RemoteCapabilitiesDTO?) -> RemoteTypingRoute {
        guard let input = capabilities?.text_input, input.available else { return .keysOnly }
        return RemoteTypingRoute(hostText: true, asciiAsKeys: isUS(layout: input.layout, variant: input.variant))
    }

    /// An unreadable layout is taken as US: keys were the only road before,
    /// and a reading that failed is not evidence of another keymap.
    static func isUS(layout: String?, variant: String?) -> Bool {
        guard let layout = layout?.trimmingCharacters(in: .whitespaces), !layout.isEmpty else { return true }
        let plainVariant = (variant ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return layout.lowercased() == "us" && plainVariant
    }
}

/// Keeps the two roads in order, and keeps the key road at a pace the host
/// can take.
///
/// * A host-text request is a round trip; keys are not. Anything typed while a
///   request is in flight is held and replayed when it answers, so
///   "你好 world" never arrives as " world你好".
/// * The fork turns each key event into evdev events on a virtual keyboard,
///   and the kernel's evdev buffer for it holds 64 — about 32 key events.
///   One `insertText:` of a whole word or sentence (a prediction, dictation,
///   a paste into the keyboard) arrives as one burst, and on Leo's host
///   everything after the 32nd event of such a burst was lost ("Hell" of
///   "Hello, World!"). And fcitx5 relays every key on Omarchy; events that
///   land microseconds apart left Shift held there. So key events go out one
///   per `interval` once a burst starts — about 80 characters a second, which
///   a person typing never reaches and a predicted word does not notice.
@MainActor final class RemoteHostTextSequencer {
    typealias Deliver = @MainActor (String) async -> RemoteHostTextOutcome
    /// `nil` when the host has no text road; the text is then dropped (never
    /// sent as the Ctrl+Shift+U sequence) and `onUndelivered` says so.
    var deliver: Deliver?
    var onUndelivered: ((RemoteHostTextOutcome) -> Void)?
    /// A runaway queue is a stuck request, not typing.
    static let holdLimit = 4096
    static let burst = 1
    static let interval = Duration.milliseconds(3)

    private enum Step { case action(() -> Void), text(String) }
    private var busy = false
    private var queue: [Step] = []
    private var epoch: UInt64 = 0
    private var draining = false
    private var windowStart = ContinuousClock.now
    private var sentInWindow = 0

    var isHolding: Bool { busy || !queue.isEmpty }

    func perform(_ action: @escaping () -> Void) {
        guard queue.count < Self.holdLimit else { return }
        queue.append(.action(action))
        pump()
    }

    func type(_ text: String) {
        guard !text.isEmpty, queue.count < Self.holdLimit else { return }
        queue.append(.text(text))
        pump()
    }

    /// The session or its input generation ended: nothing held may land on
    /// whatever comes next, and an answer still on its way is ignored.
    func reset() {
        epoch &+= 1
        busy = false
        draining = false
        queue.removeAll()
    }

    private func pump() {
        while !busy, !draining, let step = queue.first {
            switch step {
            case .text(let text):
                queue.removeFirst()
                start(text)
            case .action(let action):
                let now = ContinuousClock.now
                if now - windowStart >= Self.interval { windowStart = now; sentInWindow = 0 }
                guard sentInWindow < Self.burst else { resume(at: windowStart + Self.interval); return }
                sentInWindow += 1
                queue.removeFirst()
                action()
            }
        }
    }

    private func resume(at deadline: ContinuousClock.Instant) {
        draining = true
        let token = epoch
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let self, self.epoch == token else { return }
            self.draining = false
            self.pump()
        }
    }

    private func start(_ text: String) {
        guard let deliver else { onUndelivered?(.unavailable); return }
        busy = true
        let token = epoch
        Task { @MainActor [weak self] in
            let outcome = await deliver(text)
            guard let self, self.epoch == token else { return }
            if outcome != .typed { self.onUndelivered?(outcome) }
            self.busy = false
            self.pump()
        }
    }
}

enum RemoteHostTextOutcome: Equatable, Sendable {
    case typed
    /// No route on this host (older core, no `wtype`, no session).
    case unavailable
    /// The host tried and failed.
    case failed

    static func from(_ error: Error) -> RemoteHostTextOutcome {
        guard let error = error as? RemoteRequestError else { return .failed }
        if error.status == 404 || error.code == "remote_text_unavailable" || error.code == "route_unavailable" {
            return .unavailable
        }
        return .failed
    }
}
