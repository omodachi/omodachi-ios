import Foundation
import Observation

// MOTION-1. The animated Omodachi face for agents — the model, with no SwiftUI
// (ARCH-1 §1.4: the pixels are `DesignSystem/AgentFaceView`).
//
// This is a port of the brand study, `omodachi-brand` `agent-motion/study.html`
// at the commit `scripts/check_motion_tokens.py` pins: the whole light o is a
// spherical head of radius 44 whose outline never changes; the dark counter and
// the eyes are a face painted on that sphere. Every cell centre of the 4-unit
// grid is cast onto the sphere, rotated back into the face's rest frame and
// tested against the face there, so foreshortening, the hole sliding to the
// side and the near eye narrowing all fall out of the projection. The eyes are
// projected separately and snapped to whole cells with the study's keep-out
// rules. `OmodachiTests/Golden/agent-face-golden.json` holds frames exported
// from the study itself; `MOTION1Tests` checks this port cell for cell.
//
// Numbers come from `Resources/AgentMotionTokens.json` (the brand's
// tokens.json, verbatim). The few literals below are the study's own (blink
// phases, the B¹ double-hop windows) and are named where they are used.

// MARK: - Tokens

struct AgentMotionTokens: Decodable, Sendable {
    struct Canvas: Decodable, Sendable {
        let size_u: Double, grid_u: Int, fine_grid_u: Int, fine_grid_min_px: Double
    }
    struct Head: Decodable, Sendable { let outline: String, sphere_radius_u: Double, center_u: [Double] }
    struct Face: Decodable, Sendable { let radius_u: Double, exponent: Double }
    struct Eyes: Decodable, Sendable { let center_x_u: Double, center_y_u: Double, width_u: Double, height_u: Double }
    struct Turn: Decodable, Sendable { let full_deg: Double }
    struct Motion: Decodable, Sendable {
        struct Spring: Decodable, Sendable { let omega: Double }
        struct Blink: Decodable, Sendable { let duration_ms: Double, close_fraction: Double, min_open: Double }
        struct Hop: Decodable, Sendable {
            let height_u: Double, duration_ms: Double, loop_min_px: Double
            let working_period_ms: Double, waiting_period_ms: Double
        }
        let fps: Double, spring: Spring, blink: Blink, hop: Hop
        let low_fps_after_ms: Double, low_fps: Double, max_animating_instances: Int
    }
    struct States: Decodable, Sendable {
        struct Idle: Decodable, Sendable { let pose: [Double], loop_ms: Double, glance: [[Double]], blink_every_ms: Double }
        struct Thinking: Decodable, Sendable {
            let loop_ms: Double, yaw: [[Double]], pitch: [[Double]], blink_at_ms: Double, static_pose: [Double]
        }
        struct Working: Decodable, Sendable {
            let loop_ms: Double, yaw: [[Double]], pitch: Double, blink_every_ms: Double, static_pose: [Double]
        }
        struct Waiting: Decodable, Sendable { let loop_ms: Double, pose: [Double], double_blink_gap_ms: Double }
        struct Done: Decodable, Sendable { let loop_ms: Double, nod: [[Double]] }
        struct Error: Decodable, Sendable {
            struct Shake: Decodable, Sendable { let yaw: Double, frames: Double }
            let loop_ms: Double, shake: Shake
        }
        struct Offline: Decodable, Sendable { let pose: [Double], opacity: Double }
        /// INTEGRATE-2: a turn the user interrupted (calm; offline's closed eyes, upright, full opacity).
        struct Stopped: Decodable, Sendable { let pose: [Double], opacity: Double }
        let idle: Idle, thinking: Thinking, working: Working, waiting: Waiting, done: Done, error: Error
        let stopped: Stopped, offline: Offline
    }
    struct Shade: Decodable, Sendable {
        let threshold_dot: Double, mix_with_bg: Double, min_px: Double, cleanup_min_neighbours: Int
    }
    struct Ring: Decodable, Sendable {
        struct Sides: Decodable, Sendable {
            let span_deg: Double, centres_deg: [Double], sweep_deg: Double, step_deg: Double, step_ms: Double
        }
        struct Variants: Decodable, Sendable { let sides: Sides }
        let inner_u: Double, outer_u: Double, min_px: Double, variants: Variants, recommended: String
    }
    struct Colors: Decodable, Sendable {
        struct Waiting: Decodable, Sendable {
            let min_contrast_vs_background: Double, close_threshold_oklab_de: Double
        }
        let waiting_eyes: Waiting
    }
    let version: String
    let canvas: Canvas, head: Head, face: Face, eyes: Eyes, turn: Turn, motion: Motion
    let states: States, priority: [String], shade: Shade, ring: Ring, colors: Colors

