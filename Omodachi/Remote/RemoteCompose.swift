import Combine
import Foundation
import RemoteInputCore

/// REMOTE-INPUT-2. Type in the App, send to the computer.
///
/// Leo (2026-10-05): "输入法能做在 native 里么，而不是透传么？输入框在 app 里？
/// 否则选词不方便，哪怕英语也是." Until now the soft keyboard over the picture
/// typed key by key into the host: no candidates to pick, no predictions, no
/// autocorrect, pinyin only through the host's own fcitx5. Now the keyboard
/// writes into a field in the App — this device's whole input method works
/// there — and **Send** types the draft into the focused window on the
/// computer through core's text route (`wtype`), once.
///
/// * An **empty field passes keys through**: Backspace, Return (and with a
///   hardware keyboard Tab, Esc, the arrows, shortcuts) go to the host as keys,
///   so a terminal stays usable without typing anything into the field.
/// * **Keys mode** is the old per-key keyboard, for vim, shortcuts and games.
/// * REMOTE-INPUT-2b (Leo, on his iPad): no Send button and no "Enter after".
///   The keyboard's own return key (labelled Send) and a hardware Return type
///   the text **and** press Return, like typing on the computer and hitting
///   Enter. The one button at the field's trailing edge puts the text in
///   without Return.
///
/// The text never reaches a log or a trace; only counts do.
enum RemoteComposeText {
    /// What core published before REMOTE-INPUT-2 (`remote/text.py`), used when
    /// a host does not say.
    static let fallbackLimits = RemoteComposeLimits(maxChars: 1024, maxBytes: 4096)

    /// A line break is `\n`, whatever the paste carried (`\r\n`, `\r`). Other
    /// control characters cannot be typed — core refuses them — so they are
    /// dropped from what is sent; a tab stays (it is the Tab key).
    static func normalized(_ draft: String) -> String {
        var out = String.UnicodeScalarView()
        var previousCR = false
        for scalar in draft.unicodeScalars {
            if scalar == "\r" { out.append("\n"); previousCR = true; continue }
            defer { previousCR = false }
            if scalar == "\n" { if !previousCR { out.append(scalar) }; continue }
            if scalar == "\t" { out.append(scalar); continue }
            if scalar.properties.generalCategory == .control { continue }
            out.append(scalar)
        }
        return String(out)
    }

    /// Exactly what one send types: the draft, plus a Return for the
    /// keyboard's own return key (`wtype` types `\n` as the Return key);
    /// "insert only" types the draft alone.
    static func payload(_ draft: String, pressReturn: Bool) -> String {
        let text = normalized(draft)
        guard !text.isEmpty else { return "" }
        return pressReturn ? text + "\n" : text
    }

    /// The line breaks inside the draft itself — each one is a Return on the
    /// computer, so more than none asks first. The Return a send ends with is
    /// not counted: the person pressed it.
    static func lineBreaks(in draft: String) -> Int {
        normalized(draft).unicodeScalars.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    }
}

struct RemoteComposeLimits: Equatable, Sendable {
    var maxChars: Int
    var maxBytes: Int

    enum Overflow: Equatable, Sendable {
        /// Characters as core counts them (Unicode scalars, Python's `len`).
        case characters(count: Int, limit: Int)
        case bytes(count: Int, limit: Int)
    }

    func overflow(_ payload: String) -> Overflow? {
        let characters = payload.unicodeScalars.count
        if characters > maxChars { return .characters(count: characters, limit: maxChars) }
        let bytes = payload.utf8.count
        if bytes > maxBytes { return .bytes(count: bytes, limit: maxBytes) }
        return nil
    }

    static func from(_ input: RemoteCapabilitiesDTO.TextInput?) -> RemoteComposeLimits {
        let fallback = RemoteComposeText.fallbackLimits
        return RemoteComposeLimits(maxChars: max(1, input?.max_chars ?? fallback.maxChars),
                                   maxBytes: max(1, input?.max_bytes ?? fallback.maxBytes))
    }
}

/// How one attempt at a send went, as the composer needs to know it.
enum RemoteComposeOutcome: Equatable, Sendable {
    case typed
    /// The session is there but not live this moment (a resize): nothing was
    /// typed; wait for it and send the same id again.
    case notReady
    /// No answer — the request or its reply was lost. The host may or may not
    /// have typed it; the same id again is safe (core types an id once).
    case lost
    /// The session this send was for is gone; nothing was typed.
    case sessionGone
    /// The host answered no; the words to show.
    case refused(String)
}

