import Combine
import Foundation
import Network

/// LINKS-1. The one place a tapped link goes — from an Agent message, a tool
/// row, the Herdr mirror or the SSH panel.
///
/// * A web address opens in the Safari view over the app; the app is never
///   left (ATTACH-2 image 02 showed the old tap leaving for Safari).
/// * The computer's own page (`localhost:5173`, its own name or address) is
///   rewritten to the road this phone uses for it and tried first: a dev
///   server listening only on loopback cannot be reached from the phone, and
///   that is said in one sentence, with "Open on the computer" beside it.
/// * A file opens **on the computer** (`POST /v1/host/open`) and the app goes
///   to Remote to show it — no file bytes ever leave the host (Leo, 2026-10-04:
///   "我们有 Remote 啊").
///
/// Nothing in here knows about views: the Shell hands in how to present the
/// Safari view and how to start and show Remote (`Hooks`).
@MainActor final class LinkOpener: ObservableObject {
    struct Notice: Equatable, Identifiable, Sendable {
        enum Kind: Equatable, Sendable { case working, info, problem }
        /// "Open on the computer" for a page the phone could not reach.
        struct Offer: Equatable, Sendable {
            let url: String
            let source: LinkSource
        }
        let id = UUID()
        let at = Date()
        var kind: Kind
        var text: String
        var offer: Offer?
    }

    /// The Shell's half: everything that draws or navigates.
    struct Hooks {
        var client: @MainActor () -> (any HostOpening)? = { nil }
        var roads: @MainActor () -> HostLocalLinks = { HostLocalLinks() }
        var presentWeb: @MainActor (URL) -> Void = { _ in }
        var routeApp: @MainActor (URL) -> Void = { _ in }
        var openSystem: @MainActor (URL) -> Void = { _ in }
        var hasRemoteSession: @MainActor () -> Bool = { false }
        /// Whether this device starts Remote in extend mode when asked to.
        var extendIsDefault: @MainActor () -> Bool = { true }
        /// Start Remote in the remembered mode; false when it could not start.
        var startRemote: @MainActor () -> Bool = { false }
        /// True once the host has accepted the session (it has its own screen).
        var waitForRemote: @MainActor (Duration) async -> Bool = { _ in false }
        var showRemotePanel: @MainActor () -> Void = {}
        var showPicture: @MainActor () -> Void = {}
    }

