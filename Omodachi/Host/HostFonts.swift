import CoreText
import Foundation
import Combine
import UIKit

/// `GET /v1/fonts` and `GET /v1/fonts/{id}` (`omodachi-core/docs/fonts.md`).
/// The host monospace regular and bold, Omarchy's private icon font, and — since
/// TERM-1 — the families fontconfig falls back to for the code points the
/// monospace family does not carry. None of them is packaged into this client:
/// the icon set grows with every Omarchy release, the monospace family is
/// whatever the user chose with `omarchy font set`, and the fallback chain is a
/// property of what is installed on that machine.

public struct HostFontRowDTO: Decodable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let family: String
    public let path: String?
    public let sha256: String
    public let bytes: Int
    public let contentType: String?
    enum CodingKeys: String, CodingKey { case id, role, family, path, sha256, bytes, contentType = "content_type" }

    /// Core answers `404 font_not_found` for anything it did not publish, so the
    /// client only ever asks for an id it read out of the listing. The shape is
    /// checked rather than the spelling: TERM-1 added `fallback-<coverage>` and
    /// a coverage that needs two families adds `-2`.
    public static let known = ["mono-regular", "mono-bold", "icons"]
    /// Whether `id` is a shape core publishes, so the client never sends a
    /// download request the host can only answer `404` to. It is asked of a
    /// bare id too, by the fetch itself.
    public static func isPublished(_ id: String) -> Bool {
        if known.contains(id) { return true }
        let slug = id.hasPrefix("fallback-") ? id.dropFirst(9) : ""
        return !slug.isEmpty && slug.count <= 32
            && slug.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }
    var isKnown: Bool {
        Self.isPublished(id) && sha256.count == 64 && bytes > 0 && bytes <= 40 * 1_048_576
    }
}

/// One link of the host's fontconfig fallback chain: the family that answers a
/// group of code points, and the row its bytes can be downloaded from.
public struct HostFontFallbackDTO: Decodable, Equatable, Sendable {
    /// `symbols`, `cjk` or `emoji`.
    public let coverage: String
    public let family: String
    /// The id of the row carrying this file — `null` when the host published the
    /// family but will not serve the file, and `mono-regular` when the matched
    /// family covers the point itself.
    public let font: String?
    /// The code points this family answered, as `U+F07B`.
    public let probes: [String]
}

public struct HostFontListDTO: Decodable, Equatable, Sendable {
    public let revision: Int
    public let fonts: [HostFontRowDTO]
    /// Absent from a host running core older than TERM-1, which is the same
    /// situation as a host whose matched family carries everything: no chain.
    public let fallbackChain: [HostFontFallbackDTO]?
    enum CodingKeys: String, CodingKey { case revision, fonts, fallbackChain = "fallback_chain" }
}

/// TERM-1. Which rows of a listing are worth the bytes, and what order the
/// families that registered go in behind the host monospace.
///
/// It is a decision, not a translation, so it is written down once and away
/// from the download loop: core publishes every link of the host's chain, and
/// on Leo's machine that is 19 MB of `NotoSansCJK-Regular.ttc` and 10 MB of
/// `NotoColorEmoji.ttf` for two things this device already answers — it has its
/// own CJK face, and its emoji font is the colour one people expect. The Nerd
/// Font blocks are the ones no iOS face carries at all, and they are the reason
/// a prompt or an `ls` draws boxes.
public enum HostFontPlan {
    /// The one coverage this platform cannot answer for itself.
    public static let coverage = "symbols" // non-copy: a contract value
    /// A ceiling on one fallback file, so a host with an unusual chain cannot
    /// turn a reconnect into tens of megabytes. Leo's Nerd Font is 2.5 MB.
    public static let byteLimit = 16 * 1_048_576

    /// The ids to fetch and register, in the listing's own order.
    public static func wanted(_ listing: HostFontListDTO) -> [String] {
        let links = Set((listing.fallbackChain ?? []).filter { $0.coverage == coverage }.compactMap(\.font))
        return listing.fonts.filter { row in
            guard row.isKnown else { return false }
            if HostFontRowDTO.known.contains(row.id) { return true }
            return links.contains(row.id) && row.bytes <= byteLimit
        }.map(\.id)
    }

    /// The symbol fallbacks, in the host's order, out of what actually
    /// registered. The matched family is dropped: it is already the first face
    /// of the cascade, so naming it again behind itself is noise. A link whose
    /// file this device could not take is simply absent, and the next link
    /// answers instead. Which formats those are is CoreText's business and it
    /// is more generous than expected — it opened Leo's `fa-brands-400.woff2`
    /// — so this asks the registration rather than guessing from a suffix.
    public static func fallbacks(_ listing: HostFontListDTO, registered: [String: String]) -> [String] {
        var families: [String] = []
        for link in listing.fallbackChain ?? [] where link.coverage == coverage {
            guard let id = link.font, !HostFontRowDTO.known.contains(id),
                  let family = registered[id], !families.contains(family) else { continue }
            families.append(family)
        }
        return families
    }
}

