import XCTest
@testable import Omodachi

/// MOTION-1. The animated agent face: the port is checked cell for cell
/// against golden frames exported from the brand study itself
/// (`Golden/agent-face-golden.json`, written by omodachi-core
/// `odomo/scripts/agent-face-golden.mjs` from `agent-motion/study.html` at the
/// pinned brand commit), and the state mapping against core's fixtures.
final class MOTION1Tests: XCTestCase {
    private struct Golden: Decodable {
        struct Frame: Decodable {
            struct Eyes: Decodable { let kind: String; let open: Double?; let tilt: Int? }
            struct Ring: Decodable { let arcs: [[Double]]? }
            let hx: Double, hy: Double, yaw: Double, pitch: Double, roll: Double
            let dim: Bool
            let eyeC: String
            let eyes: Eyes
            let ring: Ring?
        }
        struct Case: Decodable {
            let kind: String, id: String
            let surface: String?, state: String?, size: Double?, t: Double?, rm: Bool?, code: String?
            let g: Int?, shade: Bool?
            let frame: Frame?
            let grid: [String]?
        }
        let brand_commit: String
        let cases: [Case]
    }

    private func golden() throws -> Golden {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "agent-face-golden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    private func model() throws -> AgentFaceModel { try XCTUnwrap(AgentFaceModel.shared, "tokens did not load") }

    /// The study's composite: head, shade, track, ring, eyes.
    private func grid(_ model: AgentFaceModel, _ r: AgentFaceRender, g: Int, shade: Bool) -> [String] {
        let n = 88 / g
        var rows = Array(repeating: Array(repeating: Character("."), count: n), count: n)
        for c in model.headCells[g] ?? [] { rows[c.y][c.x] = "H" }
        for c in r.face { rows[c.y][c.x] = "o" }
        if shade { for c in r.shade { rows[c.y][c.x] = "S" } }
        for c in r.ring { rows[c.y][c.x] = "R" }
        for c in r.eyes where c.y >= 0 && c.y < n && c.x >= 0 && c.x < n { rows[c.y][c.x] = "E" }
        return rows.map { String($0) }
    }

    func testTokensAreTheBrandFileAndDecode() throws {
        let model = try model()
        XCTAssertEqual(model.tokens.turn.full_deg, 38)
        XCTAssertEqual(model.tokens.head.sphere_radius_u, 44)
        XCTAssertEqual(model.tokens.motion.fps, 12)
        XCTAssertEqual(model.tokens.ring.recommended, "sides")
        XCTAssertEqual(model.headCells[4]?.count, 436, "v6 outline at the 4-unit grid")
        let golden = try golden()
        XCTAssertEqual(golden.brand_commit, "8318df51dc07d32c371bcca078cea5c9438ef6ed")
    }

    func testRestPoseIsTheV6CounterCellForCell() throws {
        let model = try model()
        let r = model.project(AgentFaceFrame(), grid: 4)
        let widths = [6, 8, 10, 10, 10, 10, 10, 10, 8, 6], starts = [8, 7, 6, 6, 6, 6, 6, 6, 7, 8]
        var v6 = Set<AgentFaceCell>()
        for (i, y) in (6...15).enumerated() { for k in 0..<widths[i] { v6.insert(AgentFaceCell(x: starts[i] + k, y: y)) } }
        XCTAssertEqual(Set(r.face), v6)
        XCTAssertEqual(r.eyes.count, 12, "two 2×3-cell eyes")
        XCTAssertTrue(r.shade.isEmpty, "no shade at rest")
    }

    func testEveryPoseMatchesTheStudy() throws {
        let model = try model()
        var compared = 0
        for c in try golden().cases where c.kind == "pose" {
            let f = try XCTUnwrap(c.frame), g = try XCTUnwrap(c.g)
            var frame = AgentFaceFrame()
            frame.yaw = f.yaw; frame.pitch = f.pitch; frame.roll = f.roll
            frame.eyes = AgentFaceEyes(kind: .open, open: f.eyes.open ?? 1, tilt: f.eyes.tilt ?? 0)
            let r = model.project(frame, grid: g)
            XCTAssertEqual(grid(model, r, g: g, shade: true), c.grid, c.id)
            compared += 1
        }
        XCTAssertEqual(compared, 24)
    }

    func testEverySurfaceStateAndTimeMatchesTheStudy() throws {
        let model = try model()
        var compared = 0, vendor = 0
        for c in try golden().cases where c.kind == "surface" {
            let surface = try XCTUnwrap(AgentFaceSurface(rawValue: c.surface ?? ""))
            let state = try XCTUnwrap(AgentFaceState(rawValue: c.state ?? ""))
            XCTAssertEqual(surface.code(state), c.code, c.id)
            let resolved = model.resolve(surface, state, t: c.t ?? 0, reduceMotion: c.rm ?? false, size: c.size ?? 0)
            guard let expected = c.grid, let f = c.frame else {
                XCTAssertNil(resolved, c.id); vendor += 1; continue
            }
            let got = try XCTUnwrap(resolved, c.id)
            XCTAssertEqual(got.frame.hx, f.hx, c.id); XCTAssertEqual(got.frame.hy, f.hy, c.id)
            XCTAssertEqual(got.frame.yaw, f.yaw, accuracy: 1e-9, c.id)
            XCTAssertEqual(got.frame.pitch, f.pitch, accuracy: 1e-9, c.id)
            XCTAssertEqual(got.frame.roll, f.roll, accuracy: 1e-9, c.id)
            XCTAssertEqual(got.frame.dim, f.dim, c.id)
            XCTAssertEqual(got.frame.eyeInk.rawValue, f.eyeC, c.id)
            XCTAssertEqual(got.frame.eyes.kind.rawValue, f.eyes.kind, c.id)
            XCTAssertEqual(got.frame.eyes.open, f.eyes.open ?? 1, accuracy: 1e-9, c.id)
            XCTAssertEqual(got.frame.ring?.arcs, f.ring?.arcs, c.id)
            XCTAssertEqual(got.shade, c.shade, c.id)
            XCTAssertEqual(got.grid, c.g, c.id)
            let r = model.project(got.frame, grid: got.grid)
            XCTAssertEqual(grid(model, r, g: got.grid, shade: got.shade), expected, c.id)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 300)
        XCTAssertGreaterThan(vendor, 0)
    }

    func testStillCodesNeedNoTimer() throws {
        let model = try model()
        // Static poses (A·), Reduce Motion, and Odomo's @1x bar below 24.
        XCTAssertEqual(model.resolve(.pane, .working, t: 0, reduceMotion: false, size: 24)?.still, true)
        XCTAssertEqual(model.resolve(.pane, .waiting, t: 0, reduceMotion: false, size: 24)?.still, false)
        XCTAssertEqual(model.resolve(.bar, .thinking, t: 0, reduceMotion: true, size: 24)?.still, true)
        XCTAssertEqual(model.resolve(.bar, .error, t: 0, reduceMotion: false, size: 24)?.still, true)
        XCTAssertNil(model.resolve(.bar, .idle, t: 0, reduceMotion: false, size: 24), "idle on the bar is the vendor's mark")
        // The ring only while a tool runs, frozen under Reduce Motion.
        XCTAssertNil(model.resolve(.bar, .working, t: 0, reduceMotion: false, size: 24, tool: false)?.frame.ring)
        let frozen = model.resolve(.header, .working, t: 900, reduceMotion: true, size: 32)?.frame.ring
        XCTAssertEqual(frozen?.arcs, [[70, 40], [250, 40]])
        // B¹ is a one-shot.
        XCTAssertFalse(model.oneShotOver(.bar, .done, t: 100))
        XCTAssertTrue(model.oneShotOver(.bar, .done, t: 3000))
        XCTAssertFalse(model.oneShotOver(.large, .waiting, t: 9000), "the large art's B loops")
    }

    func testSpringSettlesInAboutAQuarterSecond() throws {
        let model = try model()
        XCTAssertEqual(model.springRemainder(0), 1)
        XCTAssertLessThan(model.springRemainder(0.25), 0.1)
        XCTAssertLessThan(model.springRemainder(0.5), 0.01)
    }

    // MARK: State mapping

    private func activity(_ phase: String, turn: String? = "t1", waiting: String? = nil, pending: Int = 0) -> AgentActivity {
        AgentActivity(phase: phase, turnID: turn, waiting: waiting, pendingApprovals: pending)
    }

    func testTheDefaultAgentMapping() {
        func map(_ a: AgentActivity?, connected: Bool = true, status: String? = nil, seen: String? = nil,
                 bar: Bool = false) -> AgentFaceState {
            AgentFaceMapping.agent(connected: connected, activity: a, statusText: status, seenTurn: seen,
                                   unseenOnly: bar).state
        }
        XCTAssertEqual(map(nil), .idle, "a host with no chat yet")
        XCTAssertEqual(map(activity("idle", turn: nil)), .idle)
        XCTAssertEqual(map(activity("thinking")), .thinking)
        XCTAssertEqual(map(activity("working")), .working)
        XCTAssertEqual(map(activity("tool")), .working)
        XCTAssertTrue(AgentFaceMapping.agent(connected: true, activity: activity("tool"), statusText: nil,
                                             seenTurn: nil, unseenOnly: true).tool)
        XCTAssertEqual(map(activity("tool", waiting: "approval")), .waiting)
        XCTAssertEqual(map(activity("thinking", pending: 1)), .waiting)
        XCTAssertEqual(map(activity("thinking"), status: "waiting_on_user_input"), .waiting)
        XCTAssertEqual(map(activity("done")), .done)
        XCTAssertEqual(map(activity("error")), .error)
        XCTAssertEqual(map(activity("offline")), .offline)
        XCTAssertEqual(map(activity("working"), connected: false), .offline)
        // Priority: error > waiting > done.
        XCTAssertEqual(map(activity("error", waiting: "approval")), .error)
        XCTAssertEqual(map(activity("done", waiting: "approval")), .waiting)
        // The bar: done / error only until the panel showed that turn.
        XCTAssertEqual(map(activity("done"), seen: "t1", bar: true), .idle)
        XCTAssertEqual(map(activity("done"), seen: "t0", bar: true), .done)
        XCTAssertEqual(map(activity("error"), seen: "t1", bar: true), .idle)
        XCTAssertEqual(map(activity("done"), seen: "t1", bar: false), .done, "the panel itself keeps it")
    }

    /// INTEGRATE-2 (Leo): a turn the user interrupted is `stopped` - a calm
    /// face with closed eyes, never the red error; real failures stay errors.
    func testAnInterruptedTurnIsStoppedNotAnError() throws {
        let model = try model()
        func map(_ a: AgentActivity, seen: String? = nil, bar: Bool = false) -> AgentFaceState {
            AgentFaceMapping.agent(connected: true, activity: a, statusText: nil, seenTurn: seen, unseenOnly: bar).state
        }
        XCTAssertEqual(map(activity("stopped")), .stopped)
        XCTAssertEqual(map(activity("error")), .error, "a failure is still an error")
        XCTAssertEqual(map(activity("stopped", waiting: "approval")), .waiting)
        XCTAssertEqual(map(activity("stopped"), seen: "t0", bar: true), .stopped, "the bar keeps it until seen")
        XCTAssertEqual(map(activity("stopped"), seen: "t1", bar: true), .idle)
        XCTAssertEqual(map(activity("stopped"), seen: "t1", bar: false), .stopped, "the header keeps it")
        XCTAssertEqual(model.tokens.priority, AgentFaceState.allCases.sorted { $0.rank > $1.rank }.map(\.rawValue))
        for (surface, size) in [(AgentFaceSurface.bar, 24.0), (.odomo, 24), (.header, 32), (.large, 96)] {
            XCTAssertEqual(surface.code(.stopped), "A·", "\(surface) shows it as a static pose")
            for t in [0.0, 250, 500, 1000, 1750, 2900] {
                let r = try XCTUnwrap(model.resolve(surface, .stopped, t: t, reduceMotion: false, size: size))
                XCTAssertTrue(r.still, "no timer")
                XCTAssertEqual(r.frame.eyes.kind, .closed, "offline's eye bars")
                XCTAssertEqual(r.frame.eyeInk, .foreground, "never red")
                XCTAssertFalse(r.frame.dim, "full opacity")
                XCTAssertEqual([r.frame.hx, r.frame.hy, r.frame.yaw, r.frame.pitch, r.frame.roll], [0, 0, 0, 0, 0],
                               "no hop, no shake, no nod")
                XCTAssertNil(r.frame.ring)
            }
        }
        XCTAssertEqual(AgentFaceSurface.pane.code(.stopped), "—", "Herdr panes have no interrupt")
        XCTAssertNotEqual(AgentFaceWords.word(.stopped), AgentFaceWords.word(.error))
        XCTAssertEqual(AgentFaceWords.word(.stopped), Strings.agentFaceStopped)
    }

    func testHerdrPanes() throws {
        XCTAssertEqual(AgentFaceMapping.herdr("idle"), .idle)
        XCTAssertEqual(AgentFaceMapping.herdr("working"), .working)
        XCTAssertEqual(AgentFaceMapping.herdr("blocked"), .waiting)
        XCTAssertEqual(AgentFaceMapping.herdr("done"), .done)
        XCTAssertEqual(AgentFaceMapping.herdr("unknown"), .idle)
        XCTAssertEqual(AgentFaceMapping.herdr(nil), .idle)
        let pane = try JSONDecoder().decode(HerdrPaneDTO.self, from: Data(#"""
            {"id":"w1:p1","focused":false,"zoomed":false,"agent_status":"blocked","agent":{"kind":"codex","status":"blocked"}}
            """#.utf8))
        XCTAssertEqual(pane.face, .waiting)
        let shell = try JSONDecoder().decode(HerdrPaneDTO.self, from: Data(#"""
            {"id":"w1:p2","focused":false,"zoomed":false,"agent_status":"idle"}
            """#.utf8))
        XCTAssertNil(shell.face, "a pane with no agent keeps its square")
    }

    func testCoreFixtureCarriesTheActivity() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "state-agent-activity", withExtension: "json",
                                                          subdirectory: "CoreFixtures"))
        let state = try JSONDecoder().decode(HostStateDTO.self, from: Data(contentsOf: url))
        XCTAssertEqual(state.agent?.chat, AgentActivity(phase: "tool", turnID: "turn-fixture-01", waiting: nil,
                                                        pendingApprovals: 0))
        let plain = try JSONDecoder().decode(HostStateDTO.self, from: Data(contentsOf: url.deletingLastPathComponent()
            .appendingPathComponent("state.json")))
        XCTAssertNil(plain.agent?.chat, "a host without the field decodes as before")
    }

    /// INTEGRATE-2: the wire carries `stopped` through (found on the host: the
    /// decoder's list of known phases had no `stopped` and turned it into idle).
    func testCoreStoppedPhaseDecodes() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "state-agent-activity", withExtension: "json",
                                                          subdirectory: "CoreFixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#""phase": "tool""#))
        let stopped = text.replacingOccurrences(of: #""phase": "tool""#, with: #""phase": "stopped""#)
        let state = try JSONDecoder().decode(HostStateDTO.self, from: Data(stopped.utf8))
        XCTAssertEqual(state.agent?.chat?.phase, "stopped")
        let made = text.replacingOccurrences(of: #""phase": "tool""#, with: #""phase": "made-up""#)
        XCTAssertEqual(try JSONDecoder().decode(HostStateDTO.self, from: Data(made.utf8)).agent?.chat?.phase, "idle",
                       "an unknown phase is still idle")
    }

    // MARK: Colour, budget, schedule

    func testWaitingEyesUseYellowOnlyWhereAccentIsTheForeground() throws {
        let tokens = try model().tokens
        func hex(_ s: String) -> (Double, Double, Double) {
            let v = UInt32(s.dropFirst(), radix: 16)!
            return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        }
        // kanagawa: accent == foreground, yellow 3:1 on the background → yellow.
        XCTAssertTrue(AgentFaceColours.waitingUsesYellow(accent: hex("#dcd7ba"), foreground: hex("#dcd7ba"),
                                                         yellow: hex("#c0a36e"), background: hex("#1f1f28"), tokens: tokens))
        // tokyo-night: accent.
        XCTAssertFalse(AgentFaceColours.waitingUsesYellow(accent: hex("#7aa2f7"), foreground: hex("#a9b1d6"),
                                                          yellow: hex("#e0af68"), background: hex("#1a1b26"), tokens: tokens))
        // rose-pine (light): accent, its yellow is too faint anyway.
        XCTAssertFalse(AgentFaceColours.waitingUsesYellow(accent: hex("#56949f"), foreground: hex("#575279"),
                                                          yellow: hex("#ea9d34"), background: hex("#faf4ed"), tokens: tokens))
    }

    @MainActor func testAtMostThreeFacesAnimateAndWaitingKeepsItsSlot() {
        let budget = AgentFaceBudget()
        let ids = (0..<5).map { _ in UUID() }
        budget.claim(ids[0], priority: AgentFaceBudget.priority(.thinking, tool: false))
        budget.claim(ids[1], priority: AgentFaceBudget.priority(.working, tool: false))
        budget.claim(ids[2], priority: AgentFaceBudget.priority(.done, tool: false))
        budget.claim(ids[3], priority: AgentFaceBudget.priority(.working, tool: true))
        budget.claim(ids[4], priority: AgentFaceBudget.priority(.waiting, tool: false))
        XCTAssertEqual(ids.filter(budget.granted).count, 3)
        XCTAssertTrue(budget.granted(ids[4]), "waiting first")
        XCTAssertTrue(budget.granted(ids[3]), "then working with the ring")
        XCTAssertTrue(budget.granted(ids[0]), "then the earliest of the rest")
        XCTAssertFalse(budget.granted(ids[2]))
        budget.release(ids[4])
        XCTAssertTrue(budget.granted(ids[1]))
        XCTAssertEqual(budget.animatingCount, 3)
    }

    func testTwelveFramesASecondThenSixAfterTenMinutes() throws {
        let tokens = try model().tokens
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let schedule = AgentFaceSchedule(start: start, fps: tokens.motion.fps, lowFPS: tokens.motion.low_fps,
                                         lowAfter: tokens.motion.low_fps_after_ms / 1000)
        let early = schedule.entries(from: start, mode: .normal)
        let a = try XCTUnwrap(early.next()), b = try XCTUnwrap(early.next())
        XCTAssertEqual(b.timeIntervalSince(a), 1 / 12, accuracy: 1e-9)
        let late = schedule.entries(from: start.addingTimeInterval(601), mode: .normal)
        let c = try XCTUnwrap(late.next()), d = try XCTUnwrap(late.next())
        XCTAssertEqual(d.timeIntervalSince(c), 1 / 6, accuracy: 1e-9)
    }
}
