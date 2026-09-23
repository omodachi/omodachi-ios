import XCTest
@testable import Omodachi

/// Native bar policy, host layout contract, placement, occlusion and
/// persistence. Synthetic only.
final class NativeBarPolicyTests: XCTestCase {
    func testBarEdgeResolution() {
        let resolve = NativeBarPositionPolicy.resolve
        XCTAssertEqual(resolve(1200, 800, .bottom, .right, nil), .bottom, "landscape preference")
        XCTAssertEqual(resolve(800, 1200, .bottom, .right, nil), .right, "portrait preference")
        XCTAssertEqual(resolve(1200, 800, .left, .top, nil), .top, "invalid horizontal preference normalized")
        XCTAssertEqual(resolve(800, 1200, .left, .bottom, nil), .left, "invalid vertical preference normalized")
        XCTAssertEqual(resolve(800, 800, .top, .left, .right), .right, "square preserves prior edge")
        XCTAssertEqual(resolve(.nan, 800, .top, .left, .bottom), .bottom, "transient invalid viewport retains edge")
        XCTAssertEqual(resolve(0, 0, .bottom, .left, nil), .bottom, "initial invalid viewport deterministic")
    }

    func testHostBarLayoutContract() throws {
        let json = #"{"source":"shell.json","source_status":"available","position":"left","revision":"r1","left":[{"id":"menu","role":"logo"},{"id":"desktop","role":"workspaces"}],"center":[{"id":"external","role":"custom-unsafe"}],"right":[{"id":"companion","role":"panel"},{"id":"tray","role":"system_tray"}]}"#
        let dto = try JSONDecoder().decode(HostBarLayoutDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.nativeLayout?.left, ["logo", "workspaces"], "host order preserved")
        XCTAssertEqual(dto.nativeLayout?.center, ["unsupported"], "unknown widget not interpreted")
        XCTAssertEqual(dto.nativeLayout?.right, ["panel", "tray"], "native Panel and tray roles distinct")
        XCTAssertEqual(dto.nativeLayout?.position, .left, "host position retained")
        let invalid = json.replacingOccurrences(of: "available", with: "unavailable")
        let unavailable = try JSONDecoder().decode(HostBarLayoutDTO.self, from: Data(invalid.utf8))
        XCTAssertNil(unavailable.nativeLayout, "unavailable config cannot fabricate bar")
        let badPosition = json.replacingOccurrences(of: #""position":"left""#, with: #""position":"diagonal""#)
        let rejected = try JSONDecoder().decode(HostBarLayoutDTO.self, from: Data(badPosition.utf8))
        XCTAssertNil(rejected.nativeLayout, "invalid host edge rejected")
    }

    func testPlacementOcclusionAndPersistence() throws {
        var placement = NativeBarPlacement()
        placement.update(width: 800, height: 1200, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .left, "portrait on window geometry")
        placement.update(width: 800, height: 450, reason: .temporaryOcclusion)
        XCTAssertEqual(placement.edge, .left, "keyboard and Panel cannot change bar edge")
        XCTAssertEqual(placement.height, 1200, "keyboard and Panel cannot change bar edge")
        placement.choose(.right)
        placement.update(width: 1200, height: 800, reason: .windowGeometry)
        placement.choose(.bottom)
        XCTAssertEqual(placement.edge, .bottom, "landscape chosen independently")
        placement.update(width: 800, height: 1200, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .right, "portrait preference restored after rotation")
        placement.update(width: 1200, height: 800, reason: .windowGeometry)
        XCTAssertEqual(placement.edge, .bottom, "landscape preference restored after rotation")
        let preferencesData = try JSONEncoder().encode(placement.preferences)
        let restored = try JSONDecoder().decode(NativeBarEdgePreferences.self, from: preferencesData)
        XCTAssertEqual(restored, placement.preferences, "two edge preferences persist independently")
    }
}
