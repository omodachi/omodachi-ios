import XCTest
@testable import Omodachi

private final class FakeSocket: MicrophoneSocketIO, @unchecked Sendable {
    let lock = NSLock()
    var incoming: [MicrophoneSocketMessage] = []
    var waiters: [CheckedContinuation<MicrophoneSocketMessage, Error>] = []
    var outgoing: [MicrophoneSocketMessage] = []
    var closed = false
    func resume() {}
    func send(_ message: MicrophoneSocketMessage) async throws {
        try lock.withLock {
            guard !closed else { throw MicrophoneWireProtocol.Failure.unavailable }
            outgoing.append(message)
        }
    }
    func receive() async throws -> MicrophoneSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if closed { continuation.resume(throwing: MicrophoneWireProtocol.Failure.unavailable) }
                else if !incoming.isEmpty { continuation.resume(returning: incoming.removeFirst()) }
                else { waiters.append(continuation) }
            }
        }
    }
    func close() {
        let pending = lock.withLock { closed = true; let copy = waiters; waiters = []; return copy }
        for waiter in pending { waiter.resume(throwing: MicrophoneWireProtocol.Failure.unavailable) }
    }
    func push(_ json: String) {
        lock.withLock {
            guard !closed else { return }
            if !waiters.isEmpty { waiters.removeFirst().resume(returning: .text(json)) }
            else { incoming.append(.text(json)) }
        }
    }
    var sent: [MicrophoneSocketMessage] { lock.withLock { outgoing } }
    var isClosed: Bool { lock.withLock { closed } }
    var binaryCount: Int { sent.filter { if case .binary = $0 { return true }; return false }.count }
}

private final class SocketQueue: @unchecked Sendable {
    let lock = NSLock()
    var sockets: [FakeSocket]
    init(_ sockets: [FakeSocket]) { self.sockets = sockets }
    func next() throws -> FakeSocket {
        try lock.withLock {
            guard !sockets.isEmpty else { throw MicrophoneWireProtocol.Failure.unavailable }
            return sockets.removeFirst()
        }
    }
}

private final class Probe: @unchecked Sendable {
    let lock = NSLock()
    var beginnings: [Bool] = []
    var acknowledgements: [(Bool, Bool)] = []
    func began(_ ok: Bool) { lock.withLock { beginnings.append(ok) } }
    func ack(_ ok: Bool, _ open: Bool) { lock.withLock { acknowledgements.append((ok, open)) } }
    var begins: [Bool] { lock.withLock { beginnings } }
    var acks: [(Bool, Bool)] { lock.withLock { acknowledgements } }
}

/// Production microphone adapter: capability, begin-ACK gate, bounded local
/// drop, rejected/accepted FIFO, stale generation, end, cancel/late ACK,
/// timeout, invalid format, monotonic re-enable and unavailable route. Uses an
/// in-memory socket only; no audio APIs or sockets run.
final class MicrophoneTransportTests: XCTestCase {
    private static let begun = #"{"type":"begun","generation":1,"format":"s16le","rate":48000,"channels":1,"frame_samples":960,"frame_bytes":1920,"max_queued_frames":3}"#

    private func wait(_ message: String, _ predicate: @Sendable () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail(message)
    }

    func testCapabilityAndBeginEnvelope() throws {
        let capability = try JSONDecoder().decode(CompanionAudioInputCapability.self, from: Data(#"{"supported":true,"available":true,"active":false,"transport":"websocket","endpoint":"/v1/sessions/{lease_id}/audio","format":"s16le","rate":48000,"channels":1,"frame_samples":960,"frame_bytes":1920,"max_queued_frames":3}"#.utf8))
        XCTAssertTrue(capability.usable)
        XCTAssertFalse(capability.active)
        let beginObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(MicrophoneWireProtocol.begin(generation: 3).utf8)) as? [String: Any])
        XCTAssertEqual(beginObject["generation"] as? Int, 3)
        XCTAssertEqual(beginObject["frame_samples"] as? Int, 960)
    }

