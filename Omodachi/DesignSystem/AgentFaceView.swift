import SwiftUI
import UIKit

/// MOTION-1. The animated Omodachi face for an agent: the whole o is a
/// spherical head, the dark hole and the eyes are a face on it (brand study,
/// `agent-motion`, rounds 4–5). The model is `Agent/AgentFaceModel`; this only
/// paints its cells.
///
/// It costs nothing while it is still. A `TimelineView` exists only while the
/// face is on screen, the scene is active, its code is not a static pose,
/// Reduce Motion and Low Power are off, and `AgentFaceBudget` gave it one of
/// the three animation slots — otherwise one static pose is drawn once and no
/// timer runs (the CPU rule of the spec).
///
/// Colours are the host's: the head is the surface's text colour, the face and
/// the ring are holes (so they are whatever is behind, exactly the study's
/// "groove in the background colour"), the far-side shade is one flat 74 : 26
/// step towards the background, the eyes are the text colour, the accent while
/// waiting (yellow on a theme whose accent is its foreground), red on error.
struct AgentFace: View {
    let state: AgentFaceState
    var tool = false
    let surface: AgentFaceSurface
    let size: CGFloat
    /// The bar paints with `[bar] text` on `[bar] background` (the selected
    /// slot with the menu's selected pair); panels with `[menu] text` on
    /// `[menu] background`.
    var ground: AgentFaceGround = .panel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var id = UUID()
    @State private var clock = AgentFaceClock()
    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var budget: AgentFaceBudget { .shared }
    private var key: String { "\(state.rawValue)|\(tool)|\(surface.rawValue)" }

    /// The code wants motion and nothing on this device says no.
    private var wantsMotion: Bool {
        guard let model = AgentFaceModel.shared,
              let resolved = model.resolve(surface, state, t: 0, reduceMotion: false, size: Double(size), tool: tool)
        else { return false }
        return !resolved.still && !reduceMotion && !lowPower && onScreen && scenePhase == .active
    }

    var body: some View {
        let moving = wantsMotion && budget.granted(id)
        Group {
            if moving, let model = AgentFaceModel.shared {
                TimelineView(AgentFaceSchedule(start: clock.entered, fps: model.tokens.motion.fps,
                                               lowFPS: model.tokens.motion.low_fps,
                                               lowAfter: model.tokens.motion.low_fps_after_ms / 1000)) { context in
                    canvas(at: context.date, still: false)
                }
            } else {
                canvas(at: nil, still: true)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            onScreen = true
            clock.enter(key, at: Date())
            updateClaim()
        }
        .onDisappear {
            onScreen = false
            budget.release(id)
        }
        .onChange(of: key) { _, value in
            clock.enter(value, at: Date())
            updateClaim()
        }
        .onChange(of: reduceMotion) { _, _ in updateClaim() }
        .onChange(of: scenePhase) { _, _ in updateClaim() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            updateClaim()
        }
    }

    private func updateClaim() {
        if wantsMotion { budget.claim(id, priority: AgentFaceBudget.priority(state, tool: tool)) }
        else { budget.release(id) }
    }

    private func canvas(at date: Date?, still: Bool) -> some View {
        let drawing = AgentFaceDrawing.make(state: state, tool: tool, surface: surface, size: size,
                                            clock: clock, date: date, still: still)
        let palette = AgentFacePalette.current(ground)
        let scale = displayScale
        return Canvas { context, canvasSize in
            guard let drawing else {
                // No tokens in the bundle: the static v6 mark, never a crash.
                context.fill(OmodachiSymbol().path(in: CGRect(origin: .zero, size: canvasSize)),
                             with: .color(palette.head), style: FillStyle(eoFill: true))
                return
            }
            AgentFaceDrawing.paint(drawing, in: &context, size: canvasSize, scale: scale, palette: palette)
        }
        .opacity(drawing?.frame.dim == true ? AgentFaceDim.offline : 1)
    }
}

/// When a state was entered and the pose it left, for the per-instance clock
/// (B¹ one-shots, the 10-minute slowdown) and the spring between states.
final class AgentFaceClock {
    private(set) var entered = Date()
    private(set) var key = ""
    /// The pose the previous state was last drawn in, and where the new state
    /// starts: the difference decays with the critically damped spring.
    var lastPose: (yaw: Double, pitch: Double) = (0, 0)
    private(set) var from: (yaw: Double, pitch: Double)?

    func enter(_ newKey: String, at date: Date) {
        guard newKey != key else { return }
        from = key.isEmpty ? nil : lastPose
        key = newKey
        entered = date
    }
}

/// 12 fps for ten minutes in one state, then the tokens' low rate.
struct AgentFaceSchedule: TimelineSchedule {
    let start: Date
    let fps: Double
    let lowFPS: Double
    let lowAfter: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let current = next
            let rate = current.timeIntervalSince(start) >= lowAfter || mode == .lowFrequency ? lowFPS : fps
            next = current.addingTimeInterval(1 / max(1, rate))
            return current
        }
    }
}

/// The offline dim, from the tokens (`states.offline.opacity`).
enum AgentFaceDim {
    static var offline: Double { AgentFaceModel.shared?.tokens.states.offline.opacity ?? 0.45 }
}

/// What a face is drawn on, which decides its ink and its shade step.
enum AgentFaceGround: Sendable { case panel, bar, selected }

/// The theme colours one face paints with.
struct AgentFacePalette {
    let head: Color
    let shade: Color
    let eyes: Color
    let accentEyes: Color
    let errorEyes: Color

    @MainActor static func current(_ surface: AgentFaceGround) -> AgentFacePalette {
        make(OmodachiTheme.current, surface)
    }

