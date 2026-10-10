import Foundation

/// SETTINGS-LAYOUT-1, simulator UI runs only (`--ui-testing --settings-fixture`):
/// the two SSH fingerprints a paired host would report, so the long-value rows
/// of Diagnostics can be drawn (and their layout checked) without a host. The
/// values are synthetic and belong to no key; the host's line differs from
/// this device's on purpose, so the red "not this device's key" case shows.
enum SettingsFixture {
    static var requested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--settings-fixture")
        #else
        return false
        #endif
    }

    static var sshKey: SSHKeyReport? {
        guard requested else { return nil }
        return SSHKeyReport(deviceID: "fixture-device", // non-copy: a fixture id
                            localFingerprint: "SHA256:c2V0dGluZ3MtbGF5b3V0LTEtbG9jYWwta2V5LWZpeHR1cmU", // non-copy: synthetic
                            hostFingerprints: ["SHA256:c2V0dGluZ3MtbGF5b3V0LTEtaG9zdC1rZXktZml4dHVyZQ"]) // non-copy: synthetic
    }
}
