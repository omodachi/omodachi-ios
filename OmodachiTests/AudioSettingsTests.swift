import XCTest
@testable import Omodachi

final class AudioSettingsTests: XCTestCase {
    private func withAudio(_ test: (OMAudioController) -> Void) {
        let name = "audio-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(OMAudioController(defaults: defaults))
    }

    func testPerHostPlaybackDefaultsAndIsolation() {
        withAudio { audio in
            XCTAssertEqual(audio.preferences(forHost: "host-a")["enabled"] as? Bool, true)
            XCTAssertEqual(audio.preferences(forHost: "host-a")["volume"] as? Double, 1)
            XCTAssertFalse(audio.hostPlayback(forHost: "host-a"))
            audio.setPlaybackEnabled(false, muted: true, volume: 0.35, forHost: " HOST-A ")
            XCTAssertEqual(audio.preferences(forHost: "host-a")["volume"] as? Double, 0.35)
            audio.applyHostPlaybackDefault(true, forHost: "host-a")
            XCTAssertTrue(audio.hostPlayback(forHost: "host-a"))
            XCTAssertFalse(audio.hostPlayback(forHost: "host-b"))
            XCTAssertEqual(audio.preferences(forHost: "host-b")["enabled"] as? Bool, true)
        }
    }

    func testGainClampingAndNoPersistedCaptureAuthorization() {
        withAudio { audio in
            audio.setPlaybackEnabled(true, muted: false, volume: 7, forHost: "a")
            XCTAssertEqual(audio.preferences(forHost: "a")["volume"] as? Double, 1)
            audio.setPlaybackEnabled(true, muted: false, volume: -2, forHost: "a")
            XCTAssertEqual(audio.preferences(forHost: "a")["volume"] as? Double, 0)
            XCTAssertNil(audio.preferences(forHost: "a")["capturing"])
            XCTAssertNil(audio.preferences(forHost: "a")["authorized"])
        }
    }

    @MainActor func testUnavailableTransportCannotPromptOrCapture() {
        withAudio { audio in
            audio.beginSession(forHost: "a", generation: 10)
            // No transport exists. This returns before all permission/capture APIs.
            audio.requestMicrophoneEnabled(true)
            XCTAssertEqual(audio.snapshot(forHost: "a")["capturing"] as? Bool, false)
            XCTAssertEqual(audio.snapshot(forHost: "a")["accepted"] as? Bool, false)
            audio.endSession()
            XCTAssertEqual(audio.snapshot(forHost: "a")["active"] as? Bool, false)
        }
    }

    @MainActor func testPlaybackChangesApplyToDecodedPCMAndSessionStopMutes() {
        withAudio { audio in
            audio.setPlaybackEnabled(true, muted: false, volume: 0.5, forHost: "a")
            audio.beginSession(forHost: "a", generation: 2)
            var pcm: [Int16] = [1000, -1000, 32766, -32768]
            audio.processPlaybackPCM(&pcm, count: UInt(pcm.count))
            XCTAssertEqual(pcm, [500, -500, 16383, -16384])
            audio.setPlaybackEnabled(true, muted: true, volume: 0.5, forHost: "a")
            audio.processPlaybackPCM(&pcm, count: UInt(pcm.count))
            XCTAssertEqual(pcm, [0, 0, 0, 0])
            audio.endSession()
            pcm = [1000, -1000]
            audio.processPlaybackPCM(&pcm, count: UInt(pcm.count))
            XCTAssertEqual(pcm, [0, 0])
        }
    }
}