    /// The bundled copy. A missing or unreadable file is a build defect that
    /// `MOTION1Tests` and `check_motion_tokens.py` catch; at run time the face
    /// then falls back to the static v6 symbol rather than crashing the app.
    static let bundled: AgentMotionTokens? = {
        guard let url = Bundle.main.url(forResource: "AgentMotionTokens", withExtension: "json")
                ?? Bundle(for: TokenLocator.self).url(forResource: "AgentMotionTokens", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentMotionTokens.self, from: data)
    }()
    private final class TokenLocator {}
}

// MARK: - States and surfaces

/// The eight states the face can show, in the brand's priority order
/// (`tokens.priority`: offline > error > waiting > done > stopped > working > thinking > idle).
/// `stopped` (INTEGRATE-2, Leo) is a turn the user interrupted: calm, never the red error.
enum AgentFaceState: String, CaseIterable, Sendable {
    case idle, thinking, working, waiting, done, error, stopped, offline

    var rank: Int {
        switch self {
        case .offline: 7; case .error: 6; case .waiting: 5; case .done: 4; case .stopped: 3
        case .working: 2; case .thinking: 1; case .idle: 0
        }
    }
}

/// Where a face is drawn. The matrix is the study's `SURFACES` (round 5).
/// HERDR-7: the App no longer draws `pane` or `tiles` (Herdr shows a still
/// `HerdrAgentMarker`); the two stay because they are the brand study's, and
/// the golden frames pinned with its tokens still check them.
enum AgentFaceSurface: String, CaseIterable, Sendable {
    case bar, pane, tiles, header, large, odomo

    /// The study's code per state: `A` turns, `A·` its static pose, `B1` hops
    /// once on entry, `B` hops in a loop (≥64 px), `C` the ring while a tool
    /// runs (≥24 px), `V` the vendor's own mark, `V·` that mark dimmed, `—`
    /// nothing (the surface has no such state).
    func code(_ state: AgentFaceState) -> String {
        switch (self, state) {
        case (.bar, .idle), (.odomo, .idle): "V"
        case (.bar, .offline), (.odomo, .offline): "V·"
        case (.bar, .thinking), (.odomo, .thinking): "A"
        case (.bar, .working), (.odomo, .working): "A+C"
        case (.bar, .waiting), (.odomo, .waiting), (.bar, .done), (.odomo, .done): "A+B1"
        case (.bar, .error), (.odomo, .error), (.bar, .stopped), (.odomo, .stopped): "A·"
        case (.pane, .waiting): "A"
        case (.pane, .thinking), (.pane, .error), (.tiles, .thinking), (.tiles, .error),
             (.pane, .stopped), (.tiles, .stopped): "—"
        case (.pane, _): "A·"
        case (.tiles, .working): "A"
        case (.tiles, .waiting), (.tiles, .done): "A+B1"
        case (.tiles, _): "A·"
        case (.header, .working): "A+C"
        case (.header, .waiting), (.header, .done): "A+B1"
        case (.header, .offline), (.header, .stopped): "A·"
        case (.header, _): "A"
        case (.large, .working): "A+B+C"
        case (.large, .waiting): "A+B"
        case (.large, .done): "A+B1"
        case (.large, .offline), (.large, .stopped): "A·"
        case (.large, _): "A"
        }
    }

    var shadeAllowed: Bool { self == .header || self == .large }
    var fineGridAllowed: Bool { self == .large }
    /// Odomo's bar on an @1x desktop: below 24 px a face does not shift.
    var staticBelow: Double? { self == .odomo ? 24 : nil }
}

// MARK: - A frame

struct AgentFaceEyes: Equatable, Sendable {
    enum Kind: String, Sendable { case open, closed, happy, cross }
    var kind: Kind
    var open: Double = 1
    /// B's head tilt drops one eye a cell: -1 left, +1 right, 0 none.
    var tilt: Int = 0
}

enum AgentFaceInk: String, Sendable { case foreground = "fg", accent, red }

struct AgentFaceRing: Equatable, Sendable {
    /// `[start, span]` in face degrees, 0 = top of the face, clockwise.
    var arcs: [[Double]]
}

/// What one state looks like at one instant: the head offset (B), the pose
/// (A), the eye glyph and colour, the ring (C) and the offline dim.
struct AgentFaceFrame: Equatable, Sendable {
    var hx: Double = 0, hy: Double = 0
    var yaw: Double = 0, pitch: Double = 0, roll: Double = 0
    var eyes = AgentFaceEyes(kind: .open)
    var eyeInk: AgentFaceInk = .foreground
    var dim = false
    var ring: AgentFaceRing?
}

struct AgentFaceCell: Hashable, Sendable {
    let x: Int, y: Int
}

