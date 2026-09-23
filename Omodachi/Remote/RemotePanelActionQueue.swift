import Foundation

struct RemotePanelActionIdentity: Equatable, Sendable {
    let run: UUID
    let generation: UInt64
    let epoch: UInt64
    let serial: UInt64
}
enum RemotePanelAction: Equatable, Sendable { case key(UInt16), modifier(UInt8), keyboard }
enum RemotePanelActionEffect: Equatable, Sendable { case key(UInt16), modifier(UInt8), showKeyboard }

/// Production coordinator's single-shot action gate. A Panel button is intent,
/// not permission to send before a new visible geometry/input gate is ready.
struct RemotePanelActionQueue: Sendable {
    private enum Phase: Sendable { case frame, keyboard, keyboardFrame }
    private struct Pending: Sendable {
        let identity: RemotePanelActionIdentity
        let action: RemotePanelAction
        let deadline: Double
        var afterObservation: UInt64
        var phase: Phase = .frame
    }
    private var pending: Pending?
    var hasPending: Bool { pending != nil }
    mutating func enqueue(_ action: RemotePanelAction, identity: RemotePanelActionIdentity, observation: UInt64, now: Double) {
        pending = Pending(identity: identity, action: action, deadline: now + 3, afterObservation: observation)
    }
    mutating func cancel() { pending = nil }
    mutating func keyboardHidden() {
        if let pending, pending.phase != .frame { self.pending = nil }
    }
    mutating func keyboardShown(observation: UInt64) {
        guard pending?.phase == .keyboard else { return }
        pending?.phase = .keyboardFrame; pending?.afterObservation = observation
    }
    mutating func take(identity: RemotePanelActionIdentity, observation: UInt64, gateOpen: Bool,
                       panelVisible: Bool, keyboardVisible: Bool, now: Double) -> RemotePanelActionEffect? {
        guard let current = pending else { return nil }
        guard current.identity == identity, now <= current.deadline, !panelVisible else { pending = nil; return nil }
        guard gateOpen, observation > current.afterObservation else { return nil }
        switch current.action {
        case .key(let usage): pending = nil; return .key(usage)
        case .keyboard: pending = nil; return .showKeyboard
        case .modifier(let mask):
            if current.phase == .frame {
                if keyboardVisible { pending = nil; return .modifier(mask) }
                pending?.phase = .keyboard
                return .showKeyboard
            }
            guard current.phase == .keyboardFrame, keyboardVisible else { return nil }
            pending = nil; return .modifier(mask)
        }
    }
}

/// Panel visibility and the single-shot action gate. A Panel button is intent,
/// not permission to send: the key waits for a fresh presented frame.
///
/// The Remote overlay used to carry a modifier-key toolbar of its own. Study 01
/// §03/§06 (A-14) and Study 02 §08 (A-24) both put that strip on the SSH
/// surface and nowhere else — under Remote the overlay is the Panel and the
/// Keybindings list, "原样滑出", and nothing above them. The gate below is what
/// survived the toolbar: it is how any surface — the Keybindings list, a
/// hardware ⌘ shortcut, the host's own recall — hands one key to the stream.
extension RemoteSessionController {

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { panelActions.cancel() }
        applyInputPolicy()
    }

    /// REMOTE-2 item 3: the gate is the session, not the picture. `isStreaming`
    /// is false for every moment between a resize and the frame that ends it,
    /// and MERGE-1 §6.3 hit exactly that: the one want that has to survive the
    /// overlay closing was refused before it was ever queued. The queue itself
    /// already refuses to *send* until the input gate is open on a fresh
    /// observation, and drops the want after three seconds if it never is.
    func enqueuePanelAction(_ action: RemotePanelAction) {
        guard hasSession, backend == .sunshine, let sunshine else { return }
        panelVisible = false
        panelActions.enqueue(action, identity: .init(run: run, generation: 0, epoch: 0, serial: 0),
                             observation: presentation, now: ProcessInfo.processInfo.systemUptime)
        sunshine.invalidateViewportGeometry()
        sunshine.observeCurrentFrame()
        // The Panel closing is the want; the next latched geometry is when the
        // backend can honour it (INPUT-2).
        applyInputPolicy()
        dispatchPanelAction()
    }

    func dispatchPanelAction() {
        guard let sunshine, backend == .sunshine else { return }
        let effect = panelActions.take(identity: .init(run: run, generation: 0, epoch: 0, serial: 0),
            observation: presentation, gateOpen: inputReady, panelVisible: panelVisible,
            keyboardVisible: false, now: ProcessInfo.processInfo.systemUptime)
        switch effect {
        case .key(let usage): sunshine.sendShortcut(usage)
        case .modifier(let mask): sunshine.latchModifier(mask)
        // A-43: a modifier latch needs a keyboard under it, so the queue can
        // raise one too; it reports back so the overlay button's state cannot
        // disagree with the keyboard actually on screen.
        case .showKeyboard: sunshine.showKeyboard(); keyboardWasRaisedByQueue()
        case nil: break
        }
    }
}
