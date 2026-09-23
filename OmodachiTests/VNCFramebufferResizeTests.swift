import XCTest
@testable import Omodachi

/// REMOTE-6 §2. WayVNC 0.10.1 hands one client two framebuffer sizes: the
/// compositor's logical size in `ServerInit`, then the owned output's buffer
/// pixels from its first `NewFBSize` rect onwards. SPEC-E3 §3 avoided that by
/// planning the VNC output at scale 1, which cost the picture half its pixels
/// on a retina client. These tests are the other half of taking that back: the
/// picture follows the resize instead, and a finger lands on the same desktop
/// point before and after it.
///
/// They drive the real `OMVNCRemoteView` and the real vendored LibVNCClient
/// against `FakeWayVNCServer`, which replays the exact sequence measured on the
/// host, so nothing here depends on a host being free.
@MainActor final class VNCFramebufferResizeTests: XCTestCase {
    /// The two sizes of a 1280x960 logical desktop on a scale-2 owned output,
    /// which is what an iPad in landscape asks this host for.
    private let opening = CGSize(width: 1280, height: 960)
    private let native = CGSize(width: 2560, height: 1920)
    /// An iPad Pro 11" landscape canvas. 1194:834 is wider than 4:3, so the
    /// picture is letterboxed left and right and the aspect-fit rectangle is
    /// not the whole view — which is the case the mapping has to get right.
    private let canvas = CGSize(width: 1194, height: 834)

    /// Long enough that the opening frame is on screen before the correction
    /// arrives, short enough that the suite does not notice.
    private let holdBack: TimeInterval = 0.8

    private var server: FakeWayVNCServer!
    private var window: UIWindow!
    private var view: OMVNCRemoteView!

