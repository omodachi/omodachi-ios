import SwiftUI
import UIKit
import RemoteInputCore
import XCTest
@testable import Omodachi

/// A host that answers `/v1/remote` from memory: one session, one monotonic
/// revision, 409 `stale_revision` for an `expected_revision` that is not current.
actor FakeRemoteHost: RemoteSessionServing {
    private(set) var revision = 0
    private(set) var created: [RemoteCreateRequest] = []
    private(set) var resizes: [RemoteResizeRequest] = []
    /// ARCH-1 §5 #1: the number a keyboard and a rotation lock must not move.
    func resizeCount() -> Int { resizes.count }
    private(set) var heartbeats = 0
    private(set) var presented: [RemotePresentedRequest] = []
    private(set) var releases: [String] = []
    private var live: RemoteSessionDTO?
    private var backend: RemoteBackend = .vnc
    /// ROTATE-1: the session is in the mode it was asked for, because a turn
    /// re-plans a takeover and never an extend.
    private var mode: RemoteMode = .extend
    var failNextCreate: RemoteRequestError?
    /// Answers the first resize with a stale revision the way a host does when a
    /// second rotation overtakes the first.
    var staleOnce = false

    func setFailNextCreate(_ value: RemoteRequestError?) { failNextCreate = value }
    /// STREAM-1: what `GET /v1/preferences` answers. `nil` is a host that
    /// publishes nothing, exactly as the protocol's default does.
    private var preferences: RemoteHostPreferences?
    func setPreferences(_ value: RemoteHostPreferences?) { preferences = value }
    func remoteHostPreferences() async throws -> RemoteHostPreferences {
        preferences ?? RemoteHostPreferences(profile_defaults: nil)
    }
    func setStaleOnce(_ value: Bool) { staleOnce = value }

    private func makeSession(width: Int, height: Int) -> RemoteSessionDTO {
        revision += 1
        let connection: String = backend == .vnc
            ? #"{"backend":"vnc","transport":"wss","path":"/v1/remote/sessions/rs_0123456789abcdef0123456789abcdef/vnc","output_id":"OMODACHI-0123456789abcdef","framebuffer_pixels":{"width":\#(width),"height":\#(height)}}"#
            : #"{"backend":"sunshine","host":"192.168.1.10","https_port":47984,"app_name":"Omodachi Desktop","output_id":"OMODACHI-0123456789abcdef","stream_pixels":{"width":\#(width),"height":\#(height)},"fps":60}"#
        let body = #"{"id":"rs_0123456789abcdef0123456789abcdef","backend":"\#(backend.rawValue)","mode":"\#(mode.rawValue)","state":"ready","revision":\#(revision),"ttl_seconds":60,"placement":"right","lock_local_input":false,"connection":\#(connection)}"#
        let value = try! JSONDecoder().decode(RemoteSessionDTO.self, from: Data(body.utf8))
        live = value
        return value
    }

    /// REMOTE-SAFE-1: a host that takes `bar_occlusion_points`. Off by
    /// default, which is every host from before it.
    private var barOcclusion = false
    func setBarOcclusion(_ value: Bool) { barOcclusion = value }
    /// TAIL-2 P2-2: the asking device's tailnet path is a DERP relay.
    private var relayed = false
    func setRelayed(_ value: Bool) { relayed = value }
    func remoteCapabilities() async throws -> RemoteCapabilitiesDTO {
        let extra = (barOcclusion ? #","bar_occlusion":true"# : "")
            + (relayed ? #","default_backend":"vnc","road":{"kind":"tailnet","relayed":true,"reason":"tailnet_relayed"}"# : "")
        return try JSONDecoder().decode(RemoteCapabilitiesDTO.self, from: Data((#"{"backends":{"sunshine":{"available":true,"reason":null},"vnc":{"available":true,"reason":null,"audio":false}},"modes":["extend","takeover"],"placement_options":["right"],"lock_local_input_supported":true,"encoder_limits":null"# + extra + "}").utf8))
    }
    func createRemoteSession(_ body: RemoteCreateRequest) async throws -> RemoteSessionDTO {
        if let failure = failNextCreate { failNextCreate = nil; throw failure }
        created.append(body)
        backend = body.backend
        mode = body.mode
        return makeSession(width: 2560, height: 1600)
    }
    /// REMOTE-4: the host re-preparing the backend under a session it still
    /// holds. `GET` answers with the session, in a state that is not `ready`
    /// and carries no connection, for this many reads.
    var notReadyReads = 0
    func setNotReadyReads(_ value: Int) { notReadyReads = value }
    /// The host really did lose the session (a failed reconfigure, a TTL).
    func forgetSession() { live = nil }
    /// One host-side rebuild: the revision moves, the id does not.
    func rebuild() -> RemoteSessionDTO { makeSession(width: 2560, height: 1600) }

    func remoteSession(id: String) async throws -> RemoteSessionDTO {
        guard let live else { throw RemoteRequestError(code: "session_not_found", status: 404) }
        if notReadyReads > 0 {
            notReadyReads -= 1
            let body = #"{"id":"\#(live.id)","backend":"\#(live.backend.rawValue)","mode":"\#(mode.rawValue)","state":"resizing","revision":\#(revision),"ttl_seconds":60,"placement":"right","lock_local_input":false,"connection":null}"#
            return try JSONDecoder().decode(RemoteSessionDTO.self, from: Data(body.utf8))
        }
        return live
    }
    /// ROTATE-2: a host that takes a while to re-plan, or fails once.
    var resizeDelay: Duration = .zero
    var failNextResize: RemoteRequestError?
    func setResizeDelay(_ value: Duration) { resizeDelay = value }
    func setFailNextResize(_ value: RemoteRequestError?) { failNextResize = value }
    func resizeRemoteSession(id: String, body: RemoteResizeRequest) async throws -> RemoteSessionDTO {
        if resizeDelay > .zero { try? await Task.sleep(for: resizeDelay) }
        if let failure = failNextResize { failNextResize = nil; throw failure }
        if staleOnce { staleOnce = false; throw RemoteRequestError(code: "stale_revision", status: 409) }
        guard body.expected_revision == revision else { throw RemoteRequestError(code: "stale_revision", status: 409) }
        resizes.append(body)
        return makeSession(width: Int(body.viewport_points.height) * 2, height: Int(body.viewport_points.width) * 2)
    }
    func switchRemoteBackend(id: String, body: RemoteBackendRequest) async throws -> RemoteSessionDTO {
        guard body.expected_revision == revision else { throw RemoteRequestError(code: "stale_revision", status: 409) }
        backend = body.backend
        return makeSession(width: 2560, height: 1600)
    }
    /// REMOTE-2: a host that refuses the next `n` beats the way a busy or
    /// briefly unreachable one does, and a host that has forgotten the session.
    var heartbeatFailures = 0
    var heartbeatMissing = false
    func setHeartbeatFailures(_ value: Int) { heartbeatFailures = value }
    func setHeartbeatMissing(_ value: Bool) { heartbeatMissing = value }

    func heartbeatRemoteSession(id: String) async throws -> RemoteHeartbeatDTO {
        heartbeats += 1
        if heartbeatMissing { throw RemoteRequestError(code: "session_not_found", status: 404) }
        if heartbeatFailures > 0 {
            heartbeatFailures -= 1
            throw RemoteRequestError(code: "internal_error", status: 503)
        }
        return RemoteHeartbeatDTO(revision: revision, state: "ready")
    }
    func reportRemotePresented(id: String, body: RemotePresentedRequest) async throws -> RemotePresentedDTO {
        presented.append(body)
        return RemotePresentedDTO(accepted: true, reason: nil, revision: revision)
    }
    func releaseRemoteSession(id: String) async throws -> RemoteReleaseDTO {
        releases.append(id)
        live = nil
        return RemoteReleaseDTO(released: true, errors: [])
    }

    /// REMOTE-INPUT-2: what was typed, and the host's own rule — one id is
    /// typed once. `textFailures` answer the next attempts the given way
    /// (`nil` = the reply is lost after the host typed it).
    private(set) var textRequests: [RemoteTextRequest] = []
    private(set) var typedTexts: [String] = []
    private var typedIDs: Set<String> = []
    private var textFailures: [RemoteRequestError?] = []
    func setTextFailures(_ value: [RemoteRequestError?]) { textFailures = value }
    func typeRemoteText(id: String, body: RemoteTextRequest) async throws -> RemoteTextDTO {
        textRequests.append(body)
        if !textFailures.isEmpty {
            let failure = textFailures.removeFirst()
            if let failure { throw failure }
            // Typed, and the reply never arrived.
            if let sendID = body.id, typedIDs.insert(sendID).inserted { typedTexts.append(body.text) }
            throw CompanionHostError.transport(message: "lost")
        }
        guard live?.id == id else { throw RemoteRequestError(code: "session_not_found", status: 404) }
        if let sendID = body.id, !typedIDs.insert(sendID).inserted {
            return RemoteTextDTO(typed: true, chars: body.text.unicodeScalars.count, replayed: true)
        }
        typedTexts.append(body.text)
        return RemoteTextDTO(typed: true, chars: body.text.unicodeScalars.count)
    }
}

/// A backend that only records what the controller asked it to do and produces
/// a frame exactly when the test says so.
@MainActor final class FakeBackend: RemoteBackendDriver {
    var retainedFrame: UIImage? = UIImage()
    var isIdle = true
    var onFirstFrame: ((RemotePixels, CGRect) -> Void)?
    var onStage: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onGesture: ((RemotePictureGesture) -> Void)?
    /// GEST-1 / N-37: what the picture was told to listen for, in order.
    private(set) var registeredGestures: [Set<RemotePictureGesture>] = []
    func setRegisteredGestures(_ value: Set<RemotePictureGesture>) { registeredGestures.append(value) }
    private(set) var connections: [RemoteConnectionDTO] = []
    private(set) var profiles: [RemoteProfileDTO?] = []
    private(set) var stops = 0
    private(set) var inputEnabled: [Bool] = []

    func connect(_ connection: RemoteConnectionDTO, profile: RemoteProfileDTO?) async {
        connections.append(connection)
        profiles.append(profile)
        isIdle = false
    }
    func stop() async { stops += 1; isIdle = true }
    func setInputEnabled(_ enabled: Bool) { inputEnabled.append(enabled) }
    /// A-43. The fake keyboard is a plain latch, so a test can assert the
    /// controller published what the backend answered.
    private(set) var keyboardUp = false
    func toggleKeyboard() -> Bool { keyboardUp.toggle(); return keyboardUp }
    func hideKeyboard() { keyboardUp = false }

    /// REMOTE-INPUT-2: what the compose bar handed to the host, in order.
    enum Passed: Equatable { case key(UInt16, Bool), chord(UInt16, UInt8) }
    private(set) var passed: [Passed] = []
    private(set) var composeOwnsKeyboard = false
    private(set) var keyboardTap: (() -> Void)?
    func passKey(usage: UInt16, down: Bool) { passed.append(.key(usage, down)) }
    func passChord(usage: UInt16, modifiers: RemoteModifiers) { passed.append(.chord(usage, modifiers.rawValue)) }
    func setComposeOwnsKeyboard(_ owns: Bool) { composeOwnsKeyboard = owns }
    func setKeyboardTapHandler(_ handler: (() -> Void)?) { keyboardTap = handler }

    func deliverFrame(_ pixels: RemotePixels, rect: CGRect = CGRect(x: 0, y: 0, width: 1194, height: 746)) {
        onFirstFrame?(pixels, rect)
    }
}

@MainActor final class RemoteSessionControllerTests: XCTestCase {
    /// REMOTE-2: the two timings are injected so a case can drive minutes of
    /// session time without spending them. Production keeps 10 s and 20 s.
    private func make(heartbeatInterval: Duration = .seconds(10),
                      backgroundGrace: Duration = .seconds(20)) -> (RemoteSessionController, FakeRemoteHost, FakeBackend) {
        let host = FakeRemoteHost()
        let backend = FakeBackend()
        let controller = RemoteSessionController(service: host, driver: backend,
                                                 heartbeatInterval: heartbeatInterval,
                                                 backgroundGrace: backgroundGrace)
        // SPEC-I: the backend choice now defaults to `.auto`, which asks the
        // host. These cases are about the VNC path, so they say so.
        controller.backendChoice = .vnc
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        return (controller, host, backend)
    }

    private func settle(_ message: String, _ predicate: @escaping () async -> Bool) async {
        for _ in 0..<400 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
    }

    func testCreateConnectsTheBackendAndOnlyStreamsAfterAFrame() async throws {
        let (controller, host, backend) = make()
        XCTAssertEqual(controller.phase, .idle)
        controller.start()
        await settle("never reached connecting") { controller.phase == .connecting }
        XCTAssertFalse(controller.isStreaming, "connecting is not streaming")
        await settle("backend never connected") { await backend.connections.count == 1 }
        XCTAssertEqual(backend.connections.first?.vnc?.path,
                       "/v1/remote/sessions/rs_0123456789abcdef0123456789abcdef/vnc")
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        XCTAssertEqual(controller.phase, .streaming)
        XCTAssertTrue(controller.isStreaming)
        XCTAssertEqual(controller.decoded, "2560 × 1600 · RFB")
        // The create body carries exactly what remote-api.md declares, and
        // never asks the host to lock the physical keyboard and mouse.
        let created = await host.created
        XCTAssertEqual(created.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(created[0])) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["backend", "mode", "viewport_points", "orientation", "logical_long_edge",
                                        "quality", "decoder", "placement", "lock_local_input", "ttl_seconds"])
        XCTAssertEqual(body["lock_local_input"] as? Bool, false)
        XCTAssertEqual(body["mode"] as? String, "extend")
        XCTAssertEqual(body["ttl_seconds"] as? Double, 60)
        XCTAssertEqual((body["viewport_points"] as? [String: Double])?["width"], 1194)
        // Presentation telemetry is reported, and it blocks nothing.
        await settle("presented was never reported") { await host.presented.count == 1 }
        let reported = await host.presented
        let telemetry = try XCTUnwrap(reported.first)
        XCTAssertEqual(telemetry.decoded_pixels, RemotePixels(width: 2560, height: 1600))
        XCTAssertEqual(telemetry.revision, 1)
    }

    /// PERF-1. The edge strip is laid out beside the picture, not over it, so
    /// the viewport the app reports — and therefore the output the host plans —
    /// is the area the canvas can actually draw into. If the strip ever goes
    /// back to being an overlay this fails, because the host would again be
    /// asked to fill a rectangle whose left column the app covers with its own
    /// chrome, over the host's own left-edge Omarchy bar.
    func testTheReportedViewportIsTheWholeWindow() async throws {
        let (controller, host, backend) = make()
        let screen = CGSize(width: 1210, height: 834)
        let window = UIWindow(frame: CGRect(origin: .zero, size: screen))
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        let hosting = UIHostingController(
            rootView: RemoteStageView(controller: controller, profile: profile)
                .environmentObject(HomeStore(defaults: UserDefaults(suiteName: "omodachi.perf1.tests")!,
                                             autoConnect: false)))
        window.rootViewController = hosting
        window.isHidden = false
        hosting.view.frame = CGRect(origin: .zero, size: screen)
        hosting.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        hosting.view.layoutIfNeeded()

        controller.start()
        await settle("the session was never created") { await host.created.count == 1 }
        let requests = await host.created
        let created = try XCTUnwrap(requests.first)
        // A-40 (UX-1 item 1): the native strip is gone, so the whole window is
        // the picture and the viewport the host plans for is the window.
        XCTAssertEqual(created.viewport_points.width, screen.width,
                       "with no chrome of its own, Remote reports the whole window")
        XCTAssertEqual(created.viewport_points.height, screen.height)
        await settle("the backend never connected") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        XCTAssertTrue(controller.isStreaming)
        let resizes = await host.resizes
        XCTAssertEqual(resizes.count, 0, "showing the strip must not cost a resize round trip")
        window.isHidden = true
    }

    /// INPUT-2. The session's want is a state the controller can be asked for
    /// at any time, not a message it sends once. Every transition that can move
    /// it re-applies it, so a backend that could not honour the want when it
    /// was first expressed is told again rather than left closed.
    func testTheSessionReAppliesItsInputWantOnEveryTransition() async throws {
        let (controller, _, backend) = make()
        // ROTATE-1: only a takeover re-plans on a turn.
        controller.mode = .takeover
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        XCTAssertEqual(backend.inputEnabled, [false], "connecting closes input")
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        XCTAssertEqual(backend.inputEnabled.last, true, "a presented frame opens it")

        // The Panel is the want moving, and nothing else.
        controller.setPanelVisible(true)
        XCTAssertEqual(backend.inputEnabled.last, false)
        controller.setPanelVisible(false)
        XCTAssertEqual(backend.inputEnabled.last, true)

        // A rotation closes it, and the new first frame opens it again without
        // anybody having to toggle the Panel in between.
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        await settle("never reconnected after resize") { await backend.connections.count == 2 }
        XCTAssertEqual(backend.inputEnabled.last, false, "a session with no frame carries no input")
        backend.deliverFrame(RemotePixels(width: 2388, height: 1668))
        XCTAssertEqual(backend.inputEnabled.last, true)

        // And releasing closes it before the media leg is asked to stop.
        controller.stop()
        await settle("never released") { controller.phase == .idle }
        XCTAssertEqual(backend.inputEnabled.last, false)
    }

    /// A Panel that is open when the frame lands must not be typed through, and
    /// the want that survives the frame is still "closed" until it is closed.
    func testAPanelOpenAcrossTheFirstFrameKeepsInputClosed() async throws {
        let (controller, _, backend) = make()
        controller.setPanelVisible(true)
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        XCTAssertTrue(controller.isStreaming)
        XCTAssertEqual(backend.inputEnabled.last, false, "the Panel is over the picture")
        controller.setPanelVisible(false)
        XCTAssertEqual(backend.inputEnabled.last, true)
    }

    func testRotationStopsDecodingResizesAndKeepsTheOldFrameUntilTheNewOne() async throws {
        let (controller, host, backend) = make()
        // ROTATE-1: only a takeover re-plans on a turn.
        controller.mode = .takeover
        controller.start()
        await settle("no first connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        XCTAssertNil(controller.retainedFrame)

        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        await settle("never reconnected after resize") { await backend.connections.count == 2 }
        XCTAssertNotNil(controller.retainedFrame, "the old picture stays up until the new first frame")
        XCTAssertFalse(controller.isStreaming, "a reconnecting session is not streaming")
        XCTAssertEqual(backend.stops, 1, "the client stops its own media before asking for new geometry")
        let resizes = await host.resizes
        XCTAssertEqual(resizes.count, 1)
        XCTAssertEqual(resizes[0].expected_revision, 1)
        XCTAssertEqual(resizes[0].orientation, "portrait")
        XCTAssertEqual(resizes[0].viewport_points, RemotePoints(width: 834, height: 1194))
        backend.deliverFrame(RemotePixels(width: 2388, height: 1668))
        XCTAssertNil(controller.retainedFrame, "the retained frame is replaced by the new one")
        XCTAssertEqual(controller.phase, .streaming)
    }

    func testAStaleRevisionIsRetriedAgainstTheReReadSession() async throws {
        let (controller, host, backend) = make()
        // ROTATE-1: only a takeover re-plans on a turn.
        controller.mode = .takeover
        controller.start()
        await settle("no first connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await host.setStaleOnce(true)
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        await settle("the stale revision was not retried") { await backend.connections.count == 2 }
        let retried = await host.resizes
        XCTAssertEqual(retried.count, 1)
        XCTAssertFalse(controller.phase.isFailed)
    }

    func testStopReleasesTheHostSessionAndReturnsToIdle() async throws {
        let (controller, host, backend) = make()
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        controller.stop()
        await settle("never returned to idle") { controller.phase == .idle }
        let released = await host.releases
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(backend.stops, 1)
        XCTAssertNil(controller.session)
        XCTAssertFalse(backend.inputEnabled.last ?? true, "input is released before the session ends")
    }

    /// REMOTE-2 item 1. Backgrounding still gives the output back rather than
    /// leaving it to the TTL — but not on the first `.background` UIKit
    /// reports. The grace is what makes "the user glanced at another app" and
    /// "the user put the iPad down" different events.
    func testBackgroundingReleasesTheSessionAfterItsGraceRatherThanLeavingItToTheTTL() async throws {
        let (controller, host, backend) = make(backgroundGrace: .milliseconds(20))
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never streamed") { controller.isStreaming }
        controller.setForeground(false)
        XCTAssertNotNil(controller.session, "the session must survive the moment of leaving")
        await settle("background did not end the session") { controller.phase == .idle }
        let released = await host.releases
        XCTAssertEqual(released.count, 1)
    }

    /// Coming back cancels it. Nothing about a momentary `.inactive` — a
    /// banner, the app switcher, a system sheet — may cost the user a session
    /// that is still perfectly alive on the host.
    func testComingBackBeforeTheGraceKeepsTheSessionAndTheBeat() async throws {
        let (controller, host, backend) = make(heartbeatInterval: .milliseconds(10),
                                               backgroundGrace: .milliseconds(300))
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never streamed") { controller.isStreaming }
        controller.setForeground(false)
        try? await Task.sleep(for: .milliseconds(40))
        controller.setForeground(true)
        let beats = await host.heartbeats
        // POLISH-R2: the stream was paused while away and is dialled again
        // on return; its first frame puts the picture back.
        await settle("not dialled again on return") { await backend.connections.count == 2 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(controller.phase, .streaming, "coming back did not cancel the pending release")
        XCTAssertNotNil(controller.session)
        let released = await host.releases
        XCTAssertEqual(released.count, 0)
        let later = await host.heartbeats
        XCTAssertGreaterThan(later, beats, "the beat stopped while the app was away")
    }

    /// POLISH-R2 (Leo, 2026-10-05: "切出 app 再次连接就会有问题"). Leaving the
    /// app stops the stream cleanly and keeps the session; nothing is dialled
    /// while away, even when the stream breaks; coming back dials the same
    /// session once, at once.
    func testLeavingPausesTheStreamAndComingBackDialsTheSameSessionOnce() async throws {
        let (controller, host, backend) = make(heartbeatInterval: .milliseconds(10),
                                               backgroundGrace: .seconds(30))
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never streamed") { controller.isStreaming }
        let session = try XCTUnwrap(controller.session?.id)
        controller.setForeground(false)
        await settle("the stream was not stopped on leaving") { backend.stops >= 1 }
        XCTAssertTrue(controller.pausedForBackground)
        backend.onFailure?("The remote stream ended.")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(backend.connections.count, 1, "nothing may be dialled from the background")
        controller.setForeground(true)
        await settle("not dialled on return") { await backend.connections.count == 2 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("no picture after return") { controller.isStreaming }
        XCTAssertEqual(controller.session?.id, session, "the same session, not a new one")
        let releases = await host.releases
        XCTAssertTrue(releases.isEmpty)
        let created = await host.created.count
        XCTAssertEqual(created, 1)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(backend.connections.count, 2, "dialled once")
    }

    /// POLISH-R2 with TUTORIAL-1: a turn of the device while away is planned
    /// once, after the picture is back - not dropped, not twice.
    func testATurnWhileAwayIsPlannedOnceAfterTheReturn() async throws {
        let (controller, host, backend) = make(heartbeatInterval: .milliseconds(10),
                                               backgroundGrace: .seconds(30))
        // ROTATE-1: only a takeover re-plans on a turn.
        controller.mode = .takeover
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never streamed") { controller.isStreaming }
        let before = await host.resizeCount()
        controller.setForeground(false)
        await settle("not paused") { controller.pausedForBackground }
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        controller.viewportChanged(size: CGSize(width: 834, height: 1194), orientation: "portrait")
        controller.setForeground(true)
        await settle("not dialled on return") { await backend.connections.count == 2 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("the turn was never planned") { await host.resizeCount() == before + 1 }
        try? await Task.sleep(for: .milliseconds(500))
        let after = await host.resizeCount()
        XCTAssertEqual(after, before + 1, "one re-plan per turn")
    }

    /// Several trips out and back in a row, each a clean resume.
    func testRepeatedTripsOutAndBackEachResume() async throws {
        let (controller, host, backend) = make(heartbeatInterval: .milliseconds(10),
                                               backgroundGrace: .seconds(30))
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        for trip in 1...3 {
            controller.setForeground(false)
            await settle("trip \(trip): not paused") { controller.pausedForBackground }
            controller.setForeground(true)
            await settle("trip \(trip): not dialled") { await backend.connections.count == trip + 1 }
            backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
            await settle("trip \(trip): no picture") { controller.isStreaming }
        }
        let releases = await host.releases
        XCTAssertTrue(releases.isEmpty)
    }

    /// REMOTE-2 item 1, the rule itself: while a session exists the beat goes
    /// out, and the overlay is not one of the things allowed to stop it.
    /// MERGE-1 §8 recorded three sessions dying exactly one 60 s TTL after the
    /// last beat, and the last beat was the moment the overlay opened.
    ///
    /// 10 ms stands in for the production 10 s, so 18 beats is the three
    /// minutes the spec asks for — spent in under a second.
    func testAnOpenOverlayNeverStopsTheHeartbeat() async throws {
        let (controller, host, backend) = make(heartbeatInterval: .milliseconds(10))
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never streamed") { controller.isStreaming }

        controller.setPanelVisible(true)
        XCTAssertFalse(controller.inputReady, "the overlay is supposed to close the input gate")
        await settle("the beat stopped while the overlay was open") { await host.heartbeats >= 18 }

        XCTAssertTrue(controller.panelVisible, "the overlay never closed during the run")
        XCTAssertTrue(controller.heartbeatRunning)
        XCTAssertNotNil(controller.session)
        XCTAssertEqual(controller.phase, .streaming)
        let released = await host.releases
        XCTAssertEqual(released.count, 0)
    }

    /// A beat the host refuses for any reason other than "that session is
    /// gone" is a reason to beat again. The loop used to `return` on a client
    /// it could not build and to swallow every other failure without saying
    /// so, either of which leaves a live session unfed until the TTL.
    func testARefusedBeatIsRetriedRatherThanEndingTheLoop() async throws {
        let (controller, host, backend) = make(heartbeatInterval: .milliseconds(10))
        await host.setHeartbeatFailures(5)
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never streamed") { controller.isStreaming }
        await settle("the loop gave up after a refused beat") { await host.heartbeats >= 6 }
        XCTAssertTrue(controller.heartbeatRunning)
        XCTAssertNotNil(controller.session)
        let released = await host.releases
        XCTAssertEqual(released.count, 0)
    }

    /// The one refusal that does end it: the host says the session is gone.
    func testTheHostSayingTheSessionIsGoneEndsTheLoop() async throws {
        let (controller, host, backend) = make(heartbeatInterval: .milliseconds(10))
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        await settle("never streamed") { controller.isStreaming }
        await host.setHeartbeatMissing(true)
        await settle("a missing session must end the run") { controller.phase.isFailed }
        XCTAssertFalse(controller.heartbeatRunning)
        XCTAssertTrue(controller.message.contains(ReasonText.message("session_not_found", domain: .remote)))
    }

    func testAnExistingSessionOnTheHostFailsWithItsOwnReason() async throws {
        let (controller, _, backend) = make()
        let host = FakeRemoteHost()
        await host.setFailNextCreate(RemoteRequestError(code: "remote_session_exists", status: 409))
        let blocked = RemoteSessionController(service: host, driver: backend)
        var profile = HostProfile(); profile.mock = false; profile.companionURL = "https://omarchy.invalid:8099"
        blocked.configure(profile: profile)
        blocked.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        blocked.start()
        await settle("a 409 must surface as a failure") { blocked.phase.isFailed }
        XCTAssertTrue(blocked.message.contains(ReasonText.message("remote_session_exists", domain: .remote)))
        XCTAssertEqual(controller.phase, .idle)
    }

    /// POLISH-R item 4. The app was killed mid-session; the host still holds
    /// that session for its 60 s heartbeat, owned by this same device. The
    /// next start ends the leftover and goes on, instead of a 409 card.
    func testThisDevicesOwnLeftoverIsEndedAndTheSessionStarts() async throws {
        let key = "omodachi.deviceID.v1"
        let previous = AppDefaults.shared.string(forKey: key)
        AppDefaults.shared.set("ios-polish-r-test", forKey: key)
        defer { AppDefaults.shared.set(previous, forKey: key) }
        let (controller, host, backend) = make()
        let owner = RemoteRequestError.Owner(sessionID: "rs_leftover", deviceID: "ios-polish-r-test",
                                             deviceName: "iPad", mode: .takeover, backend: .sunshine, startedAt: nil)
        await host.setFailNextCreate(RemoteRequestError(code: "remote_session_exists", status: 409, owner: owner))
        controller.start()
        await settle("the leftover blocked the start") { await backend.connections.count == 1 }
        let releases = await host.releases
        XCTAssertEqual(releases, ["rs_leftover"], "only the leftover, and only once")
        XCTAssertNil(controller.sessionOwner)
        XCTAssertFalse(controller.phase.isFailed)
    }

    /// Another device's session is never ended from here; the card still asks.
    func testSomebodyElsesSessionIsNeverEndedFromHere() async throws {
        let key = "omodachi.deviceID.v1"
        let previous = AppDefaults.shared.string(forKey: key)
        AppDefaults.shared.set("ios-polish-r-test", forKey: key)
        defer { AppDefaults.shared.set(previous, forKey: key) }
        let (controller, host, _) = make()
        let owner = RemoteRequestError.Owner(sessionID: "rs_theirs", deviceID: "ios-someone-else",
                                             deviceName: "iPhone", mode: .extend, backend: .sunshine, startedAt: nil)
        await host.setFailNextCreate(RemoteRequestError(code: "remote_session_exists", status: 409, owner: owner))
        controller.start()
        await settle("a 409 must surface") { controller.phase.isFailed }
        let releases = await host.releases
        XCTAssertTrue(releases.isEmpty)
        XCTAssertEqual(controller.sessionOwner?.sessionID, "rs_theirs")
        XCTAssertFalse(controller.canReclaimSession)
    }

    func testABackendSwitchGoesThroughTheSameStopAndReconnect() async throws {
        let (controller, host, backend) = make()
        controller.start()
        await settle("no connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        controller.changeBackend(to: .sunshine)
        await settle("backend switch never reconnected") { await backend.connections.count == 2 }
        XCTAssertEqual(controller.backend, .sunshine)
        XCTAssertEqual(backend.connections.last?.sunshine?.appName, "Omodachi Desktop")
        XCTAssertEqual(backend.connections.last?.sunshine?.httpsPort, 47984)
    }
}

/// The wire shapes, checked against the host's own generated fixtures.
final class RemoteWireTests: XCTestCase {
    /// POLISH-R2: a release with a failed step decodes (it used to throw, and
    /// the App's retry made the host end the session a second time).
    func testAReleaseWithFailedStepsDecodes() throws {
        let failed = try JSONDecoder().decode(RemoteReleaseDTO.self, from: Data(
            #"{"released":false,"errors":[{"step":"backend","code":"session_not_stopped"},{"step":"workspaces","code":"x"}]}"#.utf8))
        XCTAssertFalse(failed.released)
        XCTAssertEqual(failed.errors, ["backend", "workspaces"])
        let clean = try JSONDecoder().decode(RemoteReleaseDTO.self, from: Data(#"{"released":true,"errors":[]}"#.utf8))
        XCTAssertTrue(clean.released)
        let names = try JSONDecoder().decode(RemoteReleaseDTO.self, from: Data(#"{"released":false,"errors":["backend"]}"#.utf8))
        XCTAssertEqual(names.errors, ["backend"])
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: RemoteSessionControllerTests.self).url(forResource: name, withExtension: "json", subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }

    func testSessionFixtureDecodesWithItsVNCConnection() throws {
        let session = try JSONDecoder().decode(RemoteSessionDTO.self, from: fixture("remote-session"))
        XCTAssertEqual(session.id, "rs_00000000000000000000000000000000")
        XCTAssertEqual(session.backend, .vnc)
        XCTAssertEqual(session.mode, .extend)
        XCTAssertEqual(session.revision, 2)
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.lockLocalInput, false)
        // POLISH-U: core's fixture as core writes it today (the copy here had
        // drifted): the stream and the VNC framebuffer are the output's mode
        // pixels, and the connection names the framebuffer it starts at.
        XCTAssertEqual(session.profile?.stream_pixels, RemotePixels(width: 2560, height: 1788))
        let vnc = try XCTUnwrap(session.connection?.vnc)
        XCTAssertEqual(vnc.path, "/v1/remote/sessions/rs_00000000000000000000000000000000/vnc")
        XCTAssertEqual(vnc.framebufferPixels, RemotePixels(width: 2560, height: 1788))
        XCTAssertEqual(vnc.initialFramebufferPixels, RemotePixels(width: 2560, height: 1788))
        XCTAssertEqual(session.profile?.output_mode_pixels, RemotePixels(width: 2560, height: 1788))
        XCTAssertNil(session.connection?.sunshine, "a VNC connection is never read as a Sunshine one")
    }

    func testConnectionFixtureAndTheSunshineShape() throws {
        let vnc = try JSONDecoder().decode(RemoteConnectionDTO.self, from: fixture("remote-connection"))
        XCTAssertEqual(vnc.decodedPixels, RemotePixels(width: 2560, height: 1788))
        let sunshine = try JSONDecoder().decode(RemoteConnectionDTO.self, from: Data(#"{"backend":"sunshine","host":"192.168.1.11","https_port":47984,"app_name":"Omodachi Desktop","output_id":"OMODACHI-abc","stream_pixels":{"width":2560,"height":1440},"fps":60}"#.utf8))
        XCTAssertEqual(sunshine.sunshine?.appName, "Omodachi Desktop")
        XCTAssertEqual(sunshine.decodedPixels, RemotePixels(width: 2560, height: 1440))
        XCTAssertNil(sunshine.vnc)
        // A VNC document that does not name the authenticated bridge is not
        // usable: no raw host/port endpoint is ever accepted on this path.
        for body in [#"{"backend":"vnc","transport":"tcp","host":"192.168.1.10","port":5901,"output_id":"OMODACHI-abc","framebuffer_pixels":{"width":100,"height":100}}"#,
                     #"{"backend":"vnc","transport":"ssh-forward","host":"127.0.0.1","port":5901,"output_id":"OMODACHI-abc","framebuffer_pixels":{"width":100,"height":100}}"#,
                     #"{"backend":"vnc","transport":"wss","path":"/v1/events","output_id":"OMODACHI-abc","framebuffer_pixels":{"width":100,"height":100}}"#,
                     #"{"backend":"vnc","transport":"wss","path":"/v1/remote/sessions/rs_abc/audio","output_id":"OMODACHI-abc","framebuffer_pixels":{"width":100,"height":100}}"#] {
            let exposed = try JSONDecoder().decode(RemoteConnectionDTO.self, from: Data(body.utf8))
            XCTAssertNil(exposed.vnc, "only the host's own session-scoped bridge path is accepted: \(body)")
        }
    }

    func testCapabilitiesFixtureReportsWhyABackendIsUnavailable() throws {
        let capabilities = try JSONDecoder().decode(RemoteCapabilitiesDTO.self, from: fixture("remote-capabilities"))
        XCTAssertFalse(capabilities.available(.sunshine))
        XCTAssertEqual(capabilities.reason(.vnc), "backend_not_installed")
        XCTAssertEqual(capabilities.modes, ["extend", "takeover"])
        XCTAssertEqual(capabilities.encoder_limits?.max_fps, 60)
    }

    func testTheVNCQualityBudgetIsTheDecoderCeilingNotAnEncoderOne() {
        XCTAssertEqual(RemoteQuality.forBackend(.vnc).max_pixels, RemoteDecoderLimits().max_pixels)
        XCTAssertEqual(RemoteQuality.forBackend(.sunshine).max_pixels, 4_000_000)
        // VideoToolbox H.264, declared rather than inferred from the viewport.
        XCTAssertEqual(RemoteDecoderLimits().max_width, 4096)
        XCTAssertEqual(RemoteDecoderLimits().max_height, 2304)
    }

    func testEveryDocumentedErrorCodeHasItsOwnExplanation() {
        let codes = ["remote_session_exists", "stale_revision", "session_not_found", "session_not_ready",
                     "permission_denied", "media_pairing_required", "wayvnc_0_10_1_required",
                     "sunshine_desktop_unavailable", "remote_runtime_unavailable", "dynamic_resolution_policy_denied",
                     "host_waking", "vnc_bridge_exists", "vnc_bridge_unavailable"]
        var seen = Set<String>()
        for code in codes {
            let error = RemoteRequestError(code: code, status: 409)
            XCTAssertFalse(error.userMessage.isEmpty, code)
            if code != "stale_revision" { XCTAssertTrue(seen.insert(error.userMessage).inserted, "duplicate copy for \(code)") }
        }
        XCTAssertTrue(RemoteRequestError(code: "stale_revision", status: 409).isStaleRevision)
        XCTAssertTrue(RemoteRequestError(code: "remote_session_exists", status: 409).isSessionExists)
        XCTAssertTrue(RemoteRequestError(code: "dynamic_resolution_policy_denied", status: 403).isDynamicResolutionDenied)
    }

    func testResizeAndBackendBodiesCarryOnlyWhatTheHostAccepts() throws {
        let geometry = RemoteGeometryRequest(viewport_points: .init(width: 834, height: 1194), orientation: "portrait",
                                             logical_long_edge: 1280, quality: .forBackend(.vnc))
        let resize = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteResizeRequest(expectedRevision: 4, geometry: geometry))) as? [String: Any])
        XCTAssertEqual(Set(resize.keys), ["expected_revision", "viewport_points", "orientation", "logical_long_edge", "quality", "decoder"])
        XCTAssertEqual(resize["expected_revision"] as? Int, 4)
        let backend = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteBackendRequest(expected_revision: 4, backend: .sunshine))) as? [String: Any])
        XCTAssertEqual(Set(backend.keys), ["expected_revision", "backend"])
        let presented = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemotePresentedRequest(
            revision: 4, video_rect_points: .init(x: 0, y: 44, width: 1194, height: 746),
            decoded_pixels: .init(width: 2560, height: 1600)))) as? [String: Any])
        XCTAssertEqual(Set(presented.keys), ["revision", "video_rect_points", "decoded_pixels"])
    }
}

/// REMOTE-4. The host reconfigures its displays while a session is up.
///
/// Leo, 2026-09-22, in a takeover: he changed the display scale from the
/// Omarchy Display panel, the picture went away, and the App was back on panel
/// ① with the session gone. The App had not crashed — it had treated a backend
/// that stopped as a session that ended, and core had ended one it did not
/// need to. This suite is the client half of the repair: while the host still
/// holds the session, the picture stays and the same session is dialled again.
@MainActor final class RemoteHostReconfigureTests: XCTestCase {
    private func make() -> (RemoteSessionController, FakeRemoteHost, FakeBackend) {
        let host = FakeRemoteHost()
        let backend = FakeBackend()
        let controller = RemoteSessionController(service: host, driver: backend,
                                                 heartbeatInterval: .milliseconds(10),
                                                 backgroundGrace: .seconds(60))
        controller.backendChoice = .vnc
        controller.reconnectWindow = .milliseconds(400)
        controller.reconnectPoll = .milliseconds(5)
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        return (controller, host, backend)
    }

    private func settle(_ message: String, _ predicate: @escaping () async -> Bool) async {
        for _ in 0..<400 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
    }

    /// Bring one session up to a live picture.
    private func streaming(_ controller: RemoteSessionController, _ backend: FakeBackend) async {
        controller.start()
        await settle("the backend never connected") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        XCTAssertTrue(controller.isStreaming)
    }

    func testABackendThatStoppedIsNotBySelfASessionThatEnded() async throws {
        let (controller, host, backend) = make()
        await streaming(controller, backend)
        let identity = try XCTUnwrap(controller.session?.id)
        backend.onFailure?("stream_dropped")
        await settle("the session was never dialled again") { await backend.connections.count == 2 }
        XCTAssertEqual(controller.session?.id, identity, "the same session, not a new one")
        XCTAssertTrue(controller.hasSession, "and it was never let go of")
        let releases = await host.releases
        XCTAssertEqual(releases, [], "nothing was released")
        XCTAssertEqual(controller.reconnection, .none)
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        XCTAssertTrue(controller.isStreaming)
    }

    func testTheHostSayingItReconfiguredDialsTheSameSessionAgain() async throws {
        let (controller, host, backend) = make()
        await streaming(controller, backend)
        let identity = try XCTUnwrap(controller.session?.id)
        _ = await host.rebuild()
        controller.hostSessionChanged(RemoteSessionChange(id: identity, revision: 4, state: "ready",
                                                          reason: "host_reconfigured"))
        await settle("the session was never dialled again") { await backend.connections.count == 2 }
        XCTAssertEqual(controller.session?.id, identity)
        let releases = await host.releases
        XCTAssertEqual(releases, [])
    }

    /// The whole point of the repair, stated as the Shell states it: N-32 routes
    /// away from the picture the moment `hasSession` goes false, so a host
    /// reconfigure that ever nils the session lands the user on panel ① — which
    /// is exactly what Leo saw.
    func testAHostReconfigureNeverRoutesAwayFromThePicture() async throws {
        let (controller, _, backend) = make()
        let registry = PanelRegistry(hostID: "host-remote4",
                                     defaults: UserDefaults(suiteName: "remote4.router.\(UUID().uuidString)")!)
        let router = SurfaceRouter(registry: registry)
        router.rememberReturn()
        await streaming(controller, backend)
        router.enterPicture()
        XCTAssertEqual(router.stage, .picture)
        // The Shell's own rule, applied on every reading the controller takes.
        var sawSessionGone = false
        let watch = Task { @MainActor in
            for _ in 0..<600 {
                if !controller.hasSession {
                    sawSessionGone = true
                    if router.stage == .picture { router.endSession() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        backend.onFailure?("stream_dropped")
        controller.hostSessionChanged(RemoteSessionChange(id: try XCTUnwrap(controller.session?.id),
                                                          revision: 5, state: "ready",
                                                          reason: "host_reconfigured"))
        await settle("the session was never dialled again") { await backend.connections.count >= 2 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        try? await Task.sleep(for: .milliseconds(60))
        watch.cancel()
        XCTAssertFalse(sawSessionGone, "the session was let go of during a host reconfigure")
        XCTAssertEqual(router.stage, .picture, "and the picture is still what the user is looking at")
        XCTAssertTrue(controller.isStreaming)
    }

    func testAHostThatReallyLostTheSessionStillEndsIt() async throws {
        let (controller, host, backend) = make()
        await streaming(controller, backend)
        await host.forgetSession()
        backend.onFailure?("stream_dropped")
        await settle("the session was never given up") { !controller.hasSession }
        XCTAssertTrue(controller.phase.isFailed)
        let dialled = backend.connections.count
        XCTAssertEqual(dialled, 1, "there was nothing to dial again")
    }

    func testAReconnectThatDoesNotLandInsideItsWindowSaysWhyAndOffersARetry() async throws {
        let (controller, host, backend) = make()
        await streaming(controller, backend)
        await host.setNotReadyReads(1000)
        backend.onFailure?("stream_dropped")
        await settle("the banner never stalled") {
            if case .stalled = controller.reconnection { return true }
            return false
        }
        XCTAssertTrue(controller.hasSession, "a stalled reconnect still holds the session")
        let releases = await host.releases
        XCTAssertEqual(releases, [], "and never released it")
        XCTAssertTrue(controller.phase.isFailed)
        // The retry is the one thing that can help, and it works.
        await host.setNotReadyReads(0)
        controller.retryReconnect()
        await settle("the retry never reconnected") { await backend.connections.count == 2 }
        XCTAssertEqual(controller.reconnection, .none)
    }

    func testTheBeatKeepsGoingWhileTheHostIsReconfiguringItself() async throws {
        let (controller, host, backend) = make()
        await streaming(controller, backend)
        await host.setNotReadyReads(1000)
        backend.onFailure?("stream_dropped")
        await settle("the banner never stalled") {
            if case .stalled = controller.reconnection { return true }
            return false
        }
        let before = controller.heartbeatCount
        await settle("the beat stopped while the host was being reconfigured") {
            controller.heartbeatCount > before
        }
        XCTAssertTrue(controller.heartbeatRunning)
    }

    /// A backend that is broken rather than being rebuilt must still end the
    /// session. Without a bound, a failure that dials and fails again is an
    /// infinite loop with a live host output on the other end of it.
    func testABackendThatKeepsFailingIsNotDialledForever() async throws {
        let (controller, host, backend) = make()
        await streaming(controller, backend)
        for _ in 0..<6 {
            backend.onFailure?("stream_dropped")
            try? await Task.sleep(for: .milliseconds(30))
        }
        await settle("the session was never given up") { !controller.hasSession }
        let releases = await host.releases
        XCTAssertEqual(releases.count, 1, "and it was given back to the host exactly once")
    }

    func testAHostThatSaysTheSessionWasReleasedEndsIt() async throws {
        let (controller, _, backend) = make()
        await streaming(controller, backend)
        let identity = try XCTUnwrap(controller.session?.id)
        controller.hostSessionChanged(RemoteSessionChange(id: identity, revision: 6, state: "released",
                                                          reason: "heartbeat_timeout"))
        await settle("the session was never ended") { !controller.hasSession }
        XCTAssertTrue(controller.phase.isFailed)
    }

    func testAnEventForSomebodyElsesSessionIsIgnored() async throws {
        let (controller, _, backend) = make()
        await streaming(controller, backend)
        controller.hostSessionChanged(RemoteSessionChange(id: "rs_ffffffffffffffffffffffffffffffff",
                                                          revision: 9, state: "released", reason: "released"))
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(controller.isStreaming)
        let dialled = backend.connections.count
        XCTAssertEqual(dialled, 1)
    }

    /// The host publishes `remote.session.changed` with a reason; the client
    /// that holds that session reads the reason rather than only re-reading
    /// state. A frame with no `rs_` id is not one of ours.
    func testTheChangeEventIsDecodedFromTheHostsOwnFrame() throws {
        let frame = Data(#"{"event":{"seq":7,"event_id":"e-7","type":"remote.session.changed","payload":{"id":"rs_0123456789abcdef0123456789abcdef","revision":4,"state":"ready","reason":"host_reconfigured"}}}"#.utf8)
        let event = try CompanionHostClient.decodeEvent(frame)
        XCTAssertEqual(event.remoteSession,
                       RemoteSessionChange(id: "rs_0123456789abcdef0123456789abcdef", revision: 4,
                                           state: "ready", reason: "host_reconfigured"))
        let stray = Data(#"{"event":{"seq":8,"event_id":"e-8","type":"remote.session.changed","payload":{"id":"nope","revision":4}}}"#.utf8)
        XCTAssertNil(try CompanionHostClient.decodeEvent(stray).remoteSession)
    }
}

/// REMOTE-5. `media_pairing_required` is a **step**, never a terminal state.
///
/// PAIR-1 §4.3 made the host's refusal start the Sunshine certificate pairing
/// and resume the session once it landed. REMOTE-4 then rewrote the failure
/// path around it (`driver.onFailure` re-dials instead of ending the session),
/// and GEST-1 §6b read a freshly paired simulator as "no first frame" — so
/// this suite nails the rule down on both sides of that rewrite: the refusal
/// does not end anything, and the re-dial machinery cannot be what ends it.
@MainActor final class RemoteMediaPairingIsNotTerminalTests: XCTestCase {
    private func make() -> (RemoteSessionController, FakeRemoteHost, FakeBackend) {
        let host = FakeRemoteHost()
        let backend = FakeBackend()
        let controller = RemoteSessionController(service: host, driver: backend,
                                                 heartbeatInterval: .milliseconds(10),
                                                 backgroundGrace: .seconds(60))
        controller.backendChoice = .sunshine
        controller.reconnectWindow = .milliseconds(200)
        controller.reconnectPoll = .milliseconds(5)
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        controller.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
        return (controller, host, backend)
    }

    private func settle(_ message: String, _ predicate: @escaping () async -> Bool) async {
        for _ in 0..<400 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
    }

    private func refuseOnce(_ host: FakeRemoteHost) async {
        await host.setFailNextCreate(RemoteRequestError(code: "media_pairing_required", status: 409))
    }

    /// The refusal describes the moment *before* a pairing request exists. A
    /// device that has just been paired with core holds no streaming
    /// certificate yet, so this is the ordinary first run of every new device.
    func testTheHostsRefusalIsNotAFailedPhase() async throws {
        let (controller, host, _) = make()
        await refuseOnce(host)
        controller.start()
        await settle("the refusal never settled") { !controller.pairingStatus.isEmpty }
        XCTAssertFalse(controller.phase.isFailed,
                       "media_pairing_required left the session on a failure: \(controller.phase)")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.session, "nothing was created, so nothing is held")
    }

    /// The whole point of taking the refusal as a step: the user asked for a
    /// session, and the pairing was only its precondition.
    func testAPairingThatLandsAsksForTheSessionAgain() async throws {
        let (controller, host, backend) = make()
        await refuseOnce(host)
        controller.start()
        await settle("the refusal never settled") { !controller.pairingStatus.isEmpty }
        let createdAfterRefusal = await host.created.count
        XCTAssertEqual(createdAfterRefusal, 0, "the refused create is not a create")
        controller.receivePairing(.paired)
        await settle("the session was never asked for again") { await host.created.count == 1 }
        await settle("the backend never connected") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        XCTAssertTrue(controller.isStreaming, "the first frame after a pairing is the point")
        XCTAssertTrue(controller.sunshinePaired)
    }

    /// POLISH-R item 5 (LINKS-1): the panel said "Sunshine has not approved
    /// this device" right above "Sunshine pairing is done". The pairing had
    /// landed; the session it resumed then failed for another reason. One
    /// truthful state: no repair card once the pairing is done, and the
    /// failure in its own words.
    func testAFinishedPairingNeverBringsBackTheUnapprovedCard() async throws {
        let (controller, host, _) = make()
        await refuseOnce(host)
        controller.start()
        await settle("the refusal never settled") { !controller.pairingStatus.isEmpty }
        XCTAssertFalse(controller.showsSunshineRepair, "a pairing in flight with no PIN yet is not a failure")
        await host.setFailNextCreate(RemoteRequestError(code: "sunshine_desktop_unavailable", status: 503))
        controller.receivePairing(.paired)
        await settle("the resumed session never failed") { controller.phase.isFailed }
        XCTAssertTrue(controller.sunshinePaired)
        XCTAssertEqual(controller.pairingStatus, Strings.mediaPairingDone)
        XCTAssertFalse(controller.showsSunshineRepair,
                       "the repair card's headline would contradict the pairing that just finished")
        XCTAssertFalse(controller.message.isEmpty, "the real failure is still said")
    }

    /// A pairing that never finished still gets the repair card.
    func testAPairingThatFailedStillShowsTheRepair() async throws {
        let (controller, host, _) = make()
        await refuseOnce(host)
        controller.start()
        await settle("the refusal never settled") { !controller.pairingStatus.isEmpty }
        controller.receivePairing(.pin(""))
        await settle("the failure never settled") { controller.phase.isFailed }
        XCTAssertFalse(controller.sunshinePaired)
        XCTAssertTrue(controller.showsSunshineRepair)
    }

    /// A pairing that was cancelled must not leave a session queued behind it:
    /// the next `paired` event belongs to whatever the user does next.
    func testACancelledPairingDoesNotResumeASessionLater() async throws {
        let (controller, host, _) = make()
        await refuseOnce(host)
        controller.start()
        await settle("the refusal never settled") { !controller.pairingStatus.isEmpty }
        controller.cancelSunshinePairing()
        controller.receivePairing(.paired)
        try? await Task.sleep(for: .milliseconds(60))
        let createdAfterCancel = await host.created.count
        XCTAssertEqual(createdAfterCancel, 0, "a cancelled pairing resumed a session by itself")
    }

    /// REMOTE-4's re-dial is for a backend that stopped under a **live**
    /// session. The refusal happens before any session exists, so the re-dial
    /// must never see it — otherwise the banner ("正在重新连接…") replaces the
    /// pairing the user actually needs.
    func testTheRedialMachineryNeverSeesTheRefusal() async throws {
        let (controller, host, _) = make()
        await refuseOnce(host)
        controller.start()
        await settle("the refusal never settled") { !controller.pairingStatus.isEmpty }
        XCTAssertEqual(controller.reconnectCycles, 0, "the refusal was taken for a dropped backend")
        XCTAssertEqual(controller.reconnectAttempts, 0)
        XCTAssertEqual(controller.reconnection, .none)
    }

    /// And once the pairing has landed, the session that follows is an ordinary
    /// one: a backend that drops under it is still re-dialled (REMOTE-4), which
    /// is what proves the two paths did not get crossed.
    func testTheSessionAfterAPairingIsAnOrdinarySession() async throws {
        let (controller, host, backend) = make()
        await refuseOnce(host)
        controller.start()
        await settle("the refusal never settled") { !controller.pairingStatus.isEmpty }
        controller.receivePairing(.paired)
        await settle("the backend never connected") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 2560, height: 1600))
        let identity = try XCTUnwrap(controller.session?.id)
        backend.onFailure?("stream_dropped")
        await settle("the session was not dialled again") { await backend.connections.count == 2 }
        XCTAssertEqual(controller.session?.id, identity, "the re-dial kept the same session")
        XCTAssertTrue(controller.hasSession)
    }
}
