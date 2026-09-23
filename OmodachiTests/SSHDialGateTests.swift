import XCTest
@testable import Omodachi

/// UX-3 §2. The ladder, as a thing that can actually be walked.
///
/// The host's own log is the specification this is written against:
///
/// ```
/// 06:42:04 Connection closed by authenticating user alex 192.168.1.24 [preauth]
/// 06:42:05 Connection closed by authenticating user alex 192.168.1.24 [preauth]
/// 06:42:07 Connection closed by authenticating user alex 192.168.1.24 [preauth]
/// 06:42:09 Connection closed by authenticating user alex 192.168.1.24 [preauth]
/// 06:42:09 srclimit_penalise: 192.168.1.24/32: activating ipv4 penalty … failed authentication
/// ```
///
/// Four connections in five seconds, and then the penalty box. UX-2 had
/// already written a `4 / 12 / 30` ladder; it simply was not on this path,
/// because it belonged to a *reattachable session* and the SSH panel opens a
/// shell. `sshd` penalises an address, so the ladder has to belong to the
/// pair "this device, that host" — which is what this object keys on.
@MainActor
final class SSHDialGateTests: XCTestCase {
    private func identity(_ host: String = "omarchy") -> SSHConnectionIdentity {
        SSHConnectionIdentity(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                              hostname: host, port: 22, username: "alex", mock: false,
                              keyAccount: "ssh-1")
    }

    func testOneDialAtATimePerHost() {
        let gate = SSHDialGate()
        let key = identity()
        XCTAssertEqual(gate.admit(key), .admitted)
        XCTAssertEqual(gate.admit(key), .busy, "a second runtime must not dial the same host")
        XCTAssertEqual(gate.admit(identity("elsewhere")), .admitted, "a different host is not held up")
    }

    /// The exact shape of the sshd log, refused.
    ///
    /// Those four connections land at 06:42:04, :05, :07 and :09 — offsets 0,
    /// 1, 3 and 5 — and `sshd` answers the run with `srclimit_penalise`. Fed
    /// the same four moments, the gate lets through the first and then nothing
    /// until its first rung has elapsed. The second, third and fourth
    /// connections, which are the ones inside two seconds of each other, do
    /// not happen at all.
    ///
    /// Two attempts over those five seconds rather than one is correct and
    /// deliberate: the 4 s rung is up by :09, and standing back for four
    /// seconds is the whole bargain. What earned the penalty was the cluster,
    /// not the count.
    func testTheBurstThatEarnedThePenaltyCannotHappen() {
        let gate = SSHDialGate()
        let key = identity()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var admitted: [Double] = []
        for offset in [0.0, 1.0, 3.0, 5.0] {
            let now = start.addingTimeInterval(offset)
            if gate.admit(key, now: now) == .admitted {
                admitted.append(offset)
                gate.finished(key, success: false, now: now)
            }
        }
        XCTAssertEqual(admitted, [0.0, 5.0], "the cluster inside two seconds is gone")
        for (earlier, later) in zip(admitted, admitted.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, Double(SSHDialGate.backoff[0]),
                                        "no two attempts closer than the first rung")
        }
    }

    func testTheLadderIsFourThenTwelveThenThirty() {
        let gate = SSHDialGate()
        let key = identity()
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        var rungs: [Int] = []
        for _ in 0..<3 {
            XCTAssertEqual(gate.admit(key, now: now), .admitted)
            gate.finished(key, success: false, now: now)
            rungs.append(try! XCTUnwrap(gate.waitSeconds(key, now: now)))
            now = now.addingTimeInterval(TimeInterval(rungs.last!))
        }
        XCTAssertEqual(rungs, [4, 12, 30])
        XCTAssertEqual(rungs, SSHDialGate.backoff)
        XCTAssertEqual(TerminalRuntime.reattachDelays, [4, 12, 30], "one ladder, not two")
    }

    func testAnAttemptInsideARungIsRefusedAndSaysHowLong() {
        let gate = SSHDialGate()
        let key = identity()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(gate.admit(key, now: start), .admitted)
        gate.finished(key, success: false, now: start)
        XCTAssertEqual(gate.admit(key, now: start.addingTimeInterval(1)),
                       .backingOff(seconds: 3, attempt: 1))
        XCTAssertEqual(gate.admit(key, now: start.addingTimeInterval(4)), .admitted)
    }

    /// Three rungs and then it stops on its own. A ladder that loops forever
    /// is the loop it exists to prevent, one order of magnitude slower.
    func testTheLadderRunsOutRatherThanLoopingForever() {
        let gate = SSHDialGate()
        let key = identity()
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        for rung in SSHDialGate.backoff {
            XCTAssertEqual(gate.admit(key, now: now), .admitted)
            gate.finished(key, success: false, now: now)
            now = now.addingTimeInterval(TimeInterval(rung))
        }
        XCTAssertEqual(gate.admit(key, now: now), .exhausted(attempts: 3))
        XCTAssertEqual(gate.admit(key, now: now.addingTimeInterval(3600)), .exhausted(attempts: 3))
    }

    /// A host that works is never slowed down, and a person who taps is never
    /// argued with.
    func testSuccessAndAnExplicitTapBothClearTheLadder() {
        let gate = SSHDialGate()
        let key = identity()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 0..<3 {
            _ = gate.admit(key, now: now)
            gate.finished(key, success: false, now: now)
        }
        XCTAssertEqual(gate.admit(key, now: now), .exhausted(attempts: 3))
        gate.reset(key)
        XCTAssertEqual(gate.admit(key, now: now), .admitted)
        gate.finished(key, success: true, now: now)
        XCTAssertNil(gate.waitSeconds(key, now: now))
        XCTAssertEqual(gate.admit(key, now: now), .admitted, "a working host waits for nothing")
    }
}
