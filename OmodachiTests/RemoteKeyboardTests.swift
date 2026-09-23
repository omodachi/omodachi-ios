import UIKit
import XCTest
@testable import Omodachi

/// REMOTE-2 item 3. A-43's keyboard has two entries — the three-finger tap
/// inside the picture and the overlay's button — and one rule: raising it needs
/// a live session *and* a view UIKit will actually make first responder.
///
/// MERGE-1 §6.3 found the button lighting up with no keyboard under it four
/// runs in a row. Two necessary conditions were fixed there (the gate was the
/// input gate rather than the session, and the picture had its hit testing
/// turned off under the overlay) and it still did not come up, because nothing
/// ever looked at what `becomeFirstResponder` answered: the switch was flipped,
/// the button read the switch, and UIKit was never consulted. These cases pin
/// the answer instead of the want.
///
/// The three-finger tap itself cannot be synthesized on iOS 26.5 (XCUITest
/// refuses to compute coordinates for a multi-finger gesture against this app,
/// and simctl/axe HID injection is broken on the same runtime), so what is
/// covered here is its configuration and the callback it fires — which is the
/// same `presentSoftwareKeyboard:` the button reaches.
@MainActor final class RemoteKeyboardTests: XCTestCase {

    /// A real window, because "can this view become first responder" is a
    /// question only a window can answer.
    private func hosted() -> (UIWindow, OMRemoteRenderView) {
        let client = OMRemoteClient(host: "127.0.0.1")
        let view = client.renderView
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        return (window, view)
    }

    /// UX-2 §2. Leo, on the real iPad: "三指点击 → 键盘出来了，菜单也出来了".
    ///
    /// A-62 says three fingers are the keyboard and nothing else. Two things on
    /// this view could put a panel up without being asked, and both are gone:
    /// the edge pan (A-59 rev 5 abolished "边缘 pan" but the recogniser was
    /// still registered and still called `requestPanel`), and the single-finger
    /// press that used to be sent to the host 80 ms into a gesture that turned
    /// out to have three fingers in it — on the host that is a real touch
    /// down, and a touch down on Omarchy's own bar opens Omarchy's own menu.
    ///
    /// What is assertable without synthesizing the gesture (see the note above)
    /// is the inventory: which recognisers exist, how many fingers each wants,
    /// and that none of them reaches `requestPanel`.
    func testTheOnlyGesturesOnThePictureArePointerGestures() throws {
        let client = OMRemoteClient(host: "127.0.0.1")
        let view = client.renderView
        let recognizers = try XCTUnwrap(view.gestureRecognizers)

        var summoned: [String] = []
        client.panelHandler = { summoned.append($0) }

        let pans = recognizers.compactMap { $0 as? UIPanGestureRecognizer }
        XCTAssertEqual(pans.count, 1, "the edge pan that summoned a panel is gone (A-59 rev 5)")
        let scroll = try XCTUnwrap(pans.first)
        XCTAssertEqual(scroll.minimumNumberOfTouches, 2, "the one pan left is two-finger scrolling")
        XCTAssertEqual(scroll.maximumNumberOfTouches, 2)

        XCTAssertEqual(view.keyboardTap.numberOfTouchesRequired, 3, "A-62")
        XCTAssertEqual(view.rightClickTap.numberOfTouchesRequired, 2)

        // Nothing on the picture asks for a panel. The two hardware aliases and
        // VoiceOver's custom action are the whole list, and they are not here.
        for recognizer in recognizers {
            recognizer.isEnabled = recognizer.isEnabled // touch it, do not fire it
        }
        XCTAssertTrue(summoned.isEmpty)
    }

