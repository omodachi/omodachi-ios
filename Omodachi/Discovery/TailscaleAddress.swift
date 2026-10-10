import Foundation
import UIKit

/// TAIL-3b. Is Tailscale up on *this* device right now?
///
/// Omodachi cannot see the Tailscale app. What it can see is whether a tunnel
/// interface (`utun*`) carries an address in Tailscale's ranges — 100.64.0.0/10
/// or fd7a:115c:a1e0::/48. That is a hint for the first screen and for one
/// sentence when a Tailscale host does not answer; it never decides where to
/// dial and never blocks a button.
enum TailscaleAddress {
    /// The interface names and addresses this device has now. Injectable so a
    /// test can say "on" or "off" without a VPN.
    nonisolated(unsafe) static var interfaces: () -> [(name: String, address: String)] = systemInterfaces

    static var isUp: Bool { isUp(interfaces()) }

    /// Tailscale for iOS on the App Store (Tailscale Inc., `io.tailscale.ipn.ios`;
    /// id checked 2026-10-01 against the iTunes lookup API).
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id1470499037")!

    static func isUp(_ list: [(name: String, address: String)]) -> Bool {
        list.contains { $0.name.hasPrefix("utun") && HostRoads.isTailnetAddress($0.address) }
    }

    static func systemInterfaces() -> [(name: String, address: String)] {
        #if DEBUG && targetEnvironment(simulator)
        // The simulator shares the Mac's interfaces, so it always "has" the
        // Mac's Tailscale; this shows the screens of a device that does not
        // (S01, E01) without touching the Mac's Tailscale.
        if ProcessInfo.processInfo.arguments.contains("--tailscale-off") { return [] }
        #endif
        var result: [(name: String, address: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // An IPv6 link-local carries a `%utunN` scope; the prefix is what matters.
            let bare = text.split(separator: "%").first.map(String.init) ?? text
            result.append((String(cString: entry.pointee.ifa_name), bare))
        }
        return result
    }
}

/// TAIL-3b W01. Whether "Look on this Wi-Fi" has been pressed on this device:
/// after that iOS has asked its one question, and the Wi-Fi road opens on the
/// list rather than on the explanation.
enum LanSearchMemory {
    static let storageKey = "omodachi.lanSearchStarted.v1"
    static var started: Bool {
        get { AppDefaults.shared.bool(forKey: storageKey) }
        set { AppDefaults.shared.set(newValue, forKey: storageKey) }
    }
}

/// The device word the onboarding copy puts in "this iPhone" / "this iPad".
/// A product name, so it is the same in both languages and not in the catalog.
enum DeviceWord {
    @MainActor static var current: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" // non-copy: product names
    }
}