/// REMOTE-INPUT-2. Which keys a focused compose field hands to the host.
///
/// iPad hardware keyboard, decided: the picture keeps the keyboard by default,
/// so with the bar down every key — shortcuts, arrows, Esc — goes straight to
/// the host as it always did. Summoning the bar puts this device's input
/// method (pinyin, predictions) in the field; there the field keeps what
/// edits text, and passes through what a terminal needs when the field is
/// empty. ⌘ chords that edit text (paste, copy, cut, select all, undo) always
/// stay in the field — pasting into it is half the point.
enum RemoteComposePassthrough {
    enum Decision: Equatable, Sendable {
        case local
        /// Down now, up when the key comes up (the host repeats it).
        case hold(usage: UInt16)
        /// One press with modifiers (the host's own shortcuts).
        case chord(usage: UInt16, modifiers: RemoteModifiers)
    }

    static let backspace: UInt16 = 0x2A
    static let returnKey: UInt16 = 0x28
    static let keypadEnter: UInt16 = 0x58
    static let tab: UInt16 = 0x2B
    static let escape: UInt16 = 0x29
    static let right: UInt16 = 0x4F, left: UInt16 = 0x50, down: UInt16 = 0x51, up: UInt16 = 0x52

    /// The keys an empty field sends on: editing and navigation, never text.
    static let navigation: Set<UInt16> = Set([backspace, returnKey, keypadEnter, tab, escape, right, left, down, up,
                                              0x4A, 0x4B, 0x4C, 0x4D, 0x4E]).union(Set(0x3A...0x45)) // home…pgdn, F1–F12

    /// ⌘ + these letters edit the field: A, C, V, X, Z.
    static let editingChords: Set<UInt16> = [0x04, 0x06, 0x19, 0x1B, 0x1D]

    static func decide(usage: UInt16, modifiers: RemoteModifiers, fieldEmpty: Bool, composing: Bool) -> Decision {
        if composing || HIDKeyboardMapper.modifier(for: HIDUsage(rawValue: usage)) != nil { return .local }
        let command = modifiers.contains(.superKey)
        if command, editingChords.contains(usage) { return .local }
        guard fieldEmpty else { return .local }
        if !modifiers.subtracting(.shift).isEmpty { return .chord(usage: usage, modifiers: modifiers) }
        guard navigation.contains(usage) else { return .local }
        return modifiers.isEmpty ? .hold(usage: usage) : .chord(usage: usage, modifiers: modifiers)
    }
}

/// REMOTE-INPUT-2. The compose bar's state: the draft, the two switches, and a
/// send that happens exactly once.
///
/// A send is bound to the session it was pressed in and carries one id for
/// all its attempts. It waits while the picture reconnects (it never types
/// blind into a desktop nobody can see), and gives up — keeping the draft —
/// if the picture does not come back. A lost reply is retried with the same
/// id, which the host types once, so a retry never types twice. A different
/// session is never typed into: its id is not the one the send was made for.
@MainActor final class RemoteComposer: ObservableObject {
    enum Phase: Equatable {
        case editing
        /// The draft has line breaks; the send asked first. `pressReturn` is
        /// whether it ends with Return (the return key) or not (insert only).
        case confirmLines(Int, pressReturn: Bool)
        /// Waiting for the picture to come back before sending.
        case waiting
        case sending
        /// It was typed. Shown briefly.
        case sent
        /// Not sent (or not known to be); the draft is still here.
        case failed(String)
    }

    @Published var draft = "" {
        didSet {
            guard draft != oldValue else { return }
            switch phase {
            case .sent, .failed, .confirmLines: phase = .editing
            default: break
            }
        }
    }
    @Published private(set) var phase: Phase = .editing
    /// The per-key keyboard instead of the field. Remembered per computer.
    @Published var keysMode = false { didSet { if keysMode != oldValue { save() } } }
    @Published private(set) var limits = RemoteComposeText.fallbackLimits
    /// The host types a whole draft in one request (`text_input.compose`). A
    /// host without it gets Keys mode, which works everywhere.
    @Published private(set) var hostSupportsCompose = false
    /// The input method is composing in the field (pinyin letters not yet
    /// committed): they are not the draft yet, but the field is not empty.
    @Published var composing = false
    /// Bumped to ask the field to take the keyboard, or to let it go.
    @Published private(set) var focusRequest = 0
    @Published private(set) var resignRequest = 0

