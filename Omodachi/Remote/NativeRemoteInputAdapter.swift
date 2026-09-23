import Foundation
import RemoteInputCore
import UIKit

/// The package maps input and owns gesture/latch semantics. This adapter keeps
/// UIKit identity/geometry attached and forwards to OMRemoteClient's one C sink.
/// Input data never enters diagnostics, JSON, shell commands or SwiftUI state.
@MainActor final class NativeRemoteInputAdapter: NSObject, @preconcurrency OMRemoteInputReceiver, @preconcurrency RemoteInputEventSink {
    private weak var client: OMRemoteClient?
    private lazy var controller = RemoteInputController(sink: self)
    private var geometry = VideoInputGeometry(viewport: .init(x: 0, y: 0, width: 0, height: 0),
        videoRect: .init(x: 0, y: 0, width: 0, height: 0), streamPixels: .init(width: 0, height: 0))
    private var generation: UInt64?
    private var epoch: UInt64 = 0
    private var serial: UInt64 = 0
    private var touchpadGesture = NativeTouchpadGesture()
    private var relativeRemainder = NativeDeltaAccumulator()
    private var scrollRemainder = NativeDeltaAccumulator()
    private var latchedModifiers: RemoteModifiers = []
    private var directNativeTouch = false
    private var lastTouchPoint: InputPoint?

    init(client: OMRemoteClient) { self.client = client; super.init() }

