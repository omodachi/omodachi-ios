// lint:host-words — a UI-test harness: its literals are a stand-in host and its wire fixtures.
import Foundation
import RemoteInputCore
import SwiftUI
import UIKit

/// REMOTE-INPUT-2. Whether this launch is the compose bar's UI-test harness.
@MainActor enum RemoteComposeHarnessLaunch {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--remote-compose-harness")
        #else
        return false
        #endif
    }

    @ViewBuilder static func view() -> some View {
        #if DEBUG && targetEnvironment(simulator)
        RemoteComposeHarness()
        #else
        EmptyView()
        #endif
    }
}

#if DEBUG && targetEnvironment(simulator)

/// REMOTE-INPUT-2, simulator and DEBUG only: the compose bar over a stand-in
/// picture, for the UI test (`REMOTEINPUT2UITests`). The session controller is
/// the real one; the host and the media leg are in memory, and what reached
/// "the computer" is written on the picture so the test can read it.
/// `--ui-testing --remote-compose-harness`.
struct RemoteComposeHarness: View {
    @StateObject private var remote: RemoteSessionController
    @StateObject private var host: HarnessLog
    private let service: HarnessRemoteHost
    private let driver: HarnessDriver

    init() {
        let log = HarnessLog()
        let service = HarnessRemoteHost(log: log)
        let driver = HarnessDriver(log: log)
        self.service = service
        self.driver = driver
        _host = StateObject(wrappedValue: log)
        _remote = StateObject(wrappedValue: RemoteSessionController(
            service: service, driver: driver, heartbeatInterval: .seconds(600), backgroundGrace: .seconds(600)))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                OmodachiTheme.pictureLetterbox
                Text(verbatim: host.line)
                    .font(OmodachiTheme.font("body-small"))
                    .foregroundStyle(OmodachiTheme.text)
                    .padding(OmodachiTheme.space("xl"))
                    .accessibilityIdentifier("harness-host-log")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if !remote.keyboardVisible { remote.toggleKeyboard() } }
            if remote.keyboardVisible, remote.hasSession {
                RemoteComposeBar(controller: remote)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task {
            var profile = HostProfile()
            profile.mock = false
            profile.hostname = "harness"
            profile.companionURL = "https://harness.invalid:8099"
            remote.configure(profile: profile)
            remote.backendChoice = .vnc
            remote.viewportChanged(size: CGSize(width: 1194, height: 834), orientation: "landscape_left")
            remote.start()
            for _ in 0..<200 where !remote.isStreaming { try? await Task.sleep(for: .milliseconds(20)) }
            remote.toggleKeyboard()
        }
    }
}

/// What reached the stand-in computer, in order, as one line.
@MainActor final class HarnessLog: ObservableObject {
    @Published private(set) var typed: [String] = []
    @Published private(set) var keys: [String] = []
    func type(_ text: String) { typed.append(text) }
    func key(_ name: String) { keys.append(name) }
    var line: String {
        let shown = typed.map { $0.replacingOccurrences(of: "\n", with: "⏎") }
        return "typed=" + shown.joined(separator: "|") + " keys=" + keys.joined(separator: ",") // non-copy: a test readout
    }
}

/// The media leg: connects at once and presents one frame.
@MainActor final class HarnessDriver: RemoteBackendDriver {
    private let log: HarnessLog
    init(log: HarnessLog) { self.log = log }
    var retainedFrame: UIImage? { nil }
    var isIdle = true
    var onFirstFrame: ((RemotePixels, CGRect) -> Void)?
    var onStage: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onGesture: ((RemotePictureGesture) -> Void)?
    private var keyboardUp = false
    func connect(_ connection: RemoteConnectionDTO, profile: RemoteProfileDTO?) async {
        isIdle = false
        DispatchQueue.main.async { [weak self] in
            self?.onFirstFrame?(RemotePixels(width: 2388, height: 1668), CGRect(x: 0, y: 0, width: 1194, height: 834))
        }
    }
    func stop() async { isIdle = true }
    func setInputEnabled(_ enabled: Bool) {}
    func toggleKeyboard() -> Bool { keyboardUp.toggle(); log.key(keyboardUp ? "perkey-up" : "perkey-down"); return keyboardUp } // non-copy
    func hideKeyboard() { if keyboardUp { log.key("perkey-down") }; keyboardUp = false } // non-copy
    func setRegisteredGestures(_ gestures: Set<RemotePictureGesture>) {}
    func passKey(usage: UInt16, down: Bool) { if down { log.key(String(format: "%02X", usage)) } } // non-copy
    func passChord(usage: UInt16, modifiers: RemoteModifiers) { log.key(String(format: "%02X+%d", usage, modifiers.rawValue)) } // non-copy
}

/// The host: one session, and core's text route with its one-id-once rule.
actor HarnessRemoteHost: RemoteSessionServing {
    private let log: HarnessLog
    private var revision = 0
    private var typedIDs: Set<String> = []
    init(log: HarnessLog) { self.log = log }

    private func session() throws -> RemoteSessionDTO {
        revision += 1
        let body = #"{"id":"rs_0123456789abcdef0123456789abcdef","backend":"vnc","mode":"extend","state":"ready","revision":\#(revision),"ttl_seconds":60,"placement":"right","lock_local_input":false,"connection":{"backend":"vnc","transport":"wss","path":"/v1/remote/sessions/rs_0123456789abcdef0123456789abcdef/vnc","output_id":"OMODACHI-0123456789abcdef","framebuffer_pixels":{"width":2388,"height":1668}}}"# // non-copy: a wire fixture
        return try JSONDecoder().decode(RemoteSessionDTO.self, from: Data(body.utf8))
    }
    func remoteCapabilities() async throws -> RemoteCapabilitiesDTO {
        let body = #"{"backends":{"sunshine":{"available":false,"reason":"backend_not_installed"},"vnc":{"available":true,"reason":null}},"modes":["extend","takeover"],"placement_options":["right"],"lock_local_input_supported":true,"encoder_limits":null,"text_input":{"available":true,"layout":"us","variant":null,"max_chars":1024,"max_bytes":4096,"compose":true}}"# // non-copy: a wire fixture
        return try JSONDecoder().decode(RemoteCapabilitiesDTO.self, from: Data(body.utf8))
    }
    func createRemoteSession(_ body: RemoteCreateRequest) async throws -> RemoteSessionDTO { try session() }
    func remoteSession(id: String) async throws -> RemoteSessionDTO { try session() }
    func resizeRemoteSession(id: String, body: RemoteResizeRequest) async throws -> RemoteSessionDTO { try session() }
    func switchRemoteBackend(id: String, body: RemoteBackendRequest) async throws -> RemoteSessionDTO { try session() }
    func heartbeatRemoteSession(id: String) async throws -> RemoteHeartbeatDTO { RemoteHeartbeatDTO(revision: revision, state: "ready") }
    func reportRemotePresented(id: String, body: RemotePresentedRequest) async throws -> RemotePresentedDTO {
        RemotePresentedDTO(accepted: true, reason: nil, revision: revision)
    }
    func releaseRemoteSession(id: String) async throws -> RemoteReleaseDTO { RemoteReleaseDTO(released: true, errors: []) }
    func typeRemoteText(id: String, body: RemoteTextRequest) async throws -> RemoteTextDTO {
        if let sendID = body.id, !typedIDs.insert(sendID).inserted {
            return RemoteTextDTO(typed: true, chars: body.text.unicodeScalars.count, replayed: true)
        }
        let text = body.text
        await MainActor.run { log.type(text) }
        return RemoteTextDTO(typed: true, chars: text.unicodeScalars.count)
    }
}
#endif