/// The rendered cells of one frame, in grid coordinates (0..<88/g).
struct AgentFaceRender: Equatable, Sendable {
    var face: [AgentFaceCell]
    var eyes: [AgentFaceCell]
    var shade: [AgentFaceCell]
    var ring: [AgentFaceCell]
}

/// What a surface resolves for one state at one time: the frame, whether the
/// shade step is drawn, the grid, and whether this code is static at all.
struct AgentFaceResolved: Equatable, Sendable {
    var frame: AgentFaceFrame
    var shade: Bool
    var grid: Int
    /// No timer is needed: the code is a static pose (or Reduce Motion is on).
    var still: Bool
}

// MARK: - The model

struct AgentFaceModel: Sendable {
    let tokens: AgentMotionTokens
    let headCells: [Int: [AgentFaceCell]]

    init(tokens: AgentMotionTokens) {
        self.tokens = tokens
        let outline = Self.polygon(tokens.head.outline)
        var cells: [Int: [AgentFaceCell]] = [:]
        for g in [tokens.canvas.grid_u, tokens.canvas.fine_grid_u] {
            let n = 88 / g
            var row: [AgentFaceCell] = []
            for gy in 0..<n { for gx in 0..<n where Self.inside(outline, Double(gx * g) + Double(g) / 2, Double(gy * g) + Double(g) / 2) {
                row.append(AgentFaceCell(x: gx, y: gy))
            } }
            cells[g] = row
        }
        headCells = cells
    }

    static let shared: AgentFaceModel? = AgentMotionTokens.bundled.map(AgentFaceModel.init(tokens:))

    var frameMS: Double { 1000 / tokens.motion.fps }
    private var turn: Double { tokens.turn.full_deg }
    private var radius: Double { tokens.head.sphere_radius_u }

    // MARK: Geometry (study: polys / inside / toFace / rotFwd / eyeFrames)

    static func polygon(_ d: String) -> [(Double, Double)] {
        var tokens: [String] = []
        var number = ""
        for ch in d {
            if "MHVZ".contains(ch) {
                if !number.isEmpty { tokens.append(number); number = "" }
                tokens.append(String(ch))
            } else if ch == " " || ch == "," {
                if !number.isEmpty { tokens.append(number); number = "" }
            } else { number.append(ch) }
        }
        if !number.isEmpty { tokens.append(number) }
        var out: [(Double, Double)] = []
        var x = 0.0, y = 0.0, i = 0
        while i < tokens.count {
            switch tokens[i] {
            case "M": x = Double(tokens[i + 1]) ?? 0; y = Double(tokens[i + 2]) ?? 0; out = [(x, y)]; i += 2
            case "H": x = Double(tokens[i + 1]) ?? 0; out.append((x, y)); i += 1
            case "V": y = Double(tokens[i + 1]) ?? 0; out.append((x, y)); i += 1
            default: break
            }
            i += 1
        }
        return out
    }

    static func inside(_ p: [(Double, Double)], _ px: Double, _ py: Double) -> Bool {
        var r = false
        var j = p.count - 1
        for i in 0..<p.count {
            let (xi, yi) = p[i], (xj, yj) = p[j]
            if (yi > py) != (yj > py), px < (xj - xi) * (py - yi) / (yj - yi) + xi { r.toggle() }
            j = i
        }
        return r
    }

    private static func rad(_ d: Double) -> Double { d * Double.pi / 180 }

    /// JavaScript's `Math.round`: halves go up, also for negatives.
    static func jsRound(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }
    private static func jsSign(_ v: Int) -> Int { v > 0 ? 1 : v < 0 ? -1 : 0 }
    /// JavaScript's `%` on numbers: the sign of the dividend.
    private static func mod(_ a: Double, _ b: Double) -> Double { a.truncatingRemainder(dividingBy: b) }

    func toFace(_ px: Double, _ py: Double, _ f: AgentFaceFrame) -> (Double, Double)? {
        let R = radius
        let X = (px - 44) / R, Y = (py - 44) / R, r2 = X * X + Y * Y
        if r2 >= 1 { return nil }
        let Z = (1 - r2).squareRoot()
        let cy = cos(Self.rad(f.yaw)), sy = sin(Self.rad(f.yaw)), cp = cos(Self.rad(f.pitch)), sp = sin(Self.rad(f.pitch))
        let x = X * cy - Z * sy, z1 = X * sy + Z * cy
        let y = Y * cp - z1 * sp, z = Y * sp + z1 * cp
        if z <= 0 { return nil }
        let cr = cos(Self.rad(f.roll)), sr = sin(Self.rad(f.roll))
        return ((x * cr + y * sr) * R, (-x * sr + y * cr) * R)
    }

