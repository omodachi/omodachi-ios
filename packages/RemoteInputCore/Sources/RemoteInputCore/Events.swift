import Foundation

public struct VirtualKey: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let backspace = VirtualKey(rawValue: 0x08)
    public static let tab = VirtualKey(rawValue: 0x09)
    public static let enter = VirtualKey(rawValue: 0x0D)
    public static let shift = VirtualKey(rawValue: 0x10)
    public static let control = VirtualKey(rawValue: 0xA2)
    public static let alt = VirtualKey(rawValue: 0xA4)
    public static let pause = VirtualKey(rawValue: 0x13)
    public static let capsLock = VirtualKey(rawValue: 0x14)
    public static let escape = VirtualKey(rawValue: 0x1B)
    public static let space = VirtualKey(rawValue: 0x20)
    public static let pageUp = VirtualKey(rawValue: 0x21)
    public static let pageDown = VirtualKey(rawValue: 0x22)
    public static let end = VirtualKey(rawValue: 0x23)
    public static let home = VirtualKey(rawValue: 0x24)
    public static let left = VirtualKey(rawValue: 0x25)
    public static let up = VirtualKey(rawValue: 0x26)
    public static let right = VirtualKey(rawValue: 0x27)
    public static let down = VirtualKey(rawValue: 0x28)
    public static let insert = VirtualKey(rawValue: 0x2D)
    public static let delete = VirtualKey(rawValue: 0x2E)
    public static let leftGUI = VirtualKey(rawValue: 0x5B)
    public static let rightGUI = VirtualKey(rawValue: 0x5C)
    public static let application = VirtualKey(rawValue: 0x5D)
}

public struct HIDUsage: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let a = HIDUsage(rawValue: 0x04)
    public static let b = HIDUsage(rawValue: 0x05)
    public static let c = HIDUsage(rawValue: 0x06)
    public static let d = HIDUsage(rawValue: 0x07)
    public static let e = HIDUsage(rawValue: 0x08)
    public static let f = HIDUsage(rawValue: 0x09)
    public static let g = HIDUsage(rawValue: 0x0A)
    public static let h = HIDUsage(rawValue: 0x0B)
    public static let i = HIDUsage(rawValue: 0x0C)
    public static let j = HIDUsage(rawValue: 0x0D)
    public static let k = HIDUsage(rawValue: 0x0E)
    public static let l = HIDUsage(rawValue: 0x0F)
    public static let m = HIDUsage(rawValue: 0x10)
    public static let n = HIDUsage(rawValue: 0x11)
    public static let o = HIDUsage(rawValue: 0x12)
    public static let p = HIDUsage(rawValue: 0x13)
    public static let q = HIDUsage(rawValue: 0x14)
    public static let r = HIDUsage(rawValue: 0x15)
    public static let s = HIDUsage(rawValue: 0x16)
    public static let t = HIDUsage(rawValue: 0x17)
    public static let u = HIDUsage(rawValue: 0x18)
    public static let v = HIDUsage(rawValue: 0x19)
    public static let w = HIDUsage(rawValue: 0x1A)
    public static let x = HIDUsage(rawValue: 0x1B)
    public static let y = HIDUsage(rawValue: 0x1C)
    public static let z = HIDUsage(rawValue: 0x1D)
    public static let one = HIDUsage(rawValue: 0x1E)
    public static let zero = HIDUsage(rawValue: 0x27)
    public static let returnOrEnter = HIDUsage(rawValue: 0x28)
    public static let escape = HIDUsage(rawValue: 0x29)
    public static let deleteOrBackspace = HIDUsage(rawValue: 0x2A)
    public static let tab = HIDUsage(rawValue: 0x2B)
    public static let spacebar = HIDUsage(rawValue: 0x2C)
    public static let minus = HIDUsage(rawValue: 0x2D)
    public static let equal = HIDUsage(rawValue: 0x2E)
    public static let leftBracket = HIDUsage(rawValue: 0x2F)
    public static let rightBracket = HIDUsage(rawValue: 0x30)
    public static let backslash = HIDUsage(rawValue: 0x31)
    public static let semicolon = HIDUsage(rawValue: 0x33)
    public static let quote = HIDUsage(rawValue: 0x34)
    public static let grave = HIDUsage(rawValue: 0x35)
    public static let comma = HIDUsage(rawValue: 0x36)
    public static let period = HIDUsage(rawValue: 0x37)
    public static let slash = HIDUsage(rawValue: 0x38)
    public static let capsLock = HIDUsage(rawValue: 0x39)
    public static let f1 = HIDUsage(rawValue: 0x3A)
    public static let f12 = HIDUsage(rawValue: 0x45)
    public static let printScreen = HIDUsage(rawValue: 0x46)
    public static let scrollLock = HIDUsage(rawValue: 0x47)
    public static let pause = HIDUsage(rawValue: 0x48)
    public static let insert = HIDUsage(rawValue: 0x49)
    public static let home = HIDUsage(rawValue: 0x4A)
    public static let pageUp = HIDUsage(rawValue: 0x4B)
    public static let deleteForward = HIDUsage(rawValue: 0x4C)
    public static let end = HIDUsage(rawValue: 0x4D)
    public static let pageDown = HIDUsage(rawValue: 0x4E)
    public static let rightArrow = HIDUsage(rawValue: 0x4F)
    public static let leftArrow = HIDUsage(rawValue: 0x50)
    public static let downArrow = HIDUsage(rawValue: 0x51)
    public static let upArrow = HIDUsage(rawValue: 0x52)
    public static let numLock = HIDUsage(rawValue: 0x53)
    public static let keypadSlash = HIDUsage(rawValue: 0x54)
    public static let keypadAsterisk = HIDUsage(rawValue: 0x55)
    public static let keypadMinus = HIDUsage(rawValue: 0x56)
    public static let keypadPlus = HIDUsage(rawValue: 0x57)
    public static let keypadEnter = HIDUsage(rawValue: 0x58)
    public static let keypadOne = HIDUsage(rawValue: 0x59)
    public static let keypadZero = HIDUsage(rawValue: 0x62)
    public static let keypadPeriod = HIDUsage(rawValue: 0x63)
    public static let application = HIDUsage(rawValue: 0x65)
    public static let leftControl = HIDUsage(rawValue: 0xE0)
    public static let leftShift = HIDUsage(rawValue: 0xE1)
    public static let leftAlt = HIDUsage(rawValue: 0xE2)
    public static let leftGUI = HIDUsage(rawValue: 0xE3)
    public static let rightControl = HIDUsage(rawValue: 0xE4)
    public static let rightShift = HIDUsage(rawValue: 0xE5)
    public static let rightAlt = HIDUsage(rawValue: 0xE6)
    public static let rightGUI = HIDUsage(rawValue: 0xE7)
}

