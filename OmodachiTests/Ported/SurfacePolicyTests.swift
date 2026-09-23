import XCTest
import RemoteInputCore
@testable import Omodachi

/// Production Panel action gate: no pre-close/stale-proof send, fresh
/// geometry/native gate required, exactly-once Tab, keyboard-present-then-fresh
/// -proof modifier, timeout/cancel/panel/replacement/run/epoch/generation/serial
/// rejection. Synthetic only.
final class RemotePanelActionQueueTests: XCTestCase {
    func testPanelActionGate() {
        let identity = RemotePanelActionIdentity(run: UUID(), generation: 5, epoch: 7, serial: 2)
        var queue = RemotePanelActionQueue()
        queue.enqueue(.key(0x2b), identity: identity, observation: 10, now: 100)
        XCTAssertNil(queue.take(identity: identity, observation: 10, gateOpen: true, panelVisible: false, keyboardVisible: false, now: 100.1))
        XCTAssertNil(queue.take(identity: identity, observation: 11, gateOpen: false, panelVisible: false, keyboardVisible: false, now: 100.2))
        queue.keyboardHidden() // Panel's search keyboard hides; pending Tab remains.
        XCTAssertTrue(queue.hasPending)
        XCTAssertEqual(queue.take(identity: identity, observation: 12, gateOpen: true, panelVisible: false, keyboardVisible: false, now: 100.3), .key(0x2b))
        XCTAssertNil(queue.take(identity: identity, observation: 13, gateOpen: true, panelVisible: false, keyboardVisible: false, now: 100.4))

        queue.enqueue(.modifier(5), identity: identity, observation: 20, now: 200)
        XCTAssertEqual(queue.take(identity: identity, observation: 21, gateOpen: true, panelVisible: false, keyboardVisible: false, now: 200.1), .showKeyboard)
        XCTAssertNil(queue.take(identity: identity, observation: 22, gateOpen: true, panelVisible: false, keyboardVisible: true, now: 200.2))
        queue.keyboardShown(observation: 22)
        XCTAssertNil(queue.take(identity: identity, observation: 22, gateOpen: true, panelVisible: false, keyboardVisible: true, now: 200.3))
        XCTAssertNil(queue.take(identity: identity, observation: 23, gateOpen: false, panelVisible: false, keyboardVisible: true, now: 200.4))
        XCTAssertEqual(queue.take(identity: identity, observation: 24, gateOpen: true, panelVisible: false, keyboardVisible: true, now: 200.5), .modifier(5))
        XCTAssertFalse(queue.hasPending)
        queue.enqueue(.modifier(1), identity: identity, observation: 30, now: 300)
        XCTAssertEqual(queue.take(identity: identity, observation: 31, gateOpen: true, panelVisible: false, keyboardVisible: true, now: 300.1), .modifier(1))

        for changed in [RemotePanelActionIdentity(run: UUID(), generation: 5, epoch: 7, serial: 2),
                        .init(run: identity.run, generation: 6, epoch: 7, serial: 2),
                        .init(run: identity.run, generation: 5, epoch: 8, serial: 2),
                        .init(run: identity.run, generation: 5, epoch: 7, serial: 3)] {
            queue.enqueue(.key(4), identity: identity, observation: 0, now: 0)
            XCTAssertNil(queue.take(identity: changed, observation: 1, gateOpen: true, panelVisible: false, keyboardVisible: false, now: 0.1))
            XCTAssertFalse(queue.hasPending)
        }
        queue.enqueue(.key(4), identity: identity, observation: 0, now: 0); queue.cancel()
        XCTAssertNil(queue.take(identity: identity, observation: 1, gateOpen: true, panelVisible: false, keyboardVisible: false, now: 0.1))
        queue.enqueue(.key(4), identity: identity, observation: 0, now: 0)
        XCTAssertNil(queue.take(identity: identity, observation: 1, gateOpen: true, panelVisible: true, keyboardVisible: false, now: 0.1))
        XCTAssertFalse(queue.hasPending)
        queue.enqueue(.modifier(1), identity: identity, observation: 0, now: 0)
        _ = queue.take(identity: identity, observation: 1, gateOpen: true, panelVisible: false, keyboardVisible: false, now: 0.1)
        queue.keyboardShown(observation: 1); queue.keyboardHidden()
        XCTAssertFalse(queue.hasPending)
        queue.enqueue(.key(4), identity: identity, observation: 0, now: 0)
        XCTAssertNil(queue.take(identity: identity, observation: 1, gateOpen: true, panelVisible: false, keyboardVisible: false, now: 3.1))
        queue.enqueue(.key(4), identity: identity, observation: 0, now: 0)
        queue.enqueue(.key(5), identity: identity, observation: 1, now: 0.1)
        XCTAssertEqual(queue.take(identity: identity, observation: 2, gateOpen: true, panelVisible: false, keyboardVisible: false, now: 0.2), .key(5))
    }
}

