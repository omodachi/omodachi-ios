import Foundation

/// LINKS-1. What a link in agent output is, where it was seen, and how it is
/// recognised in plain text.
///
/// Leo, 2026-10-04: "如果是 URL，因为在 Tailscale / 内网，我们可以直接作为链接
/// 打开；如果是文件，我们可以跳转到 Remote 里打开." A web address opens on the
/// phone, in the Safari view over the app; a file opens *on the computer* and
/// the app shows it through Remote. Nothing here reads a file.

/// Where a link was seen. Core only opens a path that really appeared there
/// (`POST /v1/host/open`'s "mentioned" rule), so the source travels with it.
enum LinkSource: Equatable, Sendable {
    /// An Agent row: a message, or a tool row's `paths`.
    case agent(item: String)
    /// A pane of the Herdr session this device is looking at.
    case herdr(pane: String, session: String?)
    /// The SSH panel. Its target may not even be this computer, so only web
    /// addresses open from it.
    case ssh

    /// The `source` object of `POST /v1/host/open`; nil for SSH.
    var wire: HostOpenSourceWire? {
        switch self {
        case .agent(let item): HostOpenSourceWire(kind: "agent", item: item, pane: nil, session: nil)
        case .herdr(let pane, let session): HostOpenSourceWire(kind: "herdr", item: nil, pane: pane, session: session)
        case .ssh: nil
        }
    }
}

enum LinkTarget: Equatable, Sendable {
    /// `http`/`https`.
    case web(URL)
    /// A path as it appeared — `/home/u/x.md:12`, `~/x.png`, `./out.csv`,
    /// `out.csv` — with any `:line` / `#L12` left on for core to read.
    case path(String)
    /// `omodachi://…` or `https://omodachi.app/open/…`: the app's own routes.
    case app(URL)
    /// Anything else with a scheme (`mailto:`): the system's.
    case other(URL)

    /// A markdown link's target, or a tapped token, as one of the four.
    static func classify(_ raw: String) -> LinkTarget? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096, !value.contains("\0") else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: value) ?? URL(string: value.addingPercentEncoding(
                withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed)) ?? ""),
                  url.host?.isEmpty == false else { return nil }
            return AppLink.parse(url) != nil ? .app(url) : .web(url)
        }
        if lower.hasPrefix("omodachi:") { return URL(string: value).map(LinkTarget.app) }
        if lower.hasPrefix("file://") { return .path(value) }
        if value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") || value.hasPrefix("../") {
            return .path(value)
        }
        if value.hasPrefix("#") || value.hasPrefix("?") { return nil }
        // `mailto:`, `tel:` — a scheme, not a `name.ext:12`.
        if value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]{1,31}:"#, options: .regularExpression) != nil,
           value.range(of: #"^[^:]+\.[A-Za-z0-9]+:[0-9]+"#, options: .regularExpression) == nil {
            return URL(string: value).map(LinkTarget.other)
        }
        // A relative path (`out.csv`, `docs/a.md`) — the agent's own folder.
        guard !value.contains(where: { $0.isWhitespace }) else { return nil }
        return .path(value)
    }
}

/// How a target rides through SwiftUI's `openURL`. A web address is itself; a
/// path becomes `omodachi-link://path?t=<the text>`, a scheme only this app
/// reads, so iOS never tries to open `/home/…` as a file on the phone (which
/// is what it did: "Failed to open URL … invalid input parameters").
enum LinkCarrier {
    static let scheme = "omodachi-link"

    static func url(for target: LinkTarget) -> URL? {
        switch target {
        case .web(let url), .app(let url), .other(let url): return url
        case .path(let text):
            var components = URLComponents()
            components.scheme = scheme
            components.host = "path"
            components.queryItems = [URLQueryItem(name: "t", value: text)]
            return components.url
        }
    }

    static func url(forRaw raw: String) -> URL? { LinkTarget.classify(raw).flatMap(url(for:)) }

    static func target(from url: URL) -> LinkTarget? {
        if url.scheme?.lowercased() == scheme {
            guard url.host == "path",
                  let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "t" })?.value else { return nil }
            return .path(text)
        }
        return LinkTarget.classify(url.absoluteString)
    }
}

/// Addresses and paths in plain text: an agent's prose, a terminal row.
///
/// The rules are core's `contracts/fixtures/links-detect.json` (its `notes`),
/// which Odomo tests against too, so the two clients find the same links in
/// the same row. Left to right, a link starts at the start of the text or
/// right after whitespace or one of `( [ { < " ' ` = ;`, and the first of URL,
/// PATH, BARE that matches there wins. Then trailing `. , ; : ! ?` go, and a
/// trailing `) ] }` with no opener inside the link, repeatedly.
enum LinkDetector {
    struct Match: Equatable {
        enum Kind: String, Equatable { case url, path }
        let range: Range<String.Index>
        let text: String
        let kind: Kind
    }

