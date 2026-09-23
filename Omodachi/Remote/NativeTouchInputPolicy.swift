import Foundation

/// Per-device preference: a new installation always uses direct touch.
/// Host display/input permissions are independent of this local interaction choice.
enum NativePointerPreference {
    static let key = "omodachi.remote.pointerMode"
    static func relativeTouchpad(in defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: key) == "touchpad"
    }
    static func save(relativeTouchpad: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(relativeTouchpad ? "touchpad" : "direct", forKey: key)
    }
}

enum NativeTouchpadAction: Equatable, Sendable {
    case move(dx: Double, dy: Double)
    case press
    case release
}
/// Relative touchpad: hover on movement, tap to click, long-press to drag.
/// Buttons never go down merely because a finger touched the trackpad.
struct NativeTouchpadGesture: Sendable {
    private var origin: (Double, Double)?
    private var previous: (Double, Double)?
    private var moved = false
    private var dragging = false
    mutating func begin(x: Double, y: Double) -> [NativeTouchpadAction] {
        let releases = cancel()
        guard x.isFinite, y.isFinite else { return releases }
        origin = (x,y); previous = (x,y); return releases
    }
    mutating func move(x: Double, y: Double) -> [NativeTouchpadAction] {
        guard x.isFinite, y.isFinite, let start = origin, let last = previous else { return [] }
        let substantial = hypot(x-start.0, y-start.1) > 3
        guard moved || dragging || substantial else { return [] }
        let from = moved || dragging ? last : start
        previous = (x,y); moved = moved || substantial
        return [.move(dx:x-from.0,dy:y-from.1)]
    }
    mutating func beginDrag() -> [NativeTouchpadAction] {
        guard origin != nil, !dragging else { return [] }
        dragging = true; return [.press]
    }
    mutating func end(x: Double, y: Double) -> [NativeTouchpadAction] {
        guard let start = origin else { return [] }
        let click = !moved && !dragging && x.isFinite && y.isFinite && hypot(x-start.0,y-start.1) <= 6
        let actions: [NativeTouchpadAction] = dragging ? [.release] : click ? [.press,.release] : []
        _ = cancel(); return actions
    }
    mutating func cancel() -> [NativeTouchpadAction] {
        let actions: [NativeTouchpadAction] = dragging ? [.release] : []
        origin = nil; previous = nil; moved = false; dragging = false
        return actions
    }
}

/// Preserve fractional touch deltas, with a bounded signed-16-bit native send.
struct NativeDeltaAccumulator: Sendable {
    private var x = 0.0
    private var y = 0.0
    mutating func take(dx: Double, dy: Double, scale: Double = 1) -> (Int, Int) {
        guard dx.isFinite, dy.isFinite, scale.isFinite, scale > 0 else { return (0,0) }
        let tx = min(32767, max(-32767, x + dx * scale))
        let ty = min(32767, max(-32767, y + dy * scale))
        let ix = Int(tx.rounded(.towardZero)), iy = Int(ty.rounded(.towardZero))
        x = tx-Double(ix); y = ty-Double(iy)
        return (ix,iy)
    }
    mutating func reset() { x = 0; y = 0 }
}

enum NativeShortcutText {
    /// Single ASCII keys may consume a one-shot modifier latch. Composed/IME
    /// text follows the existing UTF-8 text path, never fabricated HID codes.
    static func usage(_ text: String) -> UInt16? {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return nil }
        let code = scalar.value
        if (65...90).contains(code) { return UInt16(4 + code - 65) }
        if (97...122).contains(code) { return UInt16(4 + code - 97) }
        if (49...57).contains(code) { return UInt16(0x1e + code - 49) }
        switch code {
        case 48: return 0x27
        case 10,13: return 0x28
        case 9: return 0x2b
        case 32: return 0x2c
        default: return nil
        }
    }
}
