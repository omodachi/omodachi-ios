import Foundation

/// A credential provider keeps companion authorization separate from host URL
/// configuration. Implementations must never persist the token in UserDefaults
/// or include it in logs.
public protocol CompanionCredentialProviding: AnyObject, Sendable {
    func loadToken(account: String) throws -> String?
}

public struct CompanionHostConfiguration: Sendable, Equatable {
    public let endpoint: URL
    public let account: String

    public init(endpoint: URL, account: String? = nil) throws {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw CompanionHostError.invalidEndpoint
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        guard let normalized = components.url else { throw CompanionHostError.invalidEndpoint }
        self.endpoint = normalized
        self.account = account ?? normalized.absoluteString
        guard !self.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompanionHostError.invalidEndpoint
        }
    }
}

public enum CompanionHostError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case notConnected
    case missingCredential
    case unauthorized
    case unavailable(code: String?, message: String)
    case blocked(code: String?, message: String)
    case mismatch(code: String?, message: String)
    case staleTarget(message: String)
    case decoding(message: String)
    case transport(message: String)
    case protocolError(message: String)
    /// The host presented a certificate that is not the pinned one. This is a
    /// hard failure by contract: no fallback, no "continue anyway".
    case certificateChanged(observed: String, pinned: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: Strings.hostErrorInvalidEndpoint
        case .notConnected: Strings.hostErrorNotConnected
        case .missingCredential: Strings.hostErrorMissingCredential
        case .unauthorized: Strings.hostErrorUnauthorized
        case let .unavailable(_, message), let .blocked(_, message), let .mismatch(_, message): message
        case let .staleTarget(message), let .decoding(message), let .transport(message), let .protocolError(message): message
        case .certificateChanged: Strings.hostErrorCertificateChanged
        }
    }
}

public protocol CompanionServing: Sendable {
    func connect() async throws
    func disconnect() async
    func fetchState() async throws -> HostStateDTO
    func fetchSnapshot() async throws -> CompanionSnapshot
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter], targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse
    func invokeWorkspaceLayout(_ request: WorkspaceLayoutRequest) async throws -> CompanionActionResponse
    func selectWorkspace(_ id: Int) async throws
    /// A-64 rev 5 / review #24. The neighbour is named by the host, not by a
    /// client reading its own snapshot.
    func selectRelativeWorkspace(_ step: RemoteWorkspaceStep) async throws
    func wakeDesktop() async throws -> HostWakeResponseDTO
    func fetchShortcuts() async throws -> ShortcutSnapshot
    func executeShortcut(_ request: ShortcutExecutionRequest) async throws -> ShortcutExecutionResult
    func searchCatalog(_ query: String) async throws -> HostCatalogDTO
    func fetchTheme() async throws -> HostTheme
    func fetchThemeBackground(knownDigest: String?) async throws -> Data?
    func fetchFonts() async throws -> HostFontListDTO
    func fetchFontFile(id: String) async throws -> Data
    /// ICON-1. One icon from the host's icon theme, by the name the host itself
    /// published on a catalog row. `nil` means `304` — what the caller already
    /// holds is current.
    func fetchIcon(name: String, pixels: Int, knownDigest: String?) async throws -> HostIconBytes?
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error>
}

public extension CompanionServing {
    func searchCatalog(_ query: String) async throws -> HostCatalogDTO {
        throw CompanionHostError.protocolError(message: ReasonText.message("route_unavailable", domain: .host))
    }
    func fetchTheme() async throws -> HostTheme {
        throw CompanionHostError.unavailable(code: "theme_unavailable", message: ReasonText.message("theme_unavailable", domain: .host))
    }
    func fetchThemeBackground(knownDigest: String?) async throws -> Data? { nil }
    func fetchFonts() async throws -> HostFontListDTO {
        throw CompanionHostError.unavailable(code: "fonts_unavailable", message: ReasonText.message("fonts_unavailable", domain: .host))
    }
    func fetchFontFile(id: String) async throws -> Data {
        throw CompanionHostError.unavailable(code: "font_not_found", message: ReasonText.message("font_not_found", domain: .host))
    }
    func fetchIcon(name: String, pixels: Int, knownDigest: String?) async throws -> HostIconBytes? {
        throw CompanionHostError.unavailable(code: "icon_not_found", message: ReasonText.message("icon_not_found", domain: .host))
    }
    func fetchShortcuts() async throws -> ShortcutSnapshot { throw ShortcutWireError.unavailableContext }
    func executeShortcut(_ request: ShortcutExecutionRequest) async throws -> ShortcutExecutionResult { throw ShortcutWireError.unavailableContext }
    func wakeDesktop() async throws -> HostWakeResponseDTO {
        throw CompanionHostError.protocolError(message: ReasonText.message("route_unavailable", domain: .host))
    }
    func selectWorkspace(_ id: Int) async throws {
        throw CompanionHostError.protocolError(message: ReasonText.message("route_unavailable", domain: .host))
    }
    func selectRelativeWorkspace(_ step: RemoteWorkspaceStep) async throws {
        throw CompanionHostError.protocolError(message: ReasonText.message("route_unavailable", domain: .host))
    }
    func invokeWorkspaceLayout(_ request: WorkspaceLayoutRequest) async throws -> CompanionActionResponse {
        throw WorkspaceLayoutRequestError(code: "workspace_preflight_unavailable")
    }
}