/// What the app can actually draw with right now: the PostScript names CoreText
/// accepted, never the family names the host reported. A family that failed to
/// register is absent, so the renderer falls back instead of drawing nothing.
public struct HostFontSet: Equatable, Sendable {
    /// The host monospace family name, as registered.
    public var mono: String?
    public var monoBold: String?
    /// Omarchy's `omarchy.ttf`, for rows tagged `"iconFont": "omarchy"`.
    public var icons: String?
    /// True when the host monospace family publishes Nerd Font code points, so
    /// a menu row's `icon` glyph can be drawn in the body font. `docs/fonts.md`
    /// is explicit that this is often false — Leo's host resolves
    /// `fc-match monospace` to Nimbus Mono PS.
    public var monoHasNerdGlyphs = false
    /// TERM-1. The registered families the host falls back to for Nerd Font
    /// code points, in the order core published them. Empty until the download
    /// lands, and empty for ever on a host whose fallback files this device
    /// cannot register at all.
    public var symbolFallbacks: [String] = []
    public var revision = 0

    /// The bundled symbols-only fallback (see `docs/THIRD-PARTY.md`). It carries
    /// no letterforms, so it is never used for body text.
    public static let bundledSymbols = "Symbols Nerd Font Mono" // non-copy: a font family

    /// Which registered family should draw one catalog row's `icon`.
    /// `iconFont == "omarchy"` is Omarchy's private icon font; everything else
    /// in that field is a Nerd Font code point.
    public func iconFamily(iconFont: String?) -> String? {
        if iconFont == "omarchy" { return icons }
        if monoHasNerdGlyphs, let mono { return mono }
        return Self.bundledSymbols
    }

    /// TERM-1. What goes behind the host monospace in a terminal's cascade for
    /// Nerd Font code points: the host's own fallback families when they are
    /// here, and the bundled symbols-only face until then — and instead of them
    /// on a host whose files this device cannot register. Never both, because
    /// the first face in a cascade that carries the point wins and a second
    /// copy of the same glyph only costs a lookup.
    public var symbolCascade: [String] {
        symbolFallbacks.isEmpty ? [Self.bundledSymbols] : symbolFallbacks
    }

    public static let unavailable = HostFontSet()
}

/// Fetch, cache-by-digest, register. Files land in Application Support keyed by
/// their sha256, so a re-fetch after `fonts.changed` only downloads what moved
/// and a restart registers from disk without touching the network.
actor HostFontInstaller {
    struct Installed: Sendable {
        let id: String
        let family: String
        let url: URL
    }

    private let directory: URL
    private var registered: [String: URL] = [:]

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Omodachi/HostFonts", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func cachedURL(id: String, sha256: String) -> URL {
        directory.appendingPathComponent("\(id)-\(sha256.prefix(32))").appendingPathExtension("font")
    }

    func hasCached(id: String, sha256: String) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(id: id, sha256: sha256).path)
    }

    func store(_ data: Data, id: String, sha256: String) throws -> URL {
        let url = cachedURL(id: id, sha256: sha256)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `CTFontManagerRegisterFontsForURL` with `.process` scope. Registering the
    /// same URL twice is reported as already-registered, which is a success for
    /// this caller, not a failure.
    func register(_ url: URL, id: String) -> String? {
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        // Already-registered and duplicated-name both mean "this family is
        // usable", which is what the caller asked. Only a real failure — an
        // unreadable or unrecognised file — is one.
        let tolerated: Set<Int> = [CTFontManagerError.alreadyRegistered.rawValue,
                                   CTFontManagerError.duplicatedName.rawValue]
        if !ok {
            let code = (error?.takeRetainedValue()).map { ($0 as Error as NSError).code }
            guard let code, tolerated.contains(code) else { return nil }
        }
        registered[id] = url
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let family = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
        else { return nil }
        return family
    }

    /// Withdraw a file the host replaced, so the stale glyphs cannot be picked
    /// up by name after the new file registers under the same family.
    func unregister(id: String) {
        guard let url = registered.removeValue(forKey: id) else { return }
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Whether a registered family actually carries Nerd Font code points.
    /// `U+F00A` sits in the Font Awesome block every Nerd Font patch includes;
    /// a plain monospace family has no glyph there.
    nonisolated static func hasNerdGlyphs(family: String) -> Bool {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        var characters: [UniChar] = [0xF00A]
        var glyphs: [CGGlyph] = [0]
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1) && glyphs[0] != 0
    }
}