    @Published private(set) var notice: Notice? {
        didSet {
            // A result that needs nothing more ("It's open on the computer's
            // screen") goes by itself; a refusal stays until it is read.
            guard let notice, notice.kind == .info else { return }
            let id = notice.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?.notice?.id == id { self?.notice = nil }
            }
        }
    }
    var hooks = Hooks()
    /// `true` when `host:port` answered a TCP connect within the time.
    var probe: @Sendable (String, Int) async -> Bool = { host, port in await PortProbe.reachable(host: host, port: port) }
    /// How long Remote gets to come up before the file is opened anyway.
    var remoteWait: Duration = .seconds(20)
    private var task: Task<Void, Never>?
    private var lastOpen: (target: LinkTarget, at: Date)?

    func dismiss() { notice = nil }

    /// Another panel came up: what a link in the last one left behind is not
    /// about this one. Work still in flight keeps its line.
    func panelChanged(now: Date = Date()) {
        guard let notice, notice.kind != .working else { return }
        // The opener itself just moved to the Remote panel and said why; that
        // move arrives here a frame later and must not take the line with it.
        if now.timeIntervalSince(notice.at) < 1 { return }
        self.notice = nil
    }

    /// A link a SwiftUI `Text` handed to `openURL`.
    func open(url: URL, from source: LinkSource) {
        guard let target = LinkCarrier.target(from: url) else {
            LinkTrace.dropped("unrecognised", source: source)
            return
        }
        open(target, from: source)
    }

    func open(_ target: LinkTarget, from source: LinkSource) {
        // One tap can reach here twice (SwiftTerm's own link tap and ours on
        // an iPad with a pointer); the second is the same tap, not a request.
        let now = Date()
        if let last = lastOpen, last.target == target, now.timeIntervalSince(last.at) < 0.8 {
            LinkTrace.dropped("same-tap", source: source)
            return
        }
        lastOpen = (target, now)
        LinkTrace.note(target: target, source: source)
        switch target {
        case .app(let url): hooks.routeApp(url)
        case .other(let url): hooks.openSystem(url)
        case .web(let url): run { await self.openWeb(url, from: source) }
        case .path(let text):
            // SSH: the terminal may be another machine, so a path there is
            // not a file this computer could open.
            guard source != .ssh else { LinkTrace.dropped("path-from-ssh", source: source); return }
            run { await self.openOnComputer(path: text, url: nil, from: source) }
        }
    }

    /// "Open on the computer" beside a page the phone could not reach.
    func openOffer(_ offer: Notice.Offer) {
        run { await self.openOnComputer(path: nil, url: offer.url, from: offer.source) }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { await work() }
    }

    // MARK: - A web address

    private func openWeb(_ url: URL, from source: LinkSource) async {
        guard let rewritten = hooks.roads().rewrite(url) else {
            notice = nil
            hooks.presentWeb(url)
            return
        }
        notice = Notice(kind: .working, text: Strings.linkReaching)
        let port = rewritten.port ?? (rewritten.scheme?.lowercased() == "https" ? 443 : 80)
        let reachable = await probe(rewritten.host ?? "", port)
        guard !Task.isCancelled else { return }
        if reachable {
            notice = nil
            hooks.presentWeb(rewritten)
        } else {
            // The words do not ask anyone to change their agent: whether a dev
            // server listens beyond the computer is the person's call (Leo,
            // 2026-10-04 — no prompt injection).
            let offer = source.wire == nil ? nil : Notice.Offer(url: url.absoluteString, source: source)
            notice = Notice(kind: .problem, text: Strings.linkComputerOnly, offer: offer)
        }
    }

    // MARK: - A file (or a page) on the computer

    private func openOnComputer(path: String?, url: String?, from source: LinkSource) async {
        guard let wire = source.wire else { LinkTrace.dropped("no-source", source: source); return }
        guard let client = hooks.client() else {
            LinkTrace.dropped("no-client", source: source)
            notice = Notice(kind: .problem, text: Strings.linkNoComputer)
            return
        }
        notice = Notice(kind: .working, text: Strings.linkOpeningOnComputer)
        let request = HostOpenRequest(source: wire, path: path, url: url)
        do {
            var check = request
            check.check = true
            _ = try await client.hostOpen(check)
            guard !Task.isCancelled else { return }
            if hooks.hasRemoteSession() {
                _ = try await client.hostOpen(request)
                notice = nil
                hooks.showPicture()
            } else {
                // The file waits for Remote's own screen: opened before it, it
                // would land on the computer's own screen, where nobody is
                // looking. Takeover is a choice made at its card, with its own
                // confirmation, so a link never starts it; and a Remote that
                // could not start (Sunshine not paired yet, someone else in a
                // session, 20 s) opens nothing — the person is left on the
                // Remote panel, which says what it needs, and taps again.
                let started = hooks.extendIsDefault() && hooks.startRemote()
                if started, await hooks.waitForRemote(remoteWait) {
                    guard !Task.isCancelled else { return }
                    _ = try await client.hostOpen(request)
                    notice = nil
                } else {
                    hooks.showRemotePanel()
                    notice = Notice(kind: .problem, text: Strings.linkStartRemoteFirst)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            notice = Notice(kind: .problem, text: Self.message(error))
        }
    }

    static func message(_ error: Error) -> String {
        if let refusal = error as? HostOpenError {
            return ReasonText.message(refusal.code, domain: .host, status: refusal.status)
        }
        if let host = error as? CompanionHostError { return host.errorDescription ?? Strings.linkNoComputer }
        return Strings.linkNoComputer
    }
}

/// Whether anything answers on `host:port` from here: a bare TCP connect, no
/// request. `Network` is not under App Transport Security, so a tailnet
/// address literal can be tried even though the app never dials one itself.
enum PortProbe {
    static func reachable(host: String, port: Int, timeout: Duration = .milliseconds(2500)) async -> Bool {
        guard !host.isEmpty, (1...65535).contains(port),
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let once = ProbeOnce()
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.set(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true)
                // `.waiting` is "refused / no route, will retry": for a probe
                // that is the answer.
                case .failed, .cancelled, .waiting: once.finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: timeout)
                once.finish(false)
            }
        }
        connection.cancel()
        return answer
    }
}

/// The continuation is resumed exactly once, whichever of the state handler
/// and the timer gets there first.
private final class ProbeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    func set(_ value: CheckedContinuation<Bool, Never>) {
        lock.lock(); continuation = value; lock.unlock()
    }
    func finish(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// One line per opened link for the lab and Settings' diagnostics: what kind,
/// from where — never the address or the path itself.
enum LinkTrace {
    static func note(target: LinkTarget, source: LinkSource) {
        let kind = switch target {
        case .web: "web" // non-copy: a log word
        case .path: "path" // non-copy: a log word
        case .app: "app" // non-copy: a log word
        case .other: "other" // non-copy: a log word
        }
        AppLinkTrace.note("open \(kind) from=\(from(source))") // non-copy: a log line
    }

    /// A tap that reached the app and was let go, and why.
    static func dropped(_ why: String, source: LinkSource) {
        AppLinkTrace.note("open dropped=\(why) from=\(from(source))") // non-copy: a log line
    }

    /// Every open's outcome as core answered it (a code, never the path).
    static func outcome(_ step: String, _ value: String) {
        AppLinkTrace.note("open \(step)=\(value)") // non-copy: a log line
    }

    private static func from(_ source: LinkSource) -> String {
        switch source {
        case .agent: "agent" // non-copy: a log word
        case .herdr: "herdr" // non-copy: a log word
        case .ssh: "ssh" // non-copy: a log word
        }
    }
}
