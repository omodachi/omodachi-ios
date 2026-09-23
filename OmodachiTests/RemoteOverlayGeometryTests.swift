import UIKit
import XCTest
@testable import Omodachi

/// ARCH-1 §5 #1 and A-60's rotation lock: the two things that are allowed to
/// cover the picture, and the geometry neither of them may move.
///
/// REMOTE-2 measured what the old behaviour cost. Raising the soft keyboard
/// shrank the window's safe area, the viewport reader reported a smaller
/// rectangle, and the app asked the host to re-plan its output — which moved
/// the desktop's workspaces around and left the picture letterboxed, every time
/// the user typed. A-61 rev 5 is the rule that replaces it: **the keyboard and
/// the panel are layers over the picture, and the host's geometry never moves
/// for either.** The bottom half of the picture is simply covered.
///
/// A-60's lock refuses for a different reason: the user asked for *this*
/// orientation. Both hold the reading they refused, so releasing them spends
/// exactly one resize rather than none or two.
@MainActor final class RemoteOverlayGeometryTests: XCTestCase {
    private func streaming() async throws -> (RemoteSessionController, FakeRemoteHost, FakeBackend) {
        let host = FakeRemoteHost()
        let backend = FakeBackend()
        let controller = RemoteSessionController(service: host, driver: backend,
                                                 heartbeatInterval: .seconds(600),
                                                 backgroundGrace: .seconds(600))
        controller.backendChoice = .vnc
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        controller.start()
        for _ in 0..<400 where await host.resizeCount() == 0 && controller.phase != .connecting {
            try? await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0..<400 where controller.phase != .connecting {
            try? await Task.sleep(for: .milliseconds(5))
        }
        backend.deliverFrame(RemotePixels(width: 1194, height: 834))
        XCTAssertTrue(controller.isStreaming)
        return (controller, host, backend)
    }

    /// #1: `keyboardWillShow` must not reach `viewport_points`. The controller
    /// refuses a viewport change while the keyboard is up, whatever produced it.
    func testTheKeyboardNeverAsksTheHostToRePlanItsOutput() async throws {
        let (controller, host, _) = try await streaming()
        let before = await host.resizeCount()

        controller.toggleKeyboard()
        XCTAssertTrue(controller.keyboardVisible)
        // What a keyboard does to a window: the usable rectangle gets shorter.
        controller.viewportChanged(size: CGSize(width: 1194, height: 500), orientation: "landscape_left")
        try? await Task.sleep(for: .milliseconds(450))
        let afterKeyboard = await host.resizeCount()
        XCTAssertEqual(afterKeyboard, before,
                       "A-61: the keyboard is a layer, and layers do not resize the host")

        // Putting it away does not resize either — nothing ever moved.
        controller.hideKeyboard()
        try? await Task.sleep(for: .milliseconds(450))
        let afterHiding = await host.resizeCount()
        XCTAssertEqual(afterHiding, before)
    }

    /// A-60 rev 5: locked, turning the device sends nothing; unlocking with the
    /// device already turned spends exactly one resize.
    func testTheRotationLockHoldsTheGeometryAndReleasesItOnce() async throws {
        let (controller, host, _) = try await streaming()
        let before = await host.resizeCount()

        controller.toggleRotationLock()
        XCTAssertTrue(controller.rotationLocked)
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        try? await Task.sleep(for: .milliseconds(450))
        let whileLocked = await host.resizeCount()
        XCTAssertEqual(whileLocked, before, "locked means the picture keeps its geometry")

        controller.toggleRotationLock()
        XCTAssertFalse(controller.rotationLocked)
        for _ in 0..<400 where await host.resizeCount() == before {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let afterUnlock = await host.resizeCount()
        XCTAssertEqual(afterUnlock, before + 1,
                       "unlocking with the device already turned is one resize, not none and not two")
    }

    /// The lock belongs to the session. Ending one releases it, so the next
    /// session does not start in an orientation the user locked an hour ago.
    func testTheLockIsReleasedWithTheSession() async throws {
        let (controller, _, _) = try await streaming()
        controller.toggleRotationLock()
        XCTAssertTrue(controller.rotationLocked)
        controller.stop()
        for _ in 0..<400 where controller.hasSession {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.rotationLocked)
    }

    /// A-60's one backend-dependent quick action, against the controller rather
    /// than the table: VNC carries no audio channel.
    func testOnlyTheSunshineBackendCanPlayTheHostsSound() async throws {
        let (controller, _, _) = try await streaming()
        XCTAssertEqual(controller.backend, .vnc)
        XCTAssertFalse(controller.backendHasAudio,
                       "the host published `vnc.audio: false`, so the control is dimmed for a reason")
        controller.setHostAudio(true)
        XCTAssertFalse(controller.hostAudioOn, "there is no channel to turn on")
    }
}
