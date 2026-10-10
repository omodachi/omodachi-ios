import Foundation
import OSLog

/// TAIL-3b I1. The one way into the app from outside: a universal link to
/// `https://omodachi.app/open/<target>?host=<host_id>` (Odomo's Remote
/// and app-only rows, LITE-0 §2) or the same path on the `omodachi://` scheme.
/// LITE-1c: `/open/` and `/open/app` ("Get the app" in Odomo; the site's AASA
/// claims `/open/*`, so with the app installed it lands here) just open the
/// app. NOTIFY-2: `/open/agent?host=` is the Agent panel, and
/// `/open/herdr?host=&session=&pane=` is Herdr on that session with that pane
/// selected — Odomo's "Open in Omodachi", and where a notification tap lands.
/// ODOMO-CARD: every link Odomo hands over also carries `from=odomo`, a flag
/// (`fromOdomo`) that tells the app Odomo is on this device for that host.
///
/// The URL carries a `host_id`, and for Herdr a session name and a pane id in
/// Herdr's own alphabets, and nothing else that is read. The host id is looked
/// up in this device's own paired list and never trusted beyond that: an
/// unknown id is a plain sentence, and a link can never start a pairing or
/// carry an address to dial.
struct AppLink: Equatable, Sendable {
    enum Target: String, Equatable, Sendable {
        /// Panel ③, Remote, on that host.
        case remote
        /// The app on that host (panel ①).
        case host
        /// LITE-1c: the app itself, no host named — `/open/`, `/open/app`.
        case app
        /// NOTIFY-2: panel ③, Agent, on that host.
        case agent
        /// NOTIFY-2: panel ④, Herdr, on that host — and that session and pane
        /// when the link names them.
        case herdr
    }

    let target: Target
    /// `nil` when the link named no host (or one that is not a host id).
    let hostID: String?
    /// NOTIFY-2, Herdr only: core's `herdr_bridge.SESSION_NAME`, else `nil`.
    var session: String? = nil
    /// NOTIFY-2, Herdr only and only with a session: `PANE_ID` (`w1:p2`).
    var pane: String? = nil
    /// ODOMO-CARD: `from=odomo`, and nothing else in `from` means anything.
    var fromOdomo = false

    /// core `herdr_bridge.SESSION_NAME` and `PANE_ID`.
    static func validSession(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil
    }
    static func validPane(_ value: String) -> Bool {
        value.range(of: #"^w[0-9]{1,9}:p[0-9]{1,9}$"#, options: .regularExpression) != nil
    }

    static let webHosts: Set<String> = ["omodachi.app", "www.omodachi.app"]
    static let scheme = "omodachi"

    /// `nil` for a URL that is not one of ours at all.
    static func parse(_ url: URL) -> AppLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return nil }
        let segments: [String]
        switch scheme {
        case "https":
            guard let host = components.host?.lowercased(), webHosts.contains(host) else { return nil }
            segments = components.path.split(separator: "/").map(String.init)
        case Self.scheme:
            // `omodachi://open/remote?host=…`: "open" is the URL's host part.
            segments = [components.host ?? ""].filter { !$0.isEmpty }
                + components.path.split(separator: "/").map(String.init)
        default:
            return nil
        }
        guard segments.first?.lowercased() == "open" else { return nil }
        let target = segments.count > 1 ? Target(rawValue: segments[1].lowercased()) ?? .host : .app
        let item = { (name: String) in components.queryItems?.first { $0.name == name }?.value }
        let host = item("host")?.lowercased()
        var link = AppLink(target: target, hostID: host.flatMap { HostPin.validHostID($0) ? $0 : nil })
        link.fromOdomo = item("from")?.lowercased() == "odomo"
        if target == .herdr, let session = item("session"), validSession(session) {
            link.session = session
            if let pane = item("pane"), validPane(pane) { link.pane = pane }
        }
        return link
    }

    enum Resolution: Equatable {
        case open(PairedHostRecord, Target)
        /// No host id, or one this device is not paired with.
        case unknownHost
        /// LITE-1c: open the app as it is; nothing to switch, nothing to say.
        case home
    }

    /// Only this device's own records answer; a link with no host id opens
    /// the host already on screen when there is one.
    func resolve(records: [PairedHostRecord], current: String?) -> Resolution {
        if target == .app { return .home }
        if let hostID {
            guard let record = records.first(where: { $0.hostID == hostID }) else { return .unknownHost }
            return .open(record, target)
        }
        if let current, let record = records.first(where: { HostAccount.canonical($0.account) == HostAccount.canonical(current) }) {
            return .open(record, target)
        }
        return records.count == 1 ? .open(records[0], target) : .unknownHost
    }
}

/// One line per link, for the lab and Settings' diagnostics: which target,
/// and the last six of the host id — never the whole URL.
enum AppLinkTrace {
    private static let log = Logger(subsystem: "app.omodachi", category: "link")
    static func note(_ line: String) {
        log.notice("\(line, privacy: .public)")
        SSHConnectionTrace.transcript.append(DiagnosticsTranscript.stamp() + " " + line)
    }
}