/// Device-scoped REST/WSS companion client. Creating this value performs no
/// network I/O; callers explicitly call `connect()` and then endpoint methods.
/// Every request rides a session whose TLS is decided only by the pinned host
/// fingerprint (`Security/HostTLSDelegate.swift`).
public actor CompanionHostClient: CompanionServing, RemoteSessionServing, MediaPairingServing {
    public let configuration: CompanionHostConfiguration
    private let credentials: CompanionCredentialProviding
    private let session: URLSession
    /// Events, chat and audio stay open for as long as the surface is on screen,
    /// so they cannot share the request/response session's resource timeout.
    private let sockets: URLSession
    private let tls: HostTLSDelegate
    private var bearerToken: String?
    private var socket: URLSessionWebSocketTask?
    private var socketID: UUID?

    public init(configuration: CompanionHostConfiguration,
                credentials: CompanionCredentialProviding,
                pinnedFingerprint: String?,
                session: URLSession? = nil) {
        self.configuration = configuration
        self.credentials = credentials
        let delegate = HostTLSDelegate(pinnedFingerprint: pinnedFingerprint)
        tls = delegate
        func options() -> URLSessionConfiguration {
            let value = URLSessionConfiguration.ephemeral
            value.urlCredentialStorage = nil
            value.httpCookieStorage = nil
            value.httpShouldSetCookies = false
            value.urlCache = nil
            value.requestCachePolicy = .reloadIgnoringLocalCacheData
            return value
        }
        let streaming = options()
        streaming.timeoutIntervalForRequest = 60
        streaming.timeoutIntervalForResource = .infinity
        sockets = URLSession(configuration: streaming, delegate: delegate, delegateQueue: nil)
        if let session { self.session = session }
        else {
            let request = options()
            request.timeoutIntervalForRequest = 20
            request.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: request, delegate: delegate, delegateQueue: nil)
        }
    }

    /// Loads a device-scoped token from the injected Keychain provider. This is
    /// intentionally local and does not contact the host.
    public func connect() throws {
        let token = try credentials.loadToken(account: configuration.account)
        guard let token, !token.isEmpty, token.utf8.count <= 4089,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw CompanionHostError.missingCredential }
        bearerToken = token
    }

    public func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil; socketID = nil; bearerToken = nil
    }

    // MARK: - Host surfaces

    public func fetchState() async throws -> HostStateDTO { try await request(path: "v1/state") }
    public func fetchCapabilities() async throws -> HostCapabilitiesDTO { try await request(path: "v1/capabilities") }
    public func fetchCatalog() async throws -> HostCatalogDTO { try await request(path: "v1/catalog") }
    public func fetchHerdr() async throws -> HostHerdrDTO { try await request(path: "v1/herdr") }

    // MARK: - Herdr bridge (docs/herdr.md)

    /// The owned `omodachi` session as workspaces → tabs → panes. The session
    /// is core's, never a client value: there is nothing here to name but the
    /// pane.
    public func herdrLayout() async throws -> HerdrLayoutDTO { try await request(path: "v1/herdr/layout") }

    /// Every Herdr session on the host, and the one this device is on. The
    /// owned `omodachi` session is where every device starts; the user's own
    /// sessions are the reason this route exists (`docs/herdr.md`).
    public func herdrSessions() async throws -> HerdrSessionsDTO { try await request(path: "v1/herdr/sessions") }

    /// Move this device to one of them. The host refuses a name that is not a
    /// running session it just listed, so nothing here has to guess.
    @discardableResult
    public func herdrSelectSession(_ name: String) async throws -> HerdrSessionSelectionDTO {
        guard Self.isHerdrSession(name) else { throw CompanionHostError.protocolError(message: Strings.hostErrorBadRequest) }
        return try await request(path: "v1/herdr/sessions/\(name)/select", method: "POST",
                                 body: [String: String](), herdrOperation: true)
    }

    @discardableResult
    public func herdrPaneAction(pane: String, action: HerdrPaneAction) async throws -> HerdrActionResponseDTO {
        guard Self.isHerdrPane(pane) else { throw CompanionHostError.protocolError(message: Strings.hostErrorBadRequest) }
        return try await request(path: "v1/herdr/panes/\(pane)/\(action.path)", method: "POST",
                                 body: action.body, herdrOperation: true)
    }

    @discardableResult
    public func herdrSelectWorkspace(_ id: String) async throws -> HerdrActionResponseDTO {
        guard Self.isHerdrWorkspace(id) else { throw CompanionHostError.protocolError(message: Strings.hostErrorBadRequest) }
        return try await request(path: "v1/herdr/workspaces/\(id)/select", method: "POST",
                                 body: [String: String](), herdrOperation: true)
    }

    /// One `terminal session observe|control`, on the WSS this device already
    /// authenticated. `control` is refused with **HTTP 409** before the upgrade
    /// when another end holds the pane, which is why this returns the task
    /// rather than a stream: the caller reads `task.response` to tell a refusal
    /// from a transport failure.
    public func makeHerdrSocket(pane: String, mode: HerdrStreamMode, cols: Int, rows: Int,
                                takeover: Bool = false) throws -> URLSessionWebSocketTask {
        guard Self.isHerdrPane(pane) else { throw CompanionHostError.protocolError(message: Strings.hostErrorBadRequest) }
        let geometry = HerdrGeometry.clamp(cols: cols, rows: rows)
        var query = [URLQueryItem(name: "cols", value: String(geometry.cols)),
                     URLQueryItem(name: "rows", value: String(geometry.rows))]
        if mode == .control && takeover { query.append(URLQueryItem(name: "takeover", value: "true")) }
        return try socketTask(path: "v1/herdr/panes/\(pane)/\(mode.rawValue)", query: query,
                              maximumMessageSize: 8 * 1_048_576)
    }

    /// `wN:pN` and `wN` are the bridge's own patterns (`herdr_bridge.py:27-28`).
    /// Checking them here means a client value can never become a flag or a
    /// path segment of its own.
    static func isHerdrPane(_ value: String) -> Bool { matches(value, separator: "p") }
    /// `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}` is the bridge's own session alphabet
    /// (`herdr_bridge.py:40`). Checking it here keeps a name off the path.
    static func isHerdrSession(_ value: String) -> Bool {
        guard (1...64).contains(value.count), let first = value.first,
              first.isASCII, first.isLetter || first.isNumber else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") }
    }
    static func isHerdrWorkspace(_ value: String) -> Bool {
        guard value.count >= 2, value.hasPrefix("w") else { return false }
        let digits = value.dropFirst()
        return digits.count <= 9 && digits.allSatisfy(\.isNumber)
    }
    private static func matches(_ value: String, separator: Character) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, isHerdrWorkspace(String(parts[0])),
              parts[1].first == separator else { return false }
        let digits = parts[1].dropFirst()
        return !digits.isEmpty && digits.count <= 9 && digits.allSatisfy(\.isNumber)
    }

    public func fetchSnapshot() async throws -> CompanionSnapshot {
        async let state: HostStateDTO = fetchState()
        async let capabilities: HostCapabilitiesDTO = fetchCapabilities()
        async let catalog: HostCatalogDTO = fetchCatalog()
        async let herdr: HostHerdrDTO = fetchHerdr()
        return try await CompanionSnapshot(state: state, capabilities: capabilities, catalog: catalog, herdr: herdr)
    }

    public func fetchShortcuts() async throws -> ShortcutSnapshot {
        let value: ShortcutListDTO = try await request(path: "v1/shortcuts")
        return try value.snapshot()
    }

    /// `GET /v1/catalog?q=` searches the same three-source merged catalog the
    /// tree is built from (`docs/local-integration.md`), so a result row is the
    /// same entry with the same route verdict — not a second action registry.
    public func searchCatalog(_ query: String) async throws -> HostCatalogDTO {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else { return try await fetchCatalog() }
        return try await request(path: "v1/catalog", query: [URLQueryItem(name: "q", value: trimmed)])
    }

    // MARK: - Theme and fonts

    public func fetchTheme() async throws -> HostTheme { try await request(path: "v1/theme") }
    public func fetchFonts() async throws -> HostFontListDTO { try await request(path: "v1/fonts") }

    /// `ETag` is the file's sha256, so a client that already holds the bytes
    /// sends `If-None-Match` and is answered `304` (`docs/theme.md`).
    public func fetchThemeBackground(knownDigest: String?) async throws -> Data? {
        try await bytes(path: "v1/theme/background", knownDigest: knownDigest, limit: 16 * 1_048_576)
    }

    public func fetchFontFile(id: String) async throws -> Data {
        // TERM-1: a `fallback-<coverage>` id is published too. The guard is
        // still here — it is what keeps a path out of the URL — but it asks
        // about the id's *shape*, not about a list of three spellings.
        guard HostFontRowDTO.isPublished(id) else {
            throw CompanionHostError.unavailable(code: "font_not_found", message: ReasonText.message("font_not_found", domain: .host))
        }
        guard let data = try await bytes(path: "v1/fonts/\(id)", knownDigest: nil, limit: 40 * 1_048_576) else {
            throw CompanionHostError.decoding(message: ReasonText.message("fonts_unavailable", domain: .host))
        }
        return data
    }

    /// `GET /v1/icons/{name}?size=<pixels>` (`omodachi-core/docs/icons.md`).
    ///
    /// The name is whatever the host wrote in the row's `icon` — a themed name
    /// or an absolute path — so it is percent-encoded rather than validated
    /// against this client's idea of a name: core owns which names it will
    /// answer for, and a name this client rejected would be a row core could
    /// draw and the app could not.
    public func fetchIcon(name: String, pixels: Int, knownDigest: String?) async throws -> HostIconBytes? {
        guard !name.isEmpty, name.utf8.count <= 1024 else {
            throw CompanionHostError.unavailable(code: "icon_not_found", message: ReasonText.message("icon_not_found", domain: .host))
        }
        let size = min(512, max(8, pixels))
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let escaped = name.addingPercentEncoding(withAllowedCharacters: allowed),
              var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false) else {
            throw CompanionHostError.unavailable(code: "icon_not_found", message: ReasonText.message("icon_not_found", domain: .host))
        }
        components.percentEncodedPath = components.path.hasSuffix("/")
            ? components.path + "v1/icons/" + escaped : components.path + "/v1/icons/" + escaped
        components.queryItems = [URLQueryItem(name: "size", value: String(size))]
        guard let url = components.url else {
            throw CompanionHostError.unavailable(code: "icon_not_found", message: ReasonText.message("icon_not_found", domain: .host))
        }
        var value = URLRequest(url: url)
        if let knownDigest, !knownDigest.isEmpty {
            value.setValue("\"\(knownDigest)\"", forHTTPHeaderField: "If-None-Match")
        }
        let (data, http) = try await send(value, method: "GET", limit: 4 * 1_048_576)
        if http.statusCode == 304 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(status: http.statusCode, code: Self.errorCode(data))
        }
        let etag = (http.value(forHTTPHeaderField: "ETag") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"W/ "))
        return HostIconBytes(data: data, etag: etag)
    }

    public func executeShortcut(_ captured: ShortcutExecutionRequest) async throws -> ShortcutExecutionResult {
        guard Self.isSafeIdentifier(captured.actionRef) else { throw ShortcutWireError.unavailableContext }
        let result: CompanionActionResponse = try await request(
            path: "v1/actions/\(captured.actionRef):invoke", method: "POST", body: ShortcutInvokeBody(captured))
        let status: ShortcutExecutionStatus = switch result.status {
        case .applied: .applied
        case .accepted: .accepted
        case .failed, .rejected: .rejected
        default: .unknown
        }
        return .init(status: status, message: result.message,
                     observed: result.observed, code: result.code)
    }

    public func wakeDesktop() async throws -> HostWakeResponseDTO {
        try await request(path: "v1/control/wake", method: "POST", body: EmptyBody())
    }

    // MARK: - AUTH-1 · approving the host's password prompts

    // MARK: - The clipboard (CLIP-1)

    /// CLIP-1's limit, both ways. It is the host's, and the client holds it too
    /// so that a 70 KB paste is refused here rather than on the wire.
    static let clipboardLimit = 65536

    /// The host's clipboard as text. An empty string means nothing is copied;
    /// the refusals are `ClipboardHostError`, so "the switch is off" never
    /// reads as "this device is not paired".
    public func fetchClipboard() async throws -> String {
        let request = URLRequest(url: configuration.endpoint.appendingPathComponent("v1/clipboard"))
        let (data, http) = try await send(request, method: "GET", limit: Self.clipboardLimit + 1)
        guard (200..<300).contains(http.statusCode) else {
            throw ClipboardHostError(code: Self.errorCode(data) ?? "clipboard_unavailable",
                                     status: http.statusCode)
        }
        guard data.count <= Self.clipboardLimit else {
            throw ClipboardHostError(code: "clipboard_too_large", status: 413)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClipboardHostError(code: "clipboard_not_text", status: 409)
        }
        return text
    }

    /// Put this device's text on the host's clipboard. The body is the text:
    /// there is nothing else to say about a paste, and an envelope would only
    /// be one more place the content could be kept.
    @discardableResult
    public func putClipboard(_ text: String) async throws -> Int {
        let encoded = Data(text.utf8)
        guard !encoded.isEmpty else { throw ClipboardHostError(code: "clipboard_invalid", status: 400) }
        guard encoded.count <= Self.clipboardLimit else {
            throw ClipboardHostError(code: "clipboard_too_large", status: 413)
        }
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent("v1/clipboard"))
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type") // non-copy: a media type
        request.setValue("application/json", forHTTPHeaderField: "Accept") // non-copy: a media type
        request.httpBody = encoded
        let (data, http) = try await send(request, method: "PUT", limit: 65536)
        guard (200..<300).contains(http.statusCode) else {
            throw ClipboardHostError(code: Self.errorCode(data) ?? "clipboard_unavailable",
                                     status: http.statusCode)
        }
        guard let receipt = try? JSONDecoder().decode(ClipboardWriteReceiptDTO.self, from: data) else {
            throw ClipboardHostError(code: "clipboard_unavailable", status: http.statusCode)
        }
        return receipt.bytes
    }

    /// The host's own half of the clipboard switch, from `GET /v1/preferences`.
    /// A host that predates CLIP-1 answers without the key, which reads as off.
    public func fetchClipboardMode() async throws -> String {
        let value: HostPreferencesDTO = try await request(path: "v1/preferences")
        return value.values.clipboardSync ?? "off"
    }

    /// Both switches, plus a fresh one-shot challenge to enrol with.
    public func fetchApprovalKeys() async throws -> HostApprovalKeys {
        try await request(path: "v1/auth/keys")
    }

    /// Register this device's public key. The signature over the challenge is
    /// what proves the device holds the private half; without it the host
    /// would be storing a key somebody else could have named.
    public func enrollApprovalKey(_ body: HostApprovalEnrollment) async throws -> HostApprovalKeyRecord {
        try await request(path: "v1/auth/keys", method: "POST", body: body)
    }

    /// The device's own half of the two switches, without re-enrolling.
    public func setApprovalEnabled(_ enabled: Bool) async throws -> HostApprovalKeyRecord {
        try await request(path: "v1/auth/keys/enabled", method: "POST", body: HostApprovalKeyState(enabled: enabled))
    }

    /// Unregister. After this the host has no key for this device and cannot
    /// ask it anything, whatever its own preference says.
    public func revokeApprovalKey() async throws -> HostApprovalRevocation {
        try await request(path: "v1/auth/keys", method: "DELETE", body: Optional<EmptyBody>.none)
    }

    /// Answer one prompt. `approve` carries the signature over the nonce;
    /// `decline` carries nothing, because refusing is the fail-safe direction.
    public func resolveApproval(_ approvalID: String, decision: HostApprovalDecision) async throws -> HostApprovalResolution {
        guard Self.isSafeIdentifier(approvalID), approvalID.hasPrefix("appr_") else {
            throw CompanionHostError.protocolError(message: Strings.hostErrorBadRequest)
        }
        return try await request(path: "v1/auth/approvals/\(approvalID)", method: "POST", body: decision)
    }

    /// What this device is still being asked, for a reconnect that missed the
    /// event. An approval that already expired is simply not in the list.
    public func pendingApprovals() async throws -> HostPendingApprovals {
        try await request(path: "v1/auth/approvals")
    }

    /// With a Remote session open the host refuses this with
    /// `remote_session_required`: a Panel tap cannot move the screen out from
    /// under the stream. The client navigates inside the remote desktop instead.
    public func selectWorkspace(_ id: Int) async throws {
        guard (1...2_147_483_647).contains(id) else { throw CompanionHostError.protocolError(message: Strings.hostErrorBadRequest) }
        let _: EmptyResponse = try await request(path: "v1/workspaces/\(id)/select", method: "POST", body: EmptyBody())
    }

    /// A-64 / GEST-1. `e+1` / `e-1`: core reads the collection it has just
    /// published, wraps, and inside a session acts on the output the session
    /// owns (`network.py:1163`, `service.relative_workspace`). The step is one
    /// of two constants, so nothing here is interpolated from host text.
    public func selectRelativeWorkspace(_ step: RemoteWorkspaceStep) async throws {
        let _: EmptyResponse = try await request(path: "v1/workspaces/relative/\(step.rawValue)/select",
                                                 method: "POST", body: EmptyBody())
    }

    public func invokeWorkspaceLayout(_ captured: WorkspaceLayoutRequest) async throws -> CompanionActionResponse {
        try await request(path: "v1/actions/\(WorkspaceLayoutRequest.entryID):invoke", method: "POST",
                          body: captured, workspaceLayoutOperation: true)
    }

    public func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter] = [:],
                       targetToken: String? = nil, stateRevision: Int? = nil) async throws -> CompanionActionResponse {
        guard entryID != WorkspaceLayoutRequest.entryID else { throw WorkspaceLayoutRequestError(code: "invalid_workspace_request") }
        guard Self.isSafeIdentifier(entryID), !catalogRevision.isEmpty, catalogRevision.utf8.count <= 256,
              parameters.count <= 32, targetToken.map({ $0.utf8.count <= 1024 }) ?? true else {
            throw CompanionHostError.protocolError(message: Strings.hostErrorBadRequest)
        }
        struct Body: Encodable {
            let request_id: String
            let catalog_revision: String
            let params: [String: CompanionParameter]
            let target_token: String?
            let state_revision: Int?
        }
        return try await request(path: "v1/actions/\(entryID):invoke", method: "POST",
            body: Body(request_id: UUID().uuidString, catalog_revision: catalogRevision,
                       params: parameters, target_token: targetToken, state_revision: stateRevision))
    }

    /// Submits text as one JSON data value. The text is never interpolated into
    /// a shell command; the host owns the fixed adapter and returns an explicit
    /// attach target when available.
    public func submitDefaultAgentTask(_ text: String, requestID: String = UUID().uuidString) async throws -> AgentTaskResponse {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 60_000, !requestID.isEmpty, requestID.utf8.count <= 128 else {
            throw CompanionHostError.blocked(code: "task_too_large", message: ReasonText.message("task_too_large", domain: .agent))
        }
        guard !clean.isEmpty else { throw CompanionHostError.blocked(code: "empty_task", message: ReasonText.message("empty_task", domain: .agent)) }
        struct Body: Encodable { let request_id: String; let agent_id = "default"; let text: String }
        let response: AgentTaskResponse = try await request(path: "v1/agent/tasks", method: "POST",
                                                            body: Body(request_id: requestID, text: text))
        guard response.agentID == "default" else {
            throw CompanionHostError.protocolError(message: Strings.hostErrorDifferentAgentTarget)
        }
        return response
    }

    // MARK: - Remote

    func remoteCapabilities() async throws -> RemoteCapabilitiesDTO {
        try await request(path: "v1/remote/capabilities", remoteOperation: true)
    }
    /// The host's own quality preference, already resolved to a rate. Remote
    /// plans against it instead of asking for the client's own ceiling.
    func remoteHostPreferences() async throws -> RemoteHostPreferences {
        try await request(path: "v1/preferences", remoteOperation: true)
    }
    func createRemoteSession(_ body: RemoteCreateRequest) async throws -> RemoteSessionDTO {
        try await remoteSession(path: "v1/remote/sessions", method: "POST", body: body)
    }
    func remoteSession(id: String) async throws -> RemoteSessionDTO {
        try await remoteSession(path: "v1/remote/sessions/\(try Self.sessionPath(id))")
    }
    func resizeRemoteSession(id: String, body: RemoteResizeRequest) async throws -> RemoteSessionDTO {
        try await remoteSession(path: "v1/remote/sessions/\(try Self.sessionPath(id))/resize", method: "POST", body: body)
    }
    func switchRemoteBackend(id: String, body: RemoteBackendRequest) async throws -> RemoteSessionDTO {
        try await remoteSession(path: "v1/remote/sessions/\(try Self.sessionPath(id))/backend", method: "POST", body: body)
    }
    func heartbeatRemoteSession(id: String) async throws -> RemoteHeartbeatDTO {
        try await request(path: "v1/remote/sessions/\(try Self.sessionPath(id))/heartbeat", method: "POST",
                          body: EmptyBody(), remoteOperation: true)
    }
    func reportRemotePresented(id: String, body: RemotePresentedRequest) async throws -> RemotePresentedDTO {
        try await request(path: "v1/remote/sessions/\(try Self.sessionPath(id))/presented", method: "POST",
                          body: body, remoteOperation: true)
    }
    /// Idempotent release. A second DELETE on a gone session is a success.
    func releaseRemoteSession(id: String) async throws -> RemoteReleaseDTO {
        do {
            return try await request(path: "v1/remote/sessions/\(try Self.sessionPath(id))", method: "DELETE",
                                     remoteOperation: true)
        } catch let error as RemoteRequestError where error.code == "session_not_found" {
            return RemoteReleaseDTO(released: true, errors: [])
        }
    }

    private struct RemoteSessionEnvelope: Decodable { let session: RemoteSessionDTO }
    private func remoteSession<Body: Encodable & Sendable>(path: String, method: String = "GET", body: Body? = nil) async throws -> RemoteSessionDTO {
        let envelope: RemoteSessionEnvelope = try await request(path: path, method: method, body: body, remoteOperation: true)
        return envelope.session
    }
    private func remoteSession(path: String) async throws -> RemoteSessionDTO {
        try await remoteSession(path: path, method: "GET", body: Optional<EmptyBody>.none)
    }
    private static func sessionPath(_ id: String) throws -> String {
        guard id.hasPrefix("rs_"), id.utf8.count <= 64, isSafeIdentifier(id) else {
            throw RemoteRequestError(code: "invalid_request", status: 400)
        }
        return id
    }

    // MARK: - Agent chat

    func prepareChatHandoff() async throws -> AgentChatHandoffPlan {
        try await request(path: "v1/agent/default/chat/handoff:prepare", method: "POST", body: EmptyBody())
    }
    func confirmChatHandoff(planID: String) async throws -> AgentChatHandoffResult {
        struct Body: Encodable { let plan_id: String; let confirmed = true }
        return try await request(path: "v1/agent/default/chat/handoff:confirm", method: "POST", body: Body(plan_id: planID))
    }
    func chatSlashCommands() async throws -> AgentSlashCatalog {
        try await request(path: "v1/agent/default/chat/commands")
    }
    func chatExecuteSlash(id: String, revision: String, arguments: String, requestID: UUID) async throws -> AgentSlashResult {
        guard Self.isSafeIdentifier(id) else { throw AgentChatHostError(code: "slash_commands_unavailable") }
        struct Body: Encodable { let revision: String; let arguments: String; let request_id: String }
        struct Response: Decodable {
            struct Result: Decodable { let summary: String? }
            struct Native: Decodable { let action: String; let arguments: String }
            let status: String; let command_id: String; let result: Result?; let native_request: Native?
        }
        let value: Response = try await request(path: "v1/agent/default/chat/commands/\(id):execute", method: "POST",
            body: Body(revision: revision, arguments: arguments, request_id: requestID.uuidString))
        return .init(status: value.status, commandID: value.command_id, message: value.result?.summary,
                     nativeRequest: value.native_request.map { .init(action: $0.action, arguments: $0.arguments) })
    }
    func ensureChat() async throws -> AgentChatSnapshot {
        struct Body: Encodable { let surface = "chat" }
        struct Response: Decodable { let snapshot: AgentChatSnapshotWire }
        let value: Response = try await request(path: "v1/agent/default:ensure", method: "POST", body: Body())
        return try value.snapshot.value()
    }
    func chatSnapshot() async throws -> AgentChatSnapshot {
        let value: AgentChatSnapshotWire = try await request(path: "v1/agent/default/chat")
        return try value.value()
    }
    /// `model` and `effort` are per-turn overrides; codex has no setter for
    /// them, so they ride the message and `thread/settings/updated` confirms
    /// what landed (`omodachi-core/docs/agent.md`).
    func chatSend(_ text: String, id: UUID, model: String? = nil, effort: String? = nil) async throws {
        struct Body: Encodable { let request_id: String; let text: String; let model: String?; let effort: String? }
        let _: EmptyResponse = try await request(path: "v1/agent/default/chat/messages", method: "POST",
                                                 body: Body(request_id: id.uuidString, text: text,
                                                            model: model, effort: effort))
    }
    func chatSteer(_ text: String, id: UUID) async throws {
        struct Body: Encodable { let request_id: String; let text: String }
        let _: EmptyResponse = try await request(path: "v1/agent/default/chat/steer", method: "POST",
                                                 body: Body(request_id: id.uuidString, text: text))
    }
    func chatInterrupt(_ turn: String) async throws {
        struct Body: Encodable { let turn_id: String }
        let _: EmptyResponse = try await request(path: "v1/agent/default/chat/interrupt", method: "POST", body: Body(turn_id: turn))
    }
    func chatApprovals() async throws -> [AgentChatApproval] {
        struct Response: Decodable { let requests: [AgentChatApprovalWire] }
        let value: Response = try await request(path: "v1/agent/default/chat/approvals")
        return value.requests.map { $0.value() }
    }
    /// Exactly one of `decision` and `input`, which is what the host accepts.
    /// The request id is the provider's own handle, so it is checked for shape
    /// before it becomes part of a path.
    func chatResolveApproval(requestID: String, decision: String?,
                             input: [String: [String]]?) async throws -> AgentChatApprovalResolution {
        guard Self.isSafeIdentifier(requestID), (decision == nil) != (input == nil) else {
            throw AgentChatHostError(code: "agent_approval_decision_invalid")
        }
        // The host refuses a body carrying both keys, so the two answers are
        // two bodies rather than one with a null in it.
        struct DecisionBody: Encodable { let decision: String }
        struct InputBody: Encodable { let input: [String: [String]] }
        struct Response: Decodable { let request_id: String; let kind: String?; let decision: String?; let resolved: Bool? }
        let path = "v1/agent/default/chat/approvals/\(requestID)"
        let value: Response
        if let decision { value = try await request(path: path, method: "POST", body: DecisionBody(decision: decision)) }
        else { value = try await request(path: path, method: "POST", body: InputBody(input: input ?? [:])) }
        return .init(requestID: value.request_id, kind: value.kind ?? "",
                     decision: value.decision ?? decision ?? "input", resolved: value.resolved ?? false)
    }
    func chatUsage() async throws -> AgentChatUsage {
        struct Response: Decodable { let usage: AgentChatUsageWire? }
        let value: Response = try await request(path: "v1/agent/default/chat/usage")
        return value.usage?.value() ?? .empty
    }
    func chatModels() async throws -> AgentModelCatalog {
        try await request(path: "v1/agent/default/models")
    }
    func chatEvents(identity: AgentChatIdentity, after sequence: Int) throws -> AsyncThrowingStream<AgentChatEnvelope, Error> {
        let ws = try socketTask(path: "v1/agent/default/chat/events", query: [], maximumMessageSize: 1_048_576)
        return AsyncThrowingStream { continuation in
            let reader = Task {
                ws.resume()
                defer { ws.cancel(with: .goingAway, reason: nil) }
                do {
                    while !Task.isCancelled {
                        let data = try Self.payload(of: try await ws.receive())
                        if let first = try? JSONDecoder().decode(ChatSnapshotEnvelope.self, from: data) {
                            guard first.snapshot.identity == identity else { throw AgentChatFailure.identityChanged }
                            continuation.yield(.init(identity: identity, sequence: first.snapshot.sequence, snapshot: try first.snapshot.value()))
                            continue
                        }
                        // `{"type": "resync_required"}` — the host dropped its
                        // own backlog and is asking to be read again.
                        if let frame = try? JSONDecoder().decode(ChatControlFrame.self, from: data),
                           frame.type == "resync_required" {
                            continuation.yield(.init(identity: identity, sequence: 0, resyncRequired: true))
                            continuation.finish()
                            return
                        }
                        let event = try JSONDecoder().decode(AgentChatEventWire.self, from: data).value()
                        guard event.identity == identity else { throw AgentChatFailure.identityChanged }
                        if event.sequence > sequence { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in reader.cancel(); ws.cancel(with: .goingAway, reason: nil) }
        }
    }
    private struct ChatSnapshotEnvelope: Decodable { let snapshot: AgentChatSnapshotWire }
    private struct ChatControlFrame: Decodable { let type: String }
    /// The subscription wraps an event in `{"event": …}`; the same event read
    /// straight off a fixture is not wrapped. Both spellings are the same row.
    private struct EventFrame<Value: Decodable>: Decodable {
        struct Wrapped: Decodable { let payload: Value? }
        let event: Wrapped?
    }

    // MARK: - Audio

    /// Read-only readiness; supported/available are distinct from active capture.
    func audioInputCapability() async throws -> CompanionAudioInputCapability {
        try await request(path: "v1/audio/input")
    }
    /// Audio-only socket factory. Opening is deferred until explicit mic enable.
    func makeAudioSocket(sessionID: String) throws -> URLSessionWebSocketTask {
        try socketTask(path: "v1/remote/sessions/\(try Self.sessionPath(sessionID))/audio", query: [], maximumMessageSize: 4096)
    }

    // MARK: - Voice

    func voiceCapabilities() async throws -> VoiceCapabilities {
        try await request(path: "v1/voice/capabilities")
    }
    /// The same PCM contract as the Remote uplink on a socket that leases no
    /// screen: scenario 2 is "I am away from the machine and talking to the
    /// agent", and there is no stream in that picture (`docs/voice.md`).
    func makeVoiceUplinkSocket(levels: Bool) throws -> URLSessionWebSocketTask {
        try socketTask(path: "v1/voice/uplink",
                       query: levels ? [URLQueryItem(name: "levels", value: "1")] : [],
                       maximumMessageSize: 4096)
    }
    func startDictation(target: VoiceTarget) async throws -> VoiceDictationResult {
        struct Body: Encodable { let target: String }
        return try await request(path: "v1/voice/dictation:start", method: "POST", body: Body(target: target.rawValue))
    }
    func stopDictation(target: VoiceTarget) async throws -> VoiceDictationResult {
        struct Body: Encodable { let target: String }
        return try await request(path: "v1/voice/dictation:stop", method: "POST", body: Body(target: target.rawValue))
    }

    // MARK: - Notifications

    func notifications(since: String? = nil, limit: Int = HostNotificationList.limit) async throws -> HostNotificationPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let since, !since.isEmpty { query.append(URLQueryItem(name: "since", value: since)) }
        return try await request(path: "v1/notifications", query: query)
    }
    /// `invoke` fires the shell's own default action on the newest popup;
    /// `dismiss` takes one off screen. The id is the shell's file name, so its
    /// shape is checked before it becomes part of a path.
    func notificationAction(id: String, invoke: Bool) async throws -> HostNotificationActionResult {
        guard Self.isNotificationID(id) else { throw CompanionHostError.protocolError(message: Strings.hostErrorBadRequest) }
        return try await request(path: "v1/notifications/\(id):\(invoke ? "invoke" : "dismiss")",
                                 method: "POST", body: EmptyBody())
    }
    func notificationDND() async throws -> Bool {
        struct Response: Decodable { let dnd: Bool }
        let value: Response = try await request(path: "v1/notifications/dnd")
        return value.dnd
    }
    func setNotificationDND(_ enabled: Bool) async throws -> Bool {
        struct Body: Encodable { let enabled: Bool }
        struct Response: Decodable { let dnd: Bool }
        let value: Response = try await request(path: "v1/notifications/dnd", method: "POST", body: Body(enabled: enabled))
        return value.dnd
    }
    /// `<milliseconds>-<shell id>`, the same shape core's own route matches.
    static func isNotificationID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...16).contains(parts[0].count), (1...12).contains(parts[1].count) else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// The VNC byte bridge (`omodachi-core/docs/wayvnc.md`). The path comes from
    /// the host's own connection document and is re-derived here from the
    /// session ID rather than trusted verbatim, so a malformed document cannot
    /// aim this socket at another route on the host.
    func makeVNCSocket(path: String) throws -> URLSessionWebSocketTask {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5, parts[0] == "v1", parts[1] == "remote", parts[2] == "sessions",
              parts[4] == "vnc" else { throw RemoteRequestError(code: "invalid_request", status: 400) }
        return try socketTask(path: "v1/remote/sessions/\(try Self.sessionPath(parts[3]))/vnc",
                              query: [], maximumMessageSize: 1_048_576)
    }

    // MARK: - Sunshine (media) pairing

    /// The fork suspends its `getservercert` answer until the PIN, so the
    /// request UUID is otherwise invisible to the app: core matches it by this
    /// device's own client certificate fingerprint and nothing else.
    func discoverMediaPairing(fingerprint: String) async throws -> MediaPairingRequestDTO {
        struct Body: Encodable { let client_cert_sha256: String; let pairing_intent = true }
        return try await request(path: "v1/media/pairing/discover", method: "POST",
                                 body: Body(client_cert_sha256: fingerprint), mediaOperation: true)
    }
    /// The PIN is spent once; a repeated submission is the same attempt.
    func submitMediaPairing(requestID: String, fingerprint: String, pin: String) async throws -> MediaPairingAttemptDTO {
        struct Body: Encodable { let request_id: String; let client_cert_sha256: String; let pin: String }
        return try await request(path: "v1/media/pairing/requests", method: "POST",
                                 body: Body(request_id: requestID, client_cert_sha256: fingerprint, pin: pin),
                                 mediaOperation: true)
    }
    func mediaPairingStatus(attemptID: String) async throws -> MediaPairingAttemptDTO {
        try await request(path: "v1/media/pairing/requests/\(try Self.attemptPath(attemptID))", mediaOperation: true)
    }
    func cancelMediaPairing(attemptID: String) async throws -> MediaPairingAttemptDTO {
        try await request(path: "v1/media/pairing/requests/\(try Self.attemptPath(attemptID))", method: "DELETE",
                          body: EmptyBody(), mediaOperation: true)
    }
    private static func attemptPath(_ id: String) throws -> String {
        guard id.utf8.count == 36, isSafeIdentifier(id) else {
            throw RemoteRequestError(code: "invalid_request", status: 400)
        }
        return id
    }

    // MARK: - Events

    /// A stream of redacted events. The client keeps no replay ring and detects
    /// no instance substitution: on any break it re-reads `GET /v1/state` and
    /// resubscribes from that snapshot's `event_cursor`.
    public func events(since: Int = 0, instanceID: String? = nil) -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        let id = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let receiver = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await self.receiveEvents(since: max(0, since), instanceID: instanceID, id: id, continuation: continuation)
                    continuation.finish()
                }
                catch is CancellationError { continuation.finish() }
                catch let error as CompanionHostError { continuation.finish(throwing: error) }
                catch { continuation.finish(throwing: CompanionHostError.transport(message: Strings.hostErrorEventStreamEnded)) }
            }
            continuation.onTermination = { [weak self] _ in
                receiver.cancel()
                Task { await self?.stopSocket(id: id) }
            }
        }
    }

    private func receiveEvents(since: Int, instanceID: String?,
                               id: UUID, continuation: AsyncThrowingStream<SanitizedHostEvent, Error>.Continuation) async throws {
        try Task.checkCancellation()
        socket?.cancel(with: .goingAway, reason: nil)
        var query = [URLQueryItem(name: "since", value: String(since))]
        if let instanceID { query.append(URLQueryItem(name: "instance_id", value: instanceID)) }
        let task = try socketTask(path: "v1/events", query: query, maximumMessageSize: 1_048_576)
        socket = task; socketID = id
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if socketID == id { socket = nil; socketID = nil }
        }
        while !Task.isCancelled {
            let data = try Self.payload(of: try await task.receive())
            let event: SanitizedHostEvent
            do { event = try Self.decodeEvent(data) }
            catch { throw CompanionHostError.decoding(message: Strings.hostErrorInvalidEvent) }
            switch continuation.yield(event) {
            case .enqueued where !event.needsResync: continue
            default: return
            }
        }
    }

    private func stopSocket(id: UUID) {
        guard socketID == id else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil; socketID = nil
    }

    /// `snapshot` and `ready` are subscription frames; everything else is an
    /// ordinary event. `resync.required` (or a `snapshot_required` payload) asks
    /// the client to re-read state, which is the only recovery this client has.
    static func decodeEvent(_ data: Data) throws -> SanitizedHostEvent {
        // Other events reuse these key names with other types — `bar.changed`
        // carries a hex `revision` string, for one — so every field is read
        // leniently. A frame whose payload does not fit is still an event.
        struct Payload: Decodable {
            let snapshot_required: Bool?
            let session_id: String?
            let revision: Int?
            let view: String?
            enum CodingKeys: String, CodingKey { case snapshot_required, session_id, revision, view }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                snapshot_required = try? c.decodeIfPresent(Bool.self, forKey: .snapshot_required)
                session_id = try? c.decodeIfPresent(String.self, forKey: .session_id)
                revision = try? c.decodeIfPresent(Int.self, forKey: .revision)
                view = try? c.decodeIfPresent(String.self, forKey: .view)
            }
        }
        struct Wire: Decodable { let seq: Int?; let event_id: String; let type: String; let payload: Payload? }
        struct Frame: Decodable {
            let type: String?
            let instance_id: String?
            let cursor: Int?
            let state: HostStateDTO?
            let event: Wire?
        }
        let frame = try JSONDecoder().decode(Frame.self, from: data)
        if let type = frame.type, type == "snapshot" || type == "ready" {
            guard let instanceID = frame.instance_id, !instanceID.isEmpty, instanceID.utf8.count <= 128,
                  let cursor = frame.cursor, cursor >= 0, type != "snapshot" || frame.state != nil else {
                throw CompanionHostError.decoding(message: Strings.hostErrorInvalidEvent)
            }
            return SanitizedHostEvent(sequence: cursor, eventID: "\(type)-\(instanceID)-\(cursor)", type: type,
                                      instanceID: instanceID, snapshot: frame.state, needsResync: false)
        }
        let wire = try frame.event ?? JSONDecoder().decode(Wire.self, from: data)
        guard !wire.event_id.isEmpty, wire.event_id.utf8.count <= 256,
              !wire.type.isEmpty, wire.type.utf8.count <= 128 else {
            throw CompanionHostError.decoding(message: Strings.hostErrorInvalidEvent)
        }
        var summon: PanelSummon?
        // An unknown `view` is not silently downgraded to the root panel; core
        // refuses one at the boundary, so a frame carrying one is not ours.
        if wire.type == "panel.summon", let payload = wire.payload,
           let sessionID = payload.session_id, sessionID.hasPrefix("rs_"), sessionID.utf8.count <= 64,
           let revision = payload.revision,
           let view = PanelSummon.View(rawValue: payload.view ?? "overview") {
            summon = PanelSummon(sessionID: sessionID, revision: revision, view: view)
        }
        // Two events carry a payload the client reads rather than treating as
        // "the snapshot is stale": a mirrored notification, and a transcript.
        var notification: HostNotification?
        var transcript: VoiceTranscriptEvent?
        if wire.type == "notification.posted" || wire.type == "voice.transcript" {
            struct Typed<Value: Decodable>: Decodable { let payload: Value? }
            if wire.type == "notification.posted" {
                notification = (try? JSONDecoder().decode(Typed<HostNotification>.self, from: data))?.payload
                    ?? (try? JSONDecoder().decode(EventFrame<HostNotification>.self, from: data))?.event?.payload
            } else {
                transcript = (try? JSONDecoder().decode(Typed<VoiceTranscriptEvent>.self, from: data))?.payload
                    ?? (try? JSONDecoder().decode(EventFrame<VoiceTranscriptEvent>.self, from: data))?.event?.payload
            }
        }
        // AUTH-1's two events carry their whole payload for the same reason a
        // notification does: there is nothing to go back and read. An approval
        // exists for its timeout and is then gone.
        var approvalRequest: HostApprovalRequest?
        var approvalResolution: HostApprovalResolution?
        if wire.type == "auth.approval.requested" {
            struct Typed<Value: Decodable>: Decodable { let payload: Value? }
            let decoded = (try? JSONDecoder().decode(Typed<HostApprovalRequest>.self, from: data))?.payload
                ?? (try? JSONDecoder().decode(EventFrame<HostApprovalRequest>.self, from: data))?.event?.payload
            // A malformed approval is not an approval. Dropping it costs the
            // user a password prompt; acting on it would mean raising a Face ID
            // sheet for something this client could not describe.
            approvalRequest = (decoded?.isWellFormed ?? false) ? decoded : nil
        } else if wire.type == "auth.approval.resolved" {
            struct Typed<Value: Decodable>: Decodable { let payload: Value? }
            approvalResolution = (try? JSONDecoder().decode(Typed<HostApprovalResolution>.self, from: data))?.payload
                ?? (try? JSONDecoder().decode(EventFrame<HostApprovalResolution>.self, from: data))?.event?.payload
        }
        // REMOTE-4. `remote.session.changed` still marks the snapshot stale for
        // everyone else; the session's own client also needs the reason, and
        // `host_reconfigured` in particular, because a backend core rebuilt
        // under a live session is a reconnect and not an ending.
        var remoteSession: RemoteSessionChange?
        if wire.type == "remote.session.changed" {
            struct Change: Decodable {
                let id: String?; let revision: Int?; let state: String?; let reason: String?
            }
            struct Typed: Decodable { let payload: Change? }
            let payload = (try? JSONDecoder().decode(Typed.self, from: data))?.payload
                ?? (try? JSONDecoder().decode(EventFrame<Change>.self, from: data))?.event?.payload
            if let payload, let id = payload.id, id.hasPrefix("rs_"), id.utf8.count <= 64,
               let revision = payload.revision, revision >= 0 {
                remoteSession = RemoteSessionChange(id: id, revision: revision,
                                                    state: payload.state ?? "", reason: payload.reason)
            }
        }
        return SanitizedHostEvent(sequence: wire.seq, eventID: wire.event_id, type: wire.type,
                                  instanceID: frame.instance_id, snapshot: nil,
                                  needsResync: wire.type == "resync.required" || wire.payload?.snapshot_required == true,
                                  panelSummon: summon, notification: notification, transcript: transcript,
                                  approvalRequest: approvalRequest, approvalResolution: approvalResolution,
                                  remoteSession: remoteSession)
    }

    // MARK: - Transport

    private func socketTask(path: String, query: [URLQueryItem], maximumMessageSize: Int) throws -> URLSessionWebSocketTask {
        guard let token = bearerToken, !token.isEmpty else { throw CompanionHostError.notConnected }
        var components = URLComponents(url: configuration.endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw CompanionHostError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = sockets.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        return task
    }

    private static func payload(of message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .string(let text): Data(text.utf8)
        case .data(let value): value
        @unknown default: Data()
        }
    }

    private func request<T: Decodable>(path: String, method: String = "GET",
                                       remoteOperation: Bool = false, mediaOperation: Bool = false) async throws -> T {
        try await request(path: path, method: method, body: Optional<EmptyBody>.none,
                          remoteOperation: remoteOperation, mediaOperation: mediaOperation)
    }

    private func request<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: configuration.endpoint.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw CompanionHostError.invalidEndpoint }
        let (data, http) = try await send(URLRequest(url: url), method: "GET", limit: 8 * 1_048_576)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(status: http.statusCode, code: Self.errorCode(data))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CompanionHostError.decoding(message: Strings.hostErrorContractMismatch) }
    }

    /// A binary body — a wallpaper or a font file. `nil` means the host answered
    /// `304`: the digest the caller already holds is still current.
    private func bytes(path: String, knownDigest: String?, limit: Int) async throws -> Data? {
        var value = URLRequest(url: configuration.endpoint.appendingPathComponent(path))
        if let knownDigest, !knownDigest.isEmpty { value.setValue("\"\(knownDigest)\"", forHTTPHeaderField: "If-None-Match") }
        let (data, http) = try await send(value, method: "GET", limit: limit)
        if http.statusCode == 304 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(status: http.statusCode, code: Self.errorCode(data))
        }
        return data
    }

    private func send(_ value: URLRequest, method: String, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard let token = bearerToken, !token.isEmpty else { throw CompanionHostError.notConnected }
        var request = value
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= limit else {
                throw CompanionHostError.protocolError(message: Strings.hostErrorTooLarge)
            }
            guard let http = response as? HTTPURLResponse else {
                throw CompanionHostError.transport(message: Strings.hostErrorNotHTTP)
            }
            return (data, http)
        }
        catch let error as CompanionHostError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            if case let .certificateChanged(observed, pinned)? = tls.lastFailure {
                throw CompanionHostError.certificateChanged(observed: observed, pinned: pinned)
            }
            throw CompanionHostError.transport(message: Strings.hostErrorUnreachable)
        }
    }

    private func request<T: Decodable, Body: Encodable & Sendable>(
        path: String, method: String = "GET", body: Body?,
        remoteOperation: Bool = false, workspaceLayoutOperation: Bool = false,
        mediaOperation: Bool = false, herdrOperation: Bool = false) async throws -> T {
        guard let token = bearerToken, !token.isEmpty else { throw CompanionHostError.notConnected }
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoded = try JSONEncoder().encode(body)
            guard encoded.count <= 65536 else { throw CompanionHostError.protocolError(message: Strings.hostErrorTooLarge) }
            request.httpBody = encoded
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= 1_048_576 else { throw CompanionHostError.protocolError(message: Strings.hostErrorTooLarge) }
            guard let http = response as? HTTPURLResponse else { throw CompanionHostError.transport(message: Strings.hostErrorNotHTTP) }
            if mediaOperation || remoteOperation {
                RemotePairingTrace.http(path: path, status: http.statusCode,
                                        code: (200..<300).contains(http.statusCode) ? nil : Self.errorCode(data))
            }
            guard (200..<300).contains(http.statusCode) else {
                let code = Self.errorCode(data)
                if remoteOperation {
                    throw RemoteRequestError(code: code ?? "invalid_request", status: http.statusCode,
                                             owner: Self.sessionOwner(data))
                }
                if mediaOperation { throw MediaPairingError(code: code ?? "media_pairing_unavailable", status: http.statusCode) }
                if herdrOperation { throw HerdrRequestError(code: code ?? "herdr_unavailable", status: http.statusCode) }
                if workspaceLayoutOperation { throw WorkspaceLayoutRequestError(code: WorkspaceLayoutRequestError.safeCode(code)) }
                if path.hasPrefix("v1/agent/default/chat") || path == "v1/agent/default:ensure" {
                    throw AgentChatHostError(code: AgentChatHostError.safeCode(code))
                }
                throw Self.mapHTTPError(status: http.statusCode, code: code)
            }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw CompanionHostError.decoding(message: Strings.hostErrorContractMismatch) }
        }
        catch let error as AgentChatHostError { throw error }
        catch let error as WorkspaceLayoutRequestError { throw error }
        catch let error as RemoteRequestError { throw error }
        catch let error as MediaPairingError { throw error }
        catch let error as HerdrRequestError { throw error }
        catch let error as CompanionHostError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            if case let .certificateChanged(observed, pinned)? = tls.lastFailure {
                throw CompanionHostError.certificateChanged(observed: observed, pinned: pinned)
            }
            throw CompanionHostError.transport(message: Strings.hostErrorUnreachable)
        }
    }

    /// Error bodies can echo the user's own text. Decode only the bounded code
    /// and map it to local copy; never surface arbitrary response text.
    /// The bounded detail `409 remote_session_exists` carries. Every field is
    /// checked: a name is a label, never an identity, and a malformed one is
    /// dropped rather than shown.
    private static func sessionOwner(_ data: Data) -> RemoteRequestError.Owner? {
        struct Body: Decodable {
            struct Error: Decodable {
                struct Detail: Decodable {
                    let sessionID: String?
                    let ownerDeviceID: String?
                    let ownerDeviceName: String?
                    let mode: String?
                    let backend: String?
                    let startedAt: Int?
                    enum CodingKeys: String, CodingKey {
                        case sessionID = "session_id"
                        case ownerDeviceID = "owner_device_id", ownerDeviceName = "owner_device_name"
                        case mode, backend
                        case startedAt = "started_at"
                    }
                }
                let detail: Detail?
            }
            let error: Error?
        }
        guard let detail = (try? JSONDecoder().decode(Body.self, from: data))?.error?.detail,
              let id = detail.ownerDeviceID, isSafeIdentifier(id), id.utf8.count <= 128,
              let session = detail.sessionID, session.hasPrefix("rs_"), session.utf8.count <= 64,
              isSafeIdentifier(session) else { return nil }
        let name = detail.ownerDeviceName.flatMap {
            (1...80).contains($0.unicodeScalars.count)
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? $0 : nil
        }
        return RemoteRequestError.Owner(
            sessionID: session, deviceID: id, deviceName: name ?? id,
            mode: detail.mode.flatMap(RemoteMode.init(rawValue:)),
            backend: detail.backend.flatMap(RemoteBackend.init(rawValue:)),
            startedAt: detail.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    private static func errorCode(_ data: Data) -> String? {
        struct Body: Decodable {
            struct Detail: Decodable { let code: String? }
            let error: Detail?
            let code: String?
        }
        let decoded = try? JSONDecoder().decode(Body.self, from: data)
        guard let candidate = decoded?.error?.code ?? decoded?.code,
              candidate.utf8.count <= 64, isSafeIdentifier(candidate) else { return nil }
        return candidate
    }

    private static func mapHTTPError(status: Int, code: String?) -> CompanionHostError {
        if status == 401 || status == 403 { return .unauthorized }
        switch code {
        case "busy", "locked", "blocked", "agent_busy", "agent_blocked":
            return .blocked(code: code, message: ReasonText.message("agent_busy", domain: .agent))
        case "agent_kind_unsupported", "agent_kind_mismatch":
            return .mismatch(code: code, message: ReasonText.message("agent_kind_mismatch", domain: .agent))
        case "stale_target", "stale_catalog_revision", "menu_action_changed":
            return .staleTarget(message: ReasonText.message("stale_catalog_revision", domain: .host))
        case "remote_session_required":
            return .blocked(code: code, message: ReasonText.message("remote_session_required", domain: .remote))
        case "default_agent_unset":
            return .unavailable(code: code, message: ReasonText.message("default_agent_unset", domain: .agent))
        case "rate_limited":
            return .blocked(code: code, message: ReasonText.message("rate_limited", domain: .host))
        default:
            return .unavailable(code: code, message: ReasonText.message(code ?? "unavailable", domain: .host))
        }
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46, 95, 45].contains($0)
        }
    }
}

public enum CompanionParameter: Encodable, Equatable, Sendable {
    case string(String), integer(Int), boolean(Bool)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }
}

struct EmptyBody: Encodable, Sendable {}
struct EmptyResponse: Decodable, Sendable {}