/// Production lifecycle/route/touchpad/delta/text policies plus the modifier
/// controller: inactive preserve, background stop, unsupported route guard,
/// relative hover/tap/drag/cancel, scroll units/fractions/bounds, one-shot latch
/// and epoch reset. Synthetic only.
final class SurfaceTouchPolicyTests: XCTestCase {
    func testLifecycleAndRoutePolicies() {
        let inactive = SurfaceLifecyclePolicy.effects(.inactive)
        XCTAssertNil(inactive.foregroundConnections)
        XCTAssertTrue(inactive.pauseRemoteInteraction)
        XCTAssertFalse(inactive.disconnectRemote)
        let background = SurfaceLifecyclePolicy.effects(.background)
        XCTAssertEqual(background.foregroundConnections, false)
        XCTAssertTrue(background.pauseRemoteInteraction)
        XCTAssertTrue(background.disconnectRemote)
        let active = SurfaceLifecyclePolicy.effects(.active)
        XCTAssertEqual(active.foregroundConnections, true)
        XCTAssertFalse(active.pauseRemoteInteraction)
        XCTAssertFalse(active.disconnectRemote)
        XCTAssertTrue(NativeRoutePolicy.supported("native:agent"))
        XCTAssertTrue(NativeRoutePolicy.supported("native:herdr"))
        XCTAssertTrue(NativeRoutePolicy.supported("native:panel"))
        XCTAssertFalse(NativeRoutePolicy.supported("native:unimplemented"))
        XCTAssertEqual(NativeRoutePolicy.unavailableMessage, Strings.routeUnavailable)
    }

    func testPointerPreferencePersistence() {
        let preferenceSuite = "omodachi-pointer-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: preferenceSuite)!
        defer { defaults.removePersistentDomain(forName: preferenceSuite) }
        XCTAssertFalse(NativePointerPreference.relativeTouchpad(in: defaults))
        NativePointerPreference.save(relativeTouchpad: true, in: defaults)
        XCTAssertTrue(NativePointerPreference.relativeTouchpad(in: UserDefaults(suiteName: preferenceSuite)!))
        NativePointerPreference.save(relativeTouchpad: false, in: defaults)
        XCTAssertFalse(NativePointerPreference.relativeTouchpad(in: UserDefaults(suiteName: preferenceSuite)!))
        defaults.set("unknown", forKey: NativePointerPreference.key)
        XCTAssertFalse(NativePointerPreference.relativeTouchpad(in: defaults))
    }