    func testBeginGateBoundedDropFIFOAcknowledgementsAndEnd() async throws {
        let fake = FakeSocket(), probe = Probe()
        let transport = CompanionMicrophoneTransport(factory: { fake })
        transport.beginGeneration(10, sampleRate: 48000, channels: 1, samplesPerFrame: 960, completion: probe.began, acknowledgement: probe.ack)
        try await wait("begin not sent", { !fake.sent.isEmpty })
        XCTAssertTrue(probe.begins.isEmpty, "Opening a socket is not a begin ACK.")
        XCTAssertFalse(transport.acceptPCM(Data(count: 1920), generation: 10, sequence: 0, sampleTime: 0))
        fake.push(Self.begun)
        try await wait("begin ACK not delivered", { probe.begins == [true] })
        for sequence in 0..<4 { // fourth capture frame is intentionally dropped locally
            XCTAssertTrue(transport.acceptPCM(Data(count: 1920), generation: 10, sequence: UInt64(sequence), sampleTime: UInt64(sequence * 960)))
        }
        try await wait("binary writes missing", { fake.binaryCount == 3 })
        XCTAssertTrue(probe.acks.isEmpty, "send completion is never host acceptance.")
        fake.push(#"{"type":"accepted","generation":1,"sequence":1}"#)
        fake.push(#"{"type":"rejected","generation":1,"sequence":2,"reason":"audio_input_backpressure"}"#)
        fake.push(#"{"type":"accepted","generation":1,"sequence":3}"#)
        try await wait("FIFO acknowledgements missing", { probe.acks.count == 3 })
        XCTAssertTrue(probe.acks[0].0)
        XCTAssertFalse(probe.acks[1].0)
        XCTAssertTrue(probe.acks[1].1)
        XCTAssertTrue(probe.acks[2].0)
        XCTAssertTrue(transport.acceptPCM(Data(count: 1920), generation: 10, sequence: 4, sampleTime: 3840))
        try await wait("post-drop frame not sent", { fake.binaryCount == 4 })
        // capture sequence 4 maps to wire ordinal 4, not 5.
        fake.push(#"{"type":"accepted","generation":1,"sequence":4}"#)
        try await wait("post-drop ACK mismatch", { probe.acks.count == 4 })
        XCTAssertTrue(probe.acks.last!.0)
        XCTAssertFalse(transport.acceptPCM(Data(count: 1919), generation: 10, sequence: 5, sampleTime: 4800))
        XCTAssertFalse(transport.acceptPCM(Data(count: 1920), generation: 9, sequence: 5, sampleTime: 4800))
        transport.endGeneration(9)
        XCTAssertFalse(fake.isClosed, "stale end cannot close another generation.")
        transport.endGeneration(10)
        try await wait("end not closed", { fake.isClosed })
        XCTAssertTrue(fake.sent.contains { if case .text(let text) = $0 { return text.contains("\"type\":\"end\"") }; return false })
        XCTAssertFalse(transport.acceptPCM(Data(count: 1920), generation: 10, sequence: 5, sampleTime: 4800))
    }

    func testLateAcknowledgementCannotRestartCapture() async throws {
        let late = FakeSocket(), lateProbe = Probe()
        let canceled = CompanionMicrophoneTransport(factory: { late })
        canceled.beginGeneration(1, sampleRate: 48000, channels: 1, samplesPerFrame: 960, completion: lateProbe.began, acknowledgement: lateProbe.ack)
        try await wait("late begin missing", { !late.sent.isEmpty })
        canceled.endGeneration(1)
        late.push(Self.begun)
        try await wait("canceled channel not closed", { late.isClosed })
        XCTAssertTrue(lateProbe.begins.isEmpty, "late ACK cannot restart capture.")
    }

    func testAcknowledgementDeadlineClosesChannel() async throws {
        let timeout = FakeSocket(), timeoutProbe = Probe()
        let timed = CompanionMicrophoneTransport(factory: { timeout })
        timed.beginGeneration(1, sampleRate: 48000, channels: 1, samplesPerFrame: 960, completion: timeoutProbe.began, acknowledgement: timeoutProbe.ack)
        try await wait("timeout begin missing", { !timeout.sent.isEmpty })
        timeout.push(Self.begun)
        try await wait("timeout begin ACK missing", { timeoutProbe.begins == [true] })
        XCTAssertTrue(timed.acceptPCM(Data(count: 1920), generation: 1, sequence: 0, sampleTime: 0))
        try await wait("ACK deadline failed to close", { timeoutProbe.acks.contains { !$0.0 && !$0.1 } })
        XCTAssertTrue(timeout.isClosed)
        XCTAssertFalse(timed.isAvailable(forGeneration: 1))
    }

    func testInvalidFormatRejected() async throws {
        let bad = FakeSocket(), badProbe = Probe()
        let rejected = CompanionMicrophoneTransport(factory: { bad })
        rejected.beginGeneration(1, sampleRate: 48000, channels: 1, samplesPerFrame: 960, completion: badProbe.began, acknowledgement: badProbe.ack)
        try await wait("bad begin missing", { !bad.sent.isEmpty })
        bad.push(Self.begun.replacingOccurrences(of: "48000", with: "44100"))
        try await wait("invalid format accepted", { badProbe.begins == [false] })
        XCTAssertTrue(badProbe.acks.isEmpty)
    }

    func testMonotonicWireGenerationOnReEnable() async throws {
        let first = FakeSocket(), second = FakeSocket(), repeatedProbe = Probe()
        let sockets = SocketQueue([first, second])
        let repeated = CompanionMicrophoneTransport(factory: { try sockets.next() })
        repeated.beginGeneration(5, sampleRate: 48000, channels: 1, samplesPerFrame: 960, completion: repeatedProbe.began, acknowledgement: repeatedProbe.ack)
        try await wait("first repeat missing", { !first.sent.isEmpty })
        first.push(Self.begun)
        try await wait("first repeat ack missing", { repeatedProbe.begins.count == 1 })
        repeated.endGeneration(5)
        try await wait("first repeat end missing", { first.isClosed })
        repeated.beginGeneration(5, sampleRate: 48000, channels: 1, samplesPerFrame: 960, completion: repeatedProbe.began, acknowledgement: repeatedProbe.ack)
        try await wait("second repeat missing", { !second.sent.isEmpty })
        guard case .text(let secondBegin) = second.sent[0] else { XCTFail("begin must be text"); return }
        let secondObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(secondBegin.utf8)) as? [String: Any])
        XCTAssertEqual(secondObject["generation"] as? Int, 2)
        second.push(Self.begun.replacingOccurrences(of: "\"generation\":1", with: "\"generation\":2"))
        try await wait("second repeat ack missing", { repeatedProbe.begins == [true, true] })
        repeated.endGeneration(5)
    }

    func testUnavailableRouteNeverBecomesReady() async throws {
        let unavailableProbe = Probe()
        let unavailable = CompanionMicrophoneTransport(factory: { throw MicrophoneWireProtocol.Failure.unavailable })
        unavailable.beginGeneration(1, sampleRate: 48000, channels: 1, samplesPerFrame: 960, completion: unavailableProbe.began, acknowledgement: unavailableProbe.ack)
        try await wait("unavailable route incorrectly ready", { unavailableProbe.begins == [false] })
        XCTAssertFalse(unavailable.isAvailable(forGeneration: 1))
        XCTAssertTrue(unavailableProbe.acks.isEmpty)
    }
}
