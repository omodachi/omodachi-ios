import Foundation
import UIKit

/// ICON-1. The pictures behind the icon **names** the host publishes.
///
/// A catalog row's `icon` is a code point on most of Omarchy's six hundred
/// rows, and an XDG icon *name* on every `apps.*` row core compiles from a
/// `.desktop` file — `org.gnome.Nautilus`, `google-chrome`, `x`. A name is not
/// a picture, and turning one into a picture needs the machine's icon theme,
/// its inheritance chain and the file tree under every icon base directory.
/// None of that is on an iPad, so core resolves it and answers with the bytes
/// (`omodachi-core/docs/icons.md`).
///
/// MENU-1 drew those rows as one generic application window, which was honest
/// and which Leo read exactly as it was meant: "icon 还是没有". This is the
/// half that was missing.
public enum HostIconKind: String, Sendable, Equatable {
    /// One code point the device can draw itself, in a face it has.
    case glyph
    /// An XDG icon name.
    case xdg
    /// An absolute path out of a `.desktop` file's `Icon=`.
    case path
    /// The host published nothing.
    case none

    /// Whether this is something only `GET /v1/icons` can turn into a picture.
    public var isFetched: Bool { self == .xdg || self == .path }

    /// The same rule core applies (`omodachi_core/icons.py` `classify_icon`),
    /// for a host that has not been updated yet and publishes no `icon_kind`.
    ///
    /// It is kept in step with `HostGlyph.resolve` deliberately: a value this
    /// says is a name is a value that resolver refuses to draw, and the two
    /// disagreeing would mean a row that is neither drawn nor fetched.
    public static func classify(_ value: String?, iconFont: String? = nil) -> HostIconKind {
        guard let value, !value.isEmpty else { return .none }
        if value.hasPrefix("/") { return .path }
        if let iconFont, !iconFont.isEmpty { return .glyph }
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 1 else { return .xdg }
        if scalars[0].isASCII, CharacterSet.alphanumerics.contains(scalars[0]) { return .xdg }
        return .glyph
    }
}

/// One host icon, at one pixel size, for one host.
struct HostIconRequest: Hashable, Sendable {
    let hostID: String
    let name: String
    /// Physical pixels, which is what core is asked for — a 36pt slot on a @3x
    /// screen is 108, and asking for 36 would send back a blurred 36.
    let pixels: Int
}

/// What a `HostGlyphView` is allowed to draw for a name, and when.
///
/// The rule is deliberately narrow: **the store never blocks a row**. A row
/// whose name has not arrived draws the generic application glyph, the fetch
/// happens off the render, and the row swaps to the real icon when the bytes
/// land. Nothing waits, nothing spins, and a host that answers `404` leaves
/// the generic glyph in place for ever rather than retrying on every scroll.
@MainActor @Observable final class HostIconStore {
    static let shared = HostIconStore()

    /// Installed by `HomeStore` when a host connects, and cleared when it goes.
    /// A store with no fetcher is a store that answers from disk and nothing
    /// else — which is what the demo host and the previews get.
    @ObservationIgnored var fetch: (@Sendable (String, Int, String?) async throws -> HostIconBytes?)?

    private(set) var images: [HostIconRequest: UIImage] = [:]
    /// Names this host answered `404` for. Asked once, never again.
    @ObservationIgnored private var refused: Set<HostIconRequest> = []
    @ObservationIgnored private var inFlight: Set<HostIconRequest> = []
    @ObservationIgnored private let cache: HostIconCache

    init(cache: HostIconCache = HostIconCache()) { self.cache = cache }
    /// The host these pictures belong to. Icons are per host because the icon
    /// theme is: the same name is a different picture on a different machine.
    @ObservationIgnored private(set) var hostID = ""

    /// A ceiling on what one host's menu can hold in memory. 47 app rows at
    /// 108px is nothing; a pathological catalog is not allowed to be.
    private static let limit = 512
    /// `omodachi-core/docs/icons.md`: the one error that means "this host has
    /// no picture for that name", as opposed to "not right now".
    static let missCode = "icon_not_found"

    func adopt(hostID: String) {
        guard hostID != self.hostID else { return }
        self.hostID = hostID
        images.removeAll()
        refused.removeAll()
        inFlight.removeAll()
    }

    /// The picture for this name if it is already here, and a fetch if it is
    /// not. Called from `body`, so it must be cheap and must not publish.
    func image(named name: String, points: CGFloat, scale: CGFloat) -> UIImage? {
        guard !hostID.isEmpty, !name.isEmpty else { return nil }
        let request = HostIconRequest(hostID: hostID, name: name, pixels: Self.pixels(points, scale))
        if let image = images[request] { return image }
        if !refused.contains(request), !inFlight.contains(request) { start(request) }
        return nil
    }

