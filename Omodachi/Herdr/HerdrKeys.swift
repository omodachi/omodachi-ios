import Foundation

/// HERDR-3. Keys and text go into a pane as one-shot calls on core's bridge
/// (`POST /v1/herdr/panes/{p}/keys|text` → Herdr's `pane.send_keys` /
/// `pane.send_text`). Nothing here takes the pane or resizes it: that is the
/// Collie way, and it is the default. `control` is only the explicit
/// "Take keyboard".
///
/// Key names are Herdr's own grammar, probed on herdr 0.8.2 (HERDR-3 report
/// §1): `Escape`, `Tab`, `Enter`, `Space`, `Backspace`, the four arrows,
/// `F1`–`F12`, one printable character, and `ctrl+` / `alt+` / `shift+` in
/// front of one of those. `PageUp`, `PageDown`, `Home`, `End`, `Insert` and
/// `Delete` do not exist there.

/// One key on the keys row: what it says, what it sends, and whether holding
/// it repeats.
struct HerdrKeyCap: Identifiable, Equatable, Sendable {
    enum Name: String, Sendable {
        case escape, tab, shiftTab, enter, space, up, down, left, right, backspace, ctrlC, ctrlD, digit
    }

    let id: String
    /// The key cap's face: a glyph or Herdr's own key name, never a sentence.
    let face: String
    /// Herdr's spelling, exactly as `pane.send_keys` takes it.
    let key: String
    let name: Name
    /// The arrows and ⌫ repeat while held, the way a keyboard's do.
    var repeats: Bool { [.up, .down, .left, .right, .backspace].contains(name) }

    // non-copy: every face below is a key cap, not a sentence
    static let row: [HerdrKeyCap] = [
        .init(id: "esc", face: "esc", key: "Escape", name: .escape), // non-copy
        .init(id: "tab", face: "⇥", key: "Tab", name: .tab), // non-copy
        .init(id: "shift-tab", face: "⇧⇥", key: "shift+Tab", name: .shiftTab), // non-copy
        .init(id: "enter", face: "↩", key: "Enter", name: .enter), // non-copy
        .init(id: "space", face: "␣", key: "Space", name: .space), // non-copy
        .init(id: "up", face: "↑", key: "Up", name: .up), // non-copy
        .init(id: "down", face: "↓", key: "Down", name: .down), // non-copy
        .init(id: "left", face: "←", key: "Left", name: .left), // non-copy
        .init(id: "right", face: "→", key: "Right", name: .right), // non-copy
        // HERDR-9: deleting what is on the pane's input line, without Type.
        .init(id: "backspace", face: "⌫", key: "Backspace", name: .backspace), // non-copy
        .init(id: "ctrl-c", face: "^C", key: "ctrl+c", name: .ctrlC), // non-copy
        .init(id: "ctrl-d", face: "^D", key: "ctrl+d", name: .ctrlD), // non-copy
    ] + (1...5).map { .init(id: "digit-\($0)", face: "\($0)", key: "\($0)", name: .digit) }

    /// HERDR-4: on a phone the row splits after the arrows — Esc to → on the
    /// first line, ⌫ ^C ^D and the digits (then the presets) on the second.
    static let firstRow = 9
}

/// HERDR-9: one key that just went to the pane, as the strip of echoes
/// shows it (`y ↵ ⌫`), so a person typing into a terminal they cannot quite
/// see knows each key arrived. Gone after a moment.
struct HerdrKeyEcho: Identifiable, Equatable, Sendable {
    let id: Int
    /// A glyph or the character itself; never a sentence.
    let face: String
    /// What VoiceOver says for it, in the reader's language.
    let spoken: String
    let at: Date

    /// The most a strip shows: the latest few.
    static let maximum = 12

