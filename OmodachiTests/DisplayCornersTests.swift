import CoreGraphics
import XCTest
@testable import Omodachi

/// REMOTE-SAFE-1. The corner table, the shape, and what reaches the host.
final class DisplayCornersTests: XCTestCase {
    private func phone(_ model: String, inset: CGFloat = 34) -> CGFloat {
        DisplayCorners.radius(model: model, isPad: false, homeIndicatorInset: inset)
    }
    private func pad(_ model: String, inset: CGFloat = 20) -> CGFloat {
        DisplayCorners.radius(model: model, isPad: true, homeIndicatorInset: inset)
    }
    private func fullScreen(_ radius: CGFloat, _ size: CGSize) -> DisplayCorners {
        DisplayCorners.window(frame: CGRect(origin: .zero, size: size), screen: CGRect(origin: .zero, size: size),
                              radius: radius)
    }
    /// What `RemoteSessionController.barOcclusion` computes: Omarchy's 26 px
    /// bar on an output whose long edge is 1280 px.
    private func occlusion(_ corners: DisplayCorners, viewport: CGSize, bar: CGFloat = 26) -> RemoteBarOcclusion {
        corners.barOcclusion(thickness: bar * max(viewport.width, viewport.height) / 1280)
    }

    // MARK: - The table, one shipping device of each class

    func testEveryShippingClassHasItsRadius() {
        XCTAssertEqual(phone("iPhone18,1"), 62, "iPhone 17 Pro")
        XCTAssertEqual(phone("iPhone18,2"), 62, "iPhone 17 Pro Max")
        XCTAssertEqual(phone("iPhone18,4"), 62, "iPhone Air")
        XCTAssertEqual(phone("iPhone17,5"), 47.33, "iPhone 16e")
        XCTAssertEqual(phone("iPhone16,1"), 55, "iPhone 15 Pro")
        XCTAssertEqual(phone("iPhone14,4"), 44, "iPhone 13 mini")
        XCTAssertEqual(phone("iPhone10,3"), 39, "iPhone X")
        XCTAssertEqual(pad("iPad17,1"), 30, "iPad Pro 11-inch (M5)")
        XCTAssertEqual(pad("iPad16,5"), 30, "iPad Pro 13-inch (M4)")
        XCTAssertEqual(pad("iPad14,3"), 18, "iPad Pro 11-inch (4th generation), Face ID: the smaller radius")
        XCTAssertEqual(pad("iPad16,8"), 18, "iPad Air 11-inch (M4)")
        XCTAssertEqual(pad("iPad16,1"), 21.5, "iPad mini (A17 Pro)")
        XCTAssertEqual(pad("iPad15,7"), 25, "iPad (A16)")
    }

    func testHomeButtonDevicesAreSquare() {
        // iPhone SE (3rd generation), iPhone 8, iPad (9th generation), iPad Air
        // (3rd generation): no entry, and no home indicator to fall back on.
        XCTAssertEqual(phone("iPhone14,6", inset: 0), 0)
        XCTAssertEqual(phone("iPhone10,1", inset: 0), 0)
        XCTAssertEqual(pad("iPad12,1", inset: 0), 0)
        XCTAssertEqual(pad("iPad11,3", inset: 0), 0,
                       "Xcode lists 18 for this one, but it has a home button and a square screen")
        XCTAssertEqual(occlusion(fullScreen(phone("iPhone14,6", inset: 0), CGSize(width: 375, height: 667)),
                                 viewport: CGSize(width: 375, height: 667)),
                       RemoteBarOcclusion(top: 0, bottom: 0, left: 0, right: 0))
    }

    func testAnUnknownModelFallsBackOnTheHomeIndicator() {
        XCTAssertEqual(phone("iPhone99,1", inset: 34), DisplayCorners.unknownPhoneRadius)
        XCTAssertEqual(pad("iPad99,1", inset: 20), DisplayCorners.unknownPadRadius)
        XCTAssertEqual(phone("iPhone99,1", inset: 0), 0)
        XCTAssertEqual(pad("iPad99,1", inset: 0), 0)
        XCTAssertEqual(phone("arm64", inset: 21), DisplayCorners.unknownPhoneRadius,
                       "a simulator without its model in the environment still counts as rounded")
    }