    func testRelativeTouchpadGesture() {
        var touchpad = NativeTouchpadGesture()
        XCTAssertTrue(touchpad.begin(x: 100, y: 100).isEmpty)
        XCTAssertTrue(touchpad.move(x: 102, y: 100).isEmpty)
        XCTAssertEqual(touchpad.move(x: 110, y: 105), [.move(dx: 10, dy: 5)])
        XCTAssertTrue(touchpad.end(x: 110, y: 105).isEmpty) // hover does not drag/click
        XCTAssertTrue(touchpad.begin(x: 100, y: 100).isEmpty)
        XCTAssertEqual(touchpad.end(x: 101, y: 100), [.press, .release])
        _ = touchpad.begin(x: 100, y: 100)
        XCTAssertEqual(touchpad.beginDrag(), [.press])
        XCTAssertTrue(touchpad.beginDrag().isEmpty)
        XCTAssertEqual(touchpad.move(x: 115, y: 100), [.move(dx: 15, dy: 0)])
        XCTAssertEqual(touchpad.cancel(), [.release])
        XCTAssertTrue(touchpad.end(x: 115, y: 100).isEmpty)
        XCTAssertTrue(touchpad.move(x: 115, y: 100).isEmpty)
        _ = touchpad.begin(x: 100, y: 100); _ = touchpad.beginDrag()
        XCTAssertEqual(touchpad.begin(x: 200, y: 200), [.release])
        _ = touchpad.cancel()
        XCTAssertTrue(touchpad.begin(x: .nan, y: 20).isEmpty)
        XCTAssertTrue(touchpad.beginDrag().isEmpty)
    }

    func testScrollAccumulatorUnitsFractionsAndBounds() {
        var scroll = NativeDeltaAccumulator()
        XCTAssertTrue(scroll.take(dx: 0, dy: 0.2, scale: 3) == (0, 0))
        XCTAssertTrue(scroll.take(dx: 0, dy: 0.2, scale: 3) == (0, 1))
        scroll.reset()
        XCTAssertTrue(scroll.take(dx: -40, dy: 40, scale: 3) == (-120, 120))
        XCTAssertTrue(scroll.take(dx: 1e9, dy: -1e9) == (32767, -32767))
        XCTAssertTrue(scroll.take(dx: .nan, dy: 5) == (0, 0))
        scroll.reset()
        XCTAssertTrue(scroll.take(dx: 0.25, dy: 0.25) == (0, 0))
        XCTAssertTrue(scroll.take(dx: 0.75, dy: 0.75) == (1, 1))
    }

    func testShortcutTextAndOneShotModifierLatch() {
        XCTAssertEqual(NativeShortcutText.usage("a"), 4)
        XCTAssertEqual(NativeShortcutText.usage("A"), 4)
        XCTAssertEqual(NativeShortcutText.usage("1"), 0x1e)
        XCTAssertEqual(NativeShortcutText.usage("0"), 0x27)
        XCTAssertNil(NativeShortcutText.usage("输入"))
        XCTAssertNil(NativeShortcutText.usage("é"))
        let input = RemoteInputController()
        input.activate(generation: 3, geometryEpoch: 8)
        input.latch(.control, generation: 3, geometryEpoch: 8)
        let down = input.key(usage: .init(rawValue: NativeShortcutText.usage("a")!), phase: .down, generation: 3, geometryEpoch: 8)
        let up = input.key(usage: .init(rawValue: 4), phase: .up, generation: 3, geometryEpoch: 8)
        guard case .key(_, .down, let firstModifiers) = down.first?.payload,
              case .key(_, .up, let upModifiers) = up.first?.payload else { XCTFail("No shortcut events"); return }
        XCTAssertEqual(firstModifiers, .control)
        XCTAssertEqual(upModifiers, .control)
        let next = input.key(usage: .init(rawValue: 5), phase: .down, generation: 3, geometryEpoch: 8)
        guard case .key(_, .down, let nextModifiers) = next.first?.payload else { XCTFail("No next key"); return }
        XCTAssertTrue(nextModifiers.isEmpty)
        input.latch([.control, .shift], generation: 3, geometryEpoch: 8)
        input.disconnect(generation: 3); input.activate(generation: 4, geometryEpoch: 9)
        XCTAssertTrue(input.key(usage: .init(rawValue: 4), phase: .down, generation: 3, geometryEpoch: 8).isEmpty)
        let reset = input.key(usage: .init(rawValue: 4), phase: .down, generation: 4, geometryEpoch: 9)
        guard case .key(_, .down, let resetModifiers) = reset.first?.payload else { XCTFail("No current key"); return }
        XCTAssertTrue(resetModifiers.isEmpty)
    }
}
