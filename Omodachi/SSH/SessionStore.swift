import Combine
import Foundation
import SwiftTerm
import Combine
import UIKit

@MainActor final class SessionStore: ObservableObject {
    typealias Runtime = TerminalRuntime
    typealias TransportFactory = @MainActor (SessionDescriptor) -> any PTYTransport
    @Published private(set) var runtimes: [Runtime] = []
    @Published var selectedSurface = "panel"
    let trust: HostTrustCoordinator
    private let defaults: UserDefaults
    private let transportFactory: TransportFactory
    private var observations: [UUID: AnyCancellable] = [:]
    private let metadataKey = "omodachi.sessions.v3"
    /// UX-3 §2. One ladder per host, shared by every runtime in this process.
    /// `sshd` penalises an address, so the thing that must be paced is the
    /// device, not the session; a per-runtime guard cannot see the burst.
    let dialGate = SSHDialGate()
    /// UX-4 §2. What repairs a key the host no longer holds, shared by every
    /// runtime for the same reason the gate is.
    let keyOffer: (any SSHKeyOffering)?

    init(defaults: UserDefaults = .standard, trust: HostTrustCoordinator = HostTrustCoordinator(),
         keyOffer: (any SSHKeyOffering)? = SSHKeyOffer(), factory: TransportFactory? = nil) {
        self.defaults = defaults
        self.trust = trust
        self.keyOffer = keyOffer
        self.transportFactory = factory ?? { descriptor in
            if descriptor.host.mock { return MockPTYTransport(kind: descriptor.kind) }
            let launch: SSHLaunch = switch descriptor.kind {
            case .agent, .herdr: .fixedArgv(descriptor.argv)
            case .shell: .shell
            case .command: .fixedArgv(descriptor.argv)
            }
            let keyAccount = descriptor.host.keyAccount
            return SSHTransport(
                options: SSHConnectionOptions(host: descriptor.host.hostname, port: descriptor.host.port,
                    username: descriptor.host.username, privateKeyAccount: keyAccount, launch: launch),
                privateKeyProvider: { try SSHKeyStore().loadPrivateKey(account: keyAccount) },
                hostKeyValidator: { challenge in try await trust.validate(challenge) }
            )
        }
        // Migrate away from the early draft transcript key. Persist descriptors only.
        defaults.removeObject(forKey: "omodachi.terminal.sessions")
        if let data = defaults.data(forKey: metadataKey),
           let descriptors = try? JSONDecoder().decode([SessionDescriptor].self, from: data) {
            for descriptor in descriptors.suffix(12) { add(descriptor, restored: true) }
        }
    }
    @discardableResult func create(_ descriptor: SessionDescriptor) -> Runtime {
        // Non-command entries return to the same local session. Commands remain separate invocations.
        if descriptor.kind != .command, let existing = runtimes.first(where: {
            $0.descriptor.reuseIdentity == descriptor.reuseIdentity
        }) { return existing }
        let runtime = add(descriptor, restored: false)
        persist()
        return runtime
    }
    @discardableResult private func add(_ descriptor: SessionDescriptor, restored: Bool) -> Runtime {
        let runtime = Runtime(descriptor: descriptor, restored: restored, factory: transportFactory,
                              gate: dialGate, keyOffer: keyOffer)
        observations[runtime.id] = runtime.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        runtimes.append(runtime)
        return runtime
    }
    func runtime(id: UUID) -> Runtime? { runtimes.first { $0.id == id } }
    func remove(_ runtime: Runtime) async {
        await runtime.disconnect()
        runtimes.removeAll { $0.id == runtime.id }
        observations.removeValue(forKey: runtime.id)
        persist()
    }
    func setForeground(_ foreground: Bool) {
        if !foreground { trust.rejectAll() }
        for runtime in runtimes { runtime.setForeground(foreground) }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(runtimes.map(\.descriptor)) { defaults.set(data, forKey: metadataKey) }
    }
}

