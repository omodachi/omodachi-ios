import Foundation

struct CompanionAudioInputCapability: Decodable, Sendable {
    let supported: Bool
    let available: Bool
    let active: Bool
    let transport: String
    let endpoint: String
    let format: String
    let rate: Int
    let channels: Int
    let frame_samples: Int
    let frame_bytes: Int
    let max_queued_frames: Int
    var usable: Bool {
        supported && available && transport == "websocket" && endpoint == "/v1/sessions/{lease_id}/audio"
            && format == "s16le" && rate == 48_000 && channels == 1
            && frame_samples == 960 && frame_bytes == 1920 && max_queued_frames == 3
    }
}

struct MicrophoneWireAck: Decodable, Sendable {
    let type: String
    let generation: UInt64
    let sequence: UInt64?
    let reason: String?
    let format: String?
    let rate: Int?
    let channels: Int?
    let frame_samples: Int?
    let frame_bytes: Int?
    let max_queued_frames: Int?
    var validBegin: Bool {
        type == "begun" && format == "s16le" && rate == 48_000 && channels == 1
            && frame_samples == 960 && frame_bytes == 1920 && max_queued_frames == 3
    }
}

enum MicrophoneWireProtocol {
    static func begin(generation: UInt64) throws -> String {
        guard generation > 0 else { throw Failure.invalidFrame }
        let object: [String: Any] = ["generation": generation, "format": "s16le", "rate": 48_000, "channels": 1, "frame_samples": 960]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    static func end(generation: UInt64) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["type": "end", "generation": generation], options: [.sortedKeys]), as: UTF8.self)
    }
    static func ack(_ text: String) throws -> MicrophoneWireAck {
        let bytes = Data(text.utf8)
        guard bytes.count <= 4096 else { throw Failure.invalidFrame }
        return try JSONDecoder().decode(MicrophoneWireAck.self, from: bytes)
    }
    /// `GET /v1/voice/uplink?levels=1` carries the waveform on the same socket
    /// as the acknowledgements. A level row has no generation and is not an
    /// acknowledgement of anything, so it is recognized before the ack decode
    /// rather than failing it.
    static func level(_ text: String) -> VoiceLevel? {
        let bytes = Data(text.utf8)
        guard bytes.count <= 4096,
              let tagged = try? JSONDecoder().decode(TypeTag.self, from: bytes),
              tagged.type == "voice.level" else { return nil }
        return try? JSONDecoder().decode(VoiceLevel.self, from: bytes)
    }
    private struct TypeTag: Decodable { let type: String }
    enum Failure: Error { case invalidFrame, invalidAck, unavailable }
}

/// Used by the real transport under its lock. Local reservation is never a host
/// acknowledgement; unacknowledged frames (sent or queued) are bounded to three.
struct MicrophoneFrameWindow: Sendable {
    enum Reservation: Equatable { case queued, dropped, invalid }
    enum Acknowledgement: Equatable { case accepted, rejected, invalid }
    let generation: UInt64
    private(set) var lastCaptureSequence: UInt64?
    private(set) var pending: [UInt64] = []
    private(set) var reserved = 0
    private(set) var sentThrough: UInt64 = 0
    mutating func reserve(bytes: Int, sequence: UInt64, sampleTime: UInt64) -> Reservation {
        guard bytes == 1920, sequence <= UInt64.max / 960,
              sampleTime == sequence * 960, lastCaptureSequence.map({ sequence > $0 }) ?? true else { return .invalid }
        lastCaptureSequence = sequence
        guard reserved < 3 else { return .dropped }
        reserved += 1; return .queued
    }
    mutating func sending() -> UInt64? {
        guard pending.count < reserved, sentThrough < UInt64.max else { return nil }
        sentThrough += 1; pending.append(sentThrough); return sentThrough
    }
    mutating func acknowledge(_ ack: MicrophoneWireAck) -> Acknowledgement {
        guard ack.generation == generation, let sequence = ack.sequence,
              sequence <= sentThrough, pending.first == sequence else { return .invalid }
        let result: Acknowledgement
        if ack.type == "accepted" { result = .accepted }
        else if ack.type == "rejected", ack.reason == "audio_input_backpressure" { result = .rejected }
        else { return .invalid }
        pending.removeFirst(); reserved -= 1; return result
    }
}