    /// Herdr's key name as a face: `Enter` → `↵`, `Backspace` → `⌫`,
    /// `ctrl+c` → `^C`, a character as itself.
    static func face(_ key: String) -> String {
        switch key {
        case "Enter": "↵" // non-copy: key glyphs
        case "Backspace": "⌫" // non-copy
        case "Escape": "esc" // non-copy
        case "Tab": "⇥" // non-copy
        case "shift+Tab": "⇧⇥" // non-copy
        case "Space": "␣" // non-copy
        case "Up": "↑" // non-copy
        case "Down": "↓" // non-copy
        case "Left": "←" // non-copy
        case "Right": "→" // non-copy
        default:
            if key.lowercased().hasPrefix("ctrl+"), key.count == 6 { "^" + key.suffix(1).uppercased() }
            else { key }
        }
    }

    /// The key's name as VoiceOver says it.
    static func spoken(_ key: String) -> String {
        switch key {
        case "Enter": Strings.herdrKeyEnter // non-copy: Herdr key names
        case "Backspace": Strings.herdrKeyBackspace // non-copy
        case "Escape": Strings.herdrKeyEscape // non-copy
        case "Tab": Strings.herdrKeyTab // non-copy
        case "shift+Tab": Strings.herdrKeyShiftTab // non-copy
        case "Space": Strings.herdrKeySpace // non-copy
        case "Up": Strings.herdrKeyUp // non-copy
        case "Down": Strings.herdrKeyDown // non-copy
        case "Left": Strings.herdrKeyLeft // non-copy
        case "Right": Strings.herdrKeyRight // non-copy
        default: face(key)
        }
    }

    /// A write as (face, spoken) pairs: each key, or a run of typed text
    /// shortened.
    static func items(_ write: HerdrWrite) -> [(face: String, spoken: String)] {
        switch write {
        case .keys(let keys): keys.map { (face($0), spoken($0)) }
        case .text(let text, _), .attached(let text, _): [(text.count > 12 ? String(text.prefix(11)) + "…" : text, text)]
        }
    }
}

/// What a write into a pane is: keys, or text that is typed and not submitted.
/// A composer send is the one write that asks for Enter, and it does so only
/// through `submit`, never by carrying `\r`.
enum HerdrWrite: Equatable, Sendable {
    case keys([String])
    case text(String, submit: Bool)
    /// ATTACH-1: a composer send with chips. It is always submitted; core
    /// swaps each marker for its file's path before typing.
    case attached(String, attachments: [AttachmentRef])
}

/// The bytes a keystroke would put on a PTY, read back into Herdr key names.
///
/// SwiftTerm turns the soft keyboard, a hardware keyboard and paste into the
/// bytes a terminal would receive. In Type mode those bytes do not go to a PTY
/// (that would need `control`); they go to `/keys`, so they are read back here
/// into the names Herdr's `send_keys` takes. A run of plain characters longer
/// than a few keys — a paste, a dictated word — is sent as text instead, in
/// order with the keys around it.
enum HerdrKeyEncoder {
    /// A run of plain characters at most this long goes as single-character
    /// keys; anything longer goes as one `/text`.
    static let maximumKeyRun = 8
    /// `pane.send_keys` takes at most this many in one call (core's cap).
    static let maximumKeysPerCall = 32

    struct Result: Equatable, Sendable {
        var writes: [HerdrWrite] = []
        /// A key Herdr has no name for (Home, End, PageUp…): dropped, and the
        /// caller says so rather than sending something else.
        var dropped = 0
    }

