import SwiftUI
import UIKit
import XCTest
@testable import Omodachi

/// STORE-6 §B6. Every glyph is drawn whole and centred, at every size.
///
/// The bar and menu icons were cut off on the right on a paired computer: the
/// host's non-Mono Nerd Font gives an icon ink up to twice its advance, and a
/// `Text` box is its advance. These render the glyphs and read the pixels back,
/// so a glyph that is clipped or pushed off-centre fails here rather than in a
/// store screenshot.
@MainActor final class GlyphInkTests: XCTestCase {
    private static let sizes: [CGFloat] = [10, 12, 14, 16, 18, 22, 28, 34, 40, 56]

    /// Every icon the app names, in the bundled face, at every size: whole,
    /// inside its box, and centred on its ink.
    func testEveryAppIconIsWholeAndCentredInTheBundledFace() throws {
        let family = HostFontSet.bundledSymbols
        for icon in Self.icons {
            for size in Self.sizes {
                let outline = try XCTUnwrap(GlyphInk.outline(icon, family: family, size: size),
                                            "U+\(Self.hex(icon)) has no outline in \(family)")
                let image = try XCTUnwrap(GlyphInk.render(icon, family: family, size: size, scale: 3, always: true))
                try assertWholeAndCentred(image, outline: outline, size: size, label: "U+\(Self.hex(icon)) @\(size)")
            }
        }
    }

    /// A face whose ink leaves its advance — the shape of the host's
    /// `JetBrainsMono Nerd Font` icons — is drawn from its outline, whole.
    /// Zapfino is on every iOS device and its swashes overhang their advance by
    /// far more than a Nerd Font icon does, so it is the harder case.
    func testAGlyphWiderThanItsCellIsDrawnWholeNotCut() throws {
        let family = "Zapfino" // non-copy: a system font used as a fixture
        let candidates = ["f", "g", "j", "Q", "y"]
        let overflowing = candidates.first { GlyphInk.outline($0, family: family, size: 22)?.overflows == true }
        let glyph = try XCTUnwrap(overflowing, "the fixture face has no overhanging glyph")
        for size in Self.sizes {
            let outline = try XCTUnwrap(GlyphInk.outline(glyph, family: family, size: size))
            XCTAssertTrue(outline.overflows)
            let image = try XCTUnwrap(GlyphInk.image(glyph, family: family, size: size, scale: 3),
                                      "an overflowing glyph is drawn from its outline, not as clipped text")
            try assertWholeAndCentred(image, outline: outline, size: size, label: "\(glyph) @\(size)")
        }
    }

    /// The view the bar and the menu actually use: with an overflowing face it
    /// is a `size` box with the whole glyph centred in it.
    func testTheGlyphViewDrawsTheWholeGlyphInItsBox() throws {
        let family = "Zapfino" // non-copy: a system font used as a fixture
        let glyph = try XCTUnwrap(["f", "g", "j", "Q", "y"].first {
            GlyphInk.outline($0, family: family, size: 22)?.overflows == true })
        let size: CGFloat = 22
        let renderer = ImageRenderer(content: HostGlyphText(text: glyph, family: family, size: size)
            .foregroundStyle(.black).frame(width: 60, height: 60).background(.white))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let ink = try XCTUnwrap(Self.inkBounds(image, dark: true))
        // The box is centred in the 60pt frame, so the ink must be inside
        // [19, 41] and its centre within a point of 30.
        let box = CGRect(x: 19 * 3, y: 19 * 3, width: 22 * 3, height: 22 * 3).insetBy(dx: -2, dy: -2)
        XCTAssertTrue(box.contains(ink), "ink \(ink) leaves its box \(box)")
        XCTAssertEqual(ink.midX, 90, accuracy: 3)
        XCTAssertEqual(ink.midY, 90, accuracy: 3)
    }

    /// A glyph whose ink fits its cell is still drawn as text, so the demo and
    /// every screen already right look exactly as they did.
    func testAGlyphThatFitsItsCellIsLeftToText() {
        for icon in Self.icons {
            let outline = GlyphInk.outline(icon, family: HostFontSet.bundledSymbols, size: 22)
            if outline?.overflows == false {
                XCTAssertNil(GlyphInk.image(icon, family: HostFontSet.bundledSymbols, size: 22, scale: 3))
            }
        }
    }

    // MARK: - Helpers

    private func assertWholeAndCentred(_ image: UIImage, outline: GlyphInk.Outline, size: CGFloat,
                                       label: String) throws {
        let cg = try XCTUnwrap(image.cgImage)
        let scale = image.scale
        let ink = try XCTUnwrap(Self.inkBounds(cg, dark: false), "\(label): nothing drawn")
        let box = CGFloat(cg.width)
        XCTAssertEqual(box, size * scale, accuracy: 1, label)
        // Whole: nothing touches an edge unless the glyph fills the box.
        let placed = GlyphInk.placement(of: outline.ink, in: size)
        XCTAssertEqual(ink.width, placed.ink.width * scale, accuracy: 3, "\(label): width cut")
        XCTAssertEqual(ink.height, placed.ink.height * scale, accuracy: 3, "\(label): height cut")
        // Centred on its own ink.
        XCTAssertEqual(ink.midX, box / 2, accuracy: 2, "\(label): off-centre horizontally")
        XCTAssertEqual(ink.midY, box / 2, accuracy: 2, "\(label): off-centre vertically")
    }

    /// The bounding box of the pixels that are drawn: alpha for the template
    /// image, darkness for a view rendered black on white.
    static func inkBounds(_ image: CGImage, dark: Bool) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let on = dark ? pixels[i] < 128 && pixels[i + 3] > 128 : pixels[i + 3] > 40
                if on { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static var icons: [String] {
        [Icon.menu, Icon.search, Icon.close, Icon.check, Icon.chevronRight, Icon.chevronDown, Icon.pin,
         Icon.remote, Icon.agent, Icon.herdr, Icon.ssh, Icon.settings, Icon.bell, Icon.bellOff, Icon.keyboard,
         Icon.warning, Icon.error, Icon.host, Icon.send, Icon.retry, Icon.dnd, Icon.more, Icon.app].map(\.nerd)
    }

    private static func hex(_ text: String) -> String {
        String(text.unicodeScalars.first?.value ?? 0, radix: 16, uppercase: true)
    }
}