    static func rotFwd(_ x0: Double, _ y0: Double, _ z0: Double, yaw: Double, pitch: Double, roll: Double) -> (Double, Double, Double) {
        var x = x0, y = y0, z = z0
        let cr = cos(rad(roll)), sr = sin(rad(roll))
        (x, y) = (x * cr - y * sr, x * sr + y * cr)
        let cp = cos(rad(pitch)), sp = sin(rad(pitch))
        (y, z) = (y * cp + z * sp, -y * sp + z * cp)
        let cy = cos(rad(yaw)), sy = sin(rad(yaw))
        (x, z) = (x * cy + z * sy, -x * sy + z * cy)
        return (x, y, z)
    }

    private struct EyeFrame { let s: Int, cx: Double, cy: Double, sx: Double, sy: Double }

    private func eyeFrames(_ f: AgentFaceFrame) -> [EyeFrame?] {
        let R = radius, E = tokens.eyes
        return [-1, 1].map { s -> EyeFrame? in
            let u = (Double(s) * E.center_x_u) / R, v = E.center_y_u / R
            let z0 = max(0, 1 - u * u - v * v).squareRoot()
            let (x, y, z) = Self.rotFwd(u, v, z0, yaw: f.yaw, pitch: f.pitch, roll: f.roll)
            if z <= 0.05 { return nil }
            let lon0 = atan2(u, z0), lat0 = asin(v), lon = atan2(x, z), lat = asin(max(-1, min(1, y)))
            let sx = max(0.5, cos(lon) / cos(lon0)), sy = max(0.5, cos(lat) / cos(lat0))
            return EyeFrame(s: s, cx: 44 + x * R, cy: 44 + y * R, sx: sx, sy: sy)
        }
    }

