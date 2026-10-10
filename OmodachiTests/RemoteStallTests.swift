import XCTest
@testable import Omodachi

/// POLISH-R item 6. A stall has to look like one, and be kept.
final class RemoteStallTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    private func healthy(_ fps: Int = 30, codec: String = "hevc") -> RemoteStreamStats {
        RemoteStreamStats(window: 1, totalFrames: fps, receivedFrames: fps, networkDroppedFrames: 0,
                          renderedFrames: fps, rttMs: 8, rttVarianceMs: 1, codec: codec)
    }

    /// The bug the stall hid behind: the last healthy second was replayed
    /// while no frame arrived. With the window's age, the reading says so.
    func testAReplayedWindowReadsAsNoFrames() {
        let event: [String: Any] = ["window": 1.0, "total_frames": 30, "received_frames": 30,
                                    "network_dropped_frames": 0, "rendered_frames": 0, "codec": "hevc",
                                    "stalled_s": 4.2]
        let stats = try! XCTUnwrap(RemoteStreamStats(event: event))
        XCTAssertEqual(stats.stalledSeconds, 4.2)
        XCTAssertEqual(stats.receivedFPS, 0, "the 30 is the last good second, not this one")
        XCTAssertTrue(stats.line.contains("no frame for 4.2 s"), stats.line)
        XCTAssertNil(RemoteStreamStats(event: ["window": 1.0, "total_frames": 30, "received_frames": 30,
                                               "network_dropped_frames": 0])?.stalledSeconds)
    }

    func testANoFrameStallBeginsWhenTheFramesStoppedAndEndsWhenTheyCome() {
        var detector = RemoteStallDetector()
        XCTAssertTrue(detector.observe(healthy(), plannedFPS: 30, at: t0).isEmpty)
        var stalled = healthy(); stalled.stalledSeconds = 2
        let began = detector.observe(stalled, plannedFPS: 30, at: t0.addingTimeInterval(3))
        guard case .began(let stall)? = began.first else { return XCTFail("\(began)") }
        XCTAssertEqual(stall.kind, .noFrames)
        XCTAssertEqual(stall.start, t0.addingTimeInterval(1), "it began when the last frame came")
        stalled.stalledSeconds = 3; stalled.rttMs = 340
        XCTAssertTrue(detector.observe(stalled, plannedFPS: 30, at: t0.addingTimeInterval(4)).isEmpty)
        let ended = detector.observe(healthy(), plannedFPS: 30, at: t0.addingTimeInterval(5))
        guard case .ended(let done)? = ended.first else { return XCTFail("\(ended)") }
        XCTAssertEqual(done.seconds(at: t0), 4, accuracy: 0.001)
        XCTAssertEqual(done.worstRttMs, 340)
        XCTAssertTrue(done.summary.hasPrefix("4.0 s no_frames"), done.summary)
    }

    /// A still desktop is not a stall: the fork keeps half the planned rate
    /// flowing ("Minimum FPS target"), well above a fifth.
    func testAStillDesktopIsNotAStall() {
        var detector = RemoteStallDetector()
        for second in 0..<10 {
            XCTAssertTrue(detector.observe(healthy(15), plannedFPS: 30, at: t0.addingTimeInterval(Double(second))).isEmpty)
        }
        XCTAssertNil(detector.open)
    }

    func testTheKindSaysWhereTheFramesWereLost() {
        let detector = RemoteStallDetector()
        let few = RemoteStreamStats(window: 1, totalFrames: 3, receivedFrames: 3, networkDroppedFrames: 0, renderedFrames: 3)
        XCTAssertEqual(detector.kind(of: few, plannedFPS: 30), .fewFrames)
        let lossy = RemoteStreamStats(window: 1, totalFrames: 30, receivedFrames: 18, networkDroppedFrames: 12, renderedFrames: 18)
        XCTAssertEqual(detector.kind(of: lossy, plannedFPS: 30), .loss)
        let undecoded = RemoteStreamStats(window: 1, totalFrames: 30, receivedFrames: 30, networkDroppedFrames: 0, renderedFrames: 1)
        XCTAssertEqual(detector.kind(of: undecoded, plannedFPS: 30), .decoder)
        XCTAssertNil(detector.kind(of: healthy(), plannedFPS: 30))
    }

    /// The app's own once-a-second reading did not run for five seconds.
    func testAGapBetweenReadingsIsTheAppsOwnStall() {
        var detector = RemoteStallDetector()
        _ = detector.observe(healthy(), plannedFPS: 30, at: t0)
        let events = detector.observe(healthy(), plannedFPS: 30, at: t0.addingTimeInterval(5))
        XCTAssertEqual(events.count, 2)
        guard case .ended(let stall)? = events.last else { return XCTFail() }
        XCTAssertEqual(stall.kind, .app)
        XCTAssertEqual(stall.seconds(at: t0), 5, accuracy: 0.001)
    }

    /// `自动` steps down on a stall instead of counting it as a clean second.
    func testTheAdaptiveQualityCountsAStallAsBad() {
        var adaptive = RemoteAdaptiveQuality(start: .quality,
                                             thresholds: .init(downAfter: 3, settle: 0))
        var stalled = healthy(); stalled.stalledSeconds = 2
        var decision = RemoteAdaptiveQuality.Decision.hold
        for _ in 0..<3 { decision = adaptive.observe(stalled) }
        XCTAssertEqual(adaptive.tier, .balanced, "\(decision)")
    }

    /// The log outlives the process: a stall the user ended by closing the
    /// app is still there, as a `began` with no `ended`.
    func testTheLogKeepsAStallAcrossLaunches() throws {
        let suite = "polish-r-stalls-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = RemoteStall.Context(session: "rs_test", backend: "sunshine", codec: "hevc",
                                          plannedFPS: 30, plannedKbps: 8000)
        let stall = RemoteStall(start: t0, end: nil, kind: .noFrames, codec: "hevc", lowestReceivedFPS: 0)
        RemoteStallLog(defaults: defaults).began(stall, context: context)
        let next = RemoteStallLog(defaults: defaults)
        XCTAssertEqual(next.lines.count, 1)
        XCTAssertTrue(next.lines[0].contains("stall.began session=rs_test backend=sunshine codec=hevc planned=30fps/8000kbps kind=no_frames"),
                      next.lines[0])
        for _ in 0..<(RemoteStallLog.capacity + 5) { next.began(stall, context: context) }
        XCTAssertEqual(next.lines.count, RemoteStallLog.capacity)
    }

    /// Leaving Remote in the middle of a stall still writes how it ended.
    @MainActor func testEndingTheSessionClosesAnOpenStall() throws {
        let suite = "polish-r-stalls-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = RemoteStreamMonitor(log: RemoteStallLog(defaults: defaults))
        let session = try JSONDecoder().decode(RemoteSessionDTO.self, from: Data(
            #"{"id":"rs_stall","backend":"sunshine","mode":"extend","state":"ready","revision":1,"profile":{"output_id":"OMODACHI-0123456789abcdef","output_mode_pixels":{"width":2560,"height":1920},"output_scale":2.0,"logical_size":{"width":1280.0,"height":960.0},"stream_pixels":{"width":2560,"height":1920},"fps":30,"bitrate_kbps":8000,"codec":"hevc","dynamic_range":"sdr","transform":0,"strategy":"headless"}}"#.utf8))
        monitor.publish(healthy(), preset: .host, tier: .quality, session: session, at: t0)
        var stalled = healthy(); stalled.stalledSeconds = 2
        monitor.publish(stalled, preset: .host, tier: .quality, session: session, at: t0.addingTimeInterval(1))
        stalled.stalledSeconds = 3
        monitor.publish(stalled, preset: .host, tier: .quality, session: session, at: t0.addingTimeInterval(2))
        XCTAssertEqual(monitor.stalls, 1)
        XCTAssertTrue(monitor.line?.contains("stalls 1") == true, monitor.line ?? "")
        monitor.clear(at: t0.addingTimeInterval(9))
        let lines = RemoteStallLog(defaults: defaults).lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("how=session-ended"), lines[1])
    }
}
