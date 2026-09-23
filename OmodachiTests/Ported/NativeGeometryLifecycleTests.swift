import XCTest
import RemoteInputCore
@testable import Omodachi

/// RemoteInputCore's own release and remapping rules: a disconnect releases what
/// was held, and a new generation/epoch never accepts a gesture mapped for the
/// old one. Synthetic only.
@MainActor
final class NativeGeometryLifecycleTests: XCTestCase {
    func testInputReleaseAndNewGenerationMapping() {
        let input = RemoteInputController()
        let geometry = VideoInputGeometry(viewport: .init(x: 0, y: 0, width: 1000, height: 600),
            videoRect: .init(x: 320, y: 0, width: 360, height: 600), streamPixels: .init(width: 600, height: 1000))
        input.activate(generation: 4, geometryEpoch: 8)
        XCTAssertFalse(input.absolutePress(.init(x: 500, y: 300), geometry: geometry, generation: 4, geometryEpoch: 8).isEmpty)
        let released = input.disconnect(generation: 4)
        XCTAssertFalse(released.isEmpty)
        input.activate(generation: 5, geometryEpoch: 9)
        XCTAssertTrue(input.absoluteMove(.init(x: 500, y: 300), geometry: geometry, generation: 4, geometryEpoch: 8).isEmpty)
        XCTAssertTrue(input.absoluteMove(.init(x: 500, y: 300), geometry: geometry, generation: 5, geometryEpoch: 8).isEmpty)
        XCTAssertTrue(input.absoluteMove(.init(x: 50, y: 300), geometry: geometry, generation: 5, geometryEpoch: 9).isEmpty)
        let mapped = input.absoluteMove(.init(x: 500, y: 300), geometry: geometry, generation: 5, geometryEpoch: 9)
        guard let event = mapped.first, case .absolutePointer(let x, let y, let width, let height) = event.payload else { XCTFail("No mapped pointer"); return }
        XCTAssertEqual(x, 300)
        XCTAssertEqual(y, 500)
        XCTAssertEqual(width, 600)
        XCTAssertEqual(height, 1000)
        XCTAssertEqual(event.geometryEpoch, 9)
    }
}