    static func writes(from bytes: [UInt8]) -> Result {
        var result = Result()
        var keys: [String] = []
        var run = ""

        func flushRun() {
            guard !run.isEmpty else { return }
            let single = run.allSatisfy { $0 == " " || ($0.unicodeScalars.count == 1 && keyable($0)) }
            if single && run.count <= maximumKeyRun {
                keys += run.map { $0 == " " ? "Space" : String($0) }
            } else {
                flushKeys()
                result.writes.append(.text(run, submit: false))
            }
            run = ""
        }
        func flushKeys() {
            guard !keys.isEmpty else { return }
            var start = 0
            while start < keys.count {
                let end = min(keys.count, start + maximumKeysPerCall)
                result.writes.append(.keys(Array(keys[start..<end])))
                start = end
            }
            keys = []
        }
        func key(_ name: String) {
            flushRun()
            keys.append(name)
        }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x1b:
                let (name, length) = escape(bytes, at: index)
                if let name { key(name) } else { flushRun(); result.dropped += 1 }
                index += length
                continue
            case 0x0d: key("Enter")
            case 0x0a: key("ctrl+j")
            case 0x09: key("Tab")
            case 0x7f: key("Backspace")
            case 0x08: key("ctrl+h")
            case 0x00: key("ctrl+Space")
            case 0x01...0x1a: key("ctrl+" + String(UnicodeScalar(byte + 0x60)))
            case 0x1c: key("ctrl+\\")
            case 0x1d: key("ctrl+]")
            case 0x1e: key("ctrl+^")
            case 0x1f: key("ctrl+_")
            default:
                // A UTF-8 sequence: take the whole character.
                let length = utf8Length(byte)
                let end = min(bytes.count, index + length)
                let text = String(decoding: bytes[index..<end], as: UTF8.self)
                run += text
                index = end
                continue
            }
            index += 1
        }
        flushRun()
        flushKeys()
        return result
    }

    /// One escape sequence starting at `index`: Herdr's name for it (or nil
    /// for a key Herdr cannot send) and how many bytes it used.
    static func escape(_ bytes: [UInt8], at index: Int) -> (String?, Int) {
        guard index + 1 < bytes.count else { return ("Escape", 1) }
        let next = bytes[index + 1]
        if next == UInt8(ascii: "[") || next == UInt8(ascii: "O") {
            // CSI / SS3: parameters, then one final byte in 0x40…0x7e.
            var cursor = index + 2
            var parameters = ""
            while cursor < bytes.count, !(0x40...0x7e).contains(bytes[cursor]) {
                parameters.append(Character(UnicodeScalar(bytes[cursor])))
                cursor += 1
            }
            guard cursor < bytes.count else { return (nil, bytes.count - index) }
            let final = Character(UnicodeScalar(bytes[cursor]))
            return (csi(parameters: parameters, final: final), cursor - index + 1)
        }
        if next == 0x1b { return ("Escape", 1) }
        // ESC + a character is Alt (SwiftTerm's `optionAsMetaKey`).
        let length = utf8Length(next)
        let end = min(bytes.count, index + 1 + length)
        let text = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
        if text.count == 1, let character = text.first, character.unicodeScalars.count == 1 {
            if character == " " { return ("alt+Space", end - index) }
            if keyable(character) { return ("alt+" + text, end - index) }
            if let control = text.unicodeScalars.first?.value, (1...26).contains(control) {
                return ("ctrl+alt+" + String(UnicodeScalar(UInt8(control) + 0x60)), end - index)
            }
        }
        return (nil, end - index)
    }

    private static func csi(parameters: String, final: Character) -> String? {
        let arrows: [Character: String] = ["A": "Up", "B": "Down", "C": "Right", "D": "Left"]
        let functions: [String: String] = ["11": "F1", "12": "F2", "13": "F3", "14": "F4",
                                           "15": "F5", "17": "F6", "18": "F7", "19": "F8",
                                           "20": "F9", "21": "F10", "23": "F11", "24": "F12"]
        let parts = parameters.split(separator: ";").map(String.init)
        let modifier = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        func modified(_ base: String) -> String {
            // xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
            let bits = max(0, modifier - 1)
            var names: [String] = []
            if bits & 4 != 0 { names.append("ctrl") }
            if bits & 2 != 0 { names.append("alt") }
            if bits & 1 != 0 { names.append("shift") }
            return (names + [base]).joined(separator: "+")
        }
        if let arrow = arrows[final] { return modified(arrow) }
        switch final {
        case "Z": return "shift+Tab"
        case "P": return modified("F1")
        case "Q": return modified("F2")
        case "R": return modified("F3")
        case "S": return modified("F4")
        case "~":
            guard let first = parts.first, let name = functions[first] else { return nil }
            return modified(name)
        default:
            // Home (H), End (F), PageUp (5~), Insert, Delete… Herdr has none.
            return nil
        }
    }

    /// A letter, a digit, punctuation or a symbol: what Herdr types as itself.
    static func keyable(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    private static func utf8Length(_ lead: UInt8) -> Int {
        lead >= 0xf0 ? 4 : lead >= 0xe0 ? 3 : lead >= 0xc0 ? 2 : 1
    }
}

