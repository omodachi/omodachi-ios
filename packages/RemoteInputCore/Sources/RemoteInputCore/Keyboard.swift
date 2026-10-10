import Foundation

public enum HIDKeyboardMapper {
    public static func modifier(for usage: HIDUsage) -> RemoteModifiers? {
        switch usage.rawValue {
        case 0xE0, 0xE4: return .control
        case 0xE1, 0xE5: return .shift
        case 0xE2, 0xE6: return .alt
        case 0xE3, 0xE7: return .superKey
        default: return nil
        }
    }

    public static func virtualKey(for usage: HIDUsage) -> VirtualKey? {
        let raw = usage.rawValue
        if (0x04...0x1D).contains(raw) { return .init(rawValue: 0x41 + raw - 0x04) }
        if (0x1E...0x26).contains(raw) { return .init(rawValue: 0x31 + raw - 0x1E) }
        if raw == 0x27 { return .init(rawValue: 0x30) }
        if (0x3A...0x45).contains(raw) { return .init(rawValue: 0x70 + raw - 0x3A) }
        switch raw {
        case 0x28: return .enter; case 0x29: return .escape; case 0x2A: return .backspace; case 0x2B: return .tab; case 0x2C: return .space
        case 0x2D: return .init(rawValue: 0xBD); case 0x2E: return .init(rawValue: 0xBB)
        case 0x2F: return .init(rawValue: 0xDB); case 0x30: return .init(rawValue: 0xDD); case 0x31: return .init(rawValue: 0xDC)
        case 0x33: return .init(rawValue: 0xBA); case 0x34: return .init(rawValue: 0xDE); case 0x35: return .init(rawValue: 0xC0)
        case 0x36: return .init(rawValue: 0xBC); case 0x37: return .init(rawValue: 0xBE); case 0x38: return .init(rawValue: 0xBF)
        case 0x39: return .capsLock; case 0x46: return .init(rawValue: 0x2C); case 0x47: return .init(rawValue: 0x91); case 0x48: return .pause
        case 0x49: return .insert; case 0x4A: return .home; case 0x4B: return .pageUp; case 0x4C: return .delete; case 0x4D: return .end; case 0x4E: return .pageDown
        case 0x4F: return .right; case 0x50: return .left; case 0x51: return .down; case 0x52: return .up; case 0x53: return .init(rawValue: 0x90)
        case 0x54: return .init(rawValue: 0x6F); case 0x55: return .init(rawValue: 0x6A); case 0x56: return .init(rawValue: 0x6D); case 0x57: return .init(rawValue: 0x6B); case 0x58: return .enter
        case 0x59...0x61: return .init(rawValue: 0x61 + raw - 0x59); case 0x62: return .init(rawValue: 0x60); case 0x63: return .init(rawValue: 0x6E)
        case 0x65: return .application
        case 0xE0: return .init(rawValue: 0xA2); case 0xE1: return .init(rawValue: 0xA0); case 0xE2: return .init(rawValue: 0xA4); case 0xE3: return .leftGUI
        case 0xE4: return .init(rawValue: 0xA3); case 0xE5: return .init(rawValue: 0xA1); case 0xE6: return .init(rawValue: 0xA5); case 0xE7: return .rightGUI
        default: return nil
        }
    }
}

/// REMOTE-INPUT-1. A typed character as the key a US keyboard presses for it.
///
/// The soft keyboard hands the app text, not keys. Sending that text as
/// UTF-8 makes the Sunshine fork type it on Linux with the GTK/IBus
/// Ctrl+Shift+U + hex trick, which fcitx5 (Omarchy's input method) and most
/// non-GTK programs do not honour: Leo typed "y" and got "U+". So everything a
/// US keyboard can produce goes as the key itself plus Shift, exactly what a
/// hardware keyboard sends, and only what no key produces is left as text.
public struct KeyStroke: Equatable, Sendable {
    public let usage: HIDUsage
    public let shift: Bool
    public init(usage: HIDUsage, shift: Bool) { self.usage = usage; self.shift = shift }
}

