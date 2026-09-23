import XCTest
@testable import Omodachi

/// STREAM-1. The device's preset, the host's table, the `自动` walker, the
/// codec the Moonlight leg offers and the one-second statistics.
final class RemoteAdaptiveQualityTests: XCTestCase {
    private func second(drop: Double = 0, rtt: Int? = 5) -> RemoteStreamStats {
        let total = 60
        return RemoteStreamStats(window: 1, totalFrames: total, receivedFrames: total - Int(Double(total) * drop),
                                 networkDroppedFrames: Int(Double(total) * drop), rttMs: rtt)
    }

    private func feed(_ walker: inout RemoteAdaptiveQuality, _ sample: RemoteStreamStats,
                      seconds: Int) -> [RemoteAdaptiveQuality.Decision] {
        (0..<seconds).map { _ in walker.observe(sample) }.filter { $0 != .hold }
    }

    func testItStartsAtQualityAndJudgesNothingWhileTheStreamSettles() {
        var walker = RemoteAdaptiveQuality()
        XCTAssertEqual(walker.tier, .quality)
        XCTAssertEqual(feed(&walker, second(drop: 0.5), seconds: 10), [], "the first ten seconds are settling")
        XCTAssertEqual(walker.tier, .quality)
    }

    func testFiveBadSecondsInARowStepDownOneRow() {
        var walker = RemoteAdaptiveQuality()
        _ = feed(&walker, second(), seconds: 10)
        XCTAssertEqual(feed(&walker, second(drop: 0.1), seconds: 4), [])
        let decisions = feed(&walker, second(drop: 0.1), seconds: 1)
        guard case .step(to: .balanced, _)? = decisions.first else { return XCTFail("\(decisions)") }
        XCTAssertEqual(walker.tier, .balanced)
    }

    func testRoundTripTimeAloneIsABadLink() {
        var walker = RemoteAdaptiveQuality()
        _ = feed(&walker, second(), seconds: 10)
        XCTAssertEqual(feed(&walker, second(rtt: 81), seconds: 5).count, 1)
        XCTAssertEqual(walker.tier, .balanced)
    }

    func testAThresholdIsNotCrossedByEqualling_it() {
        var walker = RemoteAdaptiveQuality()
        _ = feed(&walker, second(), seconds: 10)
        XCTAssertEqual(feed(&walker, second(drop: 0.05, rtt: 80), seconds: 30), [])
        XCTAssertEqual(walker.tier, .quality)
    }

    func testOneGoodSecondResetsTheBadCount() {
        var walker = RemoteAdaptiveQuality()
        _ = feed(&walker, second(), seconds: 10)
        for _ in 0..<5 {
            XCTAssertEqual(feed(&walker, second(drop: 0.2), seconds: 4), [])
            XCTAssertEqual(feed(&walker, second(), seconds: 1), [])
        }
        XCTAssertEqual(walker.tier, .quality, "4 bad + 1 good, five times over, is never 5 in a row")
    }

    func testSixtyCleanSecondsStepUpAndTheReentryWaitsLonger() {
        var walker = RemoteAdaptiveQuality(start: .balanced)
        _ = feed(&walker, second(), seconds: 10)
        XCTAssertEqual(feed(&walker, second(), seconds: 59), [])
        XCTAssertEqual(feed(&walker, second(), seconds: 1).count, 1)
        XCTAssertEqual(walker.tier, .quality)
        // It falls out of `quality`…
        _ = feed(&walker, second(), seconds: 10)
        XCTAssertEqual(feed(&walker, second(drop: 0.2), seconds: 5).count, 1)
        XCTAssertEqual(walker.tier, .balanced)
        // …and does not climb straight back in 60 s: that row has cost it once.
        _ = feed(&walker, second(), seconds: 10)
        XCTAssertEqual(feed(&walker, second(), seconds: 119), [])
        XCTAssertEqual(feed(&walker, second(), seconds: 1).count, 1)
        XCTAssertEqual(walker.tier, .quality)
    }

