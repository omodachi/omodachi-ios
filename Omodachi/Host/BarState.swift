import CoreGraphics
import Foundation

/// Native presentation of host-owned bar data. Unknown occupancy and focus stay
/// nil; this model never derives them from terminal output or window titles.
enum HostBarPosition: String, Codable, CaseIterable, Sendable {
    case top, bottom, left, right
}

struct HostBarModel: Equatable, Sendable {
    var available: Bool
    var layout: BarLayout?
    var workspaces: [BarWorkspace]
    var focusedApp: BarFocus?
    /// MENU-2. Where the host's own bar is on the screen this session owns, so
    /// a tap on the Omarchy logo can be answered here instead of by a plugin
    /// that clones the host's menu. `nil` whenever there is no session, no
    /// bar, or nothing the host could measure.
    var geometry: HostBarGeometry?

    static let unavailable = HostBarModel(available: false, layout: nil, workspaces: [], focusedApp: nil,
                                          geometry: nil)
}

/// MENU-2 / `state.bar.geometry`. Rectangles in the owned output's **logical**
/// pixels, with the size of that output so they can be turned into fractions
/// of the picture — which is the only form that survives the stream's own
/// scaling.
///
/// Only the logo. The Omodachi plugin's own bar slot moves with every other
/// widget beside it, so the host does not locate it and this app does not
/// cover it: a tap there goes to the host's own icon, which decides for itself
/// what to do during a takeover (A-67).
struct HostBarGeometry: Equatable, Sendable {
    /// The output the session owns. Carried so a geometry that arrives for a
    /// session that has already been replaced can be recognised as not ours.
    let output: String
    let logicalSize: CGSize
    let position: HostBarPosition
    let bar: CGRect
    /// The Omarchy logo. `nil` when the user moved it, replaced it, or took it
    /// out of `shell.json` — then there is nothing at that end of the bar to
    /// intercept, and the App must not invent a rectangle there.
    let logo: CGRect?
    /// True when there is a rectangle to cover. Without one, the picture falls
    /// back to the corner handle (A-67).
    var hasTargets: Bool { logo != nil }
}

/// The window the host says is in front, and the icon its desktop entry
/// declares (ICON-1 §1, `state.focus`).
///
/// Nothing draws this today: A-49/A-50/A-52 deleted the focused window from
/// this app's bar and `NavigationUITests` asserts `bar-focus` does not exist,
/// and Leo's own `~/.config/omarchy/shell.json` has no `omarchy.active-window`
/// in any segment either — so there is no host item to be consistent with.
/// What ICON-1 changed is that the answer is now *available*: the host
/// resolves the focused window's `Icon=` through the same desktop database the
/// Apps submenu is compiled from, and `fallback` turns it into something a
/// `HostGlyphView` can draw the day a surface wants one.
struct BarFocus: Equatable, Sendable {
    let name: String
    /// The `Icon=` value, and what kind of value it is. An `xdg` or `path`
    /// kind becomes a real picture through `GET /v1/icons`; anything else
    /// draws the generic application glyph.
    var icon: String = ""
    var iconKind: HostIconKind = .none

    var fallback: GlyphFallback {
        iconKind.isFetched && !icon.isEmpty ? .icon(icon) : .app
    }
}

/// Role IDs preserve each placement's host order. The view maps recognized
/// roles to native controls; no host code or QML is rendered on the device.
struct BarLayout: Equatable, Sendable {
    let position: HostBarPosition?
    let left: [String]
    let center: [String]
    let right: [String]
}

struct BarWorkspace: Identifiable, Equatable, Sendable {
    let id: Int
    let active: Bool?
    let occupied: Bool?
    /// `state.workspace.items[].persistent`: one of the fixed five the official
    /// bar always draws (`Workspaces.qml 20–31`). A Remote projection has no
    /// such field, so those rows are the live set and nothing else.
    var persistent: Bool = false
    let canSelect: Bool
    let canMoveFocusedWindow: Bool
}

