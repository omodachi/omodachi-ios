import UIKit
import XCTest
@testable import Omodachi

/// INPUT-2. The input gate is six conditions and one standing want, and none of
/// them has a fixed arrival order: on 2026-09-19 the host observed the media
/// leg's `connected` land 142 ms *after* the first presented frame, which is
/// the one call the session ever made to open input. These cases pin the
/// property that made that a bug — that the answer is re-derived rather than
/// evaluated once — for every order the conditions can arrive in.
@MainActor final class RemoteInputGateTests: XCTestCase {

    /// The six conditions, as a value, so an arrival order is a list of edits.
    private struct Conditions {
        var desired = false
        var geometryReady = false
        var connected = false
        var frameReported = false
        var stopping = false
        var hasMedia = false
        var lifecycle = 0          // OmodachiMediaLifecycleStateIdle
        var allowed: Bool {
            OMRemoteClient.inputAllowed(desired: desired, geometryReady: geometryReady,
                                        lifecycle: lifecycle, connected: connected,
                                        frameReported: frameReported, stopping: stopping,
                                        hasMedia: hasMedia)
        }
    }

    /// The five things a session turns on, named so a failure says which order
    /// broke. `media` carries the lifecycle, because `Running` is what the
    /// facade sets when it reports `connected`.
    private static let steps: [(String, (inout Conditions) -> Void)] = [
        ("want", { $0.desired = true }),
        ("geometry", { $0.geometryReady = true }),
        ("connected", { $0.connected = true }),
        ("frame", { $0.frameReported = true }),
        ("media-running", { $0.hasMedia = true; $0.lifecycle = 2 }),   // ...StateRunning
    ]

    private func permutations(_ values: [Int]) -> [[Int]] {
        guard values.count > 1 else { return [values] }
        return values.flatMap { value in
            permutations(values.filter { $0 != value }).map { [value] + $0 }
        }
    }

    /// Whatever order they arrive in, input opens on the last one and never
    /// before it. This is the property `setInputEnabled` used to break by
    /// deciding once, at the moment the want was expressed.
    func testEveryArrivalOrderConvergesOnTheSameAnswer() {
        let orders = permutations(Array(Self.steps.indices))
        XCTAssertEqual(orders.count, 120)
        for order in orders {
            var conditions = Conditions()
            var opened: Int?
            for (index, step) in order.enumerated() {
                Self.steps[step].1(&conditions)
                if conditions.allowed, opened == nil { opened = index }
            }
            let names = order.map { Self.steps[$0].0 }.joined(separator: " → ")
            XCTAssertEqual(opened, Self.steps.count - 1,
                           "input must open on the last condition and not before: \(names)")
            XCTAssertTrue(conditions.allowed, "the gate never converged for \(names)")
        }
    }

    /// The two orders the host actually produced, spelled out. `frame` before
    /// `connected` is the observed one; the reverse is what the code assumed.
    func testFrameBeforeConnectedEndsUpTheSameAsConnectedBeforeFrame() {
        var frameFirst = Conditions()
        frameFirst.desired = true; frameFirst.geometryReady = true
        frameFirst.hasMedia = true; frameFirst.lifecycle = 2
        frameFirst.frameReported = true
        XCTAssertFalse(frameFirst.allowed, "a frame without a connection cannot carry input")
        frameFirst.connected = true
        XCTAssertTrue(frameFirst.allowed)

        var connectedFirst = Conditions()
        connectedFirst.desired = true; connectedFirst.geometryReady = true
        connectedFirst.hasMedia = true; connectedFirst.lifecycle = 2
        connectedFirst.connected = true
        XCTAssertFalse(connectedFirst.allowed, "a connection without a presented frame has no geometry to aim at")
        connectedFirst.frameReported = true
        XCTAssertTrue(connectedFirst.allowed)
    }

    /// Geometry arriving last — a rotation that settles after the stream is up.
    func testGeometryArrivingLastStillOpensInput() {
        var conditions = Conditions()
        conditions.desired = true; conditions.connected = true; conditions.frameReported = true
        conditions.hasMedia = true; conditions.lifecycle = 2
        XCTAssertFalse(conditions.allowed)
        conditions.geometryReady = true
        XCTAssertTrue(conditions.allowed)
        // A resize invalidates it again and the want must survive that.
        conditions.geometryReady = false
        XCTAssertFalse(conditions.allowed)
        conditions.geometryReady = true
        XCTAssertTrue(conditions.allowed, "the want is standing, so the new geometry reopens input")
    }

    /// Stopping closes the gate from any state, and a lifecycle that is not
    /// Running is not a session that can be typed into.
    func testStoppingAndANonRunningLifecycleAlwaysClose() {
        var conditions = Conditions()
        conditions.desired = true; conditions.geometryReady = true; conditions.connected = true
        conditions.frameReported = true; conditions.hasMedia = true; conditions.lifecycle = 2
        XCTAssertTrue(conditions.allowed)
        conditions.stopping = true
        XCTAssertFalse(conditions.allowed)
        conditions.stopping = false
        conditions.lifecycle = 1      // ...StateStarting
        XCTAssertFalse(conditions.allowed)
        conditions.lifecycle = 2
        conditions.hasMedia = false
        XCTAssertFalse(conditions.allowed)
    }

    /// The Panel is the want, not a condition: closing it opens input again as
    /// soon as it is closed, and only while everything else still holds.
    func testThePanelOnlyMovesTheWant() {
        var conditions = Conditions()
        conditions.geometryReady = true; conditions.connected = true; conditions.frameReported = true
        conditions.hasMedia = true; conditions.lifecycle = 2
        XCTAssertFalse(conditions.allowed, "a Panel over the picture means input is not wanted")
        conditions.desired = true
        XCTAssertTrue(conditions.allowed)
        conditions.desired = false
        XCTAssertFalse(conditions.allowed)
        conditions.desired = true
        XCTAssertTrue(conditions.allowed)
    }

    /// A rebuilt session starts from nothing: `start` clears the want, so the
    /// previous session's "input is on" cannot carry into the new one before
    /// its own first frame.
    func testARebuiltSessionDoesNotInheritTheOldWant() {
        let client = OMRemoteClient(host: "unused.invalid")
        XCTAssertTrue(client.beginLease())
        client.setInputEnabled(true, generation: 0)
        XCTAssertFalse(client.inputReady, "there is no media, so nothing can be enabled")
        client.stop { _ in }
        XCTAssertTrue(client.beginLease())
        XCTAssertFalse(client.inputReady)
        XCTAssertEqual(client.leaseSerial, 2)
    }

    /// A want addressed to a generation this client has left behind is
    /// discarded; the running session keeps whatever it was told.
    func testAWantForAnotherGenerationIsDiscarded() {
        let client = OMRemoteClient(host: "unused.invalid")
        XCTAssertTrue(client.beginLease())
        client.setInputEnabled(true, generation: 7)
        XCTAssertFalse(client.inputReady)
        XCTAssertEqual(client.generation, 0, "a stale want never moves the session")
    }
}
