// lint:host-words — operator-run harness values, never drawn as copy.
import Foundation

/// Explicit simulator operator instrumentation, disabled without launch flags.
/// It observes the real media path. No profile, credential, frame or pairing is
/// injected. PINs go only to a private on-device file and are masked in this
/// operator's UI so XCTest screenshots/logs cannot retain the code.
@MainActor enum RemoteOperatorSupport {
    private static var started = false
    private static var profileID: UUID?
    private static var receipt: [String: Any] = [:]
    static var enabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--remote-operator")
        #else
        return false
        #endif
    }
    static var phase: String { argument("--remote-operator-phase=") ?? "" }
    static var masksPIN: Bool { enabled }
    /// INPUT-2: repeat INPUT-1's landing measurement from the client. The host
    /// advertises pen/touch, so a direct-touch tap goes to the fork's touch
    /// node, and `hyprctl cursorpos` does not follow a touchscreen. This asks
    /// the client to take the absolute-pointer path instead. Operator-only.
    static var forcesAbsolutePointer: Bool {
        enabled && ProcessInfo.processInfo.arguments.contains("--remote-operator-absolute-pointer")
    }
    /// GEST-1. Three-finger swipes and pinches cannot be synthesized on this
    /// runtime (XCUITest will not compute coordinates for a multi-finger
    /// gesture; the simulator's HID injection serialises the touches). So an
    /// operator run asks the picture to replay one *through the real arbiter*
    /// — the same state machine, the same registration check, the same alias
    /// — once the first frame is up. Operator-only: DEBUG, Simulator, and an
    /// explicit launch argument. Nothing on the product path reads this.
    static var gesture: Int? {
        guard enabled, let raw = argument("--remote-operator-gesture=") else { return nil }
        switch raw {
        case "workspace_next": return 2
        case "workspace_previous": return 3
        case "scratchpad": return 4
        case "full_screen": return 5
        default: return nil
        }
    }
    /// STREAM-1. A preset walk on one real session, so the host's `remote
    /// status` can be sampled at every row and the picture captured at each:
    /// `--remote-operator-stream=performance:25,balanced:25,quality:25`,
    /// `custom@30/30000:25`, or `auto:120` (hold 自动 while the operator
    /// shapes the link). The first entry is chosen before the session is
    /// created; each later one is chosen in place after the previous entry's
    /// seconds. Operator-only: DEBUG, Simulator, explicit launch argument.
    static var streamSequence: [(choice: RemoteStreamChoice, seconds: Int)] {
        guard enabled, let raw = argument("--remote-operator-stream=") else { return [] }
        return raw.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let seconds = Int(parts[1]), seconds > 0 else { return nil }
            var choice = RemoteStreamChoice()
            let name = parts[0].split(separator: "@")
            guard let preset = RemoteStreamPreset(rawValue: String(name[0])) else { return nil }
            choice.preset = preset
            if name.count == 2 {
                let rate = name[1].split(separator: "/").compactMap { Int($0) }
                guard rate.count == 2 else { return nil }
                choice.customFPS = rate[0]
                choice.customBitrateKbps = rate[1]
            }
            return (choice, seconds)
        }
    }
    private static var expectedHost: String { argument("--remote-operator-host=") ?? "" }
    private static func argument(_ prefix: String) -> String? {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteOperator", isDirectory: true)
    }
    @discardableResult static func begin(profile: HostProfile) -> Bool {
        guard enabled else { return false }
        guard !started else { return authorized(profile) }
        started = true
        receipt = ["operator_id": UUID().uuidString, "phase": phase, "started_at_epoch": Date().timeIntervalSince1970,
                   "method": "XCTest-operated existing native App", "visually_confirmed": false]
        removePIN()
        guard !profile.mock, !expectedHost.isEmpty, profile.hostname == expectedHost,
              ["pair", "stream"].contains(phase) else {
            receipt["status"] = "refused_profile_or_phase"; saveReceipt(); return false
        }
        profileID = profile.id
        receipt["host"] = profile.hostname; receipt["profile_id"] = profile.id.uuidString
        receipt["status"] = "initialized"; saveReceipt()
        return true
    }
    static func authorized(_ profile: HostProfile) -> Bool {
        enabled && started && !profile.mock && profile.id == profileID && profile.hostname == expectedHost
    }
    static func observe(_ event: [String: Any], profile: HostProfile?) {
        guard let profile, authorized(profile), let type = event["type"] as? String else { return }
        receipt["last_event"] = type
        receipt["generation"] = event["generation"]
        receipt["lease_serial"] = event["lease_serial"]
        switch type {
        case "pin":
            guard phase == "pair", let pin = event["pin"] as? String,
                  pin.count == 4, pin.allSatisfy(\.isNumber) else { return }
            let now = Date().timeIntervalSince1970
            write(["pin": pin, "created_at_epoch": now, "client_wait_deadline_epoch": now + 150,
                   "operator_id": receipt["operator_id"] ?? "", "host": profile.hostname,
                   "profile_id": profile.id.uuidString], name: "pin.json")
            receipt["status"] = "awaiting_sunshine_approval"
        case "paired": receipt["status"] = "paired"; receipt["paired"] = true; removePIN()
        case "unpaired": receipt["status"] = "pairing_required"; receipt["paired"] = false
        case "decoded_format":
            receipt["status"] = "decoded"
            receipt["decoded"] = ["width": event["width"] ?? 0, "height": event["height"] ?? 0, "format": event["format"] ?? 0]
        case "first_frame", "frame_observation":
            receipt["status"] = "displayed_buffer_observed"
            receipt["presentation"] = event
            receipt["visually_confirmed"] = false
        case "stopped": receipt["status"] = "stopped"; receipt["stop"] = event; removePIN()
        case "error", "stop_failed": receipt["status"] = type; receipt["message"] = event["message"]; removePIN()
        default: receipt["status"] = type
        }
        saveReceipt()
    }
    static func controlFailure(_ fields: [String: Any]) {
        guard enabled, started else { return }
        receipt["control_failure"] = fields; receipt["status"] = "control_request_failed"; saveReceipt()
    }
    private static func removePIN() { try? FileManager.default.removeItem(at: directory.appendingPathComponent("pin.json")) }
    private static func saveReceipt() {
        receipt["updated_at_epoch"] = Date().timeIntervalSince1970
        write(receipt, name: "receipt.json")
    }
    private static func write(_ value: [String: Any], name: String) {
        guard enabled else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var folder = directory; var options = URLResourceValues(); options.isExcludedFromBackup = true; try folder.setResourceValues(options)
            let file = directory.appendingPathComponent(name)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Operator logging must not alter real application behavior. */ }
    }
}