    /// Wiring, set by the session controller.
    var currentSession: () -> String? = { nil }
    var isReady: (String) -> Bool = { _ in false }
    var deliver: (_ session: String, _ text: String, _ sendID: String) async -> RemoteComposeOutcome = { _, _, _ in .lost }

    /// How long a send waits for the picture to come back, and how often it
    /// looks. Injected by tests.
    var readyWait: Duration = .seconds(10)
    var readyPoll: Duration = .milliseconds(200)
    /// The pauses before the retries of a lost send (same id each time).
    var retryDelays: [Duration] = [.milliseconds(400), .seconds(1), .seconds(2)]
    var sentLinger: Duration = .milliseconds(1500)

    private let defaults: UserDefaults
    private var hostKey: String?
    private var sendTask: Task<Void, Never>?
    /// Every send ever started, for the trace and the test: one id per press.
    private(set) var sendIDs: [String] = []

    init(defaults: UserDefaults = AppDefaults.shared) { self.defaults = defaults }

    func payload(pressReturn: Bool) -> String { RemoteComposeText.payload(draft, pressReturn: pressReturn) }
    /// Measured with the Return the keyboard's send adds: the longer of the
    /// two things the field can type.
    var overflow: RemoteComposeLimits.Overflow? { limits.overflow(payload(pressReturn: true)) }
    var isEmpty: Bool { RemoteComposeText.normalized(draft).isEmpty }
    var isBusy: Bool { phase == .waiting || phase == .sending }
    /// Whether the field is the keyboard right now (rather than Keys mode).
    var usesField: Bool { hostSupportsCompose && !keysMode }
    var canSend: Bool { hostSupportsCompose && !isEmpty && overflow == nil && !isBusy }

    // MARK: Configuration

    static func storageKey(_ host: String) -> String { "omodachi.remote.compose.v1." + host }

    /// Keys mode is this computer's: vim on one box, a document on another.
    /// REMOTE-INPUT-2b: the stored `enterAfter` of the first build is
    /// ignored, and goes away with the next write.
    func configure(host: String?) {
        guard host != hostKey else { return }
        hostKey = host
        let stored = host.flatMap { defaults.dictionary(forKey: Self.storageKey($0)) } ?? [:]
        let keys = stored["keysMode"] as? Bool ?? false
        hostKey = nil // no writes while loading
        keysMode = keys
        hostKey = host
    }

    func apply(_ input: RemoteCapabilitiesDTO.TextInput?) {
        limits = RemoteComposeLimits.from(input)
        hostSupportsCompose = input?.available == true && input?.compose == true
    }

    private func save() {
        guard let hostKey else { return }
        defaults.set(["keysMode": keysMode], forKey: Self.storageKey(hostKey))
    }

    func requestFocus() { focusRequest &+= 1 }
    func requestResign() { resignRequest &+= 1 }

    // MARK: Sending

    /// The keyboard's return key (or a hardware Return) in a field with
    /// words: type them, then press Return.
    func send() { submit(pressReturn: true) }

    /// The button at the field's trailing edge: type the words, no Return.
    func insert() { submit(pressReturn: false) }

    private func submit(pressReturn: Bool) {
        guard canSend else { return }
        let breaks = RemoteComposeText.lineBreaks(in: draft)
        if breaks > 0, phase != .confirmLines(breaks, pressReturn: pressReturn) {
            phase = .confirmLines(breaks, pressReturn: pressReturn)
            return
        }
        start(pressReturn: pressReturn)
    }

    /// "Send anyway" after the question, the way it was asked.
    func confirmSend() {
        guard case .confirmLines(_, let pressReturn) = phase, canSend else { return }
        start(pressReturn: pressReturn)
    }

    func cancelPending() {
        switch phase {
        case .confirmLines, .failed, .sent: phase = .editing
        case .waiting:
            sendTask?.cancel(); sendTask = nil
            phase = .editing
        default: break
        }
    }

    private func start(pressReturn: Bool) {
        guard let session = currentSession() else {
            phase = .failed(Strings.remoteComposeSessionEnded)
            return
        }
        let text = payload(pressReturn: pressReturn)
        let id = UUID().uuidString.lowercased()
        sendIDs.append(id)
        // Busy at once: a second tap (or Return) before the task runs is
        // not a second send.
        phase = isReady(session) ? .sending : .waiting
        sendTask?.cancel()
        sendTask = Task { [weak self] in await self?.run(session: session, text: text, id: id) }
    }

