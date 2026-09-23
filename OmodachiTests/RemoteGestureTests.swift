import XCTest
@testable import Omodachi

/// GEST-1 · A-64 / N-37 / A-62.
///
/// Three-finger swipes and three-finger pinches **cannot be synthesized** on
/// this runtime: XCUITest refuses to compute coordinates for a multi-finger
/// gesture and the simulator's HID injection serialises the touches into
/// separate reports (REMOTE-2, UX-2 §0, `RemoteKeyboardTests`). So the arbiter
/// is driven here at the seam the two Objective-C views use — the same
/// `report(points:at:)` they call, with the same coordinates UIKit would have
/// handed them — and the part that cannot be reached from a test at all is a
/// checklist for a real iPad in `docs/specs/GEST-1-report.md`.
final class RemoteGestureRecognizerTests: XCTestCase {
    typealias Point = RemoteGestureRecognizer.Point

    /// Three fingers 60 pt apart around (160, 200): mean radius 40 pt.
    private func fingers(dx: Double = 0, dy: Double = 0, spread: Double = 1) -> [Point] {
        [(-60.0, 0.0), (0.0, 0.0), (60.0, 0.0)].map {
            Point(x: 160 + $0.0 * spread + dx, y: 200 + $0.1 * spread + dy)
        }
    }

    private func machine(_ registered: Set<RemotePictureGesture> = Set(RemotePictureGesture.hostGestures))
    -> RemoteGestureRecognizer {
        var value = RemoteGestureRecognizer()
        value.updateRegistered(registered)
        return value
    }

    // MARK: - Tap

    func testAThreeFingerTapIsTheKeyboardAndNothingElse() {
        var machine = machine()
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        XCTAssertEqual(machine.state, .watching)
        XCTAssertEqual(machine.report(points: [], at: 0.06), .keyboard)
        XCTAssertTrue(machine.keyboardTapConfirmed)
    }

    /// The 130 ms window decides whether these three fingers are *going*
    /// somewhere. It is deliberately not an upper bound on how long a tap may
    /// be held: an ordinary three-finger tap on an 11" iPad is 150–250 ms, and
    /// A-62's keyboard has to keep working for it.
    func testHoldingPastTheWindowIsStillTheKeyboard() {
        var machine = machine()
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        XCTAssertNil(machine.report(points: fingers(dx: 2), at: 0.20))
        XCTAssertEqual(machine.state, .tapCandidate, "the window expired with nothing crossed")
        XCTAssertEqual(machine.report(points: [], at: 0.31), .keyboard)
    }

    func testATwoFingerCycleIsNeverTheKeyboard() {
        var machine = machine()
        XCTAssertNil(machine.report(points: Array(fingers().prefix(2)), at: 0))
        XCTAssertNil(machine.report(points: [], at: 0.05))
        XCTAssertFalse(machine.keyboardTapConfirmed)
    }

    // MARK: - Swipe

    func testTheFourDirections() {
        let cases: [(Double, Double, RemotePictureGesture?)] = [
            (-40, 0, .workspaceNext), (40, 0, .workspacePrevious),
            (0, -40, .scratchpad), (0, 40, nil),
        ]
        for (dx, dy, expected) in cases {
            var machine = machine()
            XCTAssertNil(machine.report(points: fingers(), at: 0))
            XCTAssertEqual(machine.report(points: fingers(dx: dx, dy: dy), at: 0.05), expected,
                           "dx=\(dx) dy=\(dy)")
            // A-64 has no downward three-finger swipe (iPadOS owns it), so that
            // cycle is spent: lifting afterwards is not a keyboard tap either.
            XCTAssertNil(machine.report(points: [], at: 0.10))
        }
    }

    func testASwipeAfterTheWindowStillWins() {
        var machine = machine()
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        XCTAssertNil(machine.report(points: fingers(dx: 2), at: 0.20))
        XCTAssertEqual(machine.state, .tapCandidate)
        XCTAssertEqual(machine.report(points: fingers(dx: -40), at: 0.40), .workspaceNext)
        XCTAssertEqual(machine.report(points: [], at: 0.45), nil, "a claim is delivered once")
    }