    /// File extensions a bare name needs before it counts as a file (mirror
    /// only: `README.md`, `out.csv`, not `e.g.` or `v1.2.3`).
    static let extensions: Set<String> = [
        "md", "markdown", "txt", "rst", "org", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "json", "jsonl", "yaml",
        "yml", "toml", "ini", "cfg", "conf", "csv", "tsv", "log", "html", "htm", "css", "scss", "swift", "kt", "java",
        "c", "h", "cc", "cpp", "hpp", "rs", "go", "rb", "php", "lua", "sql", "sh", "zsh", "xml", "svg", "png", "jpg",
        "jpeg", "gif", "webp", "heic", "pdf", "mp4", "mov", "mp3", "wav", "zip", "gz", "ipynb", "lock", "diff", "patch",
    ]

    private static let openers: Set<Character> = ["(", "[", "{", "<", "\"", "'", "`", "=", ";"]

    /// Every link in `text`, in order, never overlapping. `bareNames` adds
    /// `name.ext` (the Herdr mirror, where codex writes relative names).
    static func detect(in text: String, bareNames: Bool) -> [Match] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        var offsets: [String.Index] = []
        offsets.reserveCapacity(chars.count + 1)
        var cursor = text.startIndex
        for _ in chars { offsets.append(cursor); cursor = text.index(after: cursor) }
        offsets.append(text.endIndex)

        var result: [Match] = []
        var index = 0
        while index < chars.count {
            let boundary = index == 0 || chars[index - 1].isWhitespace || openers.contains(chars[index - 1])
            if boundary {
                var found: (length: Int, kind: Match.Kind)?
                if let length = url(chars, at: index) { found = (length, .url) }
                else if let length = path(chars, at: index) { found = (length, .path) }
                else if bareNames, let length = bare(chars, at: index) { found = (length, .path) }
                if let found {
                    let kept = trimmed(chars[index..<(index + found.length)])
                    if kept > 0 {
                        let range = offsets[index]..<offsets[index + kept]
                        result.append(Match(range: range, text: String(text[range]), kind: found.kind))
                        index += kept
                        continue
                    }
                }
            }
            index += 1
        }
        return result
    }

    /// The link that covers character `offset` of `text`, if any.
    static func link(in text: String, at offset: Int, bareNames: Bool = true) -> Match? {
        guard offset >= 0, let index = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex),
              index < text.endIndex else { return nil }
        return detect(in: text, bareNames: bareNames).first { $0.range.contains(index) }
    }

    private static func isAlnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    private static func url(_ chars: [Character], at start: Int) -> Int? {
        for prefix in ["http://", "https://"] {
            let count = prefix.count
            guard start + count < chars.count,
                  String(chars[start..<(start + count)]).lowercased() == prefix else { continue }
            var end = start + count
            while end < chars.count, !chars[end].isWhitespace, !"<>\"'`".contains(chars[end]) { end += 1 } // non-copy: delimiter characters
            return end > start + count ? end - start : nil
        }
        return nil
    }

    private static func path(_ chars: [Character], at start: Int) -> Int? {
        var slash = start
        if chars[start] == "~" { slash = start + 1 }
        else if start + 1 < chars.count, chars[start] == ".", chars[start + 1] == "." { slash = start + 2 }
        else if chars[start] == "." { slash = start + 1 }
        guard slash < chars.count, chars[slash] == "/", slash + 1 < chars.count,
              chars[slash + 1] != "/", !chars[slash + 1].isWhitespace else { return nil }
        var end = slash + 1
        while end < chars.count, isAlnum(chars[end]) || "._~@%+=,/:#-".contains(chars[end]) { end += 1 }
        guard end > slash + 1 else { return nil }
        // A bare `/x` needs another `/` or a `.`: `</b>` and `</script>` in
        // HTML are closing tags, not paths.
        if slash == start, !chars[(slash + 1)..<end].contains(where: { $0 == "/" || $0 == "." }) { return nil }
        return end - start
    }

    private static func bare(_ chars: [Character], at start: Int) -> Int? {
        guard isAlnum(chars[start]) || chars[start] == "_" else { return nil }
        var limit = start + 1
        while limit < chars.count, isAlnum(chars[limit]) || "._-".contains(chars[limit]) { limit += 1 }
        // Longest first, as a greedy regex would backtrack.
        var end = limit
        while end > start + 2 {
            let segment = String(chars[start..<end])
            if let dot = segment.lastIndex(of: "."), segment.index(after: dot) < segment.endIndex,
               extensions.contains(segment[segment.index(after: dot)...].lowercased()) {
                let next = end < chars.count ? chars[end] : " "
                if !(isAlnum(next) || "_/-".contains(next)) { return end - start }
            }
            end -= 1
        }
        return nil
    }

    /// How much of a candidate stays once the sentence's punctuation is off.
    private static func trimmed(_ value: ArraySlice<Character>) -> Int {
        var result = value
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let last = result.last {
            if ".,;:!?".contains(last) { result.removeLast(); continue }
            if let open = pairs[last],
               result.filter({ $0 == last }).count > result.filter({ $0 == open }).count {
                result.removeLast(); continue
            }
            break
        }
        return result.count
    }
}