    private func run(session: String, text: String, id: String) async {
        guard await waitUntilReady(session) else { return }
        phase = .sending
        RemoteSessionTrace.compose(session: session, event: "send", characters: text.unicodeScalars.count,
                                   lineBreaks: RemoteComposeText.lineBreaks(in: text))
        var lostAttempts = 0
        while !Task.isCancelled {
            switch await deliver(session, text, id) {
            case .typed:
                RemoteSessionTrace.compose(session: session, event: "typed", characters: text.unicodeScalars.count,
                                           lineBreaks: 0)
                draft = ""
                phase = .sent
                let linger = sentLinger
                Task { [weak self] in
                    try? await Task.sleep(for: linger)
                    if self?.phase == .sent { self?.phase = .editing }
                }
                return
            case .notReady:
                guard await waitUntilReady(session) else { return }
                phase = .sending
            case .lost:
                guard lostAttempts < retryDelays.count else {
                    RemoteSessionTrace.compose(session: session, event: "unconfirmed", characters: 0, lineBreaks: 0)
                    phase = .failed(Strings.remoteComposeUnconfirmed)
                    return
                }
                try? await Task.sleep(for: retryDelays[lostAttempts])
                lostAttempts += 1
            case .sessionGone:
                RemoteSessionTrace.compose(session: session, event: "session-gone", characters: 0, lineBreaks: 0)
                phase = .failed(Strings.remoteComposeSessionEnded)
                return
            case .refused(let words):
                RemoteSessionTrace.compose(session: session, event: "refused", characters: 0, lineBreaks: 0)
                phase = .failed(words)
                return
            }
        }
    }

    /// True once the picture of `session` is live; false (with the reason on
    /// screen) when the session changed or the picture did not come back.
    private func waitUntilReady(_ session: String) async -> Bool {
        if isReady(session) { return true }
        if phase != .waiting { phase = .waiting }
        let deadline = ContinuousClock.now + readyWait
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: readyPoll)
            if Task.isCancelled { return false }
            guard currentSession() == session else {
                phase = .failed(Strings.remoteComposeSessionEnded)
                return false
            }
            if isReady(session) { return true }
        }
        RemoteSessionTrace.compose(session: session, event: "not-reconnected", characters: 0, lineBreaks: 0)
        phase = .failed(Strings.remoteComposeNotReconnected)
        return false
    }
}

/// REMOTE-INPUT-2. The bar's keys row: what a soft keyboard cannot type and a
/// terminal or vim needs — Esc, Tab, the arrows (they repeat while held), ^C.
/// Each goes to the host as a key, whatever is in the field.
struct RemoteKeyCap: Identifiable, Equatable, Sendable {
    let id: String
    let face: String
    let usage: UInt16
    var modifiers: RemoteModifiers = []
    var repeats = false

    // non-copy: every face below is a key cap, not a sentence
    static let row: [RemoteKeyCap] = [
        .init(id: "esc", face: "esc", usage: RemoteComposePassthrough.escape), // non-copy
        .init(id: "tab", face: "⇥", usage: RemoteComposePassthrough.tab), // non-copy
        .init(id: "left", face: "←", usage: RemoteComposePassthrough.left, repeats: true), // non-copy
        .init(id: "down", face: "↓", usage: RemoteComposePassthrough.down, repeats: true), // non-copy
        .init(id: "up", face: "↑", usage: RemoteComposePassthrough.up, repeats: true), // non-copy
        .init(id: "right", face: "→", usage: RemoteComposePassthrough.right, repeats: true), // non-copy
        .init(id: "ctrl-c", face: "^C", usage: 0x06, modifiers: .control), // non-copy
    ]

    /// What VoiceOver says: the key's name in the reader's language.
    var spoken: String {
        switch id {
        case "esc": Strings.herdrKeyEscape
        case "tab": Strings.herdrKeyTab
        case "left": Strings.herdrKeyLeft
        case "down": Strings.herdrKeyDown
        case "up": Strings.herdrKeyUp
        case "right": Strings.herdrKeyRight
        default: Strings.herdrKeyCtrlC
        }
    }
}