    private static let around = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]

    // MARK: Projection (study: project)

    func project(_ f: AgentFaceFrame, grid g: Int) -> AgentFaceRender {
        let head = headCells[g] ?? []
        let fg = Double(g)
        var face: [AgentFaceCell] = []
        var F = Set<AgentFaceCell>()
        let n = tokens.face.exponent, fr = tokens.face.radius_u
        for c in head {
            if let q = toFace(Double(c.x) * fg + fg / 2, Double(c.y) * fg + fg / 2, f),
               pow(abs(q.0 / fr), n) + pow(abs(q.1 / fr), n) <= 1 {
                face.append(c); F.insert(c)
            }
        }
        // The far-side shade step: band cells more than ~90° from the face.
        let fd = Self.rotFwd(0, 0, 1, yaw: f.yaw, pitch: f.pitch, roll: f.roll)
        var shade: [AgentFaceCell] = []
        for c in head where !F.contains(c) {
            let X = (Double(c.x) * fg + fg / 2 - 44) / radius, Y = (Double(c.y) * fg + fg / 2 - 44) / radius
            let r2 = X * X + Y * Y
            let P: (Double, Double, Double)
            if r2 < 1 { P = (X, Y, (1 - r2).squareRoot()) } else { let l = r2.squareRoot(); P = (X / l, Y / l, 0) }
            if P.0 * fd.0 + P.1 * fd.1 + P.2 * fd.2 < tokens.shade.threshold_dot { shade.append(c) }
        }
        let shaded = Set(shade)
        shade = shade.filter { c in
            Self.around.filter { shaded.contains(AgentFaceCell(x: c.x + $0.0, y: c.y + $0.1)) }.count
                >= tokens.shade.cleanup_min_neighbours
        }
        // The face ring (C): an annulus in the face's own coordinates.
        var ring: [AgentFaceCell] = []
        if let spec = f.ring {
            let rin = tokens.ring.inner_u, rout = tokens.ring.outer_u
            for c in head where !F.contains(c) {
                if Self.around.contains(where: { F.contains(AgentFaceCell(x: c.x + $0.0, y: c.y + $0.1)) }) { continue }
                guard let q = toFace(Double(c.x) * fg + fg / 2, Double(c.y) * fg + fg / 2, f) else { continue }
                let rho = pow(pow(abs(q.0), n) + pow(abs(q.1), n), 1 / n)
                if rho < rin || rho >= rout { continue }
                let a = Self.mod(atan2(q.0, -q.1) * 180 / Double.pi + 360, 360)
                if spec.arcs.contains(where: { Self.mod(Self.mod(a - $0[0], 360) + 360, 360) < $0[1] }) { ring.append(c) }
            }
        }
        let eyes = placeEyes(f, grid: g, F: F, face: face)
        return AgentFaceRender(face: face, eyes: eyes, shade: shade, ring: ring)
    }

    private struct Box { var s: Int, x0: Int, y0: Int, wC: Int, hC: Int, sx: Double, tilt: Int }

    private func cells(of b: Box, _ dx: Int, _ dy: Int, eyes e: AgentFaceEyes, k: Int) -> [AgentFaceCell] {
        var out: [AgentFaceCell] = []
        let X = b.x0 + dx, Y = b.y0 + dy + b.tilt
        func put(_ x: Int, _ y: Int) {
            for j in 0..<k { for i in 0..<k { out.append(AgentFaceCell(x: X + x * k + i, y: Y + y * k + j)) } }
        }
        let kd = Double(k)
        switch e.kind {
        case .open:
            let h = max(1, Self.jsRound(Double(b.hC) * e.open))
            for j in (b.hC - h)..<b.hC { for i in 0..<b.wC { out.append(AgentFaceCell(x: X + i, y: Y + j)) } }
        case .closed:
            for i in 0..<b.wC { out.append(AgentFaceCell(x: X + i, y: Y + b.hC - 1)) }
        case .happy:
            let cx = Self.jsRound((Double(b.wC) / kd - 3) / 2 + Double(b.s) * 0.5)
            for (x, y) in [(0, 1), (1, 0), (2, 1)] { put(cx + x, y) }
        case .cross:
            let narrow = b.sx < 0.9
            let cx = narrow ? Self.jsRound((Double(b.wC) / kd - 2) / 2)
                            : Self.jsRound((Double(b.wC) / kd - 3) / 2 + Double(b.s) * 0.5)
            let pattern: [(Int, Int)] = !narrow ? [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)]
                : b.s > 0 ? [(0, 0), (1, 1), (0, 2)] : [(1, 0), (0, 1), (1, 2)]
            let top = Self.jsRound(Double(b.hC) / kd) - 3
            for (x, y) in pattern { put(cx + x, top + y) }
        }
        return out
    }

    private func placeEyes(_ f: AgentFaceFrame, grid g: Int, F: Set<AgentFaceCell>, face: [AgentFaceCell]) -> [AgentFaceCell] {
        let e = f.eyes, k = 4 / g, fg = Double(g), E = tokens.eyes
        func ok(_ c: AgentFaceCell) -> Bool {
            F.contains(c) && Self.around.allSatisfy { F.contains(AgentFaceCell(x: c.x + $0.0, y: c.y + $0.1)) }
        }
        let boxes: [Box] = eyeFrames(f).compactMap { fr in
            guard let fr else { return nil }
            let wC = max(1, Self.jsRound(E.width_u * fr.sx / fg)), hC = max(1, Self.jsRound(E.height_u * fr.sy / fg))
            let x0 = Self.jsRound((fr.cx - Double(wC) * fg / 2) / fg), y0 = Self.jsRound((fr.cy - Double(hC) * fg / 2) / fg)
            return Box(s: fr.s, x0: x0, y0: y0, wC: wC, hC: hC, sx: fr.sx, tilt: e.tilt == fr.s ? k : 0)
        }
        guard !face.isEmpty else { return [] }
        let fx = Double(face.reduce(0) { $0 + $1.x }) / Double(face.count)
        let fy = Double(face.reduce(0) { $0 + $1.y }) / Double(face.count)
        var eyes: [AgentFaceCell] = [], placed: [AgentFaceCell] = []
        func touches(_ c: [AgentFaceCell]) -> Int {
            c.filter { q in placed.contains { abs($0.x - q.x) <= 1 && abs($0.y - q.y) <= 1 } }.count
        }
        // Far (less foreshortened) eye first; a stable sort of two.
        var ordered = boxes
        if ordered.count == 2, ordered[1].sx > ordered[0].sx { ordered.swapAt(0, 1) }
        for b in ordered {
            let cx = Double(b.x0) + Double(b.wC) / 2, cy = Double(b.y0) + Double(b.hC) / 2
            let sx = Self.jsSign(Self.jsRound(fx - cx)), sy = Self.jsSign(Self.jsRound(fy - cy))
            let shifts: [(Int, Int)] = abs(f.yaw) >= abs(f.pitch)
                ? [(sx, 0), (0, sy), (sx, sy), (2 * sx, 0), (0, 2 * sy)]
                : [(0, sy), (sx, 0), (sx, sy), (0, 2 * sy), (2 * sx, 0)]
            var trims: [Box] = []
            if e.kind == .open {
                var outer = b, inner = b, top = b, bottom = b
                if b.s < 0 { outer.x0 = b.x0 + 1; outer.wC = b.wC - 1; inner.wC = b.wC - 1 }
                else { outer.wC = b.wC - 1; inner.x0 = b.x0 + 1; inner.wC = b.wC - 1 }
                top.y0 = b.y0 + 1; top.hC = b.hC - 1
                bottom.hC = b.hC - 1
                for t in [outer, top, bottom, inner] where t.wC >= 1 && t.hC >= 1 && t.wC * t.hC >= 2 { trims.append(t) }
            }
            var tries: [(Box, Int, Int)] = [(b, 0, 0)]
            tries += trims.map { ($0, 0, 0) }
            tries += shifts.map { (b, $0.0, $0.1) }
            for t in trims { tries += shifts.map { (t, $0.0, $0.1) } }
            var best: (c: [AgentFaceCell], bad: Int)?
            for (bb, dx, dy) in tries {
                let c = cells(of: bb, dx, dy, eyes: e, k: k)
                let bad = c.filter { !ok($0) }.count + touches(c)
                if best == nil || bad < best!.bad { best = (c, bad) }
                if bad == 0 { break }
            }
            let keep = (best?.c ?? []).filter { ok($0) && touches([$0]) == 0 }
            eyes += keep
            placed += keep
        }
        return eyes
    }

    // MARK: Motion (study: g1 / track / BL / dbl / win / shakeYaw / DIRS)

    private func g1(_ tau: Double) -> Double {
        let w = tokens.motion.spring.omega
        return tau <= 0 ? 0 : 1 - (1 + w * tau) * exp(-w * tau)
    }

    /// The critically damped step from `delta` away to the target: what is
    /// left of it `tau` seconds later (closed form, stateless).
    func springRemainder(_ tau: Double) -> Double { 1 - g1(tau) }

    func track(_ t: Double, _ loop: Double, _ segs: [[Double]], smooth: Bool = true) -> Double {
        let l = Self.mod(Self.mod(t, loop) + loop, loop)
        if !smooth {
            var v = segs[0][1]
            for s in segs where l >= s[0] { v = s[1] }
            return v
        }
        var v = segs[segs.count - 1][1]
        for k in 0..<segs.count {
            let prev = k > 0 ? segs[k - 1][1] : segs[segs.count - 1][1]
            v += (segs[k][1] - prev) * g1((l - segs[k][0]) / 1000)
        }
        return v
    }

    func blink(_ t: Double, _ period: Double, _ phase: Double = 0) -> Double {
        let B = tokens.motion.blink
        let l = Self.mod(Self.mod(t + phase, period) + period, period)
        if l >= B.duration_ms { return 1 }
        let p = l / B.duration_ms
        return max(B.min_open, p < B.close_fraction ? 1 - p / B.close_fraction : (p - B.close_fraction) / (1 - B.close_fraction))
    }

    private func window(_ t: Double, _ period: Double, _ a: Double, _ b: Double) -> Bool {
        let l = Self.mod(t, period)
        return l >= a && l < b
    }

    private func scaled(_ segs: [[Double]], by s: Double) -> [[Double]] { segs.map { [$0[0], $0[1] * s] } }

    /// Layer A: where the face looks and what the eyes are, per state.
    func faceA(_ state: AgentFaceState, _ t: Double, still rm: Bool) -> AgentFaceFrame {
        var f = AgentFaceFrame()
        let T = turn, S = tokens.states
        switch state {
        case .idle:
            if rm { break }
            // Study: blink phase −3000 ms, the glance starts from the rest pose.
            f.eyes = AgentFaceEyes(kind: .open, open: blink(t, S.idle.blink_every_ms, -3000))
            f.yaw = track(t, S.idle.loop_ms, [[0, S.idle.pose[0] * T]] + scaled(S.idle.glance, by: T))
        case .thinking:
            f.pitch = track(t, S.thinking.loop_ms, scaled(S.thinking.pitch, by: T))
            if rm { f.yaw = S.thinking.static_pose[0] * T; f.pitch = S.thinking.static_pose[1] * T; break }
            f.yaw = track(t, S.thinking.loop_ms, scaled(S.thinking.yaw, by: T))
            f.eyes = AgentFaceEyes(kind: .open, open: blink(t, S.thinking.loop_ms, -S.thinking.blink_at_ms))
        case .working:
            f.pitch = S.working.pitch * T
            if rm { break }
            f.yaw = track(t, S.working.loop_ms, scaled(S.working.yaw, by: T))
            f.pitch = S.working.pitch * T * (1 - 0.25 * abs(f.yaw) / T)
            // Study: blink phase −1800 ms (half the period).
            f.eyes = AgentFaceEyes(kind: .open, open: blink(t, S.working.blink_every_ms, -S.working.blink_every_ms / 2))
        case .waiting:
            f.pitch = S.waiting.pose[1] * T
            f.eyeInk = .accent
            if !rm {
                f.eyes = AgentFaceEyes(kind: .open, open: min(blink(t, S.waiting.loop_ms),
                                                              blink(t, S.waiting.loop_ms, -S.waiting.double_blink_gap_ms)))
            }
        case .done:
            f.eyes = AgentFaceEyes(kind: .happy)
            if !rm { f.pitch = track(t, S.done.loop_ms, scaled(S.done.nod, by: T)) }
        case .error:
            f.eyes = AgentFaceEyes(kind: .cross)
            f.eyeInk = .red
            if !rm {
                let length = S.error.shake.frames * frameMS
                if window(t, S.error.loop_ms, 0, length) {
                    let odd = Int((Self.mod(t, S.error.loop_ms) / frameMS).rounded(.down)) % 2 == 1
                    f.yaw = (odd ? 1 : -1) * S.error.shake.yaw * T
                }
            }
        case .stopped:
            // INTEGRATE-2: offline's eye bars, upright, foreground ink, full
            // opacity; static on every surface (the matrix gives it A·).
            f.pitch = S.stopped.pose[1] * T
            f.eyes = AgentFaceEyes(kind: .closed)
        case .offline:
            f.pitch = S.offline.pose[1] * T
            f.eyes = AgentFaceEyes(kind: .closed)
            f.dim = true
        }
        return f
    }

    func loop(_ state: AgentFaceState) -> Double {
        let S = tokens.states
        switch state {
        case .idle: return S.idle.loop_ms
        case .thinking: return S.thinking.loop_ms
        case .working: return S.working.loop_ms
        case .waiting: return S.waiting.loop_ms
        case .done: return S.done.loop_ms
        case .error: return S.error.loop_ms
        case .stopped: return S.error.loop_ms // the study's LOOP.stopped (3000), never animated
        case .offline: return S.error.loop_ms // the study's LOOP.offline (3000), never animated
        }
    }

    /// The B¹ double hop on entering waiting: up for the first two frames of
    /// each 167 ms half (study: `l<167 || (l>=333 && l<500)`).
    private func doubleHop(_ l: Double) -> Bool { l < 167 || (l >= 333 && l < 500) }

    func ringSides(_ t: Double, still: Bool) -> AgentFaceRing {
        let o = tokens.ring.variants.sides
        let n = Double(Self.jsRound(2 * o.sweep_deg / o.step_deg) + 1)
        let off = still ? 0 : -o.sweep_deg + Self.mod((t / o.step_ms).rounded(.down), n) * o.step_deg
        return AgentFaceRing(arcs: o.centres_deg.map { [$0 + off - o.span_deg / 2, o.span_deg] })
    }

    /// The study's system resolver: one surface, one state, one size (in
    /// points, the study's px) → the frame and how to draw it. `tool` is C's
    /// condition: a tool or command is running.
    func resolve(_ surface: AgentFaceSurface, _ state: AgentFaceState, t: Double, reduceMotion rm: Bool,
                 size: Double, tool: Bool = true) -> AgentFaceResolved? {
        let code = surface.code(state)
        if code == "—" || code.hasPrefix("V") { return nil }
        let still = rm || code.contains("·") || (surface.staticBelow.map { size < $0 } ?? false)
        var f = faceA(state, t, still: still)
        let hop = tokens.motion.hop
        if !still, code.contains("B") {
            if code.contains("B1") {
                if state == .done { f.hy = window(t, loop(.done), 0, hop.duration_ms) ? -hop.height_u : 0 }
                if state == .waiting { f.hy = doubleHop(Self.mod(t, loop(.waiting))) ? -hop.height_u : 0 }
            } else if size >= hop.loop_min_px {
                if state == .working { f.hy = Self.mod(t, hop.working_period_ms) < hop.duration_ms ? -hop.height_u : 0 }
                if state == .waiting { f.hy = doubleHop(Self.mod(t, hop.waiting_period_ms)) ? -hop.height_u : 0 }
            }
        }
        if code.contains("C"), state == .working, tool, size >= tokens.ring.min_px {
            f.ring = ringSides(t, still: still)
        }
        let shade = surface.shadeAllowed && size >= tokens.shade.min_px
        let grid = surface.fineGridAllowed && size >= tokens.canvas.fine_grid_min_px
            ? tokens.canvas.fine_grid_u : tokens.canvas.grid_u
        return AgentFaceResolved(frame: f, shade: shade, grid: grid, still: still)
    }

    /// B¹ is a one-shot: after the first loop of done / waiting the head
    /// stays down (the study previews it on every loop).
    func oneShotOver(_ surface: AgentFaceSurface, _ state: AgentFaceState, t: Double) -> Bool {
        surface.code(state).contains("B1") && t >= loop(state)
    }
}

