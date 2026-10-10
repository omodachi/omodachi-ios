import SwiftUI
import XCTest
@testable import Omodachi

/// MOTION-1 evidence: the app's own `AgentFaceDrawing` painted for every
/// surface × state in four Omarchy themes (dark, light, kanagawa's accent rule,
/// a second light), still and in motion, without a host — the host's own
/// theme cannot be switched for a test. Runs only when
/// `TEST_RUNNER_OMODACHI_MOTION_GALLERY` names a directory on the Mac; every
/// other run skips it.
final class MOTION1GalleryTests: XCTestCase {
    private struct Palette {
        let name: String, mode: String, bg: String, fg: String, accent: String, yellow: String, red: String
        var theme: HostTheme {
            HostTheme(name: name, mode: mode,
                      colors: ["background": bg, "foreground": fg, "accent": accent, "yellow": yellow, "red": red],
                      shell: [:])
        }
    }

    // bg / fg / accent / yellow from the study's THEMES table (Omarchy's
    // `colors.toml`); red from the same themes.
    private let palettes = [
        Palette(name: "tokyo-night", mode: "dark", bg: "#1a1b26", fg: "#a9b1d6", accent: "#7aa2f7", yellow: "#e0af68", red: "#f7768e"),
        Palette(name: "catppuccin-latte", mode: "light", bg: "#eff1f5", fg: "#4c4f69", accent: "#1e66f5", yellow: "#df8e1d", red: "#d20f39"),
        Palette(name: "kanagawa", mode: "dark", bg: "#1f1f28", fg: "#dcd7ba", accent: "#dcd7ba", yellow: "#c0a36e", red: "#c34043"),
        Palette(name: "rose-pine", mode: "light", bg: "#faf4ed", fg: "#575279", accent: "#56949f", yellow: "#ea9d34", red: "#b4637a"),
    ]

    private let surfaces: [(AgentFaceSurface, CGFloat, String)] = [
        (.bar, 24, "bar 24"), (.pane, 24, "pane 24"), (.tiles, 24, "tiles 24"),
        (.header, 32, "header 32"), (.large, 96, "large 96"),
    ]

    private func out() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["OMODACHI_MOTION_GALLERY"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_OMODACHI_MOTION_GALLERY to write the gallery")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Face: View {
        let state: AgentFaceState, tool: Bool, surface: AgentFaceSurface, size: CGFloat
        let t: Double, still: Bool, palette: AgentFacePalette
        var body: some View {
            let clock = AgentFaceClock()
            let drawing = AgentFaceDrawing.make(state: state, tool: tool, surface: surface, size: size, clock: clock,
                                                date: still ? nil : clock.entered.addingTimeInterval(t / 1000), still: still)
            Canvas { context, canvas in
                if let drawing { AgentFaceDrawing.paint(drawing, in: &context, size: canvas, scale: 3, palette: palette) }
            }
            .frame(width: size, height: size)
            .opacity(drawing?.frame.dim == true ? AgentFaceDim.offline : 1)
        }
    }

    private struct Sheet: View {
        let palette: Palette
        let surfaces: [(AgentFaceSurface, CGFloat, String)]
        let t: Double
        let still: Bool
        var body: some View {
            let theme = palette.theme
            let ink = AgentFacePalette.make(theme, .panel)
            let fg = Color(rgb: theme.rgb(.foreground)), bg = Color(rgb: theme.rgb(.background))
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "MOTION-1 · \(palette.name) (\(palette.mode)) · \(still ? "Reduce Motion: static poses" : "t = \(Int(t)) ms")")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                HStack(alignment: .bottom, spacing: 0) {
                    Text(verbatim: "").frame(width: 80)
                    ForEach(AgentFaceState.allCases.map(\.rawValue) + ["tool"], id: \.self) { name in
                        Text(verbatim: name).frame(width: 104)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                ForEach(surfaces, id: \.2) { surface, size, label in
                    HStack(spacing: 0) {
                        Text(verbatim: label).font(.system(size: 11, design: .monospaced)).frame(width: 80, alignment: .leading)
                        // INTEGRATE-2: eight states (stopped added) and the tool column.
                        let states = AgentFaceState.allCases.count
                        ForEach(0...states, id: \.self) { i in
                            let state = i < states ? AgentFaceState.allCases[i] : .working
                            let code = surface.code(state)
                            Group {
                                if code == "—" {
                                    Text(verbatim: "—")
                                } else if code.hasPrefix("V") {
                                    Text(verbatim: code == "V" ? "vendor" : "vendor (dim)")
                                } else {
                                    Face(state: state, tool: i == states, surface: surface, size: size, t: t, still: still,
                                         palette: ink)
                                }
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 104, height: max(size, 30))
                        }
                    }
                }
            }
            .padding(14)
            .foregroundStyle(fg)
            .background(bg)
        }
    }

    @MainActor private func write<V: View>(_ view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        try XCTUnwrap(image.pngData()).write(to: url)
    }

    @MainActor func testGalleryStillAndMoving() throws {
        let dir = try out()
        for palette in palettes {
            // A still contact sheet at 0.3 of the loop (clear of blinks), and RM.
            try write(Sheet(palette: palette, surfaces: surfaces, t: 750, still: false),
                      to: dir.appendingPathComponent("sheet-\(palette.name).png"))
            try write(Sheet(palette: palette, surfaces: surfaces, t: 0, still: true),
                      to: dir.appendingPathComponent("sheet-\(palette.name)-rm.png"))
        }
        // GIF frames: 2.4 s at 12 fps, the dark and the light theme.
        for palette in [palettes[0], palettes[1]] {
            let frames = dir.appendingPathComponent("frames-\(palette.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            for i in 0..<29 {
                try write(Sheet(palette: palette, surfaces: surfaces, t: Double(i) * 1000 / 12, still: false),
                          to: frames.appendingPathComponent(String(format: "f%03d.png", i)))
            }
        }
    }
}
