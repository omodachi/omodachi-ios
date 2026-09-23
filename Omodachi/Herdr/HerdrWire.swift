import Foundation

/// `GET /v1/herdr/layout` and the two NDJSON streams behind
/// `/v1/herdr/panes/{pane}/{observe,control}` (`omodachi-core/docs/herdr.md`).
///
/// The bridge is a pipe: every line Herdr writes becomes one WebSocket TEXT
/// message, byte for byte. So this file decodes *Herdr's* messages, not a
/// second protocol invented here — `terminal.frame` and `terminal.closed` are
/// named, and anything a later Herdr adds decodes as `.other` and is ignored
/// rather than treated as a failure.

// MARK: - Layout

public struct HerdrPaneSizeDTO: Decodable, Equatable, Sendable {
    /// Herdr's rectangle for the pane inside its tab. Either value can be
    /// absent for a pane that has no layout row yet (a freshly split pane).
    public let cols: Int?
    public let rows: Int?
}

public struct HerdrPaneAgentDTO: Decodable, Equatable, Sendable {
    public let name: String?
    public let kind: String?
    public let status: String?
}

public struct HerdrPaneDTO: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let tabID: String?
    public let workspaceID: String?
    public let title: String?
    public let cwd: String?
    public let focused: Bool
    public let zoomed: Bool
    public let agentStatus: String?
    public let agent: HerdrPaneAgentDTO?
    public let size: HerdrPaneSizeDTO?
    public let revision: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, focused, zoomed, agent, size, revision
        case tabID = "tab_id", workspaceID = "workspace_id", agentStatus = "agent_status"
    }

    /// What the grid row says under the pane id. Herdr's own title when it has
    /// one; a pane it has not titled yet says so rather than borrowing one.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return "untitled"
    }

    /// §1.3: an agent pane shows its kind and Herdr's own status word. Herdr's
    /// authority over a codex/claude pane is a screen heuristic and `unknown`
    /// does not mean finished, so the word is never rewritten here.
    public var agentLabel: String? {
        guard let agent else { return nil }
        let kind = agent.kind ?? agent.name
        let status = agent.status ?? agentStatus
        return [kind, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var status: AgentStatus { AgentStatus(rawValue: agentStatus ?? "") ?? .unknown }
}

public struct HerdrTabDTO: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String?
    public let number: Int?
    public let focused: Bool
    public let zoomed: Bool
    public let agentStatus: String?
    public let panes: [HerdrPaneDTO]

    enum CodingKeys: String, CodingKey {
        case id, label, number, focused, zoomed, panes
        case agentStatus = "agent_status"
    }
}

public struct HerdrWorkspaceDTO: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String?
    public let number: Int?
    public let focused: Bool
    public let activeTabID: String?
    public let agentStatus: String?
    public let tabs: [HerdrTabDTO]

    enum CodingKeys: String, CodingKey {
        case id, label, number, focused, tabs
        case activeTabID = "active_tab_id", agentStatus = "agent_status"
    }
}

public struct HerdrFocusDTO: Decodable, Equatable, Sendable {
    public let workspaceID: String?
    public let tabID: String?
    public let paneID: String?
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", tabID = "tab_id", paneID = "pane_id"
    }
}

public struct HerdrLayoutDTO: Decodable, Equatable, Sendable {
    public let session: String?
    public let protocolVersion: Int?
    public let version: String?
    public let focused: HerdrFocusDTO?
    public let workspaces: [HerdrWorkspaceDTO]
    public let revision: Int

    enum CodingKeys: String, CodingKey {
        case session, version, focused, workspaces, revision
        case protocolVersion = "protocol"
    }

    public var panes: [HerdrPaneDTO] { workspaces.flatMap(\.tabs).flatMap(\.panes) }
    public func pane(_ id: String) -> HerdrPaneDTO? { panes.first { $0.id == id } }
    public func tab(of paneID: String) -> HerdrTabDTO? {
        workspaces.flatMap(\.tabs).first { $0.panes.contains { $0.id == paneID } }
    }
    public func workspace(of paneID: String) -> HerdrWorkspaceDTO? {
        workspaces.first { $0.tabs.contains { $0.panes.contains { $0.id == paneID } } }
    }

    /// The pane a freshly opened surface should show: the one Herdr says is
    /// focused, else the first pane in id order. Never a guess of "most
    /// interesting".
    public var preferredPane: String? {
        if let focused = focused?.paneID, pane(focused) != nil { return focused }
        return panes.first { $0.focused }?.id ?? panes.first?.id
    }
}