/// LINKS-1 §1. A page the computer serves to itself — `localhost:5173`, its
/// own name, its own address — is reached from the phone at the road the phone
/// uses for that computer, with the scheme, port and path kept.
struct HostLocalLinks: Equatable, Sendable {
    /// The road this device reaches the host on now.
    var current: HostRoad?
    /// Everything the host says about itself (`GET /v1/host/roads`), kept in
    /// the pin: LAN addresses, `.local` name, MagicDNS name, tailnet addresses.
    var known: [HostRoad] = []
    /// The paired host name, e.g. `omarchy`.
    var hostName: String?

    static func isLoopback(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "0.0.0.0" || host == "::1" || host == "::" || host == "0:0:0:0:0:0:0:1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "127", parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return false
    }

    /// Every spelling of this host: its roads, and the short names a `.local`
    /// or MagicDNS name starts with.
    var names: Set<String> {
        var result = Set<String>()
        func add(_ value: String?) {
            guard let value = value?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]")),
                  !value.isEmpty else { return }
            result.insert(value)
            if value.hasSuffix(".local") || HostRoads.isMagicDNSName(value),
               let first = value.split(separator: ".").first {
                result.insert(String(first))
            }
        }
        for road in known { add(road.host) }
        add(current?.host)
        add(hostName)
        return result
    }

    func isHostLocal(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        return Self.isLoopback(host) || names.contains(host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]")))
    }

    /// The address this device should use for a host-local URL, or nil when
    /// the URL is not the host's own (or there is no road to rewrite to).
    ///
    /// Plain `http` prefers an address literal when there is one: there is no
    /// name to look up and nothing a browser could decide to try over
    /// `https://` first. (Measured on iOS 27: `http://<name>.ts.net:8765` does
    /// load in the Safari view; the address is simply the shorter road.)
    func rewrite(_ url: URL) -> URL? {
        guard isHostLocal(url), let current, var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let plain = url.scheme?.lowercased() == "http"
        let host = plain ? literalHost(for: current) : current.host
        if host.contains(":") {
            components.percentEncodedHost = "[" + host + "]"
        } else {
            components.host = host
        }
        return components.url
    }

    private func literalHost(for current: HostRoad) -> String {
        if Self.isAddressLiteral(current.host) { return current.host }
        let roads = known + [current]
        if current.kind == .tailnet {
            if let ipv4 = roads.first(where: { HostRoads.isTailnetIPv4($0.host) }) { return ipv4.host }
            return current.host
        }
        if let lan = roads.first(where: { $0.kind == .lan && Self.isIPv4($0.host) && !HostRoads.isTailnetIPv4($0.host) }) {
            return lan.host
        }
        return current.host
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    static func isAddressLiteral(_ host: String) -> Bool { isIPv4(host) || host.contains(":") }
}

// MARK: - `POST /v1/host/open`

struct HostOpenSourceWire: Encodable, Equatable, Sendable {
    let kind: String
    let item: String?
    let pane: String?
    let session: String?
}

struct HostOpenRequest: Encodable, Equatable, Sendable {
    let source: HostOpenSourceWire
    var path: String? = nil
    var url: String? = nil
    var check: Bool? = nil
}

/// The answer: what was (or would be) opened, and where.
struct HostOpenResult: Decodable, Equatable, Sendable {
    let opened: Bool
    let kind: String?
    let name: String?
    let line: Int?
    /// `remote`: on the Remote session's own screen; `screen`: on the
    /// computer's screen, there being no session; nil for a check.
    let `where`: String?
    let at_line: Bool?
}

/// A refusal, with core's code (`open_not_mentioned`, `open_denied`, …).
struct HostOpenError: Error, Equatable, Sendable {
    let code: String
    let status: Int

    /// The client's own code for a core that has no `POST /v1/host/open` yet:
    /// it answers the route with a 404 or 405 that is not one of the
    /// `open_*` refusals. Said as "update Omodachi on the computer".
    static let unsupported = "open_unsupported"

    static func answer(status: Int, code: String?) -> HostOpenError {
        if (status == 404 || status == 405), !(code?.hasPrefix("open_") ?? false) {
            return HostOpenError(code: unsupported, status: status)
        }
        return HostOpenError(code: code ?? "open_unavailable", status: status)
    }
}

protocol HostOpening: Sendable {
    func hostOpen(_ request: HostOpenRequest) async throws -> HostOpenResult
}
