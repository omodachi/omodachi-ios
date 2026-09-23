import Foundation
import Combine
import UIKit

/// Pulling `/v1/theme` and `/v1/fonts` and handing them to `ThemeRuntime`.
///
/// Both are re-read when the host says so — `theme.changed` and `fonts.changed`
/// — and never on a timer. A host that publishes neither is a host with no
/// readable theme (`503 theme_unavailable`), which leaves the device on its
/// last cached document rather than on a guess.
extension HomeStore {
    func loadAppearance(refreshingFonts: Bool = true) async {
        guard !profile.mock, companionConnected, let service = client else { return }
        adoptHostIcons(using: service)
        let current = connectionGeneration
        if let theme = try? await service.fetchTheme(), current == connectionGeneration {
            ThemeRuntime.shared.apply(theme, origin: .host)
            await loadBackground(theme, using: service, generation: current)
        }
        guard refreshingFonts else { return }
        await loadFonts(using: service, generation: current)
    }

    /// The wallpaper is optional and never blocks the Panel. A theme with no
    /// wallpaper has `background: null`, which is a theme, not a broken host.
    private func loadBackground(_ theme: HostTheme, using service: any CompanionServing, generation: UUID) async {
        guard let descriptor = theme.background else { ThemeRuntime.shared.apply(background: nil); return }
        guard descriptor.sha256 != backgroundDigest else { return }
        guard let data = try? await service.fetchThemeBackground(knownDigest: backgroundDigest),
              let image = UIImage(data: data), generation == connectionGeneration else { return }
        backgroundDigest = descriptor.sha256
        ThemeRuntime.shared.apply(background: image)
    }

    func loadFonts(using service: any CompanionServing, generation: UUID) async {
        guard let listing = try? await service.fetchFonts(), generation == connectionGeneration else { return }
        var set = HostFontSet()
        set.revision = listing.revision
        // TERM-1. Not every published row is worth the bytes; `HostFontPlan`
        // holds that decision, and the loop below only carries it out.
        let wanted = HostFontPlan.wanted(listing)
        var registered: [String: String] = [:]
        for row in listing.fonts where wanted.contains(row.id) {
            let cached = await fontInstaller.hasCached(id: row.id, sha256: row.sha256)
            var url = await fontInstaller.cachedURL(id: row.id, sha256: row.sha256)
            if !cached {
                guard let data = try? await service.fetchFontFile(id: row.id), generation == connectionGeneration,
                      let written = try? await fontInstaller.store(data, id: row.id, sha256: row.sha256) else { continue }
                url = written
                // The host replaced this role's file; withdraw the old one so a
                // lookup by family name cannot find the stale glyphs.
                await fontInstaller.unregister(id: row.id)
            }
            // A file CoreText will not take is not an error to report: the
            // host gave a correct answer this platform cannot use, and the
            // next link of the chain answers instead.
            guard let family = await fontInstaller.register(url, id: row.id) else { continue }
            registered[row.id] = family
            switch row.id {
            case "mono-regular":
                set.mono = family
                set.monoHasNerdGlyphs = HostFontInstaller.hasNerdGlyphs(family: family)
            case "mono-bold": set.monoBold = family
            case "icons": set.icons = family
            default: break
            }
        }
        set.symbolFallbacks = HostFontPlan.fallbacks(listing, registered: registered)
        guard generation == connectionGeneration else { return }
        ThemeRuntime.shared.apply(set)
    }
}

extension HomeStore {
    /// ICON-1. Point the icon store at this host, and give it the one call it
    /// needs.
    ///
    /// The store is keyed on the host, not the URL — PAIR-4's lesson, and here
    /// it is literal: the icon theme is a property of the machine, so the same
    /// name is a different picture on a different one. Changing hosts empties
    /// what is in memory; the disk cache keeps each host's files apart by the
    /// same key and by the host's own ETag, so nothing has to be re-downloaded
    /// to come back.
    func adoptHostIcons(using service: any CompanionServing) {
        let store = HostIconStore.shared
        store.adopt(hostID: hostPin?.hostID ?? profile.companionURL)
        store.fetch = { name, pixels, digest in
            try await service.fetchIcon(name: name, pixels: pixels, knownDigest: digest)
        }
    }

    /// The host is gone: stop asking it for pictures. What already arrived
    /// stays on screen, because a menu that blanks its icons on a dropped
    /// event stream is PERF-4 §1's grey menu with a different symptom.
    func releaseHostIcons() {
        HostIconStore.shared.fetch = nil
    }
}