    /// A-62 / A-60: the gesture and the bar's keyboard action are one switch,
    /// so what the gesture did is what the bar reports.
    func testTheKeyboardGesturePublishesWhatItDid() {
        let (window, view) = hosted()
        defer { window.isHidden = true }
        let client = OMRemoteClient(host: "127.0.0.1")
        var reported: [Bool] = []
        client.keyboardHandler = { reported.append($0) }
        view.keyboardAllowed = true
        // The gesture's body, reached the way the recogniser reaches it.
        XCTAssertTrue(view.presentSoftwareKeyboard(true))
        client.keyboardHandler?(view.softwareKeyboard)
        XCTAssertFalse(view.presentSoftwareKeyboard(false))
        client.keyboardHandler?(view.softwareKeyboard)
        XCTAssertEqual(reported, [true, false])
    }

    func testRaisingNeedsALiveSessionAndDismissingNeverDoes() {
        let (window, view) = hosted()
        defer { window.isHidden = true }

        view.keyboardAllowed = false
        XCTAssertFalse(view.presentSoftwareKeyboard(true),
                       "with no session to type into there is nothing to raise")
        XCTAssertFalse(view.isFirstResponder)

        view.keyboardAllowed = true
        XCTAssertTrue(view.presentSoftwareKeyboard(true))
        XCTAssertTrue(view.softwareKeyboard)
        XCTAssertTrue(view.isFirstResponder, "raising it is taking first responder")

        // A keyboard left up by a lost lease has to be puttable away, so the
        // dismissal is never gated on the session.
        view.keyboardAllowed = false
        XCTAssertFalse(view.presentSoftwareKeyboard(false))
        XCTAssertFalse(view.softwareKeyboard)
        XCTAssertFalse(view.isFirstResponder)
    }

    /// The answer is what UIKit did, not what was asked. This is the property
    /// MERGE-1 could not check, and it is the whole of item 3's client half:
    /// whatever reason there is for no keyboard, the button must read it.
    ///
    /// Measured here, and worth writing down because MERGE-1 §6.3 assumed the
    /// opposite: on iOS 27 a view with `isUserInteractionEnabled = false` *can*
    /// still become first responder, so removing `allowsHitTesting(false)` from
    /// the picture was not what unblocked the keyboard. Being in a window is.
    func testTheAnswerIsWhatUIKitDidRatherThanWhatWasAsked() {
        let (window, view) = hosted()
        defer { window.isHidden = true }
        view.keyboardAllowed = true

        view.isUserInteractionEnabled = false
        let withoutInteraction = view.presentSoftwareKeyboard(true)
        XCTAssertEqual(withoutInteraction, view.isFirstResponder,
                       "the answer has to be UIKit's, whichever way UIKit went")
        XCTAssertEqual(withoutInteraction, view.softwareKeyboard,
                       "a refused raise must not leave the want latched")
        _ = view.presentSoftwareKeyboard(false)

        view.isUserInteractionEnabled = true
        let raised = view.presentSoftwareKeyboard(true)
        XCTAssertTrue(raised)
        XCTAssertEqual(raised, view.isFirstResponder)
    }

    /// A view that is not in a window at all is the same answer.
    func testAViewWithNoWindowReportsNoKeyboard() {
        let client = OMRemoteClient(host: "127.0.0.1")
        let view = client.renderView
        view.keyboardAllowed = true
        XCTAssertFalse(view.presentSoftwareKeyboard(true))
        XCTAssertFalse(view.isFirstResponder)
        XCTAssertFalse(view.softwareKeyboard)
    }

    /// A-43. Three fingers, Moonlight's convention, and the two-finger right
    /// click waits for it: a third finger landing a frame late is otherwise a
    /// right click, which is what "没办法在 remote 里唤出键盘" looked like.
    func testTheThreeFingerTapIsConfiguredAsMoonlightsConvention() {
        let client = OMRemoteClient(host: "127.0.0.1")
        let view = client.renderView
        XCTAssertEqual(view.keyboardTap.numberOfTouchesRequired, 3)
        XCTAssertEqual(view.keyboardTap.numberOfTapsRequired, 1)
        XCTAssertTrue(view.keyboardTap.cancelsTouchesInView)
        XCTAssertEqual(view.rightClickTap.numberOfTouchesRequired, 2)
        XCTAssertTrue(view.gestureRecognizers?.contains(view.keyboardTap) == true,
                      "the gesture is attached to the picture, not merely constructed")
        XCTAssertTrue(view.gestureRecognizers?.contains(view.rightClickTap) == true)
    }