    func testTheGapBetweenCleanAndBadCountsForNeither() {
        var walker = RemoteAdaptiveQuality(start: .balanced)
        _ = feed(&walker, second(), seconds: 10)
        // 3 % loss is not bad (> 5 %) and not clean (<= 1 %): no step either way.
        XCTAssertEqual(feed(&walker, second(drop: 0.03), seconds: 300), [])
        XCTAssertEqual(walker.tier, .balanced)
    }

    func testTheWalkStaysBetweenTheThreeRows() {
        var walker = RemoteAdaptiveQuality()
        for _ in 0..<4 {
            _ = feed(&walker, second(), seconds: 10)
            _ = feed(&walker, second(drop: 0.5), seconds: 5)
        }
        XCTAssertEqual(walker.tier, .performance)
        XCTAssertEqual(feed(&walker, second(drop: 0.5), seconds: 30), [], "there is no row below 速度优先")
        var top = RemoteAdaptiveQuality()
        XCTAssertEqual(feed(&top, second(), seconds: 600), [], "there is no row above 画质优先")
    }

    func testAFlappingLinkCannotFlapTheStream() {
        // A link that is bad for 5 s and clean for 5 s, for ten minutes.
        var walker = RemoteAdaptiveQuality()
        var steps = 0
        for _ in 0..<60 {
            steps += feed(&walker, second(drop: 0.2), seconds: 5).count
            steps += feed(&walker, second(), seconds: 5).count
        }
        XCTAssertLessThanOrEqual(steps, 2, "down to the floor and no further; never back up")
        XCTAssertEqual(walker.tier, .performance)
    }
}