// MARK: - Which state, from what the host says

/// MOTION-1's state mapping. Core already has the signals; this reads them.
enum AgentFaceMapping {
    /// The default agent, from `state.agent` (`agent.changed`).
    ///
    /// * offline: the host is not connected, or the provider connection is gone
    /// * waiting: an approval or a question is pending (`chat.status.waiting`,
    ///   `status` `waiting_on_*`, or pending approvals)
    /// * done / error / stopped: the last turn's outcome (stopped = the user
    ///   interrupted it, INTEGRATE-2); on the bar only while that turn
    ///   has not been seen (the Agent panel was not open since)
    /// * working: a message streams, or a tool runs (`tool` = the ring)
    /// * thinking: the turn started and nothing came yet, or it is reasoning
    static func agent(connected: Bool, activity: AgentActivity?, statusText: String?,
                      seenTurn: String?, unseenOnly: Bool) -> (state: AgentFaceState, tool: Bool) {
        guard connected else { return (.offline, false) }
        let phase = activity?.phase ?? "idle"
        if phase == "offline" { return (.offline, false) }
        let unseen = !unseenOnly || activity?.turnID == nil || activity?.turnID != seenTurn
        if phase == "error", unseen { return (.error, false) }
        let waiting = activity?.waiting != nil || (activity?.pendingApprovals ?? 0) > 0
            || statusText == "waiting_on_approval" || statusText == "waiting_on_user_input" // non-copy: wire values
        if waiting { return (.waiting, false) }
        if phase == "done", unseen { return (.done, false) }
        if phase == "stopped", unseen { return (.stopped, false) }
        if phase == "working" { return (.working, false) }
        if phase == "tool" { return (.working, true) }
        if phase == "thinking" { return (.thinking, false) }
        return (.idle, false)
    }

