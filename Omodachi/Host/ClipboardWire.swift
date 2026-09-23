import Foundation

/// CLIP-1. The host's refusal, kept apart from every other one.
///
/// `CompanionHostClient.mapHTTPError` turns any 403 into `.unauthorized`,
/// which for a clipboard would be a lie with consequences: the two 403s here
/// mean "the switch is off", and a screen that reads them as "this device is
/// not paired" would send somebody to re-pair a device that is fine.
public struct ClipboardHostError: Error, Equatable, Sendable {
    public let code: String
    public let status: Int

    /// The host's switch, or the direction it allows, is what is in the way —
    /// as opposed to a fault. ⑥ says which, and says nothing about pairing.
    public var isRefusedByPreference: Bool {
        code == "clipboard_sync_disabled" || code == "clipboard_write_disabled"
    }

    public var userMessage: String { ReasonText.message(code, domain: .host, status: status) }
}

/// What `PUT /v1/clipboard` answers: a count, never the text back.
struct ClipboardWriteReceiptDTO: Decodable {
    let bytes: Int
    let mime: String
}

/// CLIP-1's `clipboard.changed`. The text is deliberately not in it — the
/// device asks for it if it wants it — so this is a length and a counter.
struct ClipboardChangedEvent: Decodable, Equatable, Sendable {
    let sequence: Int
    let bytes: Int
    let mime: String
}

/// `GET /v1/preferences`, read for one field. Remote reads the same document
/// for `profile_defaults`; this one reads the host's half of CLIP-1's switch
/// and nothing else, so a preference core adds later cannot break it.
struct HostPreferencesDTO: Decodable {
    struct Values: Decodable {
        let clipboardSync: String?
        enum CodingKeys: String, CodingKey { case clipboardSync = "clipboard_sync" }
    }
    let values: Values
}
