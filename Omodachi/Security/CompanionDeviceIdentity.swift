import Foundation

/// REMOTE-PAIR-1. The id this device pairs under, kept where the rest of its
/// identity is kept.
///
/// Until now the id lived only in the app's defaults, while everything else a
/// host knows this device by - the companion credential, the Moonlight client
/// certificate, the SSH key - lives in the Keychain. The Keychain outlives the
/// app; the defaults do not. So a reinstall came back holding the old
/// credential (adopted without a pairing, PAIR-4) but with a freshly minted
/// id, and the two disagreed from then on. Nothing showed it until the next
/// time the device paired: the request went up under the new id, the host saw
/// a new device, and Remote refused the phone's own certificate because it was
/// bound to the old one. That is Leo's iPhone, 2026-09-24 → 2026-10-05.
///
/// So: the id is read from the Keychain first (`ThisDeviceOnly`, like the
/// credential), mirrored into the defaults for the readers that only look
/// there, and - whenever this device proves it holds a live credential - set
/// to the id that credential was issued to. The host's registry is the
/// authority on which id this device is.
enum CompanionDeviceIdentity {
    static let defaultsKey = "omodachi.deviceID.v1"
    static let service = "app.omodachi.device-identity"
    static let account = "device-id"

    /// The id, minting one only when neither store has it.
    static func current(defaults: UserDefaults = AppDefaults.shared,
                        keychain: (any KeychainRecordStore)? = Self.systemKeychain()) -> String {
        if let value = stored(defaults: defaults, keychain: keychain) {
            mirror(value, defaults: defaults, keychain: keychain)
            return value
        }
        let value = "ios-" + UUID().uuidString.lowercased()
        mirror(value, defaults: defaults, keychain: keychain)
        return value
    }

    /// The id without minting one: the Keychain's, else the defaults'.
    static func stored(defaults: UserDefaults = AppDefaults.shared,
                       keychain: (any KeychainRecordStore)? = Self.systemKeychain()) -> String? {
        if let keychain, let data = try? keychain.load(service: service, account: account),
           let value = String(data: data, encoding: .utf8), PairingClient.validDeviceID(value) {
            return value
        }
        if let value = defaults.string(forKey: defaultsKey), PairingClient.validDeviceID(value) { return value }
        return nil
    }

    /// The device id a credential this host issued names, read from the
    /// credential's own payload (`base64url(json).signature`). It is this
    /// device's own secret, so nothing here is verified - the host does that
    /// on every request - and anything that does not read cleanly is `nil`.
    static func deviceID(inCredential token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count <= 4096 else { return nil }
        var body = String(parts[0]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while body.utf8.count % 4 != 0 { body += "=" }
        struct Payload: Decodable { let device_id: String }
        guard let data = Data(base64Encoded: body),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              PairingClient.validDeviceID(payload.device_id) else { return nil }
        return payload.device_id
    }

    /// Make this device's id the one its live credential was issued to.
    /// Returns the id when it changed, `nil` otherwise.
    @discardableResult
    static func adopt(credential token: String, defaults: UserDefaults = AppDefaults.shared,
                      keychain: (any KeychainRecordStore)? = Self.systemKeychain()) -> String? {
        guard let issued = deviceID(inCredential: token),
              issued != stored(defaults: defaults, keychain: keychain) else { return nil }
        mirror(issued, defaults: defaults, keychain: keychain)
        return issued
    }

    private static func mirror(_ value: String, defaults: UserDefaults, keychain: (any KeychainRecordStore)?) {
        if defaults.string(forKey: defaultsKey) != value { defaults.set(value, forKey: defaultsKey) }
        guard let keychain else { return }
        let held = (try? keychain.load(service: service, account: account)).flatMap { $0 }
        if held != Data(value.utf8) { try? keychain.save(Data(value.utf8), service: service, account: account) }
    }

    /// The real Keychain, except in a UI-test launch: that run's defaults are a
    /// suite wiped at startup (`AppDefaults`), and an id that survived in the
    /// simulator's Keychain would make it remember a device it never paired.
    static func systemKeychain() -> (any KeychainRecordStore)? {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return nil }
        // A unit-test run reads and writes its own in-memory store instead.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        #endif
        return SystemKeychainRecordStore.shared
    }
}