    /// And it is a toggle: the gesture that summoned the keyboard puts it away.
    /// This is the callback the tap fires, driven directly because the gesture
    /// itself cannot be synthesized on this runtime.
    func testTheGestureCallbackTogglesTheKeyboard() {
        let (window, view) = hosted()
        defer { window.isHidden = true }
        view.keyboardAllowed = true

        XCTAssertTrue(view.presentSoftwareKeyboard(!view.softwareKeyboard))
        XCTAssertTrue(view.softwareKeyboard)
        XCTAssertFalse(view.presentSoftwareKeyboard(!view.softwareKeyboard))
        XCTAssertFalse(view.softwareKeyboard)
        XCTAssertFalse(view.isFirstResponder)
    }
}

/// The controller half of the same button: what it publishes, and what it does
/// when the picture cannot take the keyboard from under the overlay.
@MainActor final class RemoteKeyboardControllerTests: XCTestCase {

    /// A backend that can be told whether the picture is able to raise one.
    private final class KeyboardBackend: RemoteBackendDriver {
        var retainedFrame: UIImage?
        var isIdle = true
        var onFirstFrame: ((RemotePixels, CGRect) -> Void)?
        var onStage: ((String) -> Void)?
        var onFailure: ((String) -> Void)?
        var onGesture: ((RemotePictureGesture) -> Void)?
        private(set) var registeredGestures: Set<RemotePictureGesture> = []
        func setRegisteredGestures(_ value: Set<RemotePictureGesture>) { registeredGestures = value }
        var canRaise = true
        private(set) var up = false
        private(set) var hides = 0
        func connect(_ connection: RemoteConnectionDTO, profile: RemoteProfileDTO?) async {}
        func stop() async {}
        func setInputEnabled(_ enabled: Bool) {}
        func toggleKeyboard() -> Bool {
            guard canRaise || up else { return false }
            up.toggle()
            return up
        }
        func hideKeyboard() { up = false; hides += 1 }
    }

    private func make() -> (RemoteSessionController, KeyboardBackend) {
        let backend = KeyboardBackend()
        let controller = RemoteSessionController(driver: backend)
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        return (controller, backend)
    }

    func testTheButtonPublishesWhatTheBackendReachedNotWhatItAskedFor() {
        let (controller, backend) = make()
        controller.toggleKeyboard()
        XCTAssertTrue(controller.keyboardVisible)
        controller.toggleKeyboard()
        XCTAssertFalse(controller.keyboardVisible)
        XCTAssertEqual(backend.hides, 1, "putting it away is a dismissal, not another toggle")

        backend.canRaise = false
        controller.toggleKeyboard()
        XCTAssertFalse(controller.keyboardVisible,
                       "a keyboard that did not come up must not light the button")
    }

    /// REMOTE-2 item 3. If the picture cannot take first responder while the
    /// overlay is over it, the overlay is what gives way — the keyboard is what
    /// the user asked for. MERGE-1 abandoned this path because the queue
    /// refused the want before it was ever enqueued; the enqueue now gates on
    /// the session rather than on the picture.
    func testAnUnraisableKeyboardClosesTheOverlayInsteadOfDoingNothing() {
        let (controller, backend) = make()
        backend.canRaise = false
        var closed = 0
        controller.toggleKeyboard(closingOverlay: { closed += 1 })
        XCTAssertEqual(closed, 0, "with no session there is nothing to close and nothing to raise")

        controller.setPanelVisible(true)
        backend.canRaise = true
        controller.toggleKeyboard(closingOverlay: { closed += 1 })
        XCTAssertTrue(controller.keyboardVisible)
        XCTAssertEqual(closed, 0, "a keyboard that came up in place leaves the overlay alone")
    }
}
