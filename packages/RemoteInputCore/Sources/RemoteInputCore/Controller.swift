import Foundation

public final class RemoteInputController {
    public weak var sink: (any RemoteInputEventSink)?
    public private(set) var activeGeneration: UInt64?
    public private(set) var activeGeometryEpoch: UInt64?

    private var keyboard = KeyboardInputEngine()
    private var dragging = false
    private var dragButton: MouseButton = .left

    public init(sink: (any RemoteInputEventSink)? = nil) { self.sink = sink }

    /// Starts a new media input generation. The geometry epoch is attached to
    /// every event emitted for that generation so an adapter can reject input
    /// created against an older frame layout.
    @discardableResult
    public func activate(generation: UInt64, geometryEpoch: UInt64 = 0) -> [RemoteInputEvent] {
        var events: [RemoteInputEvent] = []
        if let oldGeneration = activeGeneration {
            events.append(contentsOf: releasePayload(
                generation: oldGeneration,
                geometryEpoch: activeGeometryEpoch ?? 0,
                reason: .generationChanged))
        }
        activeGeneration = generation
        activeGeometryEpoch = geometryEpoch
        keyboard = KeyboardInputEngine()
        dragging = false
        return deliver(events)
    }

    /// Compatibility spelling for protocol-shaped call sites.
    @discardableResult
    public func activate(generation: UInt64, geometry_epoch: UInt64) -> [RemoteInputEvent] {
        activate(generation: generation, geometryEpoch: geometry_epoch)
    }

    @discardableResult
    public func absoluteMove(_ point: InputPoint, geometry: VideoInputGeometry,
                             generation: UInt64, geometryEpoch: UInt64? = nil) -> [RemoteInputEvent] {
        guard let epoch = acceptedEpoch(geometryEpoch), activeGeneration == generation,
              let mapped = geometry.map(point),
              let x = pixelCoordinate(mapped.x), let y = pixelCoordinate(mapped.y) else { return [] }
        return deliver([event(generation, epoch, .absolutePointer(
            x: x, y: y, width: geometry.streamPixels.width, height: geometry.streamPixels.height))])
    }

    @discardableResult
    public func absolutePress(_ point: InputPoint, geometry: VideoInputGeometry,
                              generation: UInt64, button: MouseButton = .left,
                              geometryEpoch: UInt64? = nil) -> [RemoteInputEvent] {
        guard let epoch = acceptedEpoch(geometryEpoch), activeGeneration == generation,
              let mapped = geometry.map(point),
              let x = pixelCoordinate(mapped.x), let y = pixelCoordinate(mapped.y) else { return [] }
        let pointer = event(generation, epoch, .absolutePointer(
            x: x, y: y, width: geometry.streamPixels.width, height: geometry.streamPixels.height))
        let press = event(generation, epoch, .mouseButton(button, .down))
        dragging = true; dragButton = button
        return deliver([pointer, press])
    }

    @discardableResult
    public func absoluteRelease(_ point: InputPoint?, geometry: VideoInputGeometry,
                                generation: UInt64, button: MouseButton = .left,
                                geometryEpoch: UInt64? = nil) -> [RemoteInputEvent] {
        guard let epoch = acceptedEpoch(geometryEpoch), activeGeneration == generation else { return [] }
        var events: [RemoteInputEvent] = []
        if let point, let mapped = geometry.map(point),
           let x = pixelCoordinate(mapped.x), let y = pixelCoordinate(mapped.y) {
            events.append(event(generation, epoch, .absolutePointer(
                x: x, y: y, width: geometry.streamPixels.width, height: geometry.streamPixels.height)))
        }
        events.append(event(generation, epoch, .mouseButton(button, .up)))
        if button == dragButton { dragging = false }
        return deliver(events)
    }

    @discardableResult
    public func relativeBegin(generation: UInt64, button: MouseButton = .left,
                              geometryEpoch: UInt64? = nil) -> [RemoteInputEvent] {
        guard let epoch = acceptedEpoch(geometryEpoch), activeGeneration == generation, !dragging else { return [] }
        dragging = true
        dragButton = button
        return deliver([event(generation, epoch, .mouseButton(button, .down))])
    }