    /// A Herdr pane's agent: Herdr has idle / working / blocked / done and no
    /// thinking or tool distinction.
    static func herdr(_ status: String?) -> AgentFaceState {
        switch status {
        case "working": .working
        case "blocked": .waiting
        case "done": .done
        default: .idle
        }
    }
}

/// `state.agent.chat` as this app reads it (MOTION-1 `activity` + the waiting
/// bits that were already there).
struct AgentActivity: Equatable, Sendable {
    var phase: String
    var turnID: String?
    var waiting: String?
    var pendingApprovals: Int
}

// MARK: - Colour rule for the waiting eyes

/// Round 5 (b): waiting eyes are the accent, except where the accent is the
/// foreground to the eye (OKLab ΔE < 0.05, e.g. kanagawa) and the theme's
/// yellow reaches 3:1 on the background — then yellow.
enum AgentFaceColours {
    typealias RGB = (Double, Double, Double)

    static func luminance(_ c: RGB) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.0) + 0.7152 * ch(c.1) + 0.0722 * ch(c.2)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func oklab(_ c: RGB) -> RGB {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.0), g = lin(c.1), b = lin(c.2)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
    }

    static func deltaE(_ a: RGB, _ b: RGB) -> Double {
        let x = oklab(a), y = oklab(b)
        return ((x.0 - y.0) * (x.0 - y.0) + (x.1 - y.1) * (x.1 - y.1) + (x.2 - y.2) * (x.2 - y.2)).squareRoot()
    }

    /// True when the waiting eyes should be the theme's yellow.
    static func waitingUsesYellow(accent: RGB, foreground: RGB, yellow: RGB, background: RGB,
                                  tokens: AgentMotionTokens) -> Bool {
        let rule = tokens.colors.waiting_eyes
        return deltaE(accent, foreground) < rule.close_threshold_oklab_de
            && contrast(yellow, background) >= rule.min_contrast_vs_background
    }
}

