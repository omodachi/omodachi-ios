import XCTest
@testable import Omodachi

/// An in-memory socket. No network, no audio device: the point is the first
/// text frame the transport writes.
private final class FakeMicrophoneSocket: MicrophoneSocketIO, @unchecked Sendable {
    private let lock = NSLock()
    private var outgoing: [MicrophoneSocketMessage] = []
    private var closed = false
    func resume() {}
    func send(_ message: MicrophoneSocketMessage) async throws {
        try lock.withLock {
            guard !closed else { throw MicrophoneWireProtocol.Failure.unavailable }
            outgoing.append(message)
        }
    }
    func receive() async throws -> MicrophoneSocketMessage {
        // Nothing ever answers; these tests only read what was written.
        try await Task.sleep(for: .seconds(30))
        throw MicrophoneWireProtocol.Failure.unavailable
    }
    func close() { lock.withLock { closed = true } }

    /// The `generation` of the begin frame, once it has been written.
    func firstGeneration() async throws -> UInt64 {
        for _ in 0..<400 {
            if let value = lock.withLock({ outgoing.first }), case .text(let json) = value,
               let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let generation = object["generation"] as? UInt64 ?? (object["generation"] as? NSNumber)?.uint64Value {
                return generation
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MicrophoneWireProtocol.Failure.invalidFrame
    }
}

/// SPEC-G2 §2. The voice frame encoding and the capability gate, against the
/// documents core generates. No audio device is opened anywhere here.
final class VoiceUplinkTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json",
                                                           subdirectory: "CoreFixtures"))
        return try Data(contentsOf: url)
    }

    /// The host's own numbers. SPEC-G2 §2 says 16 kHz; `docs/voice.md` and the
    /// generated capability document say 48 kHz s16le mono in 960-sample
    /// frames, and core refuses anything else at the begin frame. The host owns
    /// the source, so the host's numbers are the ones this client produces.
    func testCapabilityDocumentIsTheOneThisClientCanActuallyFeed() throws {
        let capabilities = try JSONDecoder().decode(VoiceCapabilities.self, from: fixture("voice-capabilities"))
        XCTAssertTrue(capabilities.uplink.usable)
        XCTAssertEqual(capabilities.uplink.rate, 48_000)
        XCTAssertEqual(capabilities.uplink.frameBytes, VoiceCapture.frameBytes)
        XCTAssertEqual(capabilities.uplink.frameSamples, Int(VoiceCapture.frameSamples))
        XCTAssertEqual(capabilities.uplink.endpoint, "/v1/voice/uplink")
        XCTAssertEqual(capabilities.dictation.route, "default_source")
        XCTAssertEqual(capabilities.levels.hz, 20)
        XCTAssertTrue(capabilities.ready)
        XCTAssertNil(capabilities.blockedReason)
    }

    func testEveryMissingPreconditionHasItsOwnReason() throws {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("voice-capabilities")) as? [String: Any])

        func decode(_ value: [String: Any]) throws -> VoiceCapabilities {
            try JSONDecoder().decode(VoiceCapabilities.self, from: JSONSerialization.data(withJSONObject: value))
        }

        var voxtype = try XCTUnwrap(document["voxtype"] as? [String: Any])
        voxtype["installed"] = false
        voxtype["install_command"] = ["omarchy-voxtype-install"]
        document["voxtype"] = voxtype
        var missing = try decode(document)
        XCTAssertFalse(missing.ready)
        XCTAssertEqual(missing.blockedReason, "voxtype_not_installed", "a missing Voxtype is the answer with an installer behind it")
        XCTAssertEqual(missing.voxtype.installCommand, ["omarchy-voxtype-install"])

        voxtype["installed"] = true
        document["voxtype"] = voxtype
        document["voice_uplink_enabled"] = false
        missing = try decode(document)
        XCTAssertFalse(missing.ready)
        XCTAssertEqual(missing.blockedReason, "voice_uplink_disabled")

        document["voice_uplink_enabled"] = true
        var dictation = try XCTUnwrap(document["dictation"] as? [String: Any])
        dictation["available"] = false
        dictation["reason"] = "voxtype_wait_unsupported"
        document["dictation"] = dictation
        missing = try decode(document)
        XCTAssertEqual(missing.blockedReason, "voxtype_wait_unsupported")
        XCTAssertEqual(VoiceReason.message("voxtype_wait_unsupported"),
                       ReasonText.message("voxtype_wait_unsupported", domain: .voice))
        XCTAssertNotEqual(VoiceReason.message("voxtype_wait_unsupported"), "voxtype_wait_unsupported")
    }

    func testDictationStopCarriesTheHostsOwnTranscript() throws {
        let result = try JSONDecoder().decode(VoiceDictationResult.self, from: fixture("voice-dictation"))
        XCTAssertEqual(result.text, "make the bar taller")
        XCTAssertEqual(result.chars, 19)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.target, "client")
        XCTAssertNil(result.deliveredToHost)
    }

    /// The begin frame and the acknowledgements are the Remote uplink's, byte
    /// for byte; the only difference is the route it is opened on.
    func testBeginFrameAndAcknowledgementsMatchTheHostContract() throws {
        let begin = try MicrophoneWireProtocol.begin(generation: 3)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(begin.utf8)) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "s16le")
        XCTAssertEqual(object["rate"] as? Int, 48_000)
        XCTAssertEqual(object["channels"] as? Int, 1)
        XCTAssertEqual(object["frame_samples"] as? Int, 960)
        XCTAssertEqual(object["generation"] as? Int, 3)

        let begun = try MicrophoneWireProtocol.ack(#"{"type": "begun", "generation": 3, "source_name": "omodachi_mic", "format": "s16le", "rate": 48000, "channels": 1, "frame_samples": 960, "frame_bytes": 1920, "max_queued_frames": 3, "state": "active"}"#)
        XCTAssertTrue(begun.validBegin)

        var window = MicrophoneFrameWindow(generation: 3)
        XCTAssertEqual(window.reserve(bytes: 1920, sequence: 0, sampleTime: 0), .queued)
        XCTAssertEqual(window.reserve(bytes: 960, sequence: 1, sampleTime: 960), .invalid, "a half frame is not a frame")
        XCTAssertEqual(window.reserve(bytes: 1920, sequence: 1, sampleTime: 960), .queued)
        XCTAssertEqual(window.reserve(bytes: 1920, sequence: 2, sampleTime: 1920), .queued)
        XCTAssertEqual(window.reserve(bytes: 1920, sequence: 3, sampleTime: 2880), .dropped,
                       "at most three frames may be unacknowledged")
    }

    /// `?levels=1` puts the waveform on the same socket as the ACKs. A level
    /// row has no generation, so recognizing it has to happen before the ack
    /// decode rather than failing it.
    func testLevelRowsShareTheSocketWithAcknowledgementsWithoutBreakingThem() throws {
        let row = try XCTUnwrap(MicrophoneWireProtocol.level(#"{"type": "voice.level", "seq": 1204, "peak": -14.3, "rms": 0.21, "vad": true}"#))
        XCTAssertEqual(row.seq, 1204)
        XCTAssertEqual(row.vad, true)
        XCTAssertEqual((row.bar * 1000).rounded(), 762, "-14.3 dBFS on a -60 dB floor")
        XCTAssertEqual(VoiceLevel(seq: 1, peak: -120, rms: 0, vad: false).bar, 0, "silence is a flat line")

        XCTAssertNil(MicrophoneWireProtocol.level(#"{"type": "accepted", "generation": 1, "sequence": 4}"#),
                     "an acknowledgement is not a level row")
        let ack = try MicrophoneWireProtocol.ack(#"{"type": "accepted", "generation": 1, "sequence": 4}"#)
        XCTAssertEqual(ack.sequence, 4)
    }

    /// The host found this one. `voice_service.py` keeps the highest generation
    /// it has seen **per device** for as long as its daemon runs, so a wire
    /// counter that restarts at 1 with the app is `audio_input_generation_stale`
    /// for good after the first recording. A Remote lease still starts at 1,
    /// because that record is scoped to the lease.
    func testTheVoiceUplinkGenerationSurvivesAnAppRestart() async throws {
        let lease = FakeMicrophoneSocket()
        let remote = CompanionMicrophoneTransport(factory: { lease })
        remote.beginGeneration(1, sampleRate: 48_000, channels: 1, samplesPerFrame: 960,
                               completion: { _ in }, acknowledgement: { _, _ in })
        let leaseGeneration = try await lease.firstGeneration()
        XCTAssertEqual(leaseGeneration, 1, "a lease's own uplink starts at 1")
        remote.invalidate()

        // Two launches of the app, each building its own transport.
        let base = UInt64(Date().timeIntervalSince1970 * 1000)
        let first = FakeMicrophoneSocket()
        let voice = CompanionMicrophoneTransport(factory: { first }, generationBase: base &- 1)
        voice.beginGeneration(base, sampleRate: 48_000, channels: 1, samplesPerFrame: 960,
                              completion: { _ in }, acknowledgement: { _, _ in })
        let firstGeneration = try await first.firstGeneration()
        XCTAssertEqual(firstGeneration, base, "the wire carries the monotonic value")
        voice.invalidate()

        let second = FakeMicrophoneSocket()
        let relaunched = CompanionMicrophoneTransport(factory: { second }, generationBase: base)
        relaunched.beginGeneration(base &+ 1, sampleRate: 48_000, channels: 1, samplesPerFrame: 960,
                                   completion: { _ in }, acknowledgement: { _, _ in })
        let next = try await second.firstGeneration()
        XCTAssertGreaterThan(next, base, "a relaunch never asks for a generation the host already saw")
        relaunched.invalidate()
    }

    /// A rejected frame is backpressure, not a dead channel; a rejection with
    /// any other reason is not a wire this client keeps talking on.
    func testBackpressureIsDistinctFromAFailedChannel() {
        var window = MicrophoneFrameWindow(generation: 1)
        XCTAssertEqual(window.reserve(bytes: 1920, sequence: 0, sampleTime: 0), .queued)
        XCTAssertNotNil(window.sending())
        let rejected = MicrophoneWireAck(type: "rejected", generation: 1, sequence: 1,
                                         reason: "audio_input_backpressure", format: nil, rate: nil,
                                         channels: nil, frame_samples: nil, frame_bytes: nil,
                                         max_queued_frames: nil)
        XCTAssertEqual(window.acknowledge(rejected), .rejected)

        var other = MicrophoneFrameWindow(generation: 1)
        XCTAssertEqual(other.reserve(bytes: 1920, sequence: 0, sampleTime: 0), .queued)
        XCTAssertNotNil(other.sending())
        let fatal = MicrophoneWireAck(type: "rejected", generation: 1, sequence: 1, reason: "audio_input_busy",
                                      format: nil, rate: nil, channels: nil, frame_samples: nil,
                                      frame_bytes: nil, max_queued_frames: nil)
        XCTAssertEqual(other.acknowledge(fatal), .invalid)
    }
}
