import Foundation

/// The four things codex asks the *client* for, projected by core into one
/// bounded row each (`omodachi-core/docs/agent.md`, "Approvals and input
/// requests"). The handle is the provider's own request id; this client never
/// invents one, and never answers on the user's behalf.

/// One scalar line of an approval's `details`. Core promises scalars and short
/// strings only, so a detail is a label and a value — never a nested document
/// this view would have to render generically.
struct AgentChatDetail: Identifiable, Equatable, Sendable {
    let key: String
    let value: String
    var id: String { key }
    /// `command_kind` reads as "command kind"; the host's key names are
    /// snake_case and are shown as words rather than re-spelled here.
    var label: String { key.replacingOccurrences(of: "_", with: " ") }
}

/// A `userInput` question. Options are the provider's own labels; a question
/// with none is answered with free text.
struct AgentChatQuestion: Identifiable, Equatable, Sendable {
    let id: String
    let header: String?
    let question: String
    let secret: Bool
    let options: [String]
}

enum AgentChatApprovalState: Equatable, Sendable {
    case pending
    /// A decision is in flight. The card stays on screen and its buttons are
    /// inert: a second tap must not send a second answer to the same request.
    case deciding(String)
    /// `source` is `client` when this device answered and `elsewhere` when the
    /// same prompt was answered on the host (`serverRequest/resolved`).
    case resolved(decision: String?, source: String)
}

struct AgentChatApproval: Identifiable, Equatable, Sendable {
    let requestID: String
    let kind: String
    let summary: String
    let details: [AgentChatDetail]
    let questions: [AgentChatQuestion]
    /// What the provider says may be answered. An empty list is a `userInput`
    /// prompt, which is answered with values rather than a decision.
    let decisions: [String]
    var state: AgentChatApprovalState = .pending

    var id: String { requestID }
    var isPending: Bool { if case .resolved = state { false } else { true } }
    var isDeciding: Bool { if case .deciding = state { true } else { false } }

    /// The kinds core names. An unfamiliar one is shown by its own word rather
    /// than mapped onto a sentence that might not be true.
    var title: String {
        switch kind {
        case "commandExecution": Strings.approvalKindCommand
        case "fileChange": Strings.approvalKindFileChange
        case "permissions": Strings.approvalKindPermissions
        case "userInput": Strings.approvalKindUserInput
        default: kind
        }
    }

    static func label(decision: String) -> String {
        switch decision {
        case "accept": Strings.approvalAccept
        case "acceptForSession": Strings.approvalAcceptSession
        case "decline": Strings.approvalDecline
        case "cancel": Strings.actionCancel
        default: decision
        }
    }
}

struct AgentChatApprovalResolution: Equatable, Sendable {
    let requestID: String
    let kind: String
    let decision: String
    let resolved: Bool
}

/// `thread/status/changed`, as core projects it. `waiting` is the provider's
/// own answer to "is it waiting on me", which is the one thing a pane heuristic
/// cannot see.
struct AgentChatStatus: Equatable, Sendable {
    var type: String?
    var activeFlags: [String] = []
    var waiting: String?
    static let unknown = AgentChatStatus(type: nil, activeFlags: [], waiting: nil)

    var label: String {
        switch waiting {
        case "approval": Strings.agentWaitingOnYou
        case "user_input": Strings.agentNeedsInput
        default: type ?? "—"
        }
    }
}

