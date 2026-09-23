// lint:host-words — MockCatalog stands in for Omarchy's own menu, so its
// labels are the host's words and are drawn untranslated (ARCH-1 §6).
import Foundation

/// Turning the host's flat catalog rows into the Panel's menu tree. The client
/// never evaluates a menu expression: `descriptor` is the host's own verdict on
/// where a row goes and whether it is ready.
///
/// PERF-4 §1. A row draws `不可用` when, and only when, the host said so. It
/// used to also draw it whenever this client was not connected — and because
/// the client drops to "not connected" on any refresh that fails or any break
/// in the event stream, a host that was merely slow turned the whole menu grey
/// for as long as the reconnect ladder took. Whether a tap can be *sent* is a
/// different question from whether the host says the row is ready, and it is
/// answered where the tap is sent (`HomeStore.prepareAction`), in the 26-high
/// toast. Connection is the bar's dot.
enum HostMenu {
    static func build(from entries: [CatalogEntryDTO]) -> [MenuItem] {
        let rows = Array(entries.prefix(4096)).filter { $0.visible != false }
        // MENU-4: the submenus that have rows the host hides.
        let hiding = Set(entries.prefix(4096).filter { $0.visible == false }.compactMap(\.parentID))
        var byID: [String: CatalogEntryDTO] = [:]
        for row in rows where byID[row.id] == nil { byID[row.id] = row }
        func parent(_ row: CatalogEntryDTO) -> String? {
            var candidate = row.parentID
            var visited = Set<String>()
            while let value = candidate, !value.isEmpty, value != "root", !visited.contains(value) {
                visited.insert(value)
                if byID[value] != nil { return value }
                candidate = value.contains(".") ? value.split(separator: ".").dropLast().joined(separator: ".") : nil
            }
            return nil
        }
        var groups: [String: [CatalogEntryDTO]] = [:]
        for row in rows where row.id != "root" { groups[parent(row) ?? "root", default: []].append(row) }
        func build(_ row: CatalogEntryDTO, ancestors: Set<String>, path: [String]) -> MenuItem? {
            guard !ancestors.contains(row.id), ancestors.count < 24 else { return nil }
            let label = row.label ?? row.id
            let children = (groups[row.id] ?? []).compactMap {
                build($0, ancestors: ancestors.union([row.id]), path: path + [label])
            }
            // MENU-4. A submenu whose every row the host hides is not drawn, as
            // Omarchy's own `isVisible` leaves it out (Remove › Gaming with no
            // game installed). It used to be drawn as a leaf reading 不可用.
            // A provider's submenu stays: Omarchy keeps it while it is empty.
            if row.kind == "menu", children.isEmpty, hiding.contains(row.id), !row.providerMenu { return nil }
            let descriptor = row.descriptor
            let route = descriptor?.route == "native" ? "native:\(descriptor?.nativeView ?? "")" : descriptor?.route ?? "host"
            return MenuItem(id: row.id, label: label, icon: fallback(for: row),
                            glyph: row.icon ?? "", iconFont: row.iconFont ?? "", path: path,
                            aliases: row.aliases, children: children,
                            route: route,
                            enabled: row.id == "omodachi.agent" || (row.id == "omodachi.desktop" && route == "desktop")
                                || !children.isEmpty
                                || (hostShows(row) && descriptor?.supported == true && descriptor?.ready != false),
                            disabledReason: descriptor?.ready == false
                                ? descriptor?.readinessReason.flatMap { spokenReasons.contains($0) ? $0 : nil } : nil,
                            confirm: descriptor?.confirm == true,
                            checked: row.checked, terminalArgv: nil)
        }
        return (groups["root"] ?? []).compactMap { build($0, ancestors: [], path: []) }
    }

    /// The readiness reasons a grey row says in words instead of `不可用`:
    /// MENU-3's `condition_disabled`, and MENU-4's two rows the host looked at
    /// and will not run. Anything else is still the plain `不可用`.
    static let spokenReasons: Set<String> = ["condition_disabled", "menu_action_needs_terminal",
                                             "menu_action_empty"]

    /// MENU-3. Whether the host's `when` lets this row be used: a definite
    /// true, or `unknown` - the host ran the expression and got no answer,
    /// which on the desktop leaves the row showing and clickable too. A
    /// definite false never reaches here (it is filtered out above, the same
    /// row the host's menu hides), and `unavailable` - no evaluator at all -
    /// is still grey, because the host refuses to run it.
    static func hostShows(_ row: CatalogEntryDTO) -> Bool {
        row.visible == true || (row.visible == nil && row.conditions?.when?.status == "unknown")
    }