public enum USKeyboardText {
    /// `nil` for anything that is not one printable US-ASCII character (or
    /// Return / Tab). Return is `\n`, `\r` or the `\r\n` grapheme.
    public static func stroke(for character: Character) -> KeyStroke? {
        if character == "\r\n" { return KeyStroke(usage: .returnOrEnter, shift: false) }
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, scalar.isASCII else { return nil }
        let code = UInt16(scalar.value)
        switch code {
        case 0x61...0x7A: return KeyStroke(usage: .init(rawValue: 0x04 + code - 0x61), shift: false)
        case 0x41...0x5A: return KeyStroke(usage: .init(rawValue: 0x04 + code - 0x41), shift: true)
        case 0x31...0x39: return KeyStroke(usage: .init(rawValue: 0x1E + code - 0x31), shift: false)
        case 0x30: return KeyStroke(usage: .zero, shift: false)
        case 0x0A, 0x0D: return KeyStroke(usage: .returnOrEnter, shift: false)
        case 0x09: return KeyStroke(usage: .tab, shift: false)
        case 0x20: return KeyStroke(usage: .spacebar, shift: false)
        default: break
        }
        guard let entry = punctuation[scalar] else { return nil }
        return KeyStroke(usage: entry.usage, shift: entry.shift)
    }

    /// Whether a stroke lands on the same character whatever the host's
    /// layout is: Return, Tab and Space sit on the same keys everywhere.
    public static func isLayoutIndependent(_ stroke: KeyStroke) -> Bool {
        stroke.usage == .returnOrEnter || stroke.usage == .tab || stroke.usage == .spacebar
    }

    private static let punctuation: [Unicode.Scalar: (usage: HIDUsage, shift: Bool)] = [
        "!": (.one, true), "@": (.init(rawValue: 0x1F), true), "#": (.init(rawValue: 0x20), true),
        "$": (.init(rawValue: 0x21), true), "%": (.init(rawValue: 0x22), true), "^": (.init(rawValue: 0x23), true),
        "&": (.init(rawValue: 0x24), true), "*": (.init(rawValue: 0x25), true), "(": (.init(rawValue: 0x26), true),
        ")": (.zero, true),
        "-": (.minus, false), "_": (.minus, true), "=": (.equal, false), "+": (.equal, true),
        "[": (.leftBracket, false), "{": (.leftBracket, true), "]": (.rightBracket, false), "}": (.rightBracket, true),
        "\\": (.backslash, false), "|": (.backslash, true), ";": (.semicolon, false), ":": (.semicolon, true),
        "'": (.quote, false), "\"": (.quote, true), "`": (.grave, false), "~": (.grave, true),
        ",": (.comma, false), "<": (.comma, true), ".": (.period, false), ">": (.period, true),
        "/": (.slash, false), "?": (.slash, true),
    ]

    /// A control character the soft keyboard has no business sending (Escape,
    /// DEL, C1). It is dropped rather than typed as text.
    public static func isUntypable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
    }
}

public struct KeyboardInputEngine: Sendable {
    /// Physical modifier usages are tracked independently so left and right
    /// keys can overlap. A key-repeat down does not create a second hold.
    private var physicalModifierKeys: Set<HIDUsage> = []
    private var latchedModifiers: RemoteModifiers = []
    private var heldKeys: [VirtualKey: RemoteModifiers] = [:]
    private var textSuppressed: Set<VirtualKey> = []

    public init() {}

    private var physicalModifiers: RemoteModifiers {
        physicalModifierKeys.reduce(into: RemoteModifiers()) { result, usage in
            if let modifier = HIDKeyboardMapper.modifier(for: usage) { result.insert(modifier) }
        }
    }

    public var modifiers: RemoteModifiers { physicalModifiers.union(latchedModifiers) }
    public var hasHeldKeys: Bool { !heldKeys.isEmpty }
    public var hasLatchedModifiers: Bool { !latchedModifiers.isEmpty }

    public mutating func latch(_ modifier: RemoteModifiers) { latchedModifiers.insert(modifier) }
    public mutating func cancelLatch() { latchedModifiers = [] }