    override func tearDown() async throws {
        if let view {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                view.disconnect { continuation.resume() }
            }
        }
        server?.stop()
        window?.isHidden = true
        view = nil; window = nil; server = nil
        try await super.tearDown()
    }

    // MARK: - the two sizes

    func testTheFramebufferThatChangesSizeMidStreamIsFollowedNotTreatedAsAFailure() async throws {
        let presented = Presented()
        try await connect(native: native, presented: presented, resizeDelay: holdBack)

        let sizes = try await presented.awaitSizes(count: 2, timeout: 25)
        XCTAssertEqual(sizes, [opening, native],
                       "the opening logical size, then the output's own pixels")
        XCTAssertEqual(presented.resizes, [Resize(from: .zero, to: opening), Resize(from: opening, to: native)],
                       "the size it opened at, then the one it corrected itself to")
        XCTAssertNil(presented.disconnected,
                     "a resize is not a disconnect: \(presented.disconnected ?? "-")")
        XCTAssertFalse(server.clientClosed, "the client stayed on the same RFB connection")
        XCTAssertTrue(presented.stages.contains("framebuffer_resized"))
    }

    func testTheRealHostsTimingNeverPutsTheOpeningSizeOnScreenAtAll() async throws {
        // WayVNC sends its correction immediately: SPEC-E3 measured update 0 as
        // the logical size and update 1 already carrying the NewFBSize rect.
        // The opening frame is therefore superseded before the display link
        // that would have presented it ever runs, so the user's first sight of
        // the desktop is the sharp one. Both sizes are still on the record.
        let presented = Presented()
        try await connect(native: native, presented: presented)
        _ = try await presented.awaitSizes(count: 1, timeout: 25)
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(presented.sizes, [native], "no frame was presented at a size already superseded")
        XCTAssertEqual(presented.resizes, [Resize(from: .zero, to: opening), Resize(from: opening, to: native)])
        XCTAssertNil(presented.disconnected)
        XCTAssertFalse(server.clientClosed)
    }

    func testEachSizeIsPresentedIntoItsOwnAspectFitRectangle() async throws {
        let presented = Presented()
        try await connect(native: native, presented: presented, resizeDelay: holdBack)
        _ = try await presented.awaitSizes(count: 2, timeout: 25)

        for (pixels, rect) in presented.frames {
            // The picture fills the canvas on one axis and is centred on the
            // other, at both sizes. Both of these are 4:3 in a 1194x834 view,
            // so the fit is height-bound and the letterbox is horizontal.
            let scale = min(canvas.width / pixels.width, canvas.height / pixels.height)
            XCTAssertEqual(rect.width, pixels.width * scale, accuracy: 0.5, "\(pixels)")
            XCTAssertEqual(rect.height, pixels.height * scale, accuracy: 0.5, "\(pixels)")
            XCTAssertEqual(rect.origin.x, (canvas.width - rect.width) / 2, accuracy: 0.5, "\(pixels)")
            XCTAssertEqual(rect.origin.y, (canvas.height - rect.height) / 2, accuracy: 0.5, "\(pixels)")
        }
        XCTAssertEqual(presented.frames.count, 2)
    }

    func testAServerThatNeverResizesStillPresentsExactlyOnce() async throws {
        // The scale-1 shape SPEC-E3 planned for. It has to keep working: it is
        // what a host with `render_density` 1 still serves, and it is the
        // control for the assertions above.
        let presented = Presented()
        try await connect(native: opening, presented: presented)
        _ = try await presented.awaitSizes(count: 1, timeout: 20)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(presented.sizes, [opening])
        XCTAssertEqual(presented.resizes, [Resize(from: .zero, to: opening)], "opened once, never corrected")
        XCTAssertNil(presented.disconnected)
    }

    // MARK: - input precision at both sizes

    func testAFingerLandsOnTheSameDesktopPointAtBothFramebufferSizes() async throws {
        let presented = Presented()
        try await connect(native: native, presented: presented, resizeDelay: holdBack)
        _ = try await presented.awaitSizes(count: 1, timeout: 25)

        view.setInputEnabled(true)
        let atOpening = try await tapGrid(expecting: opening)
        _ = try await presented.awaitSizes(count: 2, timeout: 25)
        view.setInputEnabled(true)
        let atNative = try await tapGrid(expecting: native)

        XCTAssertEqual(atOpening.count, Self.grid.count)
        XCTAssertEqual(atNative.count, Self.grid.count)
        // Both are converted into the ONE thing that is the same on both sides
        // of the resize: the host's logical desktop, 1280x960 either way.
        for (index, fraction) in Self.grid.enumerated() {
            let want = CGPoint(x: fraction.x * opening.width, y: fraction.y * opening.height)
            for (label, event, framebuffer) in [("opening", atOpening[index], opening),
                                                ("native", atNative[index], native)] {
                let logical = CGPoint(x: Double(event.x) * opening.width / framebuffer.width,
                                      y: Double(event.y) * opening.height / framebuffer.height)
                XCTAssertEqual(logical.x, want.x, accuracy: 2,
                               "\(label) x at \(fraction): sent \(event.x)/\(Int(framebuffer.width))")
                XCTAssertEqual(logical.y, want.y, accuracy: 2,
                               "\(label) y at \(fraction): sent \(event.y)/\(Int(framebuffer.height))")
            }
        }
    }

    func testInputIsHeldBetweenTheResizeAndTheFirstFrameAtTheNewSize() async throws {
        // Between the two sizes the view's picture and the server's framebuffer
        // disagree, so a pointer mapped in that window would land at half the
        // intended place. Nothing may be sent until the new size is on screen.
        let presented = Presented()
        try await connect(native: native, presented: presented, resizeDelay: holdBack)
        _ = try await presented.awaitSizes(count: 1, timeout: 25)
        view.setInputEnabled(true)
        XCTAssertTrue(view.inputReady)

        var readyDuringResize: [Bool] = []
        view.onFramebufferResized = { [weak self] from, _ in
            guard let self, from.width > 0 else { return }
            readyDuringResize.append(self.view.inputReady)
        }
        _ = try await presented.awaitSizes(count: 2, timeout: 25)
        XCTAssertEqual(readyDuringResize, [false], "input is dropped the moment the size changes")
        // And it comes back by itself once the picture caught up, without the
        // session having to re-authorise anything.
        XCTAssertTrue(view.inputReady)
    }

    // MARK: - harness

    /// A 10-point grid: four corners, four edge midpoints, the centre, and one
    /// off-centre point that is not on any axis of symmetry.
    private static let grid: [CGPoint] = [
        CGPoint(x: 0.02, y: 0.02), CGPoint(x: 0.50, y: 0.02), CGPoint(x: 0.98, y: 0.02),
        CGPoint(x: 0.02, y: 0.50), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.98, y: 0.50),
        CGPoint(x: 0.02, y: 0.98), CGPoint(x: 0.50, y: 0.98), CGPoint(x: 0.98, y: 0.98),
        CGPoint(x: 0.27, y: 0.73),
    ]

    private struct Resize: Equatable { let from: CGSize; let to: CGSize }

    /// What the view told its owner, in order.
    @MainActor private final class Presented {
        private(set) var frames: [(CGSize, CGRect)] = []
        private(set) var resizes: [Resize] = []
        private(set) var stages: [String] = []
        private(set) var disconnected: String?
        var sizes: [CGSize] { frames.map(\.0) }

        func awaitSizes(count: Int, timeout: TimeInterval) async throws -> [CGSize] {
            let deadline = Date().addingTimeInterval(timeout)
            while frames.count < count, disconnected == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if let disconnected { XCTFail("stream ended early: \(disconnected)") }
            guard frames.count >= count else {
                XCTFail("only \(frames.count) frame(s) presented within \(timeout)s: \(sizes)")
                return sizes
            }
            return sizes
        }

        fileprivate func attach(_ view: OMVNCRemoteView) {
            view.onFramePresented = { [weak self] pixels, rect in self?.frames.append((pixels, rect)) }
            view.onFramebufferResized = { [weak self] from, to in
                self?.resizes.append(Resize(from: from, to: to))
            }
            view.onStage = { [weak self] stage in self?.stages.append(stage) }
            view.onDisconnected = { [weak self] reason in self?.disconnected = reason }
        }
    }

    private func connect(native: CGSize, presented: Presented, resizeDelay: TimeInterval = 0) async throws {
        server = FakeWayVNCServer(opening: opening, native: native, resizeDelay: resizeDelay)
        try server.start()
        window = UIWindow(frame: CGRect(origin: .zero, size: canvas))
        view = OMVNCRemoteView(frame: CGRect(origin: .zero, size: canvas))
        presented.attach(view)
        window.addSubview(view)
        window.isHidden = false
        window.makeKeyAndVisible()
        // The ceiling the host names is the larger of the two sizes, which is
        // what `VNCBackendAdapter` computes from the connection document.
        view.connectLoopbackPort(server.port,
                                 expectedPixels: native.width >= opening.width ? native : opening)
    }

    /// Taps the grid inside the current aspect-fit rectangle and returns the
    /// pointer events the server received for it, in the same order.
    private func tapGrid(expecting framebuffer: CGSize) async throws -> [FakeWayVNCServer.PointerEvent] {
        let scale = min(canvas.width / framebuffer.width, canvas.height / framebuffer.height)
        let size = CGSize(width: framebuffer.width * scale, height: framebuffer.height * scale)
        let video = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                           width: size.width, height: size.height)
        let before = server.pointerEvents.count
        for fraction in Self.grid {
            view.sendPointer(atViewPoint: CGPoint(x: video.minX + fraction.x * video.width,
                                                  y: video.minY + fraction.y * video.height), buttons: 0)
        }
        let deadline = Date().addingTimeInterval(10)
        while server.pointerEvents.count < before + Self.grid.count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The size the server happened to be serving when it *read* these bytes
        // is not evidence of anything — it may already have moved on. What the
        // client mapped against is what the coordinates themselves say, and
        // that is what the caller checks.
        return Array(server.pointerEvents.dropFirst(before))
    }
}