    /// The table is Xcode's own device data, not a copy that drifted: every
    /// Face-ID-class device type Xcode ships has exactly its
    /// `DeviceCornerRadius` here, and nothing else is in the table. Skipped
    /// where the profiles are not readable (a device, or a machine without
    /// Xcode's CoreSimulator profiles).
    func testTheTableIsXcodesOwnDeviceProfiles() throws {
        let root = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            throw XCTSkip("Xcode's device profiles are not readable here")
        }
        func find(_ value: Any, _ key: String) -> Any? {
            if let dict = value as? [String: Any] {
                if let hit = dict[key] { return hit }
                for child in dict.values { if let hit = find(child, key) { return hit } }
            } else if let list = value as? [Any] {
                for child in list { if let hit = find(child, key) { return hit } }
            }
            return nil
        }
        func mainScreen(_ value: Any) -> [String: Any]? {
            if let dict = value as? [String: Any] {
                if (dict["screenID"] as? NSNumber)?.intValue == 1, dict["width"] != nil { return dict }
                for child in dict.values { if let hit = mainScreen(child) { return hit } }
            } else if let list = value as? [Any] {
                for child in list { if let hit = mainScreen(child) { return hit } }
            }
            return nil
        }
        var checked = 0
        var listed = Set<String>()
        for name in names where name.hasPrefix("iPhone") || name.hasPrefix("iPad") {
            let resources = root.appendingPathComponent(name).appendingPathComponent("Contents/Resources")
            guard let profileData = try? Data(contentsOf: resources.appendingPathComponent("profile.plist")),
                  let profile = try PropertyListSerialization.propertyList(from: profileData, format: nil) as? [String: Any],
                  let capabilityData = try? Data(contentsOf: resources.appendingPathComponent("capabilities.plist")) else { continue }
            let capabilities = try PropertyListSerialization.propertyList(from: capabilityData, format: nil)
            let radius = (find(capabilities, "DeviceCornerRadius") as? NSNumber)?.doubleValue ?? 0
            let faceID = (find(capabilities, "HomeButtonType") as? NSNumber)?.intValue == 2
            let models = profile["representedModelIdentifiers"] as? [String]
                ?? [profile["modelIdentifier"] as? String].compactMap { $0 }
            for model in models {
                if faceID && radius > 0 {
                    listed.insert(model)
                    XCTAssertEqual(Double(DisplayCorners.radii[model] ?? -1), radius, accuracy: 0.01, "\(name) \(model)")
                    let screen = try XCTUnwrap(mainScreen(capabilities), name)
                    XCTAssertEqual(DisplayCorners.displays[model]?.native,
                                   CGSize(width: (screen["width"] as? NSNumber)?.doubleValue ?? 0,
                                          height: (screen["height"] as? NSNumber)?.doubleValue ?? 0), "\(name) \(model)")
                } else {
                    XCTAssertNil(DisplayCorners.radii[model], "\(name) \(model) is a home-button device")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 60)
        XCTAssertEqual(Set(DisplayCorners.radii.keys), listed, "every entry is one Xcode vouches for")
    }

    /// Stage Manager on a monitor: the window's screen is not the model's own
    /// panel, and a monitor has square corners.
    func testAnExternalDisplayIsSquare() {
        let native = CGSize(width: 1668, height: 2420)
        XCTAssertEqual(DisplayCorners.radius(model: "iPad17,1", isPad: true, homeIndicatorInset: 20, nativePixels: native), 30)
        XCTAssertEqual(DisplayCorners.radius(model: "iPad17,1", isPad: true, homeIndicatorInset: 20,
                                             nativePixels: CGSize(width: 2420, height: 1668)), 30, "either orientation")
        XCTAssertEqual(DisplayCorners.radius(model: "iPad17,1", isPad: true, homeIndicatorInset: 0,
                                             nativePixels: CGSize(width: 3840, height: 2160)), 0)
    }

    // MARK: - The shape

    func testTheCornerIsContinuousNotACircle() {
        let radius: CGFloat = 62
        func circle(_ depth: CGFloat) -> CGFloat { radius - (radius * radius - (radius - depth) * (radius - depth)).squareRoot() }
        for depth: CGFloat in [1, 3, 5, 10, 20] {
            XCTAssertGreaterThan(DisplayCorners.occlusion(radius: radius, depth: depth), circle(depth),
                                 "the continuous corner reaches further than a circle at \(depth) pt")
        }
        XCTAssertEqual(DisplayCorners.occlusion(radius: radius, depth: radius), 0)
        XCTAssertEqual(DisplayCorners.occlusion(radius: 0, depth: 4), 0)
        // Monotone: deeper in, less of the edge is covered.
        var previous = CGFloat.infinity
        for step in 0...40 {
            let value = DisplayCorners.occlusion(radius: radius, depth: CGFloat(step) * radius / 40)
            XCTAssertLessThanOrEqual(value, previous)
            previous = value
        }
    }

    // MARK: - The numbers a real session sends

    /// The number core's `tests/test_remote_corners.py` starts from.
    func testIPhone17ProPortraitAndLandscape() {
        let radius = phone("iPhone18,1")
        let portrait = CGSize(width: 402, height: 874)
        let expected = RemoteBarOcclusion(top: 46.4, bottom: 46.4, left: 46.4, right: 46.4)
        XCTAssertEqual(occlusion(fullScreen(radius, portrait), viewport: portrait), expected)
        let landscape = CGSize(width: 874, height: 402)
        XCTAssertEqual(occlusion(fullScreen(radius, landscape), viewport: landscape), expected,
                       "every corner has one radius, so the ends do not care which way the phone is turned")
        // In the host's pixels: 46.4 pt of an 874 pt picture of a 1280 px
        // output is 68 px - the power button, 7 px from the edge before,
        // moves in to 68 + the slot's own padding.
        XCTAssertEqual((46.4 * 1280 / 874).rounded(.up), 68)
    }

    func testIPadProM5Portrait() {
        let size = CGSize(width: 834, height: 1210)
        let value = occlusion(fullScreen(pad("iPad17,1"), size), viewport: size)
        XCTAssertEqual(value.top, 14.8, accuracy: 0.001)
        XCTAssertEqual(value.left, 14.8, accuracy: 0.001)
    }

    func testAThickerBarIsMeasuredDeeperAndLosesLess() {
        let size = CGSize(width: 402, height: 874)
        let corners = fullScreen(62, size)
        XCTAssertLessThan(occlusion(corners, viewport: size, bar: 40).top, occlusion(corners, viewport: size, bar: 26).top)
    }

    // MARK: - Only the window's corners that are the display's

    func testSplitViewAndStageManagerOnlyCountTheCornersTheWindowTouches() {
        let screen = CGRect(x: 0, y: 0, width: 1210, height: 834)
        let left = DisplayCorners.window(frame: CGRect(x: 0, y: 0, width: 600, height: 834), screen: screen, radius: 30)
        XCTAssertEqual(left, DisplayCorners(topLeft: 30, topRight: 0, bottomLeft: 30, bottomRight: 0))
        let occlusion = left.barOcclusion(thickness: 24)
        XCTAssertGreaterThan(occlusion.top, 0, "a vertical bar on the left edge still meets the top-left corner")
        XCTAssertGreaterThan(occlusion.left, 0)
        XCTAssertEqual(occlusion.right, 0, "the window's right edge is the split, not the display's corner")
        let floating = DisplayCorners.window(frame: CGRect(x: 100, y: 80, width: 700, height: 600), screen: screen, radius: 30)
        XCTAssertEqual(floating, .square)
        XCTAssertTrue(floating.barOcclusion(thickness: 24).isZero)
    }

    // MARK: - The wire

    private func geometry(_ occlusion: RemoteBarOcclusion?) -> RemoteGeometryRequest {
        var value = RemoteGeometryRequest(viewport_points: .init(width: 402, height: 874), orientation: "portrait",
                                          logical_long_edge: 1280, quality: RemoteQuality())
        value.bar_occlusion_points = occlusion
        return value
    }

    func testTheFieldTravelsOnCreateAndResizeAndIsAbsentWithoutIt() throws {
        let value = RemoteBarOcclusion(top: 46.4, bottom: 46.4, left: 46.4, right: 46.4)
        for body in [try JSONEncoder().encode(RemoteCreateRequest(backend: .vnc, mode: .extend, geometry: geometry(value), ttlSeconds: 60)),
                     try JSONEncoder().encode(RemoteResizeRequest(expectedRevision: 2, geometry: geometry(value)))] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["bar_occlusion_points"] as? [String: Double],
                           ["top": 46.4, "bottom": 46.4, "left": 46.4, "right": 46.4])
        }
        for body in [try JSONEncoder().encode(RemoteCreateRequest(backend: .vnc, mode: .extend, geometry: geometry(nil), ttlSeconds: 60)),
                     try JSONEncoder().encode(RemoteResizeRequest(expectedRevision: 2, geometry: geometry(nil)))] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(json["bar_occlusion_points"], "a host from before REMOTE-SAFE-1 refuses unknown fields")
        }
    }

    func testTheCapabilityIsReadAndItsAbsenceMeansNo() throws {
        let base = #"{"backends":{},"modes":["extend"],"placement_options":["right"],"lock_local_input_supported":true,"encoder_limits":null"#
        XCTAssertNil(try JSONDecoder().decode(RemoteCapabilitiesDTO.self, from: Data((base + "}").utf8)).bar_occlusion)
        XCTAssertEqual(try JSONDecoder().decode(RemoteCapabilitiesDTO.self,
                                                from: Data((base + #","bar_occlusion":true}"#).utf8)).bar_occlusion, true)
    }
}

/// REMOTE-SAFE-1 through the controller: the create body carries the corners
/// only to a host that takes them, in either mode, and a rotation re-sends.
@MainActor final class RemoteBarOcclusionControllerTests: XCTestCase {
    private func make(host capable: Bool, mode: RemoteMode = .extend) async -> (RemoteSessionController, FakeRemoteHost, FakeBackend) {
        let host = FakeRemoteHost()
        await host.setBarOcclusion(capable)
        let backend = FakeBackend()
        let controller = RemoteSessionController(service: host, driver: backend)
        controller.backendChoice = .vnc
        controller.mode = mode
        var profile = HostProfile()
        profile.mock = false
        profile.hostname = "omarchy"
        profile.companionURL = "https://omarchy.invalid:8099"
        controller.configure(profile: profile)
        let size = CGSize(width: 402, height: 874)
        controller.viewportChanged(size: size, orientation: "portrait",
                                   corners: DisplayCorners.window(frame: CGRect(origin: .zero, size: size),
                                                                  screen: CGRect(origin: .zero, size: size), radius: 62))
        return (controller, host, backend)
    }

    private func settle(_ message: String, _ predicate: @escaping () async -> Bool) async {
        for _ in 0..<400 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
    }

    func testAnExtendSessionOnACapableHostSendsTheCorners() async throws {
        let (controller, host, _) = await make(host: true)
        controller.start()
        await settle("the session was never created") { await host.created.count == 1 }
        let created = await host.created
        XCTAssertEqual(created.first?.bar_occlusion_points, RemoteBarOcclusion(top: 46.4, bottom: 46.4, left: 46.4, right: 46.4))
    }

    func testAnOlderHostIsNeverSentTheField() async throws {
        let (controller, host, _) = await make(host: false)
        controller.start()
        await settle("the session was never created") { await host.created.count == 1 }
        let created = await host.created
        XCTAssertNil(created.first?.bar_occlusion_points)
    }

    /// REMOTE-SAFE-1b. A takeover's output is the same device shape with the
    /// whole desktop on it; its bar reaches the same corners.
    func testATakeoverSendsThemToo() async throws {
        let (controller, host, _) = await make(host: true, mode: .takeover)
        controller.start()
        await settle("the session was never created") { await host.created.count == 1 }
        let created = await host.created
        XCTAssertEqual(created.first?.mode, .takeover)
        XCTAssertEqual(created.first?.bar_occlusion_points, RemoteBarOcclusion(top: 46.4, bottom: 46.4, left: 46.4, right: 46.4))
    }

    /// REMOTE-SAFE-1b. A takeover rotation re-sends the corners with the new
    /// viewport, so the host's insets follow the bar when official_bar_position
    /// flips it to the other axis.
    func testATakeoverRotationResendsThem() async throws {
        let (controller, host, backend) = await make(host: true, mode: .takeover)
        controller.start()
        await settle("no first connection") { await backend.connections.count == 1 }
        backend.deliverFrame(RemotePixels(width: 1206, height: 2622))
        let size = CGSize(width: 874, height: 402)
        controller.viewportChanged(size: size, orientation: "landscape",
                                   corners: DisplayCorners.window(frame: CGRect(origin: .zero, size: size),
                                                                  screen: CGRect(origin: .zero, size: size), radius: 62))
        await settle("the rotation never reached the host") { await host.resizeCount() == 1 }
        let resizes = await host.resizes
        XCTAssertEqual(resizes.first?.orientation, "landscape")
        XCTAssertEqual(resizes.first?.bar_occlusion_points, RemoteBarOcclusion(top: 46.4, bottom: 46.4, left: 46.4, right: 46.4))
    }

    func testTheHostsOwnBarThicknessIsUsedOnceItIsKnown() async throws {
        let (controller, _, _) = await make(host: true)
        let before = controller.barOcclusion()
        controller.applyBarGeometry(HostBarGeometry(output: "OMODACHI-0123456789abcdef",
                                                    logicalSize: CGSize(width: 589, height: 1280), position: .left,
                                                    bar: CGRect(x: 0, y: 0, width: 40, height: 1280), logo: nil))
        XCTAssertLessThan(controller.barOcclusion().top, before.top,
                          "a 40 px bar is measured deeper into the corner than the 26 px default")
    }
}
