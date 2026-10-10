import Foundation

/// HERDR-4. `GET /v1/herdr/operator-rows[?agent=]`
/// (`contracts/herdr-operator-rows.schema.json`): what one pane's Quick dock,
/// key presets and harness segment show.
///
/// core resolves the operator's own Collie-format TOML rows against what ships
/// (replace per surface, never merge; narrowest scope wins), so this client
/// only draws the answer and sends what a tap says:
///
/// * a quick item → `/text` with `submit` (the same proof as the composer);
/// * a key row → one `/keys` call with all its chords, in order;
/// * a harness button → its bare command through `/text submit` — the agent's
///   own picker opens in the pane, so no list of models is kept anywhere;
/// * an operator command with an argument hint → into the composer to finish.
///
/// `danger` / `confirm` rows need a second tap.
public struct HerdrOperatorRowsDTO: Decodable, Equatable, Sendable {
    public struct Quick: Decodable, Equatable, Sendable, Identifiable {
        /// `confirm` / `common` for what ships (the client words it);
        /// nil for an operator's group, which carries its own `title`.
        public let id: String?
        public let title: String?
        public let items: [String]
        public let isOperator: Bool
        public var identity: String { id ?? "op:" + (title ?? "") }
        enum CodingKeys: String, CodingKey { case id, title, items, isOperator = "operator" }
    }

    public struct Key: Decodable, Equatable, Sendable, Identifiable {
        public let label: String
        public let keys: [String]
        public let danger: Bool
        public let isOperator: Bool
        public var id: String { label }
        enum CodingKeys: String, CodingKey { case label, keys, danger, isOperator = "operator" }
    }

    public struct Harness: Decodable, Equatable, Sendable, Identifiable {
        /// `model` / `effort` / `compact` / `resume` for what ships.
        public let harnessID: String?
        public let label: String?
        public let command: String
        public let confirm: Bool
        public let isOperator: Bool
        public var id: String { command }
        enum CodingKeys: String, CodingKey {
            case harnessID = "id", label, command, confirm, isOperator = "operator"
        }
    }

    public struct Command: Decodable, Equatable, Sendable, Identifiable {
        public let command: String
        public let description: String?
        public let argHint: String?
        public let confirm: Bool
        public var id: String { command }
        enum CodingKeys: String, CodingKey {
            case command, description, confirm, argHint = "arg_hint"
        }
    }

    public struct Warning: Decodable, Equatable, Sendable {
        public let code: String
        public let detail: String
    }

    public struct Source: Decodable, Equatable, Sendable {
        public let file: String
        public let origin: String
        public let warning: Warning?
    }

    public let agent: String?
    public let family: String
    public let quick: [Quick]
    public let keys: [Key]
    public let harness: [Harness]
    public let commands: [Command]
    public let sources: [Source]

    /// The first file that has something to say, for the dock's one line.
    public var warning: (file: String, warning: Warning)? {
        sources.lazy.compactMap { source in source.warning.map { (source.file, $0) } }.first
    }
}

extension HerdrOperatorRowsDTO {
    /// The presets beside the keys row. What ships leaves out the two the
    /// row already has (^C, ^D); an operator's rows are all theirs, kept whole.
    var presets: [Key] {
        let fixed = Set(HerdrKeyCap.row.map { $0.key.lowercased() })
        return keys.filter { $0.isOperator || $0.keys.count != 1 || !fixed.contains($0.keys[0].lowercased()) }
    }

    /// What ships, for a core that predates the route (`404`): the same rows
    /// core's own defaults give, so an older computer still gets a Quick dock.
    static func shipped(agent: String?) -> HerdrOperatorRowsDTO {
        let name = agent?.lowercased()
        let family = name.map(HerdrPaneKind.family) ?? "shell"
        let quick: [Quick] = name == nil
            ? [Quick(id: "confirm", title: nil, items: ["y", "n"], isOperator: false)] // non-copy: sent verbatim
            : [Quick(id: "confirm", title: nil, items: ["yes", "no"], isOperator: false), // non-copy: sent verbatim
               Quick(id: "common", title: nil, // non-copy
                     items: ["continue", "commit and push", "retry", "skip"], isOperator: false)] // non-copy: sent verbatim
        let keys: [Key] = [("c", false), ("d", true), ("u", false), ("r", false), ("l", false), ("z", true)].map {
            Key(label: "Ctrl " + $0.0.uppercased(), keys: ["ctrl+" + $0.0], danger: $0.1, isOperator: false) // non-copy: key cap names
        }
        let names: [String] = switch family {
        case "claude": ["model", "effort", "compact", "resume"] // non-copy: command names
        case "codex": ["model", "compact", "resume"] // non-copy: command names
        default: []
        }
        let harness = names.map { Harness(harnessID: $0, label: nil, command: "/" + $0, confirm: false, isOperator: false) }
        return HerdrOperatorRowsDTO(agent: name, family: family, quick: quick, keys: keys, harness: harness,
                                    commands: [], sources: [])
    }
}

/// What kind of pane a row set is for, from the layout.
enum HerdrPaneKind {
    /// The agent name core resolves rows for: Herdr's own name for the
    /// detected agent, or nil for a shell (a pane with no agent).
    static func agentName(_ pane: HerdrPaneDTO?) -> String? {
        guard let agent = pane?.agent else { return nil }
        return agentName(agent: agent.name ?? agent.kind ?? "")
    }

    /// A name core accepts as `?agent=`, lowercased, or nil.
    static func agentName(agent: String) -> String? {
        let raw = agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty, raw.count <= 40,
              raw.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }),
              raw.unicodeScalars.first.map({ CharacterSet.alphanumerics.contains($0) }) == true else { return nil }
        return raw
    }

    /// Collie's family fold (`claude-code` → `claude`), for the shipped fallback.
    static func family(_ name: String) -> String {
        for family in ["claude", "codex", "opencode", "omp", "grok", "agy", "antigravity"] where name.hasPrefix(family) {
            return family
        }
        if name == "pi" || name.hasPrefix("pi-") || name.hasPrefix("pi.") { return "pi" } // non-copy
        return name
    }
}

/// A row that needs a second tap: the first one arms it for a few seconds.
struct HerdrArmed: Equatable, Sendable {
    let id: String
    let until: Date

    static let window: TimeInterval = 3

    func holds(_ id: String, now: Date = Date()) -> Bool { self.id == id && now < until }
}