// MARK: - Sessions

/// One Herdr session on the host (`GET /v1/herdr/sessions`).
///
/// `owned` is the `omodachi` session core runs itself; `herdr_default` is the
/// one a plain `herdr` on that machine attaches to — usually where the user's
/// own work is. A session that is running but stopped answering says
/// `readable: false` and carries no counts, rather than being left out of the
/// list: a name the user knows is on their machine must still be visible.
public struct HerdrSessionDTO: Decodable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let running: Bool
    public let owned: Bool
    public let herdrDefault: Bool
    public let readable: Bool
    public let workspaces: Int?
    public let tabs: Int?
    public let panes: Int?
    public let agents: Int?
    public let version: String?

    enum CodingKeys: String, CodingKey {
        case name, running, owned, readable, workspaces, tabs, panes, agents, version
        case herdrDefault = "herdr_default"
    }

    /// A session with no pane has nothing to show, so the row says so rather
    /// than offering an entry into an empty grid.
    public var isEmpty: Bool { readable && (panes ?? 0) == 0 }
}

public struct HerdrSessionsDTO: Decodable, Equatable, Sendable {
    public let selected: String
    public let owned: String
    public let sessions: [HerdrSessionDTO]

    public func session(_ name: String) -> HerdrSessionDTO? { sessions.first { $0.name == name } }
}

public struct HerdrSessionSelectionDTO: Decodable, Equatable, Sendable {
    public let selected: String
    public let owned: String
    public let scope: String?
}

// MARK: - Stream messages

/// One line off the bridge. `.frame` and `.closed` are Herdr's own two; every
/// other line is carried as `.other` so a newer Herdr cannot break this client
/// by adding a message type.
public enum HerdrStreamMessage: Equatable, Sendable {
    case frame(HerdrFrame)
    case closed(reason: String?)
    case other(type: String)
}

/// A `terminal.frame`. `bytes` is base64 ANSI: `full` means repaint from
/// scratch, otherwise it is an increment that continues the last one.
public struct HerdrFrame: Equatable, Sendable {
    public let sequence: Int?
    public let encoding: String
    public let full: Bool
    public let width: Int?
    public let height: Int?
    public let bytes: [UInt8]
}

public enum HerdrFrameDecodingError: Error, Equatable, Sendable {
    case notJSON
    case missingType
    case unsupportedEncoding(String)
    case invalidBase64
    case oversize(Int)
}

public enum HerdrStreamDecoder {
    /// One WebSocket TEXT message in, one Herdr message out.
    ///
    /// The size cap is this client's own: a frame larger than it is a bug or an
    /// attack, and either way it is refused rather than fed into the emulator.
    public static let maximumFrameBytes = 4 * 1_048_576

    public static func decode(_ data: Data) throws -> HerdrStreamMessage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HerdrFrameDecodingError.notJSON
        }
        guard let type = object["type"] as? String else { throw HerdrFrameDecodingError.missingType }
        switch type {
        case "terminal.frame":
            // Herdr 0.8.2 emits `ansi` only. A different encoding is not
            // decoded blind: the bytes would reach the emulator as garbage.
            let encoding = object["encoding"] as? String ?? "ansi"
            guard encoding == "ansi" else { throw HerdrFrameDecodingError.unsupportedEncoding(encoding) }
            let text = object["bytes"] as? String ?? ""
            // `.ignoreUnknownCharacters` alone accepts anything at all — it
            // turns `"!!!!"` into zero bytes rather than refusing it — so the
            // alphabet is checked first and the option is left in only to let a
            // folded payload through.
            guard isBase64(text), let payload = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) else {
                throw HerdrFrameDecodingError.invalidBase64
            }
            guard payload.count <= maximumFrameBytes else {
                throw HerdrFrameDecodingError.oversize(payload.count)
            }
            return .frame(.init(sequence: object["seq"] as? Int,
                                encoding: encoding,
                                full: object["full"] as? Bool ?? false,
                                width: object["width"] as? Int,
                                height: object["height"] as? Int,
                                bytes: [UInt8](payload)))
        case "terminal.closed":
            return .closed(reason: object["reason"] as? String)
        default:
            return .other(type: type)
        }
    }

    public static func decode(text: String) throws -> HerdrStreamMessage {
        try decode(Data(text.utf8))
    }

    /// The base64 alphabet, its padding, and the whitespace a folded encoder
    /// inserts. Nothing else.
    static func isBase64(_ value: String) -> Bool {
        value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 43 || $0 == 47 || $0 == 61 || $0 == 10 || $0 == 13 || $0 == 32
        }
    }
}