/// `POST /v1/herdr/panes/{p}/text`'s answer (`contracts/herdr-text.schema.json`).
public struct HerdrTextResultDTO: Decodable, Equatable, Sendable {
    public let action: String
    public let pane: String
    public let delivered: Bool
    public let submitted: Bool
    /// `nil` when submitted; `not_requested`, `not_seen`, `submit_failed`
    /// otherwise. A code, turned into a sentence by `ReasonText`.
    public let reason: String?
    /// HERDR-4: what the screen showed when Enter was pressed — `tail`,
    /// `paste`, or `line` for a reply under eight characters, which is the
    /// weaker reading. Absent from a core older than HERDR-4.
    public let proof: String?

    /// A short reply whose only proof is its line: say "Sent", not "✓".
    public var lightProof: Bool { submitted && proof == "line" }
}

/// `POST /v1/herdr/panes/{p}/keys`'s answer (`contracts/herdr-keys.schema.json`).
public struct HerdrKeysResultDTO: Decodable, Equatable, Sendable {
    public let action: String
    public let pane: String
    public let sent: Int
}

/// What the composer says under itself after a send.
enum HerdrSendState: Equatable, Sendable {
    case idle
    case sending
    case sent
    /// HERDR-4: submitted on a weak proof (a short reply's line), so the
    /// line under the composer says "Sent" and asks for a look, without ✓.
    case sentLight
    /// Typed into the pane, Enter not pressed. The reason is core's code.
    case notSubmitted(reason: String)
    case failed(message: String)
}

/// HERDR-9: which hardware keys an empty composer hands to the pane, in
/// Herdr's names (REMOTE-INPUT-2b's rule, for `pane.send_keys`). Usages are
/// the USB HID keyboard page, as UIKit reports them.
enum HerdrComposePassthrough {
    static let backspace: UInt16 = 0x2A
    static let returnKey: UInt16 = 0x28
    static let keypadEnter: UInt16 = 0x58
    static let tab: UInt16 = 0x2B
    static let escape: UInt16 = 0x29
    static let right: UInt16 = 0x4F, left: UInt16 = 0x50, down: UInt16 = 0x51, up: UInt16 = 0x52

    /// The key to send, or nil when the press is the box's own. With words
    /// in the box, or an input method composing, every key edits the box;
    /// ⌘ is always the app's.
    static func key(usage: UInt16, shift: Bool, control: Bool, alternate: Bool, command: Bool,
                    empty: Bool, composing: Bool) -> String? {
        guard empty, !composing, !command else { return nil }
        // ^C, ^D, ^L … for an empty box, as at the terminal.
        if control, !alternate, (0x04...0x1D).contains(usage) {
            return "ctrl+" + String(UnicodeScalar(UInt8(usage - 0x04) + 0x61)) // non-copy: Herdr key grammar
        }
        guard !control, !alternate else { return nil }
        switch usage {
        case backspace: return shift ? nil : "Backspace" // non-copy: Herdr key names
        case returnKey, keypadEnter: return shift ? nil : "Enter" // non-copy
        case tab: return shift ? "shift+Tab" : "Tab" // non-copy
        case escape: return "Escape" // non-copy
        case up: return shift ? nil : "Up" // non-copy
        case down: return shift ? nil : "Down" // non-copy
        case left: return shift ? nil : "Left" // non-copy
        case right: return shift ? nil : "Right" // non-copy
        default: return nil
        }
    }
}