/// `thread/tokenUsage/updated` merged with `account/rateLimits/updated`, as
/// `GET …/chat/usage` serves it. Every field is optional because a host on an
/// API key never receives rate limits at all — that is a real host state, not a
/// missing value to be invented.
struct AgentChatUsage: Equatable, Sendable {
    struct Tokens: Equatable, Sendable {
        var inputTokens = 0
        var cachedInputTokens = 0
        var cacheWriteInputTokens = 0
        var outputTokens = 0
        var reasoningOutputTokens = 0
        var totalTokens = 0
    }
    struct Window: Equatable, Sendable {
        var usedPercent: Double?
        var resetsAt: Int?
        var windowDurationMins: Int?
        /// 300 minutes is the 5-hour window and 10080 is the week; anything
        /// else is named by its own duration rather than by a guess.
        var label: String {
            switch windowDurationMins {
            case .some(300): "5h"
            case .some(10080): "weekly"
            case .some(let minutes) where minutes >= 1440: "\(minutes / 1440)d"
            case .some(let minutes) where minutes >= 60: "\(minutes / 60)h"
            case .some(let minutes): "\(minutes)m"
            case .none: "quota"
            }
        }
    }
    var last: Tokens?
    var total: Tokens?
    var modelContextWindow: Int?
    var primary: Window?
    var secondary: Window?
    var planType: String?
    var model: String?
    var effort: String?

    static let empty = AgentChatUsage()

    /// The share of the context window the last turn occupied. `nil` when the
    /// provider has not reported a window, which is the case before the first
    /// turn of a fresh attach.
    var contextFraction: Double? {
        guard let window = modelContextWindow, window > 0, let used = last?.totalTokens else { return nil }
        return min(1, max(0, Double(used) / Double(window)))
    }
    var windows: [Window] { [primary, secondary].compactMap { $0 } }
    var isEmpty: Bool { last == nil && total == nil && primary == nil && secondary == nil }
}

/// `GET /v1/agent/default/models`. codex has no model setter: model and
/// reasoning effort ride the turn, so a choice here is an override carried by
/// the next message and confirmed by `thread/settings/updated`.
struct AgentModelDescriptor: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let model: String?
    let displayName: String?
    let description: String?
    let hidden: Bool
    let isDefault: Bool
    let defaultEffort: String?
    let efforts: [String]
    var name: String { displayName ?? model ?? id }
    enum CodingKeys: String, CodingKey {
        case id, model, description, hidden, efforts
        case displayName = "display_name", isDefault = "is_default", defaultEffort = "default_effort"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        defaultEffort = try c.decodeIfPresent(String.self, forKey: .defaultEffort)
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
    }
}

struct AgentModelCatalog: Equatable, Sendable, Decodable {
    let models: [AgentModelDescriptor]
    let defaultID: String?
    enum CodingKeys: String, CodingKey { case models; case defaultID = "default" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decodeIfPresent([AgentModelDescriptor].self, forKey: .models) ?? []
        defaultID = try c.decodeIfPresent(String.self, forKey: .defaultID)
    }
    init(models: [AgentModelDescriptor], defaultID: String?) {
        self.models = models; self.defaultID = defaultID
    }
    /// Hidden models are the provider's own answer to "do not offer this".
    var offered: [AgentModelDescriptor] { models.filter { !$0.hidden } }
    func descriptor(_ id: String?) -> AgentModelDescriptor? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }
}

// MARK: - Wire

/// `details` is a bounded provider projection, so it is read leniently: scalar
/// values become display lines, `questions` becomes the typed list, and
/// anything else is skipped rather than rendered as raw JSON.
enum AgentChatJSON: Decodable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([AgentChatJSON]), object([String: AgentChatJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([AgentChatJSON].self) { self = .array(value); return }
        if let value = try? container.decode([String: AgentChatJSON].self) { self = .object(value); return }
        self = .null
    }

    /// One line of text, or nil when this value is a structure that has its own
    /// rendering. Numbers keep integer spelling so `500` is not `500.0`.
    var scalar: String? {
        switch self {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value): value == value.rounded() && abs(value) < 1e15
            ? String(Int(value)) : String(value)
        case .bool(let value): value ? "yes" : "no"
        case .null: nil
        case .array(let values): values.compactMap(\.scalar).isEmpty ? nil : values.compactMap(\.scalar).joined(separator: ", ")
        case .object(let values): values.isEmpty ? nil : values.keys.sorted()
            .compactMap { key in values[key]?.scalar.map { "\(key): \($0)" } }
            .joined(separator: ", ")
        }
    }
    var object: [String: AgentChatJSON]? { if case .object(let value) = self { value } else { nil } }
    var array: [AgentChatJSON]? { if case .array(let value) = self { value } else { nil } }
    var text: String? { if case .string(let value) = self { value } else { nil } }
    var flag: Bool { if case .bool(let value) = self { value } else { false } }
}

