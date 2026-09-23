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

    public mutating func releaseAll(_ reason: ReleaseReason) -> RemoteInputPayload {
        physicalModifierKeys = []; latchedModifiers = []; heldKeys = [:]; textSuppressed = []
        return .releaseAll(reason)
    }

    private static func isTextProducing(_ key: VirtualKey) -> Bool {
        (0x30...0x5A).contains(Int(key.rawValue)) || key == .space
    }
}