    @discardableResult
    public func relativeMove(_ delta: InputPoint, geometry: VideoInputGeometry,
                             generation: UInt64, sensitivity: Double = 1,
                             geometryEpoch: UInt64? = nil) -> [RemoteInputEvent] {
        guard let epoch = acceptedEpoch(geometryEpoch), activeGeneration == generation, dragging else { return [] }
        let mapped = geometry.relativeDelta(delta, sensitivity: sensitivity)
        let dx = Int(mapped.x.rounded()), dy = Int(mapped.y.rounded())
        guard dx != 0 || dy != 0 else { return [] }
        return deliver([event(generation, epoch, .relativePointer(dx: dx, dy: dy))])
    }

    @discardableResult
    public func relativeEnd(generation: UInt64, geometryEpoch: UInt64? = nil) -> [RemoteInputEvent] {
        guard let epoch = acceptedEpoch(geometryEpoch), activeGeneration == generation, dragging else { return [] }
        dragging = false
        return deliver([event(generation, epoch, .mouseButton(dragButton, .up))])
    }

    @discardableResult
    public func cancelGesture(generation: UInt64, geometryEpoch: UInt64? = nil) -> [RemoteInputEvent] {
        guard let epoch = acceptedEpoch(geometryEpoch), activeGeneration == generation, dragging else { return [] }
        dragging = false
        return deliver([
            event(generation, epoch, .mouseButton(dragButton, .up)),
            event(generation, epoch, .releaseAll(.gestureCancelled))
        ])
    }

    public func latch(_ modifier: RemoteModifiers, generation: UInt64,
                      geometryEpoch: UInt64? = nil) {
        guard acceptedEpoch(geometryEpoch) != nil, activeGeneration == generation else { return }
        keyboard.latch(modifier)
    }

    public func cancelLatch(generation: UInt64, geometryEpoch: UInt64? = nil) {
        guard acceptedEpoch(geometryEpoch) != nil, activeGeneration == generation else { return }
        keyboard.cancelLatch()
    }

    @discardableResult
    public func key(usage: HIDUsage, phase: KeyPhase, text: String? = nil,
                    generation: UInt64, geometryEpoch: UInt64? = nil) -> [RemoteInputEvent] {
        guard let epoch = acceptedEpoch(geometryEpoch), activeGeneration == generation,
              let payload = keyboard.key(usage: usage, phase: phase, text: text) else { return [] }
        return deliver([event(generation, epoch, payload)])
    }

    @discardableResult
    public func text(_ value: String, generation: UInt64,
                     geometryEpoch: UInt64? = nil) -> [RemoteInputEvent] {
        guard let epoch = acceptedEpoch(geometryEpoch), activeGeneration == generation,
              let payload = keyboard.text(value) else { return [] }
        return deliver([event(generation, epoch, payload)])
    }

    @discardableResult
    public func release(generation: UInt64, reason: ReleaseReason = .explicit) -> [RemoteInputEvent] {
        guard let epoch = activeGeometryEpoch, activeGeneration == generation else { return [] }
        let events = releasePayload(generation: generation, geometryEpoch: epoch, reason: reason)
        return deliver(events)
    }

    @discardableResult
    public func disconnect(generation: UInt64) -> [RemoteInputEvent] {
        guard let epoch = activeGeometryEpoch, activeGeneration == generation else { return [] }
        let events = deliver(releasePayload(generation: generation, geometryEpoch: epoch, reason: .disconnected))
        activeGeneration = nil
        activeGeometryEpoch = nil
        return events
    }

    private func acceptedEpoch(_ requested: UInt64?) -> UInt64? {
        guard let active = activeGeometryEpoch else { return nil }
        guard requested == nil || requested == active else { return nil }
        return active
    }

    private func releasePayload(generation: UInt64, geometryEpoch: UInt64,
                                reason: ReleaseReason) -> [RemoteInputEvent] {
        dragging = false
        _ = keyboard.releaseAll(reason)
        return [event(generation, geometryEpoch, .releaseAll(reason))]
    }

    private func event(_ generation: UInt64, _ geometryEpoch: UInt64,
                       _ payload: RemoteInputPayload) -> RemoteInputEvent {
        RemoteInputEvent(generation: generation, geometryEpoch: geometryEpoch, payload: payload)
    }

    private func pixelCoordinate(_ value: Double) -> Int? {
        let rounded = value.rounded()
        guard rounded.isFinite, rounded >= Double(Int.min), rounded <= Double(Int.max) else { return nil }
        return Int(rounded)
    }

    @discardableResult
    private func deliver(_ events: [RemoteInputEvent]) -> [RemoteInputEvent] {
        for inputEvent in events { sink?.remoteInput(inputEvent) }
        return events
    }
}
