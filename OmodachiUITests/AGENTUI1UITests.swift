import XCTest
import UIKit

/// AGENT-UI-1 — "agent输入框是透明的 滚动的时候好脏". The Agent composer's box
/// was a 1px frame on the panel's own background: the box and the conversation
/// were the same colour, so the lines scrolling up to it read as running on
/// into it. The box is now a filled control surface.
///
/// What is measured, in the screenshot's own pixels (portrait, the
/// `--agent-collie-fixture` long conversation):
///
/// * inside the box — the empty corner above the paperclip and the empty
///   trailing edge — is one colour, and that colour is not the panel's
///   background just under the box (it was, before: the box had no surface);
/// * that colour stays exactly put while the conversation is scrolled both
///   ways, with the keyboard down and up: nothing of the transcript shows in
///   the box.
@MainActor
final class AGENTUI1UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            executionTimeAllowance = 240
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--agent-collie-fixture"]
            app.launch()
            XCTAssertTrue(app.buttons["open-agent"].waitForExistence(timeout: 10))
            app.buttons["open-agent"].tap()
        }
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
        try await super.tearDown()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testTheComposerBoxIsAFilledSurfaceThatNothingScrollsThrough() {
        let field = element("agent-chat-composer")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        let hint = element("hint-dismiss")
        if hint.exists { hint.tap() }

        let resting = probe("keyboard down")
        XCTAssertFalse(resting.box.isClose(to: resting.panel),
                       "the box \(resting.box) is the panel's own colour \(resting.panel): it has no surface")
        scrollBothWays(checking: resting.box, "keyboard down")
        attach("agent-ui1-composer-keyboard-down")

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        let typing = probe("keyboard up")
        XCTAssertFalse(typing.box.isClose(to: typing.panel),
                       "while typing the box \(typing.box) is the panel's colour \(typing.panel)")
        scrollBothWays(checking: typing.box, "keyboard up")
        attach("agent-ui1-composer-keyboard-up")
    }

    // MARK: - Measuring

    private struct Probe { let box: RGB; let panel: RGB }

    /// The box's colour at two empty places inside it, and the panel's just
    /// under it. The box is the paperclip's row: it starts where the paperclip
    /// starts and ends a gap before Send, which shares its bottom edge
    /// (AGENT-PLAN-1: the `/` button that stood there is gone).
    private func probe(_ moment: String, file: StaticString = #filePath, line: UInt = #line) -> Probe {
        let attach = element("agent-attach").frame
        let send = element("agent-send").frame
        XCTAssertFalse(attach.isEmpty || send.isEmpty, "\(moment): the composer is not laid out",
                       file: file, line: line)
        let shot = app.screenshot().image
        let corner = pixel(shot, CGPoint(x: attach.minX + 4, y: attach.minY + 4))
        let trailing = pixel(shot, CGPoint(x: send.minX - 14, y: attach.midY))
        let panel = pixel(shot, CGPoint(x: attach.minX + 4, y: send.maxY + 3))
        XCTAssertTrue(corner.isClose(to: trailing),
                      "\(moment): the box is not one surface: \(corner) at the paperclip, \(trailing) at its end",
                      file: file, line: line)
        return Probe(box: corner, panel: panel)
    }

    /// Drags the conversation down and up and looks into the box right after
    /// each drag, while the list is still moving.
    private func scrollBothWays(checking box: RGB, _ moment: String) {
        let window = app.windows.firstMatch
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.2))
        let lower = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45))
        for (from, to, way) in [(top, lower, "down"), (lower, top, "up"), (top, lower, "down again")] {
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
            let seen = probe("\(moment), scrolled \(way)")
            XCTAssertTrue(seen.box.isClose(to: box),
                          "\(moment), scrolled \(way): the box shows \(seen.box) instead of its own \(box)")
        }
    }

    private func pixel(_ image: UIImage, _ point: CGPoint) -> RGB {
        guard let cg = image.cgImage else { return RGB(r: -1, g: -1, b: -1) }
        let scale = CGFloat(cg.width) / image.size.width
        let x = min(max(Int(point.x * scale), 0), cg.width - 1)
        let y = min(max(Int(point.y * scale), 0), cg.height - 1)
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
            return true
        }
        return drawn ? RGB(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2])) : RGB(r: -1, g: -1, b: -1)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

private struct RGB: CustomStringConvertible {
    let r: Int, g: Int, b: Int
    /// Two levels of slack for the screenshot's colour conversion.
    func isClose(to other: RGB) -> Bool {
        r >= 0 && other.r >= 0 && abs(r - other.r) <= 2 && abs(g - other.g) <= 2 && abs(b - other.b) <= 2
    }
    var description: String { "rgb(\(r),\(g),\(b))" }
}