@MainActor final class TerminalRuntime: NSObject, ObservableObject, Identifiable, @preconcurrency TerminalViewDelegate {
    let descriptor: SessionDescriptor
    nonisolated let id: UUID
    @Published private(set) var state: SessionState = .disconnected
    @Published private(set) var columns = 80
    @Published private(set) var rows = 24
    @Published private(set) var errorMessage: String?
    @Published private(set) var connectionCount = 0
    @Published var fontSize: CGFloat = 14 { didSet { TerminalFont.apply(to: terminal, size: fontSize) } }
    @Published var ctrl = false { didSet { terminal.controlModifier = ctrl } }
    @Published var alt = false { didSet { terminal.metaModifier = alt } }
    @Published var showTouchKeys = true
    private let factory: SessionStore.TransportFactory
    /// UX-3 §2. Shared with every other runtime pointed at the same host.
    private let gate: SSHDialGate
    /// UX-4 §2. Shared too, and nil in the tests that have no host.
    private let keyOffer: (any SSHKeyOffering)?
    private var keyRepairTask: Task<Void, Never>?
    private var transport: (any PTYTransport)?
    private var connectTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<Data>.Continuation?
    private var resizeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    /// Whether this runtime is holding the host's one dial slot (UX-3 §2).
    private var dialReserved = false
    private var allowAutomaticReattach = true
    private var generation = UUID()
    private var everConnected: Bool
    private var autoReattach = false
    private var restored: Bool
    var onHome: (() -> Void)?

