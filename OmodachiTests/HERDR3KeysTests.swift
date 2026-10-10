import XCTest
@testable import Omodachi

/// HERDR-3: keys, typing and handing the pane back, with no host in the room.
/// The key names are Herdr's grammar as probed on herdr 0.8.2; the replies
/// are core's own fixtures (`herdr-keys.json`, `herdr-text*.json`).
@MainActor
final class HERDR3KeysTests: XCTestCase {
    private func fixtures() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["OMODACHI_CORE_FIXTURES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CoreFixtures", withExtension: nil))
    }

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: fixtures().appendingPathComponent(name)))
    }

    private func layout() throws -> HerdrLayoutDTO { try fixture("herdr-layout.json", as: HerdrLayoutDTO.self) }

    // MARK: - The keys row

    func testTheKeysRowIsTheSpecsKeysInHerdrsOwnNames() {
        XCTAssertEqual(HerdrKeyCap.row.map(\.key),
                       ["Escape", "Tab", "shift+Tab", "Enter", "Space", "Up", "Down", "Left", "Right",
                        "Backspace", "ctrl+c", "ctrl+d", "1", "2", "3", "4", "5"])
        XCTAssertEqual(Set(HerdrKeyCap.row.map(\.id)).count, HerdrKeyCap.row.count, "identifiers are unique")
        XCTAssertEqual(HerdrKeyCap.row.filter(\.repeats).map(\.key), ["Up", "Down", "Left", "Right", "Backspace"],
                       "only the arrows and ⌫ repeat while held (HERDR-9 added ⌫)")
        // Herdr has none of these; the row never offers one.
        for missing in ["PageUp", "PageDown", "Home", "End", "Insert", "Delete"] {
            XCTAssertFalse(HerdrKeyCap.row.contains { $0.key == missing })
        }
    }

    func testEveryKeyCapHasASpokenNameInBothLanguagesWorth() {
        for cap in HerdrKeyCap.row {
            XCTAssertFalse(HerdrControlBar.spoken(cap).isEmpty, cap.id)
        }
        XCTAssertEqual(HerdrControlBar.spoken(HerdrKeyCap.row[0]), Strings.herdrKeyEscape)
    }

    // MARK: - Type mode: PTY bytes back into Herdr's key names

    private func keys(_ bytes: [UInt8]) -> [HerdrWrite] { HerdrKeyEncoder.writes(from: bytes).writes }

    func testTheSoftAndHardwareKeyboardsBytesBecomeHerdrKeys() {
        XCTAssertEqual(keys(Array("a".utf8)), [.keys(["a"])])
        XCTAssertEqual(keys([0x0d]), [.keys(["Enter"])])
        XCTAssertEqual(keys([0x1b]), [.keys(["Escape"])])
        XCTAssertEqual(keys([0x09]), [.keys(["Tab"])])
        XCTAssertEqual(keys([0x7f]), [.keys(["Backspace"])])
        XCTAssertEqual(keys([0x20]), [.keys(["Space"])])
        XCTAssertEqual(keys([0x03]), [.keys(["ctrl+c"])])
        XCTAssertEqual(keys([0x04]), [.keys(["ctrl+d"])])
        XCTAssertEqual(keys([0x1b, 0x5b, 0x41]), [.keys(["Up"])])
        XCTAssertEqual(keys([0x1b, 0x4f, 0x42]), [.keys(["Down"])], "application cursor mode")
        XCTAssertEqual(keys([0x1b, 0x5b, 0x5a]), [.keys(["shift+Tab"])])
        XCTAssertEqual(keys([0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44]), [.keys(["ctrl+Left"])])
        XCTAssertEqual(keys([0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x41]), [.keys(["shift+Up"])])
        XCTAssertEqual(keys([0x1b, 0x4f, 0x50]), [.keys(["F1"])])
        XCTAssertEqual(keys(Array("\u{1b}[15~".utf8)), [.keys(["F5"])])
        XCTAssertEqual(keys(Array("\u{1b}[24~".utf8)), [.keys(["F12"])])
        XCTAssertEqual(keys([0x1b, 0x66]), [.keys(["alt+f"])])
        XCTAssertEqual(keys(Array("é".utf8)), [.keys(["é"])])
    }

    func testOrderIsKeptAndKeysGoInOneRequestPerTick() {
        XCTAssertEqual(keys(Array("ls -la\r".utf8)), [.keys(["l", "s", "Space", "-", "l", "a", "Enter"])])
        XCTAssertEqual(keys([0x1b, 0x5b, 0x42, 0x1b, 0x5b, 0x42, 0x32, 0x0d]), [.keys(["Down", "Down", "2", "Enter"])])
    }

    /// A paste or a dictated phrase is one `/text`, in its place between keys.
    func testALongRunOfTextIsSentAsTextInOrder() {
        let pasted = "please look at the failing test"
        XCTAssertEqual(keys(Array((pasted + "\r").utf8)), [.text(pasted, submit: false), .keys(["Enter"])])
        XCTAssertEqual(keys(Array("👩‍👧‍👦".utf8)), [.text("👩‍👧‍👦", submit: false)],
                       "a character Herdr cannot take as one key goes as text")
        XCTAssertEqual(keys(Array("\u{1b}[A".utf8) + Array("hello there friend".utf8)),
                       [.keys(["Up"]), .text("hello there friend", submit: false)])
    }

    func testMoreThanThirtyTwoKeysAreSplitIntoCallsCoreAccepts() {
        let bytes = [UInt8](repeating: 0x0d, count: 40)
        XCTAssertEqual(keys(bytes), [.keys(Array(repeating: "Enter", count: 32)),
                                     .keys(Array(repeating: "Enter", count: 8))])
    }

    /// Home, End and PageUp have no name in Herdr: dropped and counted, so the
    /// surface can say why nothing happened instead of sending something else.
    func testKeysHerdrCannotSendAreDroppedAndCounted() {
        let result = HerdrKeyEncoder.writes(from: Array("\u{1b}[H\u{1b}[5~a".utf8))
        XCTAssertEqual(result.writes, [.keys(["a"])])
        XCTAssertEqual(result.dropped, 2)
    }

    // MARK: - core's replies

    func testCoresKeysAndTextFixturesDecode() throws {
        let sent = try fixture("herdr-keys.json", as: HerdrKeysResultDTO.self)
        XCTAssertEqual(sent, HerdrKeysResultDTO(action: "keys", pane: "w1:p2", sent: 3))
        let text = try fixture("herdr-text.json", as: HerdrTextResultDTO.self)
        XCTAssertTrue(text.delivered)
        XCTAssertTrue(text.submitted)
        XCTAssertNil(text.reason)
        let swallowed = try fixture("herdr-text-not-seen.json", as: HerdrTextResultDTO.self)
        XCTAssertFalse(swallowed.submitted)
        XCTAssertEqual(swallowed.reason, "not_seen")
    }

    /// Every code these routes can return is a sentence, never an identifier.
    func testEveryNewReasonIsASentenceInTheCatalog() {
        for code in ["not_seen", "submit_failed", "not_requested", "invalid_key", "herdr_key_unsupported",
                     "herdr_too_many_keys", "invalid_text", "herdr_text_too_long", "herdr_pane_gone"] {
            XCTAssertEqual(ReasonText.knownCodes[code], .herdr, code)
            let sentence = ReasonText.message(code, domain: .herdr)
            XCTAssertFalse(sentence.contains(code), "\(code) reached the screen as an identifier")
        }
        XCTAssertEqual(ReasonText.message("not_seen", domain: .herdr), Strings.reasonHerdrNotSeen)
    }

    func testTheRequestBodiesUseCoresFieldNames() throws {
        let text = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HerdrTextBody(text: "hi", submit: true)))
        XCTAssertEqual(text as? NSDictionary, ["text": "hi", "submit": true])
        let keys = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HerdrKeysBody(keys: ["Escape"])))
        XCTAssertEqual(keys as? NSDictionary, ["keys": ["Escape"]])
    }

    // MARK: - The routes

    private func client() throws -> CompanionHostClient {
        CompanionURLProtocol.storage.reset()
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [CompanionURLProtocol.self]
        return CompanionHostClient(
            configuration: try CompanionHostConfiguration(endpoint: XCTUnwrap(URL(string: "https://fixture.invalid:8443"))),
            credentials: FixtureCredential(), pinnedFingerprint: nil,
            session: URLSession(configuration: options))
    }

    func testKeysTextAndTabsReachTheirRoutes() async throws {
        let client = try client()
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/herdr/panes/w1:p2/keys",
                                         body: #"{"action":"keys","pane":"w1:p2","sent":1}"#)
        let sent = try await client.herdrKeys(pane: "w1:p2", keys: ["Escape"])
        XCTAssertEqual(sent.sent, 1)
        var request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/herdr/panes/w1:p2/keys")

        let swallowed = try String(decoding: Data(contentsOf: fixtures().appendingPathComponent("herdr-text-not-seen.json")),
                                   as: UTF8.self)
        CompanionURLProtocol.storage.set("/v1/herdr/panes/w1:p2/text", body: swallowed)
        let text = try await client.herdrText(pane: "w1:p2", text: "hello", submit: true)
        XCTAssertEqual(text.reason, "not_seen")
        XCTAssertEqual(CompanionURLProtocol.storage.requests.last?.url?.path, "/v1/herdr/panes/w1:p2/text")

        CompanionURLProtocol.storage.set("/v1/herdr/workspaces/w1/tabs", body: #"{"action":"create","workspace":"w1"}"#)
        _ = try await client.herdrNewTab(workspace: "w1")
        request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")

        CompanionURLProtocol.storage.set("/v1/herdr/workspaces/w1/tabs/w1:t2",
                                         body: #"{"action":"close","workspace":"w1"}"#)
        _ = try await client.herdrCloseTab(workspace: "w1", tab: "w1:t2")
        request = try XCTUnwrap(CompanionURLProtocol.storage.requests.last)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/herdr/workspaces/w1/tabs/w1:t2")
    }

    func testARefusedKeyComesBackAsHerdrsReason() async throws {
        let client = try client()
        try await client.connect()
        CompanionURLProtocol.storage.set("/v1/herdr/panes/w1:p2/keys", status: 400,
                                         body: #"{"error":{"code":"herdr_key_unsupported","message":"x"}}"#)
        do {
            _ = try await client.herdrKeys(pane: "w1:p2", keys: ["Escape"])
            XCTFail("expected a refusal")
        } catch let error as HerdrRequestError {
            XCTAssertEqual(error.code, "herdr_key_unsupported")
            XCTAssertEqual(error.userMessage, Strings.reasonHerdrKeyUnsupported)
        }
    }

    func testImpossibleIdentifiersAndKeyCountsNeverLeaveTheDevice() async throws {
        let client = try client()
        try await client.connect()
        for call in [{ try await client.herdrKeys(pane: "w1:t1", keys: ["Enter"]) },
                     { try await client.herdrKeys(pane: "w1:p1", keys: []) },
                     { try await client.herdrKeys(pane: "w1:p1", keys: Array(repeating: "a", count: 33)) }] as
                [() async throws -> HerdrKeysResultDTO] {
            do { _ = try await call(); XCTFail("sent") } catch is CompanionHostError {}
        }
        do { _ = try await client.herdrCloseTab(workspace: "w1", tab: "w2:t1"); XCTFail("sent") }
        catch is CompanionHostError {}
        XCTAssertTrue(CompanionURLProtocol.storage.requests.isEmpty)
        XCTAssertTrue(CompanionHostClient.isHerdrTab("w1:t2"))
        XCTAssertFalse(CompanionHostClient.isHerdrTab("w1:p2"))
    }

    // MARK: - The More menu

    private func twoTabs() throws -> HerdrLayoutDTO {
        try JSONDecoder().decode(HerdrLayoutDTO.self, from: Data("""
        {"revision": 2, "workspaces": [{"id": "w1", "focused": true, "active_tab_id": "w1:t1", "tabs": [
          {"id": "w1:t1", "focused": true, "zoomed": false, "panes": [
            {"id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1", "title": "a", "focused": true,
             "zoomed": false, "agent": null, "revision": 1}]},
          {"id": "w1:t2", "focused": false, "zoomed": false, "panes": [
            {"id": "w1:p3", "tab_id": "w1:t2", "workspace_id": "w1", "title": "b", "focused": false,
             "zoomed": false, "agent": null, "revision": 1}]}]}]}
        """.utf8))
    }

    func testTheMenuIsTheRoutesWithText() throws {
        // HERDR-5 took out "Show on the computer", "Open in Agent" and "Take keyboard".
        // HERDR-13 took out split right, split down and zoom.
        XCTAssertEqual(HerdrControlAction.menu, [.newWorkspace, .newTab, .closeTab, .close])
        for action in HerdrControlAction.menu {
            XCTAssertFalse(action.title.isEmpty, action.rawValue)
        }
        XCTAssertFalse(HerdrControlAction.menu.contains(.previousPane), "‹ › read as arrow keys; the list moves")
        XCTAssertTrue(HerdrControlAction.closeTab.confirms)
        XCTAssertTrue(HerdrControlAction.close.confirms)
        XCTAssertFalse(HerdrControlAction.newTab.confirms)
    }

    func testCloseTabSaysWhyWhenItIsTheOnlyTabAndClosesTheRightOneOtherwise() throws {
        XCTAssertEqual(HerdrControlMapper.request(.closeTab, layout: try layout(), selected: "w1:p1"),
                       .unsupported(reason: Strings.herdrOnlyOneTab))
        let value = try twoTabs()
        XCTAssertEqual(HerdrControlMapper.request(.closeTab, layout: value, selected: "w1:p3"),
                       .closeTab(workspace: "w1", tab: "w1:t2"))
        // ⌘] goes across tabs, so one-agent-per-tab sessions can still be walked.
        XCTAssertEqual(HerdrControlMapper.request(.nextPane, layout: value, selected: "w1:p1"),
                       .select(pane: "w1:p3"))
    }

    // MARK: - The store

    private func demoHome() -> HomeStore {
        let defaults = UserDefaults(suiteName: "herdr3-\(UUID().uuidString)")!
        return HomeStore(defaults: defaults, clientFactory: { _, _ in HerdrNoService() }, autoConnect: false)
    }

    /// The mirror does not raise a keyboard on a tap; only Type lets it
    /// become first responder.
    func testTheMirrorTakesNoKeyboardUntilAskedTo() {
        let store = HerdrStore(home: demoHome())
        XCTAssertFalse(store.terminal.inputAllowed)
        XCTAssertFalse(store.terminal.canBecomeFirstResponder)
        XCTAssertFalse(store.typing)
    }

    /// With no pane there is nothing to type into, and the surface says so.
    func testTypeSaysWhyWithNoPane() {
        let store = HerdrStore(home: demoHome())
        store.startTyping()
        XCTAssertFalse(store.typing)
        XCTAssertEqual(store.notice, Strings.herdrNoSelectedPane)
        store.send(key: HerdrKeyCap.row[0])
        XCTAssertEqual(store.notice, Strings.herdrNoSelectedPane)
        XCTAssertEqual(store.keyTicks, 0)
    }

    func testDraftsAreKeptPerPaneAndOnlyInMemory() {
        let store = HerdrStore(home: demoHome())
        store.draft = "ignored with no pane"
        XCTAssertEqual(store.draft, "")
        XCTAssertFalse(store.canSendDraft)
    }

    func testTypingIdleLimitIsFiveMinutes() {
        XCTAssertEqual(HerdrStore.typingIdleLimit, .seconds(300))
        XCTAssertEqual(HerdrStore.maximumTextBytes, 16 * 1024)
    }
}

/// A host that is never reached: the store tests above stop before any call.
private struct HerdrNoService: CompanionServing {
    func connect() async throws { throw CompanionHostError.notConnected }
    func disconnect() async {}
    func fetchState() async throws -> HostStateDTO { throw CompanionHostError.notConnected }
    func fetchSnapshot() async throws -> CompanionSnapshot { throw CompanionHostError.notConnected }
    func invoke(entryID: String, catalogRevision: String, parameters: [String: CompanionParameter],
                targetToken: String?, stateRevision: Int?) async throws -> CompanionActionResponse {
        throw CompanionHostError.notConnected
    }
    func submitDefaultAgentTask(_ text: String, requestID: String) async throws -> AgentTaskResponse {
        throw CompanionHostError.notConnected
    }
    func events(since: Int, instanceID: String?) async -> AsyncThrowingStream<SanitizedHostEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