    /// What a row draws when the host published no glyph this device can draw.
    ///
    /// MENU-1 §2. There used to be a table here keyed on the row id — `apps` →
    /// `square.grid.2x2`, `install` → `plus.circle` and so on — which meant the
    /// app had an opinion about eleven of Omarchy's rows and no opinion about
    /// the other six hundred. It was also silently wrong the moment Omarchy
    /// changed one: the id survives, the icon does not. The host's own `icon`
    /// is the only source of a menu glyph now, so this answers one question
    /// only — *nothing was published, what goes in the 36pt box* — and answers
    /// it from what the host says the row **is**, never from its name.
    ///
    /// The one id in here is `omodachi`: that row is published by our own menu
    /// file with an empty icon, precisely because the glyph for it is ours.
    /// ICON-1 added the middle line. A row whose `icon` is a **name** is a row
    /// the host can send a picture for, so the fallback carries that name and
    /// `HostGlyphView` asks `GET /v1/icons/{name}` for it — drawing `.app`
    /// meanwhile, and for ever if the host has no picture either.
    static func fallback(for row: CatalogEntryDTO) -> GlyphFallback {
        if row.id == "omodachi" { return .mark }
        if row.iconKind.isFetched, let name = row.icon, !name.isEmpty { return .icon(name) }
        if row.kind == "app" { return .app }
        return "circle"
    }
}

/// The demo host. It exists so the app has something to show before pairing;
/// nothing here ever reaches a real host.
enum MockCatalog {
    static let roots: [MenuItem] = [
        .init(id: "apps", label: "Apps", icon: "square.grid.2x2", aliases: ["launch"], children: [.init(id: "apps.launcher", label: "App launcher", icon: "magnifyingglass", route: "host-ui")]),
        .init(id: "learn", label: "Learn", icon: "book", children: [.init(id: "learn.keybindings", label: "Keybindings", icon: "keyboard", route: "host-ui")]),
        .init(id: "trigger", label: "Trigger", icon: "bolt", children: [
            .init(id: "trigger.toggle.top-bar", label: "Top bar", icon: "menubar.rectangle"),
            .init(id: "trigger.toggle.notifications", label: "Notifications", icon: "bell"),
            .init(id: "trigger.toggle.nightlight", label: "Night light", icon: "moon")]),
        .init(id: "style", label: "Style", icon: "paintpalette", children: [.init(id: "style.theme", label: "Theme", icon: "paintbrush", route: "host-ui")]),
        .init(id: "setup", label: "Setup", icon: "slider.horizontal.3", children: [.init(id: "setup.default.agent", label: "Default agent", icon: "person.crop.circle", route: "host-ui")]),
        .init(id: "install", label: "Install", icon: "plus.circle", children: [.init(id: "install.package", label: "Packages", icon: "shippingbox", route: "terminal", terminalArgv: ["omarchy-pkg-install"])]),
        .init(id: "remove", label: "Remove", icon: "minus.circle", children: [.init(id: "remove.package", label: "Packages", icon: "shippingbox", route: "host-ui", confirm: true)]),
        .init(id: "update", label: "Update", icon: "arrow.triangle.2.circlepath", children: [.init(id: "update.omarchy", label: "Omarchy", icon: "arrow.up.circle", route: "terminal", terminalArgv: ["omarchy-update"])]),
        .init(id: "about", label: "About", icon: "info.circle", children: [.init(id: "about.herdr", label: "Herdr", icon: "rectangle.split.2x2", route: "native:herdr")]),
        .init(id: "system", label: "System", icon: "power", children: [.init(id: "system.lock", label: "Lock", icon: "lock", confirm: true)]),
        .init(id: "omodachi", label: "Omodachi", icon: .mark, children: [
            .init(id: "omodachi.panel", label: "Panel", icon: "slider.horizontal.3", route: "native:panel"),
            .init(id: "omodachi.desktop", label: "Desktop", icon: "display", route: "desktop"),
            .init(id: "omodachi.agent", label: "Agent", icon: "person.crop.circle", route: "native:agent"),
            .init(id: "omodachi.herdr", label: "Herdr", icon: "rectangle.split.2x2", route: "native:herdr")
        ] + (1...10).map { number in
            .init(id: "omodachi.workspace.select.\(number)", label: Strings.barWorkspaceName(Format.count(number)), icon: "rectangle.grid.1x2", aliases: ["\(number)"], route: "host")
        })
    ]
}

