import XCTest
@testable import RemoteInputCore

final class RemoteInputCoreTests: XCTestCase {
    func testNinePointMappingLetterboxOutsideSafeAreaAndTransform() {
        let geometry = VideoInputGeometry(
            viewport: .init(x: 0, y: 0, width: 1000, height: 800),
            videoRect: .init(x: 100, y: 100, width: 800, height: 600),
            streamPixels: .init(width: 1920, height: 1080),
            safeAreaInsets: .init(top: 20, leading: 10, bottom: 20, trailing: 10))
        let points = [
            (InputPoint(x: 100, y: 100), InputPoint(x: 0, y: 0)),
            (InputPoint(x: 500, y: 100), InputPoint(x: 960, y: 0)),
            (InputPoint(x: 900, y: 100), InputPoint(x: 1919, y: 0)),
            (InputPoint(x: 100, y: 400), InputPoint(x: 0, y: 540)),
            (InputPoint(x: 500, y: 400), InputPoint(x: 960, y: 540)),
            (InputPoint(x: 900, y: 400), InputPoint(x: 1919, y: 540)),
            (InputPoint(x: 100, y: 700), InputPoint(x: 0, y: 1079)),
            (InputPoint(x: 500, y: 700), InputPoint(x: 960, y: 1079)),
            (InputPoint(x: 900, y: 700), InputPoint(x: 1919, y: 1079))
        ]
        for (point, expected) in points { assertPointEqual(geometry.map(point), expected) }
        XCTAssertNil(geometry.map(.init(x: 50, y: 400)))
        XCTAssertNil(geometry.map(.init(x: 500, y: 50)))
        XCTAssertNil(geometry.map(.init(x: 5, y: 400)))

        let transformed = VideoInputGeometry(viewport: geometry.viewport, videoRect: geometry.videoRect,
            streamPixels: geometry.streamPixels, streamTransform: .init(scaleX: 0.5, scaleY: 0.5, offsetX: 100, offsetY: 200))
        assertPointEqual(transformed.map(.init(x: 500, y: 400)), .init(x: 580, y: 470))
    }

    func testRelativePointerDragAndCancel() {
        let geometry = VideoInputGeometry(viewport: .init(x: 0, y: 0, width: 1000, height: 800), videoRect: .init(x: 0, y: 0, width: 1000, height: 800), streamPixels: .init(width: 2000, height: 1600))
        let controller = RemoteInputController(); XCTAssertEqual(controller.activate(generation: 7), [])
        XCTAssertEqual(controller.relativeBegin(generation: 7), [event(7, .mouseButton(.left, .down))])
        XCTAssertEqual(controller.relativeMove(.init(x: 10, y: -5), geometry: geometry, generation: 7), [event(7, .relativePointer(dx: 20, dy: -10))])
        XCTAssertEqual(controller.cancelGesture(generation: 7), [event(7, .mouseButton(.left, .up)), event(7, .releaseAll(.gestureCancelled))])
        XCTAssertEqual(controller.relativeMove(.init(x: 10, y: 10), geometry: geometry, generation: 7), [])
    }

    func testLatchConsumesOnNextKeyAndCancelDoesNotLeak() {
        let controller = RemoteInputController(); _ = controller.activate(generation: 2)
        controller.latch(.control, generation: 2)
        XCTAssertEqual(controller.key(usage: .a, phase: .down, generation: 2), [event(2, .key(.init(rawValue: 0x41), .down, .control))])
        XCTAssertEqual(controller.key(usage: .a, phase: .up, generation: 2), [event(2, .key(.init(rawValue: 0x41), .up, .control))])
        controller.latch(.alt, generation: 2); controller.cancelLatch(generation: 2)
        XCTAssertEqual(controller.key(usage: .b, phase: .down, generation: 2), [event(2, .key(.init(rawValue: 0x42), .down, []))])
    }

