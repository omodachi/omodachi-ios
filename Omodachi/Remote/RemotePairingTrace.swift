import Foundation
import OSLog

/// PAIR-1 pairing trace. Debug-only. Sunshine pairing crosses three processes
/// (this app's Moonlight half, core's `/v1/media/pairing/*` bridge and the
/// managed fork), and a failure in any of them used to surface as one sentence
/// with no way to tell which leg stopped. These lines name the leg, the
/// identity it used and the status it got back.
///
/// Nothing here is a control path: every value already exists on the wire.
/// Certificate fingerprints are public key material, never secrets; PINs and
/// bearer tokens are never traced.
enum RemotePairingTrace {
    #if DEBUG
    private static let log = Logger(subsystem: "com.omodachi.ios", category: "pairing")
    static func emit(_ line: String) { log.info("pair.\(line, privacy: .public)") }
    #else
    static func emit(_ line: String) {}
    #endif

    static func http(path: String, status: Int, code: String?) {
        emit("http path=\(path) status=\(status) code=\(code ?? "-")")
    }

    static func step(_ name: String, _ detail: String) {
        emit("\(name) \(detail)")
    }
}
