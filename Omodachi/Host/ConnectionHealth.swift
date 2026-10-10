import Foundation
import Network
import UIKit

/// HERDR-11 §3. One honest connection clock for the whole app.
///
/// Before this the bar, ① and each panel had their own idea of "connected",
/// and a socket that died without a goodbye kept its last frame looking live.
/// Now everything that proves the host is there — a frame on the event socket,
/// a pong to the two-second beat ping, a state read — stamps one time, and the
/// rest is arithmetic (Collie's `connection-health`):
///
/// - nothing for **4 s** → amber, "Reconnecting…" (not latched: the next
///   proof turns it back);
/// - nothing for **15 s** → red, naming the real cause: this phone has no
///   network, or the computer cannot be reached. (Herdr not running is the
///   Herdr panel's own third cause: the host answers, Herdr does not.)
///
/// The network path decides only the *words*, never liveness: a phone can be
/// on Wi-Fi and still not reach the computer.
enum ConnectionHealth: Equatable, Sendable {
    case live
    case trouble
    case lost(Cause)

    enum Cause: Equatable, Sendable {
        /// This phone or iPad has no network at all.
        case deviceOffline
        /// The network is there; the computer does not answer.
        case hostUnreachable
        /// The computer answers; Herdr on it does not (Herdr panel only).
        case herdrDown
    }

    static let troubleAfter: TimeInterval = 4
    static let lostAfter: TimeInterval = 15

    /// `since` is the last proof of life, or when the connection was first
    /// wanted if there has been none yet.
    static func judge(now: Date, since: Date, pathSatisfied: Bool) -> ConnectionHealth {
        let silence = now.timeIntervalSince(since)
        if silence >= lostAfter { return .lost(pathSatisfied ? .hostUnreachable : .deviceOffline) }
        if silence >= troubleAfter { return .trouble }
        return .live
    }

    var isLive: Bool { self == .live }

    /// The words a person reads, with the computer's name in them.
    @MainActor func message(host: String) -> String? {
        switch self {
        case .live: nil
        case .trouble: Strings.connectionReconnecting
        case .lost(.deviceOffline): Strings.connectionDeviceOffline(ConnectionHealth.deviceWord)
        case .lost(.hostUnreachable): Strings.connectionHostUnreachable(host)
        case .lost(.herdrDown): Strings.connectionHerdrDown(host)
        }
    }

    /// "iPhone" or "iPad": product names, the same in every language.
    @MainActor static var deviceWord: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" // non-copy: product names
    }
}

/// HERDR-11 §3: whether this device has a network path at all, and when it
/// comes back. `NWPathMonitor` decides wording and the moment to reconnect,
/// never whether the host is alive.
@MainActor final class NetworkPathWatcher {
    private(set) var satisfied = true
    private(set) var interfaces: Set<String> = []
    /// Called on the main actor when the path becomes usable again, or moves
    /// to another interface (Wi-Fi to cellular).
    var onChange: ((_ satisfied: Bool, _ returned: Bool, _ moved: Bool) -> Void)?
    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            var kinds = Set<String>()
            for kind in [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other, .loopback]
            where path.usesInterfaceType(kind) {
                kinds.insert(String(describing: kind))
            }
            Task { @MainActor [weak self] in self?.update(satisfied: satisfied, interfaces: kinds) }
        }
        monitor.start(queue: DispatchQueue(label: "app.omodachi.path")) // non-copy: a queue label
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// Internal so a test can drive it without a radio.
    func update(satisfied: Bool, interfaces: Set<String>) {
        let returned = satisfied && !self.satisfied
        let moved = satisfied && self.satisfied && !self.interfaces.isEmpty && interfaces != self.interfaces
        self.satisfied = satisfied
        self.interfaces = interfaces
        onChange?(satisfied, returned, moved)
    }
}

/// HERDR-11 §3, simulator UI runs only (`--ui-testing --connection-fixture
/// <trouble|offline|unreachable>`): the clock held in one state, so the
/// banner, the bar's dot and the dimmed mirror can be looked at.
enum ConnectionHealthFixture {
    static var forced: ConnectionHealth? {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"), let index = arguments.firstIndex(of: "--connection-fixture"),
              index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "trouble": return .trouble
        case "offline": return .lost(.deviceOffline)
        case "unreachable": return .lost(.hostUnreachable)
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
