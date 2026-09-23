import Foundation

/// The Remote choices that belong to this device (N-27).
///
/// The host owns quality, dynamic resolution and its own default backend; this
/// owns what the entry screen should be pre-set to on *this* iPad. `.auto` is
/// the point of Study 03's open question 5: a client with no opinion asks
/// `capabilities.default_backend` instead of hard-coding one and disagreeing
/// with the host forever.
enum RemoteBackendChoice: String, CaseIterable, Sendable {
    case auto, sunshine, vnc

    var title: String {
        switch self {
        case .auto: Strings.remoteBackendChoiceAuto
        case .sunshine: "Sunshine"
        case .vnc: "VNC"
        }
    }

    func resolve(_ capabilities: RemoteCapabilitiesDTO?) -> RemoteBackend {
        switch self {
        case .sunshine: .sunshine
        case .vnc: .vnc
        case .auto: capabilities?.resolvedDefault ?? .sunshine
        }
    }
}

/// Where the extra screen sits next to the physical one, and which long edge
/// the host's own bar moves to during a takeover.
struct RemotePreferences: Equatable, Sendable {
    var mode: RemoteMode = .extend
    var backend: RemoteBackendChoice = .auto
    var placement: RemotePlacement = .right
    /// `nil` = follow this device's own bar edge.
    var takeoverBarEdge: HostBarPosition?

    static let storageKey = "omodachi.remotePreferences.v1"

    static func load(_ defaults: UserDefaults = AppDefaults.shared) -> RemotePreferences {
        var value = RemotePreferences()
        guard let stored = defaults.dictionary(forKey: storageKey) else { return value }
        if let raw = stored["mode"] as? String, let mode = RemoteMode(rawValue: raw) { value.mode = mode }
        if let raw = stored["backend"] as? String, let backend = RemoteBackendChoice(rawValue: raw) { value.backend = backend }
        if let raw = stored["placement"] as? String, let placement = RemotePlacement(rawValue: raw) { value.placement = placement }
        if let raw = stored["takeoverBarEdge"] as? String { value.takeoverBarEdge = HostBarPosition(rawValue: raw) }
        return value
    }

    func save(_ defaults: UserDefaults = AppDefaults.shared) {
        var stored: [String: String] = ["mode": mode.rawValue, "backend": backend.rawValue,
                                        "placement": placement.rawValue]
        if let takeoverBarEdge { stored["takeoverBarEdge"] = takeoverBarEdge.rawValue }
        defaults.set(stored, forKey: Self.storageKey)
    }
}