struct AgentChatApprovalWire: Decodable, Sendable {
    let requestID: String
    let kind: String
    let summary: String?
    let details: [String: AgentChatJSON]?
    let decisions: [String]?
    enum CodingKeys: String, CodingKey { case requestID = "request_id", kind, summary, details, decisions }

    /// `item_id` and `turn_id` identify the row for the provider, not for the
    /// reader, so they are not drawn as detail lines.
    private static let internalKeys: Set<String> = ["item_id", "turn_id", "questions", "approval_id"]

    func value() -> AgentChatApproval {
        let fields = details ?? [:]
        let lines = fields.keys.sorted()
            .filter { !Self.internalKeys.contains($0) }
            .compactMap { key in fields[key]?.scalar.map { AgentChatDetail(key: key, value: $0) } }
        let questions = (fields["questions"]?.array ?? []).prefix(8).compactMap { row -> AgentChatQuestion? in
            guard let object = row.object, let id = object["id"]?.text, !id.isEmpty,
                  let question = object["question"]?.text ?? object["header"]?.text else { return nil }
            return AgentChatQuestion(id: id, header: object["header"]?.text, question: question,
                                     secret: object["secret"]?.flag ?? false,
                                     options: (object["options"]?.array ?? []).compactMap(\.text))
        }
        return AgentChatApproval(requestID: requestID, kind: kind,
                                 summary: summary ?? "", details: lines, questions: Array(questions),
                                 decisions: decisions ?? [])
    }
}

struct AgentChatStatusWire: Decodable, Sendable {
    let type: String?
    let activeFlags: [String]?
    let waiting: String?
    enum CodingKeys: String, CodingKey { case type, activeFlags, waiting }
    func value() -> AgentChatStatus { .init(type: type, activeFlags: activeFlags ?? [], waiting: waiting) }
}

struct AgentChatUsageWire: Decodable, Sendable {
    struct TokenSet: Decodable, Sendable {
        let last: Counts?
        let total: Counts?
        let modelContextWindow: Int?
    }
    struct Counts: Decodable, Sendable {
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let cacheWriteInputTokens: Int?
        let outputTokens: Int?
        let reasoningOutputTokens: Int?
        let totalTokens: Int?
        func value() -> AgentChatUsage.Tokens {
            .init(inputTokens: inputTokens ?? 0, cachedInputTokens: cachedInputTokens ?? 0,
                  cacheWriteInputTokens: cacheWriteInputTokens ?? 0, outputTokens: outputTokens ?? 0,
                  reasoningOutputTokens: reasoningOutputTokens ?? 0, totalTokens: totalTokens ?? 0)
        }
    }
    struct Limits: Decodable, Sendable {
        struct Window: Decodable, Sendable {
            let usedPercent: Double?
            let resetsAt: Int?
            let windowDurationMins: Int?
            func value() -> AgentChatUsage.Window {
                .init(usedPercent: usedPercent, resetsAt: resetsAt, windowDurationMins: windowDurationMins)
            }
        }
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }
    let tokens: TokenSet?
    let rate_limits: Limits?
    let model: String?
    let effort: String?

    func value() -> AgentChatUsage {
        .init(last: tokens?.last?.value(), total: tokens?.total?.value(),
              modelContextWindow: tokens?.modelContextWindow,
              primary: rate_limits?.primary?.value(), secondary: rate_limits?.secondary?.value(),
              planType: rate_limits?.planType, model: model, effort: effort)
    }
}