    func update(viewport: CGSize, videoRect: CGRect, streamPixels: CGSize) {
        guard viewport.width.isFinite, viewport.height.isFinite,
              videoRect.origin.x.isFinite, videoRect.origin.y.isFinite,
              videoRect.width.isFinite, videoRect.height.isFinite,
              streamPixels.width.isFinite, streamPixels.height.isFinite,
              streamPixels.width >= 0, streamPixels.height >= 0,
              streamPixels.width <= 32767, streamPixels.height <= 32767 else { return }
        geometry = VideoInputGeometry(
            viewport: .init(x: 0, y: 0, width: viewport.width, height: viewport.height),
            videoRect: .init(x: videoRect.minX, y: videoRect.minY, width: videoRect.width, height: videoRect.height),
            streamPixels: .init(width: Int(streamPixels.width), height: Int(streamPixels.height)))
    }
    func activate(generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        if let previous = self.generation { controller.disconnect(generation: previous) }
        _ = touchpadGesture.cancel(); relativeRemainder.reset(); scrollRemainder.reset(); latchedModifiers = []
        self.generation = generation; epoch = geometryEpoch; serial = leaseSerial
        directNativeTouch = false; lastTouchPoint = nil
        controller.activate(generation: generation, geometryEpoch: geometryEpoch)
    }
    func deactivate(generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial) else { return }
        _ = touchpadGesture.cancel(); relativeRemainder.reset(); scrollRemainder.reset(); latchedModifiers = []
        controller.disconnect(generation: generation)
        self.generation = nil
        directNativeTouch = false; lastTouchPoint = nil
    }
    func pointer(phase: Int, point: CGPoint, generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial) else { return }
        let point = InputPoint(x: point.x, y: point.y)
        if phase == 0 { directNativeTouch = client?.supportsNativeTouch == true }
        if directNativeTouch {
            let mapped = geometry.map(point) ?? (phase >= 2 ? lastTouchPoint : nil)
            if let mapped {
                lastTouchPoint = mapped
                client?.sendTouch(phase: phase, x: Int32(mapped.x), y: Int32(mapped.y),
                    width: Int32(geometry.streamPixels.width), height: Int32(geometry.streamPixels.height),
                    generation: generation, geometryEpoch: geometryEpoch, leaseSerial: leaseSerial)
            }
            if phase >= 2 { directNativeTouch = false; lastTouchPoint = nil }
            return
        }
        switch phase {
        case 0: controller.absolutePress(point, geometry: geometry, generation: generation, geometryEpoch: geometryEpoch)
        case 1: controller.absoluteMove(point, geometry: geometry, generation: generation, geometryEpoch: geometryEpoch)
        case 2: controller.absoluteRelease(point, geometry: geometry, generation: generation, geometryEpoch: geometryEpoch)
        case 3: controller.cancelGesture(generation: generation, geometryEpoch: geometryEpoch)
        default: break
        }
    }
    func hardwarePointer(phase: Int, button: Int, point: CGPoint, generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial) else { return }
        let position = InputPoint(x: point.x, y: point.y)
        let mouseButton: MouseButton = button == 3 ? .right : button == 2 ? .middle : .left
        switch phase {
        case 0: controller.absolutePress(position, geometry: geometry, generation: generation, button: mouseButton, geometryEpoch: geometryEpoch)
        case 1: controller.absoluteMove(position, geometry: geometry, generation: generation, geometryEpoch: geometryEpoch)
        case 2: controller.absoluteRelease(position, geometry: geometry, generation: generation, button: mouseButton, geometryEpoch: geometryEpoch)
        default: controller.cancelGesture(generation: generation, geometryEpoch: geometryEpoch)
        }
    }
    func touchpad(phase: Int, point: CGPoint, generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial) else { return }
        let actions: [NativeTouchpadAction]
        switch phase {
        case 0: actions = touchpadGesture.begin(x: point.x, y: point.y); relativeRemainder.reset()
        case 1: actions = touchpadGesture.move(x: point.x, y: point.y)
        case 2: actions = touchpadGesture.end(x: point.x, y: point.y)
        case 4: actions = touchpadGesture.beginDrag()
        default: actions = touchpadGesture.cancel(); relativeRemainder.reset()
        }
        for action in actions {
            switch action {
            case .press: controller.relativeBegin(generation: generation, geometryEpoch: geometryEpoch)
            case .release: controller.relativeEnd(generation: generation, geometryEpoch: geometryEpoch)
            case .move(let dx, let dy):
                let scaled = geometry.relativeDelta(.init(x: dx, y: dy))
                let delta = relativeRemainder.take(dx: scaled.x, dy: scaled.y)
                if delta != (0,0) { client?.sendRelative(x: Int32(delta.0), y: Int32(delta.1), generation: generation, geometryEpoch: geometryEpoch, leaseSerial: leaseSerial) }
            }
        }
    }
    func scroll(phase: Int, delta: CGPoint, generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial) else { return }
        if phase == 0 { scrollRemainder.reset(); controller.cancelGesture(generation: generation, geometryEpoch: geometryEpoch) }
        else if phase == 1 {
            let amount = scrollRemainder.take(dx: -delta.x, dy: delta.y, scale: 3)
            if amount != (0,0) { client?.sendScroll(vertical: Int16(amount.1), horizontal: Int16(amount.0), generation: generation, geometryEpoch: geometryEpoch, leaseSerial: leaseSerial) }
        } else { scrollRemainder.reset() }
    }
    func click(button: Int, generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial) else { return }
        controller.relativeBegin(generation: generation, button: button == 3 ? .right : .left, geometryEpoch: geometryEpoch)
        controller.relativeEnd(generation: generation, geometryEpoch: geometryEpoch)
    }
    func latch(modifiers: UInt8, generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial) else { return }
        let value = RemoteModifiers(rawValue: modifiers & 0x0f)
        latchedModifiers.formUnion(value)
        controller.latch(value, generation: generation, geometryEpoch: geometryEpoch)
    }
    func key(usage: UInt16, down: Bool, generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial) else { return }
        controller.key(usage: .init(rawValue: usage), phase: down ? .down : .up, generation: generation, geometryEpoch: geometryEpoch)
        if down, HIDKeyboardMapper.modifier(for: .init(rawValue: usage)) == nil { latchedModifiers = [] }
    }
    func cancel(generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial) else { return }
        _ = touchpadGesture.cancel(); relativeRemainder.reset(); scrollRemainder.reset(); latchedModifiers = []
        controller.release(generation: generation, reason: .gestureCancelled)
    }
    func text(_ text: String, generation: UInt64, geometryEpoch: UInt64, leaseSerial: UInt64) {
        guard matches(generation, geometryEpoch, leaseSerial), text.utf8.count <= 65536 else { return }
        if !latchedModifiers.isEmpty, let usage = NativeShortcutText.usage(text) {
            controller.key(usage: .init(rawValue: usage), phase: .down, generation: generation, geometryEpoch: geometryEpoch)
            controller.key(usage: .init(rawValue: usage), phase: .up, generation: generation, geometryEpoch: geometryEpoch)
        } else { controller.text(text, generation: generation, geometryEpoch: geometryEpoch) }
        latchedModifiers = []
    }
    private func matches(_ generation: UInt64, _ epoch: UInt64, _ serial: UInt64) -> Bool {
        self.generation == generation && self.epoch == epoch && self.serial == serial
            && client?.generation == generation && client?.geometryEpoch == epoch && client?.leaseSerial == serial
    }
    func remoteInput(_ event: RemoteInputEvent) {
        guard let client, matches(event.generation, event.geometryEpoch, serial) else { return }
        switch event.payload {
        case .absolutePointer(let x, let y, let width, let height):
            guard let x = Int32(exactly: x), let y = Int32(exactly: y),
                  let width = Int32(exactly: width), let height = Int32(exactly: height) else { return }
            client.sendAbsolute(x: x, y: y, width: width, height: height,
                generation: event.generation, geometryEpoch: event.geometryEpoch, leaseSerial: serial)
        case .relativePointer(let dx, let dy):
            client.sendRelative(x: Int32(clamping: dx), y: Int32(clamping: dy), generation: event.generation, geometryEpoch: event.geometryEpoch, leaseSerial: serial)
        case .mouseButton(let button, let phase):
            let native: Int32 = switch button { case .left: 1; case .middle: 2; case .right: 3 }
            client.sendButton(native, down: phase == .down, generation: event.generation, geometryEpoch: event.geometryEpoch, leaseSerial: serial)
        case .key(let key, let phase, let modifiers):
            // RemoteInputCore modifiers are semantic; their raw bits are not
            // the common-c MODIFIER_* wire bits (SHIFT=1, CTRL=2, ALT=4, META=8).
            var mask: UInt8 = 0
            if modifiers.contains(.shift) { mask |= 1 }
            if modifiers.contains(.control) { mask |= 2 }
            if modifiers.contains(.alt) { mask |= 4 }
            if modifiers.contains(.superKey) { mask |= 8 }
            client.sendKey(key.rawValue, down: phase == .down, modifiers: mask,
                generation: event.generation, geometryEpoch: event.geometryEpoch, leaseSerial: serial)
        case .text(let data):
            client.sendText(data, generation: event.generation, geometryEpoch: event.geometryEpoch, leaseSerial: serial)
        case .releaseAll:
            client.releaseHeld(generation: event.generation, geometryEpoch: event.geometryEpoch, leaseSerial: serial)
        }
    }
}