/// Additive core v1 bar contract. These fields are data only; the client's
/// key list deliberately excludes window titles, shell settings, and scripts.
public typealias HostBarDTO = HostBarLayoutDTO

public struct HostBarLayoutDTO: Decodable, Equatable, Sendable {
    public struct Item: Decodable, Equatable, Sendable {
        public let id: String
        public let role: String
        var nativeRole: String {
            switch role {
            case "system_tray": return "tray"
            case "focused_window": return "focus"
            case "logo", "workspaces", "clock", "agent", "stream": return role
            case "omodachi", "panel": return "panel"
            default: return "unsupported"
            }
        }
    }
    /// MENU-2 / `bar.schema.json` `geometry`. Every field is required by the
    /// schema; a host that omits one is a host this client cannot intercept
    /// for, so the whole geometry decodes to nil rather than to a partial one.
    public struct Geometry: Decodable, Equatable, Sendable {
        public struct Rect: Decodable, Equatable, Sendable {
            public let x, y, width, height: Double
            var cgRect: CGRect? {
                guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
                      width > 0, height > 0, abs(x) <= 16384, abs(y) <= 16384,
                      width <= 16384, height <= 16384 else { return nil }
                return CGRect(x: x, y: y, width: width, height: height)
            }
        }
        public struct Size: Decodable, Equatable, Sendable {
            public let width, height: Double
        }
        public let output: String
        public let logicalSize: Size
        public let position: String
        public let bar: Rect
        public let logo: Rect?
        enum CodingKeys: String, CodingKey {
            case output, logicalSize = "logical_size", position, bar, logo
        }

        var native: HostBarGeometry? {
            guard !output.isEmpty, output.count <= 128,
                  let where_ = HostBarPosition(rawValue: position),
                  let barRect = bar.cgRect,
                  logicalSize.width.isFinite, logicalSize.height.isFinite,
                  logicalSize.width > 0, logicalSize.height > 0,
                  logicalSize.width <= 16384, logicalSize.height <= 16384 else { return nil }
            let size = CGSize(width: logicalSize.width, height: logicalSize.height)
            // A rectangle the host reports outside its own output is not a
            // measurement of anything on the picture.
            func inside(_ value: Rect?) -> CGRect? {
                guard let rect = value?.cgRect,
                      CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(rect) else { return nil }
                return rect
            }
            return HostBarGeometry(output: output, logicalSize: size, position: where_,
                                   bar: barRect, logo: inside(logo))
        }
    }

    public let source: String
    public let sourceStatus: String
    public let position: String?
    public let revision: String
    public let left: [Item]
    public let center: [Item]
    public let right: [Item]
    public let geometry: Geometry?
    enum CodingKeys: String, CodingKey {
        case source, sourceStatus = "source_status", position, revision, left, center, right, geometry
    }

    var nativeLayout: BarLayout? {
        guard source == "shell.json", ["fixture", "available"].contains(sourceStatus),
              !revision.isEmpty, left.count <= 64, center.count <= 64, right.count <= 64,
              position == nil || HostBarPosition(rawValue: position!) != nil else { return nil }
        let barPosition = position.flatMap(HostBarPosition.init(rawValue:))
        return BarLayout(position: barPosition, left: left.map(\.nativeRole), center: center.map(\.nativeRole), right: right.map(\.nativeRole))
    }
}

public struct HostBarWorkspaceDTO: Decodable, Equatable, Sendable {
    public let id: Int
    public let label: String?
    public let active: Bool?
    public let occupied: Bool?
    public let persistent: Bool?
    public let windowCount: Int?
    public let selectEntryID: String?
    public let moveFocusedEntryID: String?
    enum CodingKeys: String, CodingKey {
        case id, label, active, occupied, persistent, windowCount = "window_count", selectEntryID = "select_entry_id"
        case moveFocusedEntryID = "move_focused_entry_id", moveEntryID = "move_entry_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        active = try c.decodeIfPresent(Bool.self, forKey: .active)
        occupied = try c.decodeIfPresent(Bool.self, forKey: .occupied)
        persistent = try c.decodeIfPresent(Bool.self, forKey: .persistent)
        windowCount = try c.decodeIfPresent(Int.self, forKey: .windowCount)
        selectEntryID = try c.decodeIfPresent(String.self, forKey: .selectEntryID)
        moveFocusedEntryID = try c.decodeIfPresent(String.self, forKey: .moveFocusedEntryID)
            ?? c.decodeIfPresent(String.self, forKey: .moveEntryID)
    }
}