    func testAGestureFiresOnlyOncePerCycle() {
        var machine = machine()
        _ = machine.report(points: fingers(), at: 0)
        XCTAssertEqual(machine.report(points: fingers(dx: -40), at: 0.05), .workspaceNext)
        XCTAssertNil(machine.report(points: fingers(dx: -200), at: 0.09))
        XCTAssertNil(machine.report(points: fingers(dx: -400), at: 0.12))
    }

    // MARK: - Pinch

    /// GEST-1 §2 asks for the pinch and the swipe to be mutually exclusive, and
    /// names two ways to get there. This is the second one: one state machine,
    /// so "which of the two is this" is a comparison rather than a race between
    /// two recognisers. Whichever crosses its own threshold by more claims the
    /// cycle, and a claimed cycle is finished.
    func testAPinchIsFullScreen() {
        var machine = machine()
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        XCTAssertEqual(machine.report(points: fingers(spread: 1.4), at: 0.05), .fullScreen)
    }

    func testAPinchInwardsIsAlsoFullScreen() {
        var machine = machine()
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        XCTAssertEqual(machine.report(points: fingers(spread: 0.6), at: 0.05), .fullScreen)
    }

    func testASwipeThatRollsTheFingersALittleIsStillASwipe() {
        var machine = machine()
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        // 40 pt of travel (167% of its threshold) against 5% of spread (28% of
        // its threshold): the swipe is further along, so the swipe wins.
        XCTAssertEqual(machine.report(points: fingers(dx: -40, spread: 1.05), at: 0.05), .workspaceNext)
    }

    func testAPinchThatDriftsALittleIsStillAPinch() {
        var machine = machine()
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        XCTAssertEqual(machine.report(points: fingers(dx: -10, spread: 1.5), at: 0.05), .fullScreen)
    }

    // MARK: - N-37: an unregistered gesture does not exist

    func testAGestureTheHostHasNoRowForNeverFires() {
        var machine = machine([.scratchpad])
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        XCTAssertNil(machine.report(points: fingers(dx: -40), at: 0.05),
                     "the host has no workspace row, so there is no such gesture")
        XCTAssertEqual(machine.state, .inert)
        XCTAssertNil(machine.report(points: [], at: 0.10), "and it does not fall back to the keyboard")
    }

    func testWithNothingRegisteredTheKeyboardTapStillWorks() {
        var machine = machine([])
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        XCTAssertEqual(machine.report(points: [], at: 0.06), .keyboard, "A-62 is local, not a host row")
    }

    // MARK: - Fingers that are not three

    func testAFourthFingerMakesTheCycleInert() {
        var machine = machine()
        XCTAssertNil(machine.report(points: fingers(), at: 0))
        XCTAssertNil(machine.report(points: fingers() + [Point(x: 300, y: 260)], at: 0.02))
        XCTAssertEqual(machine.state, .inert)
        XCTAssertNil(machine.report(points: fingers(dx: -80), at: 0.06))
        XCTAssertNil(machine.report(points: [], at: 0.10))
    }

    // MARK: - UX-2 §2's latch, for both backends

    func testTheLatchWithholdsEverySingleFingerPressForTheWholeCycle() {
        var machine = machine()
        XCTAssertNil(machine.report(points: [Point(x: 100, y: 200)], at: 0))
        XCTAssertTrue(machine.singleTouchAllowed, "one finger is the pointer, as it always was")
        XCTAssertNil(machine.report(points: Array(fingers().prefix(2)), at: 0.03))
        XCTAssertFalse(machine.singleTouchAllowed)
        // The third finger of an 11" three-finger tap can land later than the
        // deferred press's own timer. It must not be able to overtake it.
        XCTAssertNil(machine.report(points: fingers(), at: 0.14))
        XCTAssertFalse(machine.singleTouchAllowed)
        // And one finger lifting back to a single touch does not unlatch it.
        XCTAssertNil(machine.report(points: [Point(x: 100, y: 200)], at: 0.20))
        XCTAssertFalse(machine.singleTouchAllowed)
    }

    func testANewCycleStartsWithTheLatchOpenAgain() {
        var machine = machine()
        _ = machine.report(points: fingers(), at: 0)
        _ = machine.report(points: [], at: 0.06)
        XCTAssertNil(machine.report(points: [Point(x: 40, y: 40)], at: 1.0))
        XCTAssertTrue(machine.singleTouchAllowed)
    }

