import Foundation

enum Surface: Hashable { case terminal(UUID), remote, native(String) }
enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case working, blocked, done, idle, unknown
    var label: String { rawValue.capitalized }
    /// The role this status reads as. The colour itself comes from the host
    /// theme at draw time, so this enum stays free of one.
    var role: ThemeColorRole {
        switch self {
        case .working: .accent; case .blocked: .red; case .done: .green; case .idle: .muted; case .unknown: .yellow
        }
    }
}
enum TerminalKind: String, Codable, Sendable { case shell, agent, herdr, command }
struct HostProfile: Codable, Equatable, Sendable {
    var id = UUID()
    var hostname = "omarchy"
    var port = 22
    /// RELEASE-3b: no account until pairing hands one over. A named default
    /// here was somebody else's login on every host but the maintainer's, and
    /// `SSHTargetResolver` already treats an empty account as "nothing to
    /// dial" (`isValidAccount`).
    var username = ""
    var mock = true
    var herdrSession = ""
    var companionURL = ""
    var keyAccount: String { "ssh-\(id.uuidString)" }

    /// Identity of the SSH endpoint and credential selected by this profile.
    /// Companion transport details are deliberately excluded so pairing or
    /// endpoint canonicalization cannot orphan a retained SSH runtime.
    var sshConnectionIdentity: SSHConnectionIdentity {
        .init(profileID: id, hostname: hostname, port: port, username: username, mock: mock, keyAccount: keyAccount)
    }
}

struct SSHConnectionIdentity: Hashable, Sendable {
    let profileID: UUID
    let hostname: String
    let port: Int
    let username: String
    let mock: Bool
    let keyAccount: String
}
struct HostState: Sendable {
    var hostName = "Omarchy"
    var workspace = 1
    var focusWindow = "Terminal"
    var occupiedWorkspaces: Set<Int> = [1, 2, 4]
    var streamState = "Disconnected"
    var defaultAgentKind: String? = nil
    var agentStatus: AgentStatus = .unknown
    var herdrAgentCount: Int? = nil
    var online = false
    var toggles: [String: Bool] = ["trigger.toggle.top-bar": true, "trigger.toggle.notifications": true, "trigger.toggle.nightlight": false]
}
struct MenuItem: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    /// What the row draws when it carries no glyph of its own — an SF Symbol
    /// name, our mark, or the generic application window. It is never consulted
    /// for a row the host gave a drawable code point (MENU-1 §2).
    var icon: GlyphFallback = "circle"
    /// The host's own glyph for this row and the font it belongs to
    /// (`docs/fonts.md`). Empty means the host published none.
    var glyph: String = ""
    var iconFont: String = ""
    /// The row's place in the merged three-source menu, deepest parent last.
    /// A-19's second line for a search result is this path, not a guess.
    var path: [String] = []
    var aliases: [String] = []
    var children: [MenuItem] = []
    var route = "host"
    var enabled = true
    /// MENU-3: the host's reason code when it greyed this row on purpose
    /// (`condition_disabled`); the row says that sentence instead of `不可用`.
    var disabledReason: String?
    /// MENU-4 / A-68: the first tap arms the row, the second one sends it.
    var confirm = false
    var checked: Bool?
    var terminalArgv: [String]?
    var all: [MenuItem] { [self] + children.flatMap(\.all) }
}
struct SessionDescriptor: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var kind: TerminalKind
    var host: HostProfile
    var argv: [String]
    var createdAt = Date()
    var reattachable: Bool { kind == .agent || kind == .herdr }
    var reuseIdentity: SessionReuseIdentity {
        .init(kind: kind, connection: host.sshConnectionIdentity, namedSession: host.herdrSession, argv: argv)
    }
    /// §3: `user@host` is what the SSH surface and the lightweight bar call
    /// this session.
    /// Without an account (RELEASE-3b: nothing was paired) it is the host
    /// alone rather than a bare `@host`.
    var endpointLabel: String { host.username.isEmpty ? host.hostname : "\(host.username)@\(host.hostname)" }

    /// I18N-1: a descriptor is persisted and restored, so a title stored in it
    /// outlives the language it was written in — a session opened in Chinese
    /// still said `终端` after the device was switched to English. The panel's
    /// own shell therefore resolves its name when it is drawn; a session the
    /// host named keeps the host's own word.
    var displayTitle: String { kind == .shell ? Strings.sshTerminal : title }

    var targetLabel: String {
        switch kind {
        case .agent: "agent · default" // non-copy: the host's own agent id
        case .herdr: host.herdrSession.isEmpty ? Strings.panelHerdr : "session · \(host.herdrSession)"
        case .shell: Strings.panelSsh
        case .command: title
        }
    }
}

struct SessionReuseIdentity: Hashable, Sendable {
    let kind: TerminalKind
    let connection: SSHConnectionIdentity
    let namedSession: String
    let argv: [String]
}
enum SessionState: String, Sendable {
    case disconnected, connecting, connected, suspended, failed, exited
    /// I18N-1: the SSH title row drew this enum's `rawValue`, so a Chinese
    /// panel said `disconnected`. The wire word stays; the row says a word.
    var label: String {
        switch self {
        case .disconnected: Strings.sessionStateDisconnected
        case .connecting: Strings.sessionStateConnecting
        case .connected: Strings.sessionStateConnected
        case .suspended: Strings.sessionStateSuspended
        case .failed: Strings.sessionStateFailed
        case .exited: Strings.sessionStateExited
        }
    }
}
struct FixedArgvCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    var argv: [String] { [executable] + arguments }
    // SSH exec requests carry a string. Every token is POSIX quoted, including identifiers.
    // Agent task text NEVER travels through this path; task submission uses JSON to the core API.
    var sshExec: String { argv.map(Self.quote).joined(separator: " ") }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
enum HerdrCommandAdapter {
    static func agentAttach() -> FixedArgvCommand { .init(executable: "herdr", arguments: ["agent", "attach", "default"]) }
    static func agentPrompt(_ text: String) -> FixedArgvCommand { .init(executable: "herdr", arguments: ["agent", "prompt", "default", text]) }
    static func herdr(session: String?) -> FixedArgvCommand {
        guard let session, !session.isEmpty else { return .init(executable: "herdr", arguments: []) }
        return .init(executable: "herdr", arguments: ["session", "attach", session])
    }
}