    public mutating func key(usage: HIDUsage, phase: KeyPhase, text: String? = nil) -> RemoteInputPayload? {
        guard let key = HIDKeyboardMapper.virtualKey(for: usage) else { return nil }
        let modifier = HIDKeyboardMapper.modifier(for: usage)
        if phase == .down, modifier != nil {
            physicalModifierKeys.insert(usage)
        }
        let effective = modifiers
        if phase == .down, let text, !text.isEmpty, modifier == nil, Self.isTextProducing(key) {
            textSuppressed.insert(key)
            latchedModifiers = []
            return .text(Data(text.utf8))
        }
        if phase == .up, textSuppressed.remove(key) != nil { return nil }
        if phase == .down {
            heldKeys[key] = effective
            if modifier == nil { latchedModifiers = [] }
        } else {
            let snapshot = heldKeys.removeValue(forKey: key) ?? effective
            if modifier != nil { physicalModifierKeys.remove(usage) }
            return .key(key, .up, snapshot)
        }
        return .key(key, .down, effective)
    }

    public mutating func text(_ value: String) -> RemoteInputPayload? {
        guard !value.isEmpty else { return nil }
        latchedModifiers = []
        return .text(Data(value.utf8))
    }

    /// REMOTE-INPUT-1. Soft-keyboard text as key strokes, in order. A run of
    /// characters no US key produces stays one `.text` payload, which the
    /// adapter delivers on the host by other means; the strokes before and
    /// after it keep their place. `asciiAsKeys == false` is for a host whose
    /// layout is not US: then only Return, Tab and Space are keys and every
    /// other character is text, because a key is a position, not a character.
    /// A latched modifier (the bar's Ctrl, Alt, …) applies to the first stroke
    /// and is then spent, as it is for a hardware key.
    ///
    /// `shiftedAsText` sends the characters that need Shift (capitals, `!`,
    /// `@`, `"` …) as text too, so no Shift ever goes down the stream: on Leo's
    /// host a Shift from the fork's virtual keyboard — left or right, in any
    /// order, at any pace, with correct evdev events — stays held in the
    /// focused window once fcitx5 has relayed it ("Hi, Yo!" → "HI< YO!").
    /// It applies only while no modifier is held or latched: Ctrl+Shift+T is a
    /// shortcut, not text.
    public mutating func type(_ value: String, asciiAsKeys: Bool = true,
                              shiftedAsText: Bool = false) -> [RemoteInputPayload] {
        var payloads: [RemoteInputPayload] = []
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            payloads.append(.text(Data(pending.utf8)))
            pending = ""
            latchedModifiers = []
        }
        for character in value {
            if let stroke = USKeyboardText.stroke(for: character),
               asciiAsKeys || USKeyboardText.isLayoutIndependent(stroke),
               !(shiftedAsText && stroke.shift && modifiers.isEmpty),
               let key = HIDKeyboardMapper.virtualKey(for: stroke.usage) {
                flush()
                var effective = modifiers
                // Shift is pressed as its own key around the stroke, the way
                // a hardware keyboard (and Moonlight's own iOS client) does
                // it: Shift down, key down, key up, Shift up. Leaving it to
                // the fork's synthetic modifier (Shift down, key down, Shift
                // up, key up, microseconds apart) left Shift held on Leo's
                // host once fcitx5 relayed the keys: "Hi, Yo!" arrived as
                // "HI< YO!".
                let pressShift = stroke.shift && !effective.contains(.shift)
                if stroke.shift { effective.insert(.shift) }
                if pressShift { payloads.append(.key(Self.leftShift, .down, effective)) }
                payloads.append(.key(key, .down, effective))
                payloads.append(.key(key, .up, effective))
                if pressShift { payloads.append(.key(Self.leftShift, .up, modifiers)) }
                latchedModifiers = []
            } else if !USKeyboardText.isUntypable(character) {
                pending.append(character)
            }
        }
        flush()
        return payloads
    }

    static let leftShift = VirtualKey(rawValue: 0xA0)

    public mutating func releaseAll(_ reason: ReleaseReason) -> RemoteInputPayload {
        physicalModifierKeys = []; latchedModifiers = []; heldKeys = [:]; textSuppressed = []
        return .releaseAll(reason)
    }

    private static func isTextProducing(_ key: VirtualKey) -> Bool {
        (0x30...0x5A).contains(Int(key.rawValue)) || key == .space
    }
}