// MARK: - The on-screen budget

/// Round 5 rule 7: at most `max_animating_instances` faces animate at once;
/// waiting keeps its slot first, then working with the ring, then the rest.
/// Faces register while they are on screen and want to move; the ones over the
/// budget fall back to their static pose (no timer).
@MainActor @Observable final class AgentFaceBudget {
    static let shared = AgentFaceBudget()

    struct Claim: Equatable { let priority: Int; let order: Int }
    private(set) var claims: [UUID: Claim] = [:]
    @ObservationIgnored private var counter = 0
    var limit: Int = AgentFaceModel.shared?.tokens.motion.max_animating_instances ?? 3

    static func priority(_ state: AgentFaceState, tool: Bool) -> Int {
        state == .waiting ? 3 : (state == .working && tool) ? 2 : 1
    }

    func claim(_ id: UUID, priority: Int) {
        if claims[id]?.priority == priority { return }
        counter += 1
        claims[id] = Claim(priority: priority, order: claims[id]?.order ?? counter)
    }

    func release(_ id: UUID) {
        if claims[id] != nil { claims[id] = nil }
    }

    func granted(_ id: UUID) -> Bool {
        guard claims[id] != nil else { return false }
        return claims.sorted {
            $0.value.priority != $1.value.priority ? $0.value.priority > $1.value.priority : $0.value.order < $1.value.order
        }.prefix(limit).contains { $0.key == id }
    }

    var animatingCount: Int { min(limit, claims.count) }
}