public struct RemoteModifiers: OptionSet, Equatable, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let control = RemoteModifiers(rawValue: 1 << 0)
    public static let alt = RemoteModifiers(rawValue: 1 << 1)
    public static let shift = RemoteModifiers(rawValue: 1 << 2)
    public static let superKey = RemoteModifiers(rawValue: 1 << 3)
}

public enum KeyPhase: Equatable, Sendable { case down, up }
public enum MouseButton: Equatable, Sendable { case left, right, middle }
public enum ButtonPhase: Equatable, Sendable { case down, up }
public enum ReleaseReason: Equatable, Sendable { case gestureCancelled, disconnected, generationChanged, inputDisabled, explicit }

public enum RemoteInputPayload: Equatable, Sendable {
    case absolutePointer(x: Int, y: Int, width: Int, height: Int)
    case relativePointer(dx: Int, dy: Int)
    case mouseButton(MouseButton, ButtonPhase)
    case key(VirtualKey, KeyPhase, RemoteModifiers)
    case text(Data)
    case releaseAll(ReleaseReason)
}

/// Typed bridge contract. An OMRemoteClient adapter can translate each payload
/// to LiSendMouse*, LiSendKeyboardEvent2/LiSendUtf8TextEvent and releaseInputs.
public struct RemoteInputEvent: Equatable, Sendable {
    public let generation: UInt64
    /// Geometry epoch associated with the frame layout used to create this event.
    /// Zero is the default epoch for callers that do not use geometry transitions.
    public let geometryEpoch: UInt64
    public let payload: RemoteInputPayload

    public init(generation: UInt64, geometryEpoch: UInt64 = 0, payload: RemoteInputPayload) {
        self.generation = generation
        self.geometryEpoch = geometryEpoch
        self.payload = payload
    }

    /// Wire-name spelling for adapters that mirror the host protocol fields.
    public var geometry_epoch: UInt64 { geometryEpoch }
}

public protocol RemoteInputEventSink: AnyObject {
    func remoteInput(_ event: RemoteInputEvent)
}