    /// A-62: the tap recogniser fires after UIKit has already cancelled the
    /// touches it claimed, so the veto has to survive the end of the cycle.
    func testTheKeyboardVetoSurvivesTheEndOfTheCycle() {
        var machine = machine()
        _ = machine.report(points: fingers(), at: 0)
        XCTAssertEqual(machine.report(points: fingers(dx: -40), at: 0.05), .workspaceNext)
        _ = machine.report(points: [], at: 0.09)
        XCTAssertFalse(machine.keyboardTapConfirmed, "a swipe is not also a keyboard tap")
    }
}

// MARK: - N-37 resolution

final class RemoteGestureResolverTests: XCTestCase {
    private func entry(_ label: String, enabled: Bool = true, ref: String? = "ref",
                       reason: String? = nil, detail: String? = nil) -> ShortcutEntry {
        ShortcutEntry(id: "id-\(label)", label: label, keys: "SUPER + X", order: 1, actionRef: ref,
                      enabled: enabled, disabledReason: reason, disabledReasonDetail: detail)
    }
    private func snapshot(_ entries: [ShortcutEntry], available: Bool = true) -> ShortcutSnapshot {
        ShortcutSnapshot(revision: "r1", source: "hyprland", entries: entries, available: available)
    }

    func testTheTwoRowsAAndSixtyFourNamesResolve() {
        let value = RemoteGestureResolver.resolve(
            shortcuts: snapshot([entry("Toggle scratchpad"), entry("Full screen")]),
            workspacesSelectable: true)
        XCTAssertEqual(value[.scratchpad]?.row,
                       .shortcut(id: "id-Toggle scratchpad", actionRef: "ref", label: "Toggle scratchpad"))
        XCTAssertEqual(value[.fullScreen]?.row,
                       .shortcut(id: "id-Full screen", actionRef: "ref", label: "Full screen"))
        XCTAssertEqual(value[.workspaceNext]?.row, .relativeWorkspace(step: .next))
        XCTAssertEqual(value[.workspacePrevious]?.row, .relativeWorkspace(step: .previous))
        XCTAssertEqual(value.registered, Set(RemotePictureGesture.hostGestures))
    }

    /// N-37: the label is the handle, not the key combination. "主机改绑定手势
    /// 跟着改" is only true if the gesture follows the row rather than the keys,
    /// and the host's label is host text, so it is matched case- and
    /// space-insensitively.
    func testTheLabelIsMatchedAsHostText() {
        let value = RemoteGestureResolver.resolve(
            shortcuts: snapshot([entry("  TOGGLE   Scratchpad ")]), workspacesSelectable: false)
        XCTAssertNotNil(value[.scratchpad]?.row)
    }

    func testARowTheHostDoesNotHaveIsNotRegistered() {
        let value = RemoteGestureResolver.resolve(shortcuts: snapshot([entry("Full screen")]),
                                                  workspacesSelectable: false)
        XCTAssertNil(value[.scratchpad]?.row)
        XCTAssertEqual(value[.scratchpad]?.resolution, Strings.gestureNoHostBinding)
        XCTAssertNil(value[.workspaceNext]?.row)
        XCTAssertEqual(value[.workspaceNext]?.resolution, Strings.gestureNoWorkspaces)
        XCTAssertEqual(value.registered, [.fullScreen])
    }

    /// ARCH-1 §7 / SHORTCUT-1: a row is greyed only when the host says so, and
    /// a greyed row is treated exactly as a row that is not there. Core's own
    /// sentence about it is what the gesture section prints.
    func testARowCoreHasGreyedIsNotRegisteredAndSaysWhy() {
        let value = RemoteGestureResolver.resolve(
            shortcuts: snapshot([entry("Full screen", enabled: false,
                                       detail: "host record carries no executable binding")]),
            workspacesSelectable: true)
        XCTAssertNil(value[.fullScreen]?.row)
        XCTAssertEqual(value[.fullScreen]?.resolution, "host record carries no executable binding")
        XCTAssertFalse(value.registered.contains(.fullScreen))
    }

