import Darwin
import Foundation
import OSLog

/// TAIL-2 P0-0 (c). The name the system resolver gives a tailnet address.
///
/// People copy a computer's 100.x out of the Tailscale app. ATS will not let
/// this app reach an address literal outside the private ranges, but with
/// Tailscale on, MagicDNS (100.100.100.100) answers the reverse lookup with the
/// machine's `*.ts.net` name — which ATS does let through — so the address is
/// dialled by that name instead.
protocol TailnetNameResolving: Sendable {
    /// The PTR answer for `address`, or `nil` when there is none in time.
    func reverseName(of address: String) async -> String?
    /// TAIL-2 P0-0 (b). The addresses the system resolver gives a bare name —
    /// through the tailnet's search domain, a 100.x — empty when there are
    /// none in time.
    func forwardAddresses(of name: String) async -> [String]
}

/// `getnameinfo(NI_NAMEREQD)` on a background thread, given at most
/// `timeout` seconds; a lookup still running then is abandoned, not awaited.
struct SystemTailnetNameResolver: TailnetNameResolving {
    var timeout: Duration = .seconds(3)

    func reverseName(of address: String) async -> String? {
        await bounded(nil) { Self.lookup(address) }
    }

    func forwardAddresses(of name: String) async -> [String] {
        await bounded([]) { Self.addresses(name) }
    }

    /// `work` on a background queue, or `fallback` once `timeout` has passed;
    /// a lookup still running then is abandoned, not awaited.
    private func bounded<T: Sendable>(_ fallback: T, _ work: @escaping @Sendable () -> T) async -> T {
        let once = Once()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = work()
                if once.claim() { continuation.resume(returning: answer) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: fallback) }
            }
        }
    }

    /// `getaddrinfo` for a name, every answer as a numeric address.
    static func addresses(_ name: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var values: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, entry.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if !value.isEmpty, !values.contains(value) { values.append(value) }
                }
            }
            cursor = entry.pointee.ai_next
        }
        return values
    }

    static func lookup(_ address: String) -> String? {
        var storage = sockaddr_storage()
        let length: socklen_t
        if address.contains(":") {
            var value = sockaddr_in6()
            value.sin6_family = sa_family_t(AF_INET6)
            value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            guard inet_pton(AF_INET6, address, &value.sin6_addr) == 1 else { return nil }
            withUnsafeBytes(of: value) { bytes in
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: bytes) }
            }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            var value = sockaddr_in()
            value.sin_family = sa_family_t(AF_INET)
            value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            guard inet_pton(AF_INET, address, &value.sin_addr) == 1 else { return nil }
            withUnsafeBytes(of: value) { bytes in
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: bytes) }
            }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        let name = String(cString: host)
        return name.isEmpty ? nil : name
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

/// TAIL-2. Which way a host typed by hand went, one line each, for `log show`
/// (subsystem `app.omodachi`, category `pair.manual`) and Settings' copyable
/// diagnostics. Names only: a typed address and the name it became.
enum ManualHostTrace {
    private static let log = Logger(subsystem: "app.omodachi", category: "pair.manual")

    static func note(_ line: String) {
        log.notice("manual-host \(line, privacy: .public)")
        SSHConnectionTrace.transcript.append(DiagnosticsTranscript.stamp() + " manual-host " + line)
    }
}