    static func make(_ theme: HostTheme, _ surface: AgentFaceGround) -> AgentFacePalette {
        let (ink, ground) = switch surface {
        case .panel: (theme.shellRGBA("menu", "text", fallback: .foreground).rgb,
                      theme.shellRGBA("menu", "background", fallback: .background).rgb)
        case .bar: (theme.shellRGBA("bar", "text", fallback: .foreground).rgb,
                    theme.shellRGBA("bar", "background", fallback: .background).rgb)
        case .selected: (theme.shellRGBA("menu", "selected-text", fallback: .accent).rgb,
                         theme.shellRGBA("menu", "selected-background", fallback: .foreground).rgb)
        }
        let mix = AgentFaceModel.shared?.tokens.shade.mix_with_bg ?? 0.26
        let shade = (ink.0 * (1 - mix) + ground.0 * mix, ink.1 * (1 - mix) + ground.1 * mix,
                     ink.2 * (1 - mix) + ground.2 * mix)
        let yellow = AgentFaceModel.shared.map {
            AgentFaceColours.waitingUsesYellow(accent: theme.rgb(.accent), foreground: theme.rgb(.foreground),
                                               yellow: theme.rgb(.yellow), background: theme.rgb(.background),
                                               tokens: $0.tokens)
        } ?? false
        return AgentFacePalette(head: Color(rgb: ink), shade: Color(rgb: shade), eyes: Color(rgb: ink),
                                accentEyes: theme.color(yellow ? .yellow : .accent), errorEyes: theme.color(.red))
    }
}

/// One frame, resolved and projected, ready to paint.
struct AgentFaceDrawing {
    let frame: AgentFaceFrame
    let render: AgentFaceRender
    let head: [AgentFaceCell]
    let grid: Int
    let shade: Bool

    static func make(state: AgentFaceState, tool: Bool, surface: AgentFaceSurface, size: CGFloat,
                     clock: AgentFaceClock, date: Date?, still: Bool) -> AgentFaceDrawing? {
        guard let model = AgentFaceModel.shared else { return nil }
        let t = date.map { max(0, $0.timeIntervalSince(clock.entered) * 1000) } ?? 0
        // A face that may not move shows its static pose (Reduce Motion's).
        guard var resolved = model.resolve(surface, state, t: t, reduceMotion: still, size: Double(size), tool: tool)
            ?? model.resolve(.header, state, t: 0, reduceMotion: true, size: Double(size), tool: tool)
        else { return nil }
        if !still {
            if model.oneShotOver(surface, state, t: t) { resolved.frame.hy = 0 }
            // The spring from the pose the last state left (rule 8, ~250 ms).
            if let from = clock.from,
               let start = model.resolve(surface, state, t: 0, reduceMotion: false, size: Double(size), tool: tool) {
                let left = model.springRemainder(t / 1000)
                resolved.frame.yaw += (from.yaw - start.frame.yaw) * left
                resolved.frame.pitch += (from.pitch - start.frame.pitch) * left
            }
        }
        clock.lastPose = (resolved.frame.yaw, resolved.frame.pitch)
        let render = model.project(resolved.frame, grid: resolved.grid)
        return AgentFaceDrawing(frame: resolved.frame, render: render, head: model.headCells[resolved.grid] ?? [],
                                grid: resolved.grid, shade: resolved.shade)
    }

    /// Cells are snapped to device pixels, the way the study's SVG is drawn
    /// with `shape-rendering: crispEdges`.
    static func paint(_ d: AgentFaceDrawing, in context: inout GraphicsContext, size: CGSize, scale: CGFloat,
                      palette: AgentFacePalette) {
        let unit = Double(min(size.width, size.height)) / 96
        let cell = Double(d.grid) * unit
        let ox = (4 + d.frame.hx) * unit, oy = (4 + d.frame.hy) * unit
        let s = Double(max(1, scale))
        func snap(_ v: Double) -> Double { (v * s).rounded() / s }
        func rects(_ cells: [AgentFaceCell]) -> Path {
            var path = Path()
            for c in cells {
                let x0 = snap(ox + Double(c.x) * cell), x1 = snap(ox + Double(c.x + 1) * cell)
                let y0 = snap(oy + Double(c.y) * cell), y1 = snap(oy + Double(c.y + 1) * cell)
                path.addRect(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
            return path
        }
        let holes = Set(d.render.face).union(d.render.ring)
        let shaded = d.shade ? Set(d.render.shade).subtracting(holes) : []
        let band = d.head.filter { !holes.contains($0) && !shaded.contains($0) }
        context.fill(rects(band), with: .color(palette.head))
        if !shaded.isEmpty { context.fill(rects(Array(shaded)), with: .color(palette.shade)) }
        let eyeInk: Color = switch d.frame.eyeInk {
        case .foreground: palette.eyes
        case .accent: palette.accentEyes
        case .red: palette.errorEyes
        }
        context.fill(rects(d.render.eyes), with: .color(eyeInk))
    }
}

/// The words for a face's state (A-65: the state is in the label, not only in
/// the picture).
enum AgentFaceWords {
    static func word(_ state: AgentFaceState, tool: Bool = false) -> String {
        switch state {
        case .idle: Strings.agentFaceIdle
        case .thinking: Strings.agentFaceThinking
        case .working: tool ? Strings.agentFaceTool : Strings.agentFaceWorking
        case .waiting: Strings.agentFaceWaiting
        case .done: Strings.agentFaceDone
        case .error: Strings.agentFaceError
        case .stopped: Strings.agentFaceStopped
        case .offline: Strings.agentFaceOffline
        }
    }
}