    func testARowWithNoActionReferenceIsNotRegistered() {
        let value = RemoteGestureResolver.resolve(shortcuts: snapshot([entry("Full screen", ref: nil)]),
                                                  workspacesSelectable: false)
        XCTAssertNil(value[.fullScreen]?.row)
        XCTAssertEqual(value.registered, [])
    }

    func testNoListAtAllMeansNoGestures() {
        let value = RemoteGestureResolver.resolve(shortcuts: nil, workspacesSelectable: false)
        XCTAssertEqual(value.registered, [])
        for binding in value.bindings { XCTAssertNotNil(binding.resolution) }
    }

    func testAnUnavailableListMeansNoRowGestures() {
        let value = RemoteGestureResolver.resolve(
            shortcuts: snapshot([entry("Full screen")], available: false), workspacesSelectable: true)
        XCTAssertNil(value[.fullScreen]?.row)
        XCTAssertEqual(value.registered, [.workspaceNext, .workspacePrevious])
    }

    func testEverySettingsRowHasAName() {
        let value = RemoteGestureResolver.resolve(shortcuts: nil, workspacesSelectable: false)
        XCTAssertEqual(value.bindings.count, 4)
        for binding in value.bindings {
            XCTAssertFalse(binding.gesture.title.isEmpty)
            XCTAssertFalse(binding.resolution.isEmpty)
        }
        XCTAssertFalse(RemotePictureGesture.keyboard.title.isEmpty)
    }
}

// MARK: - The Objective-C seam and the two backends

@MainActor final class RemoteGestureArbiterTests: XCTestCase {
    private func coordinates(dx: Double = 0, spread: Double = 1) -> [NSNumber] {
        [(-60.0, 0.0), (0.0, 0.0), (60.0, 0.0)].flatMap {
            [NSNumber(value: 160 + $0.0 * spread + dx), NSNumber(value: 200 + $0.1 * spread)]
        }
    }

    func testTheArbiterAnswersTheViewsInTheirOwnCurrency() {
        let arbiter = RemoteGestureArbiter()
        arbiter.updateRegistered(gestures: [NSNumber(value: RemotePictureGesture.workspaceNext.rawValue)])
        var heard: [RemotePictureGesture] = []
        arbiter.onGesture = { heard.append($0) }
        XCTAssertEqual(arbiter.report(phase: .began, coordinates: coordinates(), timestamp: 0), .none)
        XCTAssertFalse(arbiter.singleTouchAllowed, "UX-2 §2: three fingers latch the press away")
        XCTAssertEqual(arbiter.report(phase: .moved, coordinates: coordinates(dx: -40), timestamp: 0.05),
                       .workspaceNext)
        XCTAssertEqual(heard, [.workspaceNext])
        XCTAssertFalse(arbiter.keyboardTapConfirmed)
    }

    func testTheKeyboardIsNotReportedOnTheGestureChannel() {
        let arbiter = RemoteGestureArbiter()
        var heard: [RemotePictureGesture] = []
        arbiter.onGesture = { heard.append($0) }
        _ = arbiter.report(phase: .began, coordinates: coordinates(), timestamp: 0)
        XCTAssertEqual(arbiter.report(phase: .ended, coordinates: [], timestamp: 0.06), .keyboard)
        XCTAssertTrue(heard.isEmpty, "A-62 goes through the keyboard handler, not the host channel")
        XCTAssertTrue(arbiter.keyboardTapConfirmed)
    }

    func testAnOddCoordinateArrayIsIgnoredRatherThanRead() {
        let arbiter = RemoteGestureArbiter()
        XCTAssertEqual(arbiter.report(phase: .began, coordinates: [NSNumber(value: 1.0)], timestamp: 0), .none)
    }

    /// GEST-1 §2: one policy layer, both pictures. The two Objective-C views
    /// only wire it up, so what this asserts is that they are wired up at all —
    /// a backend without an arbiter would quietly have no gestures.
    func testBothBackendsOwnAnArbiter() {
        let sunshine = SunshineBackendDriver(host: "127.0.0.1", relativeTouchpad: false)
        XCTAssertNotNil(sunshine.client.gestureArbiter)
        XCTAssertNotNil(sunshine.client.gestureHandler)
        let adapter = VNCBackendAdapter(bridge: .init(open: { _ in 0 }, close: { }))
        let vnc = VNCBackendDriver(adapter: adapter)
        XCTAssertNotNil(adapter.view.gestureArbiter)
        XCTAssertNotNil(adapter.view.onGesture)
        // And the registered set reaches both without throwing.
        sunshine.setRegisteredGestures([.fullScreen])
        vnc.setRegisteredGestures([.fullScreen])
    }