public struct HostFocusDTO: Decodable, Equatable, Sendable {
    public let appID: String?
    public let appName: String?
    public let targetToken: String?
    /// ICON-1. The focused window's own `Icon=`, resolved on the host from the
    /// same desktop database the Apps submenu is compiled from.
    public let icon: String?
    public let iconKind: HostIconKind?
    enum CodingKeys: String, CodingKey {
        case appID = "app_id", appName = "app_name", targetToken = "target_token"
        case icon, iconKind = "icon_kind"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decodeIfPresent(String.self, forKey: .appID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        targetToken = try c.decodeIfPresent(String.self, forKey: .targetToken)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        iconKind = (try? c.decodeIfPresent(String.self, forKey: .iconKind))
            .flatMap { $0.flatMap(HostIconKind.init(rawValue:)) }
    }

    var displayName: String? {
        guard let source = appName ?? appID else { return nil }
        let value = String(source.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128))
        return value.isEmpty ? nil : value
    }

    /// What the bar's focus slot draws, or nothing when the host says nothing
    /// has focus. A name longer than a `.desktop` file may carry is dropped
    /// rather than sent to the host as a request.
    var barFocus: BarFocus? {
        guard let displayName else { return nil }
        let name = (icon ?? "").utf8.count <= 1024 ? (icon ?? "") : ""
        return BarFocus(name: displayName, icon: name,
                        iconKind: iconKind ?? HostIconKind.classify(name))
    }
}

/// Layout depends on the usable viewport, not device orientation notifications.
/// The parent places the bar and the bar renders using the same resolved edge.
enum NativeBarPositionPolicy {
    static func resolve(width: Double, height: Double,
                        landscape: HostBarPosition = .top,
                        portrait: HostBarPosition = .left,
                        previous: HostBarPosition? = nil) -> HostBarPosition {
        let horizontal = landscape == .bottom ? HostBarPosition.bottom : .top
        let vertical = portrait == .right ? HostBarPosition.right : .left
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return previous ?? horizontal
        }
        if width == height, let previous { return previous }
        return width >= height ? horizontal : vertical
    }
}

struct NativeBarEdgePreferences: Codable, Equatable, Sendable {
    var landscape: HostBarPosition = .top
    var portrait: HostBarPosition = .left

    mutating func choose(_ edge: HostBarPosition) {
        switch edge {
        case .top, .bottom: landscape = edge
        case .left, .right: portrait = edge
        }
    }
}

enum NativeBarViewportChange: Sendable {
    case windowGeometry
    case temporaryOcclusion
}

/// Keep the outer window's geometry; keyboard and Panel overlays cannot rotate
/// the bar merely by shrinking the visible portion of the same window.
struct NativeBarPlacement: Equatable, Sendable {
    private(set) var width: Double = 0
    private(set) var height: Double = 0
    private(set) var edge: HostBarPosition = .top
    var preferences = NativeBarEdgePreferences()

    mutating func update(width: Double, height: Double, reason: NativeBarViewportChange) {
        guard case .windowGeometry = reason,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        self.width = width
        self.height = height
        edge = NativeBarPositionPolicy.resolve(width: width, height: height,
            landscape: preferences.landscape, portrait: preferences.portrait, previous: edge)
    }

    mutating func choose(_ edge: HostBarPosition) {
        preferences.choose(edge)
        update(width: width, height: height, reason: .windowGeometry)
    }
}