    lazy var terminal: NativeTerminalView = {
        let view = NativeTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), font: OmodachiTheme.uiFont(size: fontSize), options: TerminalOptions(cursorStyle: .steadyBlock))
        // TERM-1. The initialiser takes one font; the cascade needs all four.
        TerminalFont.apply(to: view, size: fontSize)
        view.terminalDelegate = self
        view.inputAccessoryView = nil
        view.optionAsMetaKey = true
        TerminalPalette.apply(to: view)
        view.accessibilityIdentifier = "terminal-emulator"
        view.onHome = { [weak self] in self?.onHome?() }
        return view
    }()

    init(descriptor: SessionDescriptor, restored: Bool, factory: @escaping SessionStore.TransportFactory,
         gate: SSHDialGate = SSHDialGate(), keyOffer: (any SSHKeyOffering)? = nil) {
        self.descriptor = descriptor
        self.id = descriptor.id
        self.restored = restored
        self.everConnected = restored
        self.factory = factory
        self.gate = gate
        self.keyOffer = keyOffer
        super.init()
    }
    /// Showing a newly-created surface starts its first connection. Restored
    /// descriptors stay disconnected until the user explicitly activates the
    /// retained Agent/Herdr target.
    func appeared() {
        if !restored && !everConnected && state == .disconnected { connect() }
    }

    /// Explicit activation is the boundary between cold-start restoration and
    /// user intent. It reattaches a restored Agent/Herdr session once, while
    /// leaving restored commands untouched and avoiding duplicate connections
    /// when the surface is revisited.
    ///
    /// UX-2 §1: a restored **shell** dials too. A-63 says entering ⑤ is the
    /// request, and after a cold start the persisted descriptor made the panel
    /// open on a dead terminal with a `Reconnect` button — the "open terminal"
    /// middle page AGENT-2 deleted, back under another name. A shell carries no
    /// host-side state to reattach to, so opening one is the same act whether
    /// or not this process has seen it before. A `command` still waits: it ran
    /// once and re-running it is a decision.
    func activate() {
        if restored && (descriptor.reattachable || descriptor.kind == .shell) {
            connect(explicit: true)
        } else {
            appeared()
        }
    }
    /// `asked` marks the two taps that are a person rather than a layout pass:
    /// the Reconnect button and a resume into the foreground. Only those clear
    /// the ladder — a panel that appears is not a request to dial again, which
    /// is precisely the distinction UX-2's ladder did not draw (UX-3 §2).
    func connect(explicit: Bool = false, asked: Bool = false) {
        guard connectTask == nil, state != .connected, state != .connecting else { return }
        if descriptor.kind == .command && everConnected {
            errorMessage = TerminalFailure.commandRestartRequiresConfirmation.localizedDescription
            return
        }
        guard explicit || !restored else { return }
        let identity = descriptor.host.sshConnectionIdentity
        if asked { gate.reset(identity) }
        if !descriptor.host.mock {
            switch gate.admit(identity) {
            case .admitted:
                dialReserved = true
            case .busy:
                SSHConnectionTrace.suppressed(traceTag, reason: "another attempt is already dialling \(descriptor.endpointLabel)")
                return
            case .backingOff(let seconds, let attempt):
                SSHConnectionTrace.suppressed(traceTag, reason: "backoff \(seconds)s after attempt \(attempt)")
                errorMessage = Strings.sshBackingOff("\(seconds)")
                scheduleLadderRetry(after: seconds)
                return
            case .exhausted(let attempts):
                SSHConnectionTrace.suppressed(traceTag, reason: "ladder exhausted after \(attempts) attempts")
                if errorMessage == nil { errorMessage = Strings.sshGaveUp }
                return
            }
        }
        restored = false
        if explicit { reconnectAttempts = 0; allowAutomaticReattach = true }
        reconnectTask?.cancel(); reconnectTask = nil
        let previous = transport
        outputTask?.cancel()
        inputContinuation?.finish(); inputTask?.cancel()
        resizeTask?.cancel()
        ctrl = false; alt = false
        errorMessage = nil
        state = .connecting
        let current = UUID()
        generation = current
        let connection = factory(descriptor)
        transport = connection
        outputTask = Task { [weak self] in
            do {
                for try await bytes in connection.output {
                    guard let self, self.generation == current else { return }
                    self.terminal.feed(byteArray: Array(bytes)[...])
                }
                guard let self, self.generation == current else { return }
                // UX-3 §2: a dial that already failed must stay failed. The
                // transport finishes its output stream as part of tearing the
                // socket down, so this line used to run *after* `fail()` and
                // overwrite `.failed` with `.disconnected` — which re-armed
                // `appeared()` and made every re-entry into ⑤ a fresh dial at
                // attempt zero. That is the loop `sshd` saw.
                if self.state != .failed {
                    self.state = self.descriptor.kind == .command ? .exited : .disconnected
                }
                self.terminal.resignFirstResponder()
                self.scheduleReattach()
            } catch {
                guard let self, self.generation == current else { return }
                self.fail(error)
            }
        }
        let input = AsyncStream<Data>.makeStream()
        inputContinuation = input.continuation
        inputTask = Task { [weak self] in
            for await bytes in input.stream {
                guard let self, self.generation == current else { return }
                do { try await connection.send(bytes) }
                catch { self.fail(error); break }
            }
        }
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == current { self.connectTask = nil } }
            do {
                await previous?.disconnect()
                guard self.generation == current, !Task.isCancelled else { return }
                try await connection.connect(cols: max(1, self.columns), rows: max(1, self.rows))
                guard self.generation == current, !Task.isCancelled else {
                    self.releaseDial(success: false)
                    await connection.disconnect()
                    return
                }
                self.state = .connected
                self.everConnected = true
                self.connectionCount += 1
                self.releaseDial(success: true)
                try await connection.resize(cols: max(1, self.columns), rows: max(1, self.rows))
            } catch {
                guard self.generation == current else { self.releaseDial(success: false); return }
                self.releaseDial(success: false)
                self.fail(error)
                await connection.disconnect()
            }
        }
    }
    /// The gate hands out one slot per host and takes it back here. It is
    /// idempotent on purpose: `disconnect()` can cancel a dial that would
    /// otherwise have reported for itself, and a slot nobody gives back is a
    /// host nobody ever dials again.
    private func releaseDial(success: Bool) {
        guard dialReserved else { return }
        dialReserved = false
        gate.finished(descriptor.host.sshConnectionIdentity, success: success)
    }

    private var traceTag: String { String(descriptor.id.uuidString.prefix(8)) }

    /// Wait out the rung, then ask again. This is what makes the ladder
    /// *visible*: there is a line in the trace for the wait and a line for the
    /// attempt, and the interval between them is the rung.
    private func scheduleLadderRetry(after seconds: Int) {
        guard reconnectTask == nil, allowAutomaticReattach, descriptor.kind != .command else { return }
        let current = generation
        SSHConnectionTrace.retry(traceTag, attempt: reconnectAttempts + 1, delay: seconds)
        reconnectAttempts += 1
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.generation == current,
                  self.state == .failed || self.state == .disconnected else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    func disconnect(suspended: Bool = false) async {
        generation = UUID()
        releaseDial(success: false)
        keyRepairTask?.cancel(); keyRepairTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        if !suspended { allowAutomaticReattach = false }
        connectTask?.cancel(); connectTask = nil
        resizeTask?.cancel(); resizeTask = nil
        inputContinuation?.finish(); inputContinuation = nil
        inputTask?.cancel(); inputTask = nil
        outputTask?.cancel(); outputTask = nil
        let old = transport
        transport = nil
        terminal.controlModifier = false; terminal.metaModifier = false
        ctrl = false; alt = false
        terminal.resignFirstResponder()
        state = suspended ? .suspended : .disconnected
        await old?.disconnect()
    }
    func setForeground(_ foreground: Bool) {
        if !foreground {
            let wasActive = state == .connected || state == .connecting
            autoReattach = descriptor.reattachable && wasActive && allowAutomaticReattach
            if wasActive { Task { await disconnect(suspended: true) } }
        } else if autoReattach {
            autoReattach = false
            // A fresh transport attaches only the persisted Herdr/agent target.
            // Coming back to a suspended session is a person returning to the
            // app, so it clears the ladder (UX-3 §2).
            Task { if state == .suspended { connect(explicit: true, asked: true) } }
        }
    }
    func sendBytes(_ bytes: Data) {
        guard state == .connected else { return }
        inputContinuation?.yield(bytes)
    }
    func key(_ bytes: [UInt8]) { sendBytes(Data(bytes)); terminal.becomeFirstResponder() }
    /// Repaint from the host theme and the host monospace face (§3).
    func applyAppearance() {
        TerminalFont.apply(to: terminal, size: fontSize)
        TerminalPalette.apply(to: terminal)
    }

    func dismissError() { errorMessage = nil }
    private func fail(_ error: Error) {
        state = .failed
        // Never expose peer-provided output, auth payloads, or full raw errors.
        if let failure = error as? TerminalFailure { errorMessage = failure.localizedDescription }
        // UX-2 §1: `timedOut` is the one connection failure whose text this app
        // wrote itself, about a step this app named. It is safe to show, and it
        // is the whole point of naming the steps.
        else if let ssh = error as? SSHTransportError, case .timedOut(let reason) = ssh {
            errorMessage = reason
        }
        else if let ssh = error as? SSHTransportError, case .missingPrivateKey = ssh {
            errorMessage = Strings.sshImportKeyFirst
        } else if let ssh = error as? SSHTransportError, case .unsupportedPrivateKey = ssh {
            errorMessage = Strings.sshUnsupportedKey
        } else if let ssh = error as? SSHTransportError, case .authenticationRejected = ssh {
            // UX-3 §2. The host answered, took the username and refused the
            // key. There is no second method to fall back to, so this is the
            // end of the attempt and it has a cause a person can act on.
            //
            // UX-4 §2: and one of the two things that cause it, this device can
            // put right on its own. So before the sentence that tells a person
            // to pair again, the device offers the host the key it is actually
            // holding — once — and dials again if the host takes it.
            if offerTheKeyOnce() { return }
            errorMessage = Strings.sshKeyRejected
        } else { errorMessage = Strings.sshConnectionEnded }
        // UX-3 §2: every kind of session now walks the ladder after a failed
        // dial, not only the two reattachable ones. The ladder exists to keep
        // this device out of `sshd`'s penalty box, and the penalty is applied
        // to the address, which every session shares.
        if let wait = gate.waitSeconds(descriptor.host.sshConnectionIdentity) {
            scheduleLadderRetry(after: wait)
        } else {
            scheduleReattach()
        }
    }
    /// UX-4 §2. The one automatic repair for this host, spent here.
    ///
    /// `true` means this failure has been taken over: the ladder is not started
    /// and the panel says what is happening, because the answer arrives in a
    /// second or two and a "retrying in 4s" underneath it would be describing a
    /// retry that is not the one about to happen.
    ///
    /// It is deliberately narrow. Only `publickey` refused reaches it, only a
    /// real host reaches it, and the budget lives on the shared gate, so a
    /// panel closed and reopened does not buy another one. A host that refuses
    /// the replacement as well gets exactly one more dial and then the sentence
    /// that was always there.
    private func offerTheKeyOnce() -> Bool {
        guard let keyOffer, !descriptor.host.mock, keyRepairTask == nil,
              !descriptor.host.companionURL.isEmpty,
              gate.claimKeyRepair(descriptor.host.sshConnectionIdentity) else { return false }
        let account = descriptor.host.companionURL
        let keyAccount = descriptor.host.keyAccount
        let tag = traceTag
        let current = generation
        SSHConnectionTrace.step(tag, "key-offer", detail: account)
        errorMessage = Strings.sshKeyReplacing
        keyRepairTask = Task { [weak self] in
            let outcome: Result<SSHKeyReport, Error>
            do { outcome = .success(try await keyOffer.offer(account: account, keyAccount: keyAccount)) }
            catch { outcome = .failure(error) }
            guard let self, self.generation == current else { return }
            self.keyRepairTask = nil
            switch outcome {
            case .success(let report):
                SSHConnectionTrace.step(tag, "key-replaced", detail: report.localFingerprint)
                self.errorMessage = nil
                // An explicit ask: this is a new fact about the host, not a
                // repeat of the attempt that just failed, so it does not queue
                // behind the ladder that failure built.
                self.connect(explicit: true, asked: true)
            case .failure(let error):
                let offer = error as? SSHKeyOfferError
                SSHConnectionTrace.failed(tag, step: "key-offer",
                                          reason: Self.offerReason(offer))
                self.errorMessage = Self.offerSentence(offer)
                // The key was not replaced, so the original failure stands and
                // the ladder it earned takes over from here.
                if let wait = self.gate.waitSeconds(self.descriptor.host.sshConnectionIdentity) {
                    self.scheduleLadderRetry(after: wait)
                }
            }
        }
        return true
    }

    /// The word for the trace, not for the screen: these go next to the other
    /// `step=` lines and line up against the host's journal, which is in
    /// English because `sshd` is.
    private static func offerReason(_ error: SSHKeyOfferError?) -> String {
        switch error {
        case .notPaired: "not paired" // non-copy: a trace word, never drawn
        case .noLocalKey: "no local key" // non-copy: a trace word, never drawn
        case .refused(let code): "refused \(code)"
        case .unreachable, .none: "unreachable"
        }
    }

    private static func offerSentence(_ error: SSHKeyOfferError?) -> String {
        switch error {
        // The host does not know this device any more, or this device no
        // longer holds the certificate its secret may be sent over. Neither is
        // repairable from here, and pairing is what repairs both.
        case .notPaired, .noLocalKey: Strings.sshKeyRejected
        case .refused: Strings.sshKeyReplaceRefused
        case .unreachable, .none: Strings.sshKeyReplaceUnreachable
        }
    }

    /// UX-2 §1. The old ladder was 1, 2, 4 seconds: three more connections
    /// inside seven, which is exactly the shape `sshd` answers with
    /// `srclimit_penalise` once any of them overruns `LoginGraceTime`. The
    /// device then cannot connect at all until the penalty lapses, and the
    /// retries keep renewing it. So the ladder starts after the host has had
    /// time to forget, and the attempt itself now closes its socket.
    static var reattachDelays: [Int] { SSHDialGate.backoff }

    private func scheduleReattach() {
        guard descriptor.reattachable, everConnected, allowAutomaticReattach,
              reconnectAttempts < Self.reattachDelays.count, reconnectTask == nil else { return }
        let current = generation
        let delay = Self.reattachDelays[reconnectAttempts]
        SSHConnectionTrace.retry(descriptor.id.uuidString.prefix(8).description,
                                 attempt: reconnectAttempts + 1, delay: delay)
        reconnectAttempts += 1
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == current, self.state == .failed || self.state == .disconnected else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0, newCols != columns || newRows != rows else { return }
        // Defer published state out of UIKit layout's synchronous callback.
        Task { [weak self] in
            guard let self else { return }
            self.columns = newCols; self.rows = newRows
            self.resizeTask?.cancel()
            let current = self.generation
            self.resizeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(70))
                guard let self, !Task.isCancelled, self.generation == current, self.state == .connected else { return }
                do { try await self.transport?.resize(cols: newCols, rows: newRows) }
                catch { self.fail(error) }
            }
        }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendBytes(Data(data))
        Task { [weak self] in
            self?.ctrl = source.controlModifier
            self?.alt = source.metaModifier
        }
    }
    func setTerminalTitle(source: TerminalView, title: String) {} // Do not collect host titles.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {} // No outbound services.
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {} // OSC52 does not write local clipboard.
    func clipboardRead(source: TerminalView) -> Data? { nil }
}