    /// The operator replay is the only way a three-finger gesture can be made
    /// to happen on a simulator, so what it produces has to be the real thing:
    /// the same arbiter, the same verdicts, N-37's registration check included.
    func testTheOperatorReplayProducesTheRealVerdicts() {
        for gesture in RemotePictureGesture.hostGestures {
            let arbiter = RemoteGestureArbiter()
            arbiter.updateRegistered(gestures: RemotePictureGesture.hostGestures.map {
                NSNumber(value: $0.rawValue)
            })
            var heard: [RemotePictureGesture] = []
            arbiter.onGesture = { heard.append($0) }
            arbiter.replayForOperator(gesture, at: 1000)
            XCTAssertEqual(heard, [gesture], "\(gesture)")
        }
    }

    func testTheOperatorReplayObeysTheRegistrationRule() {
        let arbiter = RemoteGestureArbiter()
        var heard: [RemotePictureGesture] = []
        arbiter.onGesture = { heard.append($0) }
        arbiter.replayForOperator(.scratchpad, at: 1000)
        XCTAssertTrue(heard.isEmpty, "N-37 applies to an operator run exactly as it does to a finger")
    }

    /// UX-2 §2 on the VNC leg, which never had it: before GEST-1 this view sent
    /// a button down from the first line of `touchesBegan`, so three fingers on
    /// the picture were three real clicks on the host's desktop.
    func testTheVNCPictureWithholdsItsPressUntilItKnowsWhatTheCycleIs() {
        let adapter = VNCBackendAdapter(bridge: .init(open: { _ in 0 }, close: { }))
        XCTAssertFalse(adapter.view.pointerPressWithheld, "nothing is pending before a touch")
    }
}

// MARK: - The controller's half: registration and the 26-high row

@MainActor final class RemoteGestureControllerTests: XCTestCase {
    func testTheBindingsArePublishedAndOnlyWhenTheyChange() {
        let controller = RemoteSessionController()
        XCTAssertEqual(controller.gestureBindings.registered, [])
        let bindings = RemoteGestureResolver.resolve(shortcuts: nil, workspacesSelectable: true)
        controller.applyGestureBindings(bindings)
        XCTAssertEqual(controller.gestureBindings.registered, [.workspaceNext, .workspacePrevious])
        controller.applyGestureBindings(bindings)
        XCTAssertEqual(controller.gestureBindings, bindings)
    }

    /// A-12 / GEST-1 §3: `accepted` while the host has only taken it, then the
    /// verdict, once. The row never claims a result the host has not confirmed.
    func testTheGestureRowReportsWhatTheHostSaid() {
        let controller = RemoteSessionController()
        let toast = PanelToast(stage: .accepted, label: "Full screen")
        controller.reportGestureToast(toast)
        XCTAssertEqual(controller.gestureToast?.stage, .accepted)
        XCTAssertEqual(controller.gestureToast?.label, "Full screen")
        controller.settleGestureToast(id: toast.id, stage: .applied, detail: nil)
        XCTAssertEqual(controller.gestureToast?.stage, .applied)
        XCTAssertEqual(controller.gestureToast?.tail, "applied")
    }

    func testASettledRowForAnotherGestureIsIgnored() {
        let controller = RemoteSessionController()
        controller.reportGestureToast(.init(stage: .accepted, label: "one"))
        controller.settleGestureToast(id: UUID(), stage: .failed, detail: "no")
        XCTAssertEqual(controller.gestureToast?.stage, .accepted)
    }

    func testTheRowIsTwentySixHigh() {
        // Study 04 §11d's shape, and A-12's: the toast is a 26-high row, which
        // is fixed in `PanelToastView` rather than restated here.
        XCTAssertEqual(PanelToast(stage: .failed, label: "x").tail, "failed")
        XCTAssertEqual(PanelToast(stage: .accepted, label: "x").role, .muted)
    }
}
