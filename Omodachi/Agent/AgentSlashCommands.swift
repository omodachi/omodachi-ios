import Foundation

struct AgentSlashDescriptor: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let argumentHint: String?
    let execution: String
    let available: Bool
    let reason: String?
    let turnPolicy: String
    enum CodingKeys: String, CodingKey {
        case id, name, description, execution, available, reason
        case argumentHint = "argument_hint", turnPolicy = "turn_policy"
    }
}
struct AgentSlashCatalog: Decodable, Equatable, Sendable {
    let revision: String
    let provider: String
    let providerVersion: String
    let commands: [AgentSlashDescriptor]
    enum CodingKeys: String, CodingKey { case revision, provider, commands; case providerVersion = "provider_version" }
}
struct AgentSlashInvocation: Equatable, Sendable {
    let name: String
    /// Includes original whitespace separator. The client never trims or
    /// tokenizes arguments: the provider owns command-specific interpretation.
    let arguments: String
    static func parse(_ text: String) -> Self? {
        guard text.first == "/", !text.hasPrefix("//") else { return nil }
        let rest = text.dropFirst()
        let boundary = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
        let name = String(rest[..<boundary])
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return .init(name: name, arguments: String(rest[boundary...]))
    }
}
struct AgentSlashNativeRequest: Equatable, Sendable {
    let action: String
    let arguments: String
}
struct AgentSlashResult: Equatable, Sendable {
    let status: String
    let commandID: String
    var message: String? = nil
    /// A maps only recognized native requests to existing UI. Never shell text.
    var nativeRequest: AgentSlashNativeRequest? = nil
}
struct AgentSlashState: Equatable, Sendable {
    var catalog: AgentSlashCatalog?
    var loading = false
    var executing = false
    var notice: String?
    var literalText = false

    func matches(_ draft: String) -> [AgentSlashDescriptor] {
        guard let parsed = AgentSlashInvocation.parse(draft), let catalog else { return [] }
        return catalog.commands.filter { parsed.name.isEmpty || $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasPrefix(parsed.name) }
    }
    func exact(_ draft: String) -> AgentSlashDescriptor? {
        guard let parsed = AgentSlashInvocation.parse(draft) else { return nil }
        return catalog?.commands.first { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == parsed.name }
    }
}