    func testDisconnectReleasesHeldInputAndOldGenerationIsIgnored() {
        let controller = RemoteInputController(); _ = controller.activate(generation: 10)
        _ = controller.relativeBegin(generation: 10)
        _ = controller.key(usage: .leftControl, phase: .down, generation: 10)
        XCTAssertEqual(controller.disconnect(generation: 10), [event(10, .releaseAll(.disconnected))])
        XCTAssertEqual(controller.key(usage: .a, phase: .down, generation: 10), [])
        _ = controller.activate(generation: 11)
        XCTAssertEqual(controller.text("中文✓", generation: 10), [])
        XCTAssertEqual(controller.text("中文✓", generation: 11), [event(11, .text(Data("中文✓".utf8)))])
    }

    func testKeyboardMappingAndTextSuppressesDuplicatePrintableKey() {
        XCTAssertEqual(HIDKeyboardMapper.virtualKey(for: .a), .init(rawValue: 0x41))
        XCTAssertEqual(HIDKeyboardMapper.virtualKey(for: .zero), .init(rawValue: 0x30))
        XCTAssertEqual(HIDKeyboardMapper.virtualKey(for: .f12), .init(rawValue: 0x7B))
        XCTAssertEqual(HIDKeyboardMapper.virtualKey(for: .leftArrow), .left)
        XCTAssertEqual(HIDKeyboardMapper.virtualKey(for: .leftControl), .init(rawValue: 0xA2))
        XCTAssertEqual(HIDKeyboardMapper.modifier(for: .rightGUI), .superKey)

        let controller = RemoteInputController(); _ = controller.activate(generation: 4)
        XCTAssertEqual(controller.key(usage: .a, phase: .down, text: "a", generation: 4), [event(4, .text(Data("a".utf8)))])
        XCTAssertEqual(controller.key(usage: .a, phase: .up, generation: 4), [])
        XCTAssertEqual(controller.key(usage: .returnOrEnter, phase: .down, generation: 4), [event(4, .key(.enter, .down, []))])
    }


    func testGeometryEpochIsAttachedAndStaleGeometryIsRejected() {
        let geometry = VideoInputGeometry(
            viewport: .init(x: 0, y: 0, width: 100, height: 100),
            videoRect: .init(x: 0, y: 0, width: 100, height: 100),
            streamPixels: .init(width: 100, height: 100))
        let controller = RemoteInputController()
        _ = controller.activate(generation: 8, geometryEpoch: 12)

        let current = controller.absoluteMove(.init(x: 50, y: 50), geometry: geometry,
                                              generation: 8, geometryEpoch: 12)
        XCTAssertEqual(current.first?.geometryEpoch, 12)
        XCTAssertEqual(controller.absoluteMove(.init(x: 50, y: 50), geometry: geometry,
                                                generation: 8, geometryEpoch: 11), [])
        XCTAssertEqual(controller.text("ok", generation: 8, geometryEpoch: 12).first?.geometry_epoch, 12)
        XCTAssertEqual(controller.key(usage: .a, phase: .down, generation: 8, geometryEpoch: 11), [])
    }

    func testActivateDeliversGenerationReleaseExactlyOnce() {
        let sink = RecordingSink()
        let controller = RemoteInputController(sink: sink)
        _ = controller.activate(generation: 1, geometryEpoch: 4)
        _ = controller.key(usage: .leftControl, phase: .down, generation: 1)
        let returned = controller.activate(generation: 2, geometryEpoch: 5)
        XCTAssertEqual(returned, [event(1, geometryEpoch: 4, .releaseAll(.generationChanged))])
        XCTAssertEqual(sink.events.filter { $0.payload == .releaseAll(.generationChanged) }.count, 1)
        XCTAssertEqual(sink.events.last?.geometryEpoch, 4)
    }

    func testFiniteGeometryRejectsNaNAndInfinityWithoutTrapping() {
        let base = VideoInputGeometry(
            viewport: .init(x: 0, y: 0, width: 100, height: 100),
            videoRect: .init(x: 0, y: 0, width: 100, height: 100),
            streamPixels: .init(width: 100, height: 100))
        XCTAssertNil(base.map(.init(x: .nan, y: 50)))
        XCTAssertNil(base.map(.init(x: 50, y: .infinity)))
        let badTransform = VideoInputGeometry(
            viewport: base.viewport, videoRect: base.videoRect, streamPixels: base.streamPixels,
            streamTransform: .init(scaleX: .nan))
        XCTAssertNil(badTransform.map(.init(x: 50, y: 50)))

        let controller = RemoteInputController()
        _ = controller.activate(generation: 3)
        XCTAssertEqual(controller.absoluteMove(.init(x: .nan, y: 50), geometry: base, generation: 3), [])
    }

