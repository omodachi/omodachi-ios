import Foundation

/// `GET /v1/theme` (`omodachi-core/docs/theme.md`). Every colour, alpha, size
/// and font step the app paints comes from this document. The app derives
/// nothing: a role the host did not publish is absent, not guessed.

/// The 25 colour roles Omarchy's `colors.toml` carries, in the order
/// `contracts/fixtures/theme.json` lists them.
public enum ThemeColorRole: String, CaseIterable, Sendable {
    case accent, selection, muted
    case background, darkBackground = "dark_background", darkerBackground = "darker_background"
    case lighterBackground = "lighter_background"
    case foreground, brightForeground = "bright_foreground", lightForeground = "light_foreground"
    case darkForeground = "dark_foreground"
    case red, yellow, orange, green, cyan, blue, magenta, brown
    case brightRed = "bright_red", brightYellow = "bright_yellow", brightGreen = "bright_green"
    case brightCyan = "bright_cyan", brightBlue = "bright_blue", brightMagenta = "bright_magenta"
}

/// One `shell.toml` value. The sections mix colours, alphas, pixel sizes and
/// flags in the same table, so the decode keeps the JSON kind rather than
/// forcing everything through `Double`.
public enum ShellValue: Decodable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case flag(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .flag(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        self = .text(try container.decode(String.self))
    }

    var string: String? { if case let .text(value) = self { return value }; return nil }
    var double: Double? {
        switch self {
        case let .number(value): return value
        case let .flag(value): return value ? 1 : 0
        case .text: return nil
        }
    }
    var bool: Bool? {
        switch self {
        case let .flag(value): return value
        case let .number(value): return value != 0
        case .text: return nil
        }
    }
}

public struct ThemeBackgroundDTO: Decodable, Equatable, Sendable {
    public let sha256: String
    public let bytes: Int
    public let contentType: String?
    enum CodingKeys: String, CodingKey { case sha256, bytes, contentType = "content_type" }
}

/// The decoded host theme. `shell` keeps every section the host published,
/// including ones this client does not read yet, so a report can name them.
public struct HostTheme: Decodable, Equatable, Sendable {
    public let name: String
    public let mode: String
    public let colors: [String: String]
    public let shell: [String: [String: ShellValue]]
    public let background: ThemeBackgroundDTO?
    public let revision: Int

    enum CodingKeys: String, CodingKey { case name, mode, colors, shell, background, revision }

    public init(name: String, mode: String, colors: [String: String],
                shell: [String: [String: ShellValue]],
                background: ThemeBackgroundDTO? = nil, revision: Int = 0) {
        self.name = name; self.mode = mode; self.colors = colors
        self.shell = shell; self.background = background; self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "dark"
        colors = try c.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        shell = try c.decodeIfPresent([String: [String: ShellValue]].self, forKey: .shell) ?? [:]
        background = try c.decodeIfPresent(ThemeBackgroundDTO.self, forKey: .background)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }

    /// A theme missing a colour role is refused by core before publication
    /// (`docs/theme.md`), so a decoded document that is missing one is not a
    /// theme this client should paint with.
    public var isComplete: Bool {
        ThemeColorRole.allCases.allSatisfy { colors[$0.rawValue].flatMap(Self.parse(hex:)) != nil }
            && ["bar", "controls", "spacing", "font", "menu", "popups", "hyprland"].allSatisfy { shell[$0] != nil }
    }

    // MARK: - Roles

    /// The document's own reading of a role, as three components. Turning that
    /// into something drawable is `DesignSystem/Tokens`'s job: this layer
    /// decodes what the host published and nothing else (ARCH-1 §1.4).
    public func rgb(_ role: ThemeColorRole) -> (Double, Double, Double) {
        colors[role.rawValue].flatMap(Self.parse(hex:)) ?? FallbackTheme.rgb(role)
    }

    /// A `shell.toml` colour key and its optional `-alpha` companion
    /// (`Color.qml 67–71`), still as numbers. The fallback role is what the
    /// generated template interpolates into that key, never a value invented
    /// here.
    public func shellRGBA(_ section: String, _ key: String,
                          fallback: ThemeColorRole) -> (rgb: (Double, Double, Double), alpha: Double) {
        let base = shell[section]?[key]?.string.flatMap(Self.parse(hex:)) ?? rgb(fallback)
        return (base, shell[section]?[key + "-alpha"]?.double ?? 1)
    }

    /// A `shell.toml` numeric token: an alpha, a pixel size or a type step.
    public func shellNumber(_ section: String, _ key: String) -> Double? {
        shell[section]?[key]?.double
    }

    public func shellNumber(_ section: String, _ key: String, fallback: Double) -> Double {
        shellNumber(section, key) ?? fallback
    }

    /// A standalone alpha token such as `[menu] scrim-alpha` or
    /// `[controls] pressed-fill-alpha`.
    public func alpha(_ section: String, _ key: String) -> Double {
        shellNumber(section, key) ?? FallbackTheme.number(section, key) ?? 1
    }

    /// A `[font]` step in points.
    public func fontStep(_ key: String) -> CGFloat {
        CGFloat(shellNumber("font", key) ?? FallbackTheme.number("font", key) ?? 12)
    }

    /// A `[spacing]` token in points.
    public func spacing(_ key: String) -> CGFloat {
        CGFloat(shellNumber("spacing", key) ?? FallbackTheme.number("spacing", key) ?? 0)
    }

    // MARK: - Parsing

    /// `#rrggbb`, `#rrggbbaa` and the `rgba(r,g,b,a)` form `[hyprland]` gradient
    /// tokens resolve to. A gradient carries several stops; the first one is the
    /// colour a flat iOS border can show, and the rest are not invented away.
    static func parse(hex value: String) -> (Double, Double, Double)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("rgba(") || trimmed.hasPrefix("rgb(") {
            let inner = trimmed.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3 else { return nil }
            return (parts[0] / 255, parts[1] / 255, parts[2] / 255)
        }
        var scalars = Substring(trimmed)
        if scalars.hasPrefix("#") { scalars = scalars.dropFirst() }
        // A Hyprland gradient is two space-separated stops and an angle, in
        // either the rgba() or the hash form: take the first stop rather than
        // refusing the whole key.
        if let space = scalars.firstIndex(of: " ") { scalars = scalars[..<space] }
        guard scalars.count == 6 || scalars.count == 8, let number = UInt32(scalars, radix: 16) else { return nil }
        let shifted = scalars.count == 8 ? number >> 8 : number
        return (Double((shifted >> 16) & 0xff) / 255,
                Double((shifted >> 8) & 0xff) / 255,
                Double(shifted & 0xff) / 255)
    }
}