// MARK: - Control commands

/// The four commands `control` reads on stdin, and the one thing `observe`
/// accepts. Their field names are Herdr's, forwarded as written
/// (`herdr_bridge.py:83-101`); nothing else may be sent, because the bridge
/// closes the socket with `invalid_control_command` for anything it does not
/// recognize.
public enum HerdrControlCommand: Equatable, Sendable {
    case input(text: String)
    case resize(cols: Int, rows: Int)
    case scroll(lines: Int)
    case release
    /// `observe` reads no stdin on 0.8.2, so the bridge itself answers this one
    /// by restarting the stream at the new size. It is not a Herdr command.
    case observeResize(cols: Int, rows: Int)

    public var json: String {
        switch self {
        case .input(let text):
            let escaped = String(decoding: (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8), as: UTF8.self)
            // `["…"]` → `"…"`: JSONSerialization is the only escaper used, so
            // control characters and non-ASCII survive exactly as typed.
            let quoted = String(escaped.dropFirst().dropLast())
            return "{\"type\":\"terminal.input\",\"text\":\(quoted)}"
        case let .resize(cols, rows):
            return "{\"type\":\"terminal.resize\",\"cols\":\(cols),\"rows\":\(rows)}"
        case .scroll(let lines):
            return "{\"type\":\"terminal.scroll\",\"lines\":\(lines)}"
        case .release:
            return "{\"type\":\"terminal.release\"}"
        case let .observeResize(cols, rows):
            return "{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}"
        }
    }
}

// MARK: - Geometry

/// `1…1000` on both axes is the bridge's own range (`herdr_bridge.py:73-79`);
/// an out-of-range request is `400 invalid_geometry`, so it is clamped here
/// rather than sent and refused.
public enum HerdrGeometry {
    public static let minimum = 1
    public static let maximum = 1000
    public static func clamp(cols: Int, rows: Int) -> (cols: Int, rows: Int) {
        (min(maximum, max(minimum, cols)), min(maximum, max(minimum, rows)))
    }
}

// MARK: - Pane action wire

/// The five routes under `/v1/herdr` and the exact bodies they accept.
public enum HerdrPaneAction: Equatable, Sendable {
    case split(direction: HerdrSplitDirection)
    case zoom(mode: HerdrZoomMode)
    /// No direction is absolute focus — the tap case. A direction is the
    /// neighbour case the 0.8.2 CLI can do on its own.
    case focus(direction: HerdrFocusDirection?)
    case close

    public var path: String {
        switch self {
        case .split: "split"; case .zoom: "zoom"; case .focus: "focus"; case .close: "close"
        }
    }

    public var body: [String: String] {
        switch self {
        case .split(let direction): ["direction": direction.rawValue]
        case .zoom(let mode): ["mode": mode.rawValue]
        case .focus(let direction): direction.map { ["direction": $0.rawValue] } ?? [:]
        case .close: [:]
        }
    }
}

public enum HerdrSplitDirection: String, Equatable, Sendable, CaseIterable { case right, down }
public enum HerdrZoomMode: String, Equatable, Sendable, CaseIterable { case on, off, toggle }
public enum HerdrFocusDirection: String, Equatable, Sendable, CaseIterable { case left, right, up, down }

public struct HerdrActionResponseDTO: Decodable, Equatable, Sendable {
    public let action: String
    public let pane: String?
    public let workspace: String?
}

public enum HerdrStreamMode: String, Equatable, Sendable, CaseIterable {
    case observe, control
}

/// The bridge's own error codes (`service.py:229-235`). `herdr_control_in_use`
/// is the one a client is expected to meet in normal use: it arrives as an HTTP
/// status *before* the WebSocket upgrade, so it is a refusal to read, not a
/// stream that died.
public struct HerdrRequestError: Error, Equatable, Sendable {
    public let code: String
    public let status: Int

    public var isControlInUse: Bool { code == "herdr_control_in_use" || status == 409 && code.isEmpty }

    public var userMessage: String { ReasonText.message(code, domain: .herdr, status: status) }
}