    /// Study 01's 36pt glyph slot, which is the box every host icon is drawn
    /// in. The host draws its own app icons at `Style.font.iconLarge` (18px)
    /// inside a `Style.space(36)` slot (`Menu.qml:1244-1256`), so the App draws
    /// them at its own glyph step inside its own 36 box — the same proportion.
    static let slot: CGFloat = 36

    /// What is asked for, in physical pixels.
    ///
    /// Requests are quantised **up to the 36 slot**, so the whole menu shares
    /// one representation per scale — 72 at @2x, 108 at @3x — instead of one
    /// per drawn size. The bar's 22pt glyph then reuses the row's bytes rather
    /// than asking the host for a third picture of the same icon.
    static func pixels(_ points: CGFloat, _ scale: CGFloat) -> Int {
        min(512, max(8, Int((max(slot, points) * max(1, scale)).rounded())))
    }

    private func start(_ request: HostIconRequest) {
        inFlight.insert(request)
        Task { [weak self] in
            guard let self else { return }
            let known = await self.cache.digest(for: request)
            if known != nil, let cached = await self.cache.image(for: request) {
                // A cached picture is shown immediately and still revalidated:
                // `If-None-Match` makes that one `304`, not one download.
                self.deliver(cached, for: request)
                self.inFlight.insert(request)
            }
            guard let fetch = self.fetch else { self.inFlight.remove(request); return }
            do {
                guard let answer = try await fetch(request.name, request.pixels, known) else {
                    self.inFlight.remove(request)
                    return  // 304: what is on screen is current.
                }
                guard let image = UIImage(data: answer.data) else {
                    // An SVG that the host could not rasterize. UIImage cannot
                    // read one, so this name stays on the generic glyph rather
                    // than being asked for again on every scroll.
                    self.refuse(request)
                    return
                }
                await self.cache.store(answer.data, etag: answer.etag, for: request)
                self.deliver(image, for: request)
            } catch {
                // A miss is permanent for this session; anything else (offline,
                // a dropped connection) is not, so only a 404 is remembered.
                if case CompanionHostError.unavailable(let code, _) = error, code == HostIconStore.missCode {
                    self.refuse(request)
                } else {
                    self.inFlight.remove(request)
                }
            }
        }
    }

    private func deliver(_ image: UIImage, for request: HostIconRequest) {
        inFlight.remove(request)
        guard request.hostID == hostID else { return }
        if images.count >= Self.limit { images.removeAll() }
        images[request] = image
    }

    private func refuse(_ request: HostIconRequest) {
        inFlight.remove(request)
        refused.insert(request)
    }
}

/// The bytes one icon request answered with, and the validator they carry.
public struct HostIconBytes: Sendable {
    public let data: Data
    public let etag: String
    public init(data: Data, etag: String) { self.data = data; self.etag = etag }
}

/// Host icons on disk, keyed by host, name, size **and** the host's ETag.
///
/// The ETag is in the file name rather than beside it, so a host that changed
/// its icon theme cannot be served last week's picture: the new validator is a
/// different file, and the old one is simply never asked for again.
actor HostIconCache {
    private let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Omodachi/HostIcons", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// A file name that is safe whatever the host called the icon. The name can
    /// be an absolute path, so it is hashed rather than escaped.
    private func stem(_ request: HostIconRequest) -> String {
        let digest = Self.fingerprint(request.hostID + "\u{1}" + request.name)
        return "\(digest)-\(request.pixels)"
    }

    private func entries(_ request: HostIconRequest) -> [URL] {
        let prefix = stem(request) + "."
        let all = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func digest(for request: HostIconRequest) -> String? {
        entries(request).first.map { $0.deletingPathExtension().pathExtension }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func image(for request: HostIconRequest) -> UIImage? {
        guard let url = entries(request).first, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func store(_ data: Data, etag: String, for request: HostIconRequest) {
        let safe = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\"W/ "))
        guard !safe.isEmpty, safe.count <= 128,
              safe.allSatisfy({ $0.isHexDigit || $0 == "-" || $0.isLetter || $0.isNumber }) else { return }
        for old in entries(request) { try? FileManager.default.removeItem(at: old) }
        let url = directory.appendingPathComponent("\(stem(request)).\(safe).icon")
        try? data.write(to: url, options: .atomic)
    }

    /// A short, stable, non-cryptographic name for a cache file. It never
    /// guards anything — it only has to not collide inside one directory.
    nonisolated static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(value.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}