    func testBothControlSidesRemainActiveUntilBothAreReleased() {
        let controller = RemoteInputController()
        _ = controller.activate(generation: 6)
        _ = controller.key(usage: .leftControl, phase: .down, generation: 6)
        XCTAssertEqual(controller.key(usage: .rightControl, phase: .down, generation: 6),
                       [event(6, .key(.init(rawValue: 0xA3), .down, .control))])
        XCTAssertEqual(controller.key(usage: .leftControl, phase: .up, generation: 6),
                       [event(6, .key(.init(rawValue: 0xA2), .up, .control))])
        XCTAssertEqual(controller.key(usage: .c, phase: .down, generation: 6),
                       [event(6, .key(.init(rawValue: 0x43), .down, .control))])
    }

    func testKeypadNumbersUseWindowsNumpadVirtualKeys() {
        XCTAssertEqual(HIDKeyboardMapper.virtualKey(for: .keypadOne), .init(rawValue: 0x61))
        XCTAssertEqual(HIDKeyboardMapper.virtualKey(for: HIDUsage(rawValue: 0x61)), .init(rawValue: 0x69))
        XCTAssertEqual(HIDKeyboardMapper.virtualKey(for: .keypadZero), .init(rawValue: 0x60))
    }

    func testSinkReceivesTypedEventsWithoutShellStrings() {
        let sink = RecordingSink(); let controller = RemoteInputController(sink: sink); _ = controller.activate(generation: 1)
        _ = controller.text("echo should never be assembled", generation: 1)
        XCTAssertEqual(sink.events.count, 1)
        if case .text(let bytes) = sink.events[0].payload { XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "echo should never be assembled") }
        else { XCTFail("expected typed text event") }
    }

    func testHardwareRightDragCancellationReleasesRightButton() {
        let controller = RemoteInputController()
        let geometry = VideoInputGeometry(viewport: .init(x: 0, y: 0, width: 100, height: 200),
            videoRect: .init(x: 0, y: 0, width: 100, height: 200), streamPixels: .init(width: 1000, height: 2000))
        controller.activate(generation: 6, geometryEpoch: 9)
        _ = controller.absolutePress(.init(x: 50, y: 100), geometry: geometry, generation: 6, button: .right, geometryEpoch: 9)
        XCTAssertEqual(controller.cancelGesture(generation: 6, geometryEpoch: 9), [
            event(6, geometryEpoch: 9, .mouseButton(.right, .up)),
            event(6, geometryEpoch: 9, .releaseAll(.gestureCancelled))])
        XCTAssertEqual(controller.absoluteMove(.init(x: 50, y: 100), geometry: geometry, generation: 6, geometryEpoch: 8), [])
    }

    func testPortraitFullScreenPointerMapsToStreamRatherThanHostOrigin() {
        let geometry = VideoInputGeometry(viewport: .init(x: 0, y: 0, width: 834, height: 1210),
            videoRect: .init(x: 0, y: 0, width: 834, height: 1210), streamPixels: .init(width: 1660, height: 2408))
        assertPointEqual(geometry.map(.init(x: 834 * 0.84, y: 1210 * 0.84)), .init(x: 1660 * 0.84, y: 2408 * 0.84))
    }

    private func event(_ generation: UInt64, geometryEpoch: UInt64 = 0,
                       _ payload: RemoteInputPayload) -> RemoteInputEvent {
        .init(generation: generation, geometryEpoch: geometryEpoch, payload: payload)
    }
}

private final class RecordingSink: RemoteInputEventSink {
    var events: [RemoteInputEvent] = []
    func remoteInput(_ event: RemoteInputEvent) { events.append(event) }
}

private func assertPointEqual(_ actual: InputPoint?, _ expected: InputPoint, accuracy: Double = 0.01, file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else { return XCTFail("expected point, got nil", file: file, line: line) }
    XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
}