final class RemoteRatePlanTests: XCTestCase {
    private let published = try! JSONDecoder().decode(RemoteHostPreferences.self, from: Data(#"""
    {"profile_defaults":{"quality":{"fps":30,"bitrate_kbps":8000},"preset":"performance",
     "presets":{"performance":{"fps":30,"bitrate_kbps":8000},"balanced":{"fps":60,"bitrate_kbps":12000},
                "quality":{"fps":60,"bitrate_kbps":20000}},
     "custom":{"fps":[30,60],"min_bitrate_kbps":4000,"max_bitrate_kbps":40000}}}
    """#.utf8))
    private let older = try! JSONDecoder().decode(RemoteHostPreferences.self, from: Data(#"""
    {"profile_defaults":{"quality":{"fps":30,"bitrate_kbps":8000}}}
    """#.utf8))

    private func plan(_ preset: RemoteStreamPreset, tier: RemoteStreamTier = .quality,
                      host: RemoteHostPreferences?, fps: Int = 60, kbps: Int = 20_000) -> RemoteRatePlan {
        RemoteRatePlan.resolve(.init(preset: preset, customFPS: fps, customBitrateKbps: kbps), tier: tier, host: host)
    }

    func testTheHostDefaultSaysNothingAndStreamsTheHostsRow() {
        XCTAssertEqual(plan(.host, host: published), RemoteRatePlan(preset: nil, adaptive: nil, fps: 30, bitrateKbps: 8000))
        XCTAssertEqual(published.preset, "performance")
    }

    func testANamedPresetIsTheHostsRowByName() {
        XCTAssertEqual(plan(.quality, host: published), RemoteRatePlan(preset: "quality", adaptive: false, fps: 60, bitrateKbps: 20000))
        XCTAssertEqual(plan(.balanced, host: published), RemoteRatePlan(preset: "balanced", adaptive: false, fps: 60, bitrateKbps: 12000))
    }

    func testAutoIsTheRowItIsOnAndSaysItIsAdaptive() {
        XCTAssertEqual(plan(.auto, tier: .balanced, host: published),
                       RemoteRatePlan(preset: "balanced", adaptive: true, fps: 60, bitrateKbps: 12000))
    }

    func testCustomIsClampedToTheRangeTheHostPublishes() {
        XCTAssertEqual(plan(.custom, host: published, fps: 30, kbps: 30_000),
                       RemoteRatePlan(preset: "custom", adaptive: false, fps: 30, bitrateKbps: 30000))
        XCTAssertEqual(plan(.custom, host: published, fps: 45, kbps: 90_000).fps, 60)
        XCTAssertEqual(plan(.custom, host: published, fps: 60, kbps: 90_000).bitrateKbps, 40000)
        XCTAssertEqual(plan(.custom, host: published, fps: 60, kbps: 1).bitrateKbps, 4000)
    }

    func testAHostFromBeforeStream1IsNeverSentAFieldItWouldRefuse() {
        for preset in RemoteStreamPreset.allCases {
            let value = plan(preset, host: older)
            XCTAssertNil(value.preset, "\(preset)")
            XCTAssertNil(value.adaptive, "\(preset)")
        }
        XCTAssertEqual(plan(.quality, host: older).bitrateKbps, 20000, "it can still ask for the numbers")
    }

    func testTheChoiceRoundTripsThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "omodachi.stream1.tests"))
        defaults.removePersistentDomain(forName: "omodachi.stream1.tests")
        XCTAssertEqual(RemoteStreamChoice.load(defaults), RemoteStreamChoice())
        let chosen = RemoteStreamChoice(preset: .custom, customFPS: 30, customBitrateKbps: 30_000)
        chosen.save(defaults)
        XCTAssertEqual(RemoteStreamChoice.load(defaults), chosen)
        defaults.set(["preset": "ultra", "customFPS": 45, "customBitrateKbps": 90_000], forKey: RemoteStreamChoice.storageKey)
        XCTAssertEqual(RemoteStreamChoice.load(defaults), RemoteStreamChoice(), "nothing out of range survives a load")
    }
}

final class RemoteStreamWireTests: XCTestCase {
    private func geometry(preset: String? = nil, adaptive: Bool? = nil) -> RemoteGeometryRequest {
        var value = RemoteGeometryRequest(viewport_points: .init(width: 1194, height: 834), orientation: "landscape_left",
                                          logical_long_edge: 1280, quality: RemoteQuality())
        value.quality_preset = preset
        value.adaptive = adaptive
        return value
    }

    func testTheHostDefaultAddsNoFieldToTheRequest() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            RemoteCreateRequest(backend: .sunshine, mode: .extend, geometry: geometry(), ttlSeconds: 60))) as? [String: Any])
        XCTAssertNil(body["quality_preset"])
        XCTAssertNil(body["adaptive"])
    }

    func testAPresetTravelsOnCreateAndResize() throws {
        let create = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            RemoteCreateRequest(backend: .sunshine, mode: .extend, geometry: geometry(preset: "quality", adaptive: true),
                                ttlSeconds: 60))) as? [String: Any])
        XCTAssertEqual(create["quality_preset"] as? String, "quality")
        XCTAssertEqual(create["adaptive"] as? Bool, true)
        let resize = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            RemoteResizeRequest(expectedRevision: 3, geometry: geometry(preset: "custom", adaptive: false))))
            as? [String: Any])
        XCTAssertEqual(resize["quality_preset"] as? String, "custom")
    }

    func testTheDecoderNamesHEVCExactlyWhenVideoToolboxDecodesItInHardware() {
        // Printed so the report can say what this runtime answers (STREAM-1 §验收).
        print("STREAM1 VTIsHardwareDecodeSupported(HEVC)=\(RemoteDecoderSupport.hevc)")
        XCTAssertEqual(RemoteDecoderLimits().codecs.contains("hevc"), RemoteDecoderSupport.hevc)
        XCTAssertEqual(RemoteDecoderLimits().codecs.first, "h264", "H.264 is always the baseline")
    }

    func testTheMoonlightLegOffersExactlyTheHostsCodec() throws {
        func profile(_ codec: String) throws -> RemoteProfileDTO {
            try JSONDecoder().decode(RemoteProfileDTO.self, from: Data(#"""
            {"output_id":"OMODACHI-0123456789abcdef","output_mode_pixels":{"width":2560,"height":1764},"output_scale":2,
             "logical_size":{"width":1280,"height":882},"stream_pixels":{"width":2408,"height":1660},"fps":60,
             "bitrate_kbps":20000,"codec":"\#(codec)","dynamic_range":"sdr"}
            """#.utf8))
        }
        XCTAssertEqual(SunshineBackendDriver.codec(profile: try profile("h264")), "h264")
        XCTAssertEqual(SunshineBackendDriver.codec(profile: try profile("hevc")), RemoteDecoderSupport.hevc ? "hevc" : "h264")
        XCTAssertEqual(SunshineBackendDriver.codec(profile: try profile("av1")), "h264")
        XCTAssertEqual(SunshineBackendDriver.codec(profile: nil), "h264")
    }

    func testTheSessionSaysWhichPresetItWasPlannedFrom() throws {
        let session = try JSONDecoder().decode(RemoteSessionDTO.self, from: Data(#"""
        {"id":"rs_0123456789abcdef0123456789abcdef","backend":"sunshine","mode":"extend","state":"ready","revision":3,
         "quality":{"preset":"balanced","adaptive":true}}
        """#.utf8))
        XCTAssertEqual(session.quality, .init(preset: "balanced", adaptive: true))
    }

    func testTheStatsEventIsReadAndSummarised() throws {
        let event: [String: Any] = ["type": "stats", "window": 1.0, "total_frames": 60, "received_frames": 57,
                                    "network_dropped_frames": 3, "rendered_frames": 57, "rtt_ms": 4,
                                    "rtt_variance_ms": 1, "host_latency_ms": 3.2, "codec": "hevc"]
        let stats = try XCTUnwrap(RemoteStreamStats(event: event))
        XCTAssertEqual(stats.dropRate, 0.05, accuracy: 1e-9)
        XCTAssertEqual(stats.receivedFPS, 57)
        XCTAssertEqual(stats.line, "HEVC · 57/57 fps · RTT 4±1 ms · drop 5.0 % · host 3.2 ms")
        XCTAssertNil(RemoteStreamStats(event: ["window": 0, "total_frames": 1, "received_frames": 1,
                                               "network_dropped_frames": 0]))
    }
}

/// The controller half: a preset change mid-stream is an in-place re-dial of
/// the same session, and `自动` drives the same path from the statistics.
@MainActor final class RemoteStreamPresetControllerTests: XCTestCase {
    private var saved: Any?

    override func setUp() async throws {
        saved = AppDefaults.shared.object(forKey: RemoteStreamChoice.storageKey)
        AppDefaults.shared.removeObject(forKey: RemoteStreamChoice.storageKey)
    }

    override func tearDown() async throws {
        if let saved { AppDefaults.shared.set(saved, forKey: RemoteStreamChoice.storageKey) }
        else { AppDefaults.shared.removeObject(forKey: RemoteStreamChoice.storageKey) }
    }

    private let published = try! JSONDecoder().decode(RemoteHostPreferences.self, from: Data(#"""
    {"profile_defaults":{"quality":{"fps":30,"bitrate_kbps":8000},"preset":"performance",
     "presets":{"performance":{"fps":30,"bitrate_kbps":8000},"balanced":{"fps":60,"bitrate_kbps":12000},
                "quality":{"fps":60,"bitrate_kbps":20000}},
     "custom":{"fps":[30,60],"min_bitrate_kbps":4000,"max_bitrate_kbps":40000}}}
    """#.utf8))

    private func make() async -> (RemoteSessionController, FakeRemoteHost, FakeBackend) {
        let host = FakeRemoteHost()
        await host.setPreferences(published)
        let backend = FakeBackend()
        let controller = RemoteSessionController(service: host, driver: backend,
                                                 heartbeatInterval: .milliseconds(50),
                                                 backgroundGrace: .seconds(60))
        controller.backendChoice = .sunshine
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

    private func stream(_ controller: RemoteSessionController, _ backend: FakeBackend, connections: Int = 1) async {
        await settle("the backend never connected") { backend.connections.count == connections }
        backend.deliverFrame(RemotePixels(width: 2408, height: 1660))
        XCTAssertTrue(controller.isStreaming)
    }

    func testThePresetGoesOutWithTheCreate() async throws {
        let (controller, host, backend) = await make()
        controller.setStreamChoice(.init(preset: .quality))
        controller.start()
        await stream(controller, backend)
        let createdBodies = await host.created
        let created = try XCTUnwrap(createdBodies.first)
        XCTAssertEqual(created.quality_preset, "quality")
        XCTAssertEqual(created.adaptive, false)
        XCTAssertEqual(created.quality.fps, 60)
        XCTAssertEqual(created.quality.bitrate_kbps, 20000)
    }

    func testSwitchingPresetMidStreamReDialsTheSameSession() async throws {
        let (controller, host, backend) = await make()
        controller.start()
        await stream(controller, backend)
        let id = try XCTUnwrap(controller.session?.id)
        let revision = try XCTUnwrap(controller.session?.revision)
        controller.setStreamChoice(.init(preset: .balanced))
        await settle("the resize never went out") { await host.resizes.count == 1 }
        await stream(controller, backend, connections: 2)
        let resizeBodies = await host.resizes
        let resize = try XCTUnwrap(resizeBodies.first)
        XCTAssertEqual(resize.quality_preset, "balanced")
        XCTAssertEqual(resize.expected_revision, revision)
        XCTAssertEqual(controller.session?.id, id, "the same session, re-dialled")
        XCTAssertGreaterThan(controller.session?.revision ?? 0, revision)
        XCTAssertEqual(backend.stops, 1, "the old stream was stopped once, before the new one")
        let created = await host.created.count
        XCTAssertEqual(created, 1, "never a second session")
    }

    func testAChoiceThatPlansTheSameRatesDoesNotReDial() async throws {
        let (controller, host, backend) = await make()
        controller.setStreamChoice(.init(preset: .custom, customFPS: 30, customBitrateKbps: 20_000))
        controller.start()
        await stream(controller, backend)
        // The slider moved within the same thousand: nothing the host would plan differently.
        controller.setStreamChoice(.init(preset: .quality, customFPS: 30, customBitrateKbps: 20_000))
        await settle("the real change never went out") { await host.resizes.count == 1 }
        controller.setStreamChoice(.init(preset: .quality, customFPS: 60, customBitrateKbps: 12_000))
        try? await Task.sleep(for: .milliseconds(100))
        let resizes = await host.resizes.count
        XCTAssertEqual(resizes, 1, "the custom numbers do not matter while the preset is 画质优先")
    }

    func testAutoStepsDownFromTheStatisticsAndReDials() async throws {
        let (controller, host, backend) = await make()
        controller.setStreamChoice(.init(preset: .auto))
        controller.start()
        await stream(controller, backend)
        let createdBodies = await host.created
        let created = try XCTUnwrap(createdBodies.first)
        XCTAssertEqual(created.quality_preset, "quality")
        XCTAssertEqual(created.adaptive, true)
        let bad = RemoteStreamStats(window: 1, totalFrames: 60, receivedFrames: 50, networkDroppedFrames: 10, rttMs: 3)
        for _ in 0..<15 { controller.receiveStats(bad) }
        await settle("自动 never stepped down") { await host.resizes.count == 1 }
        let resizeBodies = await host.resizes
        let resize = try XCTUnwrap(resizeBodies.first)
        XCTAssertEqual(resize.quality_preset, "balanced")
        XCTAssertEqual(resize.adaptive, true)
        XCTAssertNotNil(controller.streamMonitor.reading)
    }

    func testStatisticsAreShownOnlyWhileStreaming() async throws {
        let (controller, _, backend) = await make()
        let sample = RemoteStreamStats(window: 1, totalFrames: 60, receivedFrames: 60, networkDroppedFrames: 0)
        controller.receiveStats(sample)
        XCTAssertNil(controller.streamMonitor.reading)
        controller.start()
        await stream(controller, backend)
        controller.receiveStats(sample)
        XCTAssertEqual(controller.streamMonitor.reading?.stats, sample)
        controller.stop()
        await settle("the monitor kept a stopped stream's numbers") { controller.streamMonitor.reading == nil }
    }
}
